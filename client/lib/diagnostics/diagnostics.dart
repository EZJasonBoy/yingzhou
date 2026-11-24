import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../ui/device_form.dart';
import 'crash_record.dart';
import 'diagnostics_store.dart';
import 'platform_stub.dart' if (dart.library.io) 'platform_io.dart' as host;
import 'redact.dart';

/// Crash records of this app: catches what nobody else caught and keeps it in the diagnostics folder, for the
/// diagnostics page to show (`diagnostics_page.dart`). Nothing leaves the device from here.
///
/// main.dart runs the app through [runGuarded], which hooks `FlutterError.onError` and
/// `PlatformDispatcher.instance.onError` and runs it in a guarded zone, so errors in widgets, unhandled
/// asynchronous errors and errors outside the zone all end up as records. The desktop engine's output goes to the same
/// folder (`local_engine_io.dart`); on Android, `CrashRecorder.kt` writes records of the app dying there.
class Diagnostics {
  /// Records in [store]; memory when none is given (nothing on disk).
  Diagnostics({DiagnosticsStore? store, String? appVersion, String? platform, List<String>? homes})
    : store = store ?? DiagnosticsStore.files(null),
      appVersion = appVersion ?? _buildVersion,
      _platform = platform ?? platformDescription(),
      homes = homes ?? homeFolders();

  /// The app's own: records in `<support>/diagnostics`.
  Diagnostics.forApp() : this(store: DiagnosticsStore.files(host.diagnosticsDirectory));

  /// The app's diagnostics; main.dart sets it in [runGuarded]. Tests may put their own here.
  static Diagnostics instance = Diagnostics();

  final DiagnosticsStore store;

  /// `0.4.0+5`, from pubspec.yaml (`flutter build` passes it as `FLUTTER_BUILD_NAME` / `FLUTTER_BUILD_NUMBER`).
  final String appVersion;

  /// The user's home folders, to take out of records and of what is shown.
  final List<String> homes;

  String _platform;

  /// The system this runs on (on Android, the version and the device model once its side answered).
  String get platform => _platform;

  /// Decides the device form named in records; main.dart sets it.
  DeviceFormController? deviceForm;

  /// At most this many new records per run; the rest is counted, not written.
  static const maxPerRun = 20;

  static const _buildName = String.fromEnvironment('FLUTTER_BUILD_NAME');
  static const _buildNumber = String.fromEnvironment('FLUTTER_BUILD_NUMBER');
  static String get _buildVersion => _buildName.isEmpty ? '未知' : (_buildNumber.isEmpty ? _buildName : '$_buildName+$_buildNumber');

  static String platformDescription() => host.describePlatform();
  static List<String> homeFolders() => host.homeFolders();

  /// The device form as records name it: `desktop`, `phone`, `tablet`, `tv`.
  String get formName {
    final controller = deviceForm;
    if (controller == null) return host.isDesktop ? DeviceForm.desktop.name : 'unknown';
    try {
      final view = PlatformDispatcher.instance.implicitView;
      final size = view == null || view.devicePixelRatio == 0 ? Size.zero : view.physicalSize / view.devicePixelRatio;
      return controller.formFor(size).name;
    } catch (_) {
      return 'unknown';
    }
  }

  /// Takes the user's home folder, tokens and addresses out of [text] (the subscription addresses in [secrets] too).
  String redact(String text, {Iterable<String> secrets = const []}) => Redactor(homes: homes, secrets: secrets).apply(text);

  // ---- catching ----

  FlutterExceptionHandler? _previousFlutter;
  bool Function(Object, StackTrace)? _previousPlatform;
  bool _installed = false;
  bool _recording = false;
  int _written = 0;
  int _dropped = 0;
  final _seen = <String, ({String? id, CrashRecord record, DateTime saved})>{};
  Future<void> _saving = Future.value();

  /// Runs the app: hooks the handlers on [diagnostics] (the app's own by default, which becomes [instance]) and runs
  /// [body] in a guarded zone, so the binding and `runApp` are in the same zone. Completes when [body] does.
  static Future<void> runGuarded(Future<void> Function() body, {Diagnostics? diagnostics}) {
    final d = instance = diagnostics ?? Diagnostics.forApp();
    d.install();
    final done = Completer<void>();
    runZonedGuarded(() async {
      try {
        await body();
        if (host.isAndroid) unawaited(d._askAndroid());
      } finally {
        if (!done.isCompleted) done.complete();
      }
    }, (error, stack) => d.record(CrashSource.zone, error, stack));
    return done.future;
  }

  /// Hooks `FlutterError.onError` and `PlatformDispatcher.instance.onError`; whatever was there before still runs.
  void install() {
    if (_installed) return;
    _installed = true;
    _previousFlutter = FlutterError.onError;
    FlutterError.onError = _onFlutterError;
    _previousPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = _onPlatformError;
  }

  /// Puts the handlers back (tests).
  void uninstall() {
    if (!_installed) return;
    _installed = false;
    FlutterError.onError = _previousFlutter;
    PlatformDispatcher.instance.onError = _previousPlatform;
  }

  void _onFlutterError(FlutterErrorDetails details) {
    // A poster that does not load is not a crash.
    if (!details.silent && details.library != 'image resource service') {
      final context = details.context?.toDescription();
      record(CrashSource.flutter, details.exception, details.stack, context: [?details.library, ?context].join('，'));
    }
    _previousFlutter?.call(details);
  }

  bool _onPlatformError(Object error, StackTrace stack) {
    record(CrashSource.platform, error, stack);
    final previous = _previousPlatform;
    if (previous != null) return previous(error, stack);
    if (kDebugMode) debugPrint('Unhandled error: $error\n$stack');
    return true;
  }

  /// Keeps a record of [error]. The same error again in this run only counts up on the first record. Never throws.
  void record(CrashSource source, Object error, StackTrace? stack, {String? context}) {
    if (_recording) return;
    _recording = true;
    try {
      if (source == CrashSource.zone && kDebugMode) debugPrint('Unhandled error: $error\n$stack');
      final description = [error.toString(), if (context != null && context.isNotEmpty) '（$context）'].join('\n');
      _keep(
        CrashRecord(
          time: DateTime.now(),
          version: appVersion,
          platform: platform,
          form: formName,
          source: source,
          error: redact(description),
          stack: redact(stack?.toString() ?? ''),
        ),
      );
    } catch (_) {
      // A crash record must never become a crash.
    } finally {
      _recording = false;
    }
  }

  /// The desktop engine process ended by itself with [exitCode]; [lastLines] is what it printed last.
  void recordEngineExit(int exitCode, List<String> lastLines) {
    try {
      _keep(
        CrashRecord(
          time: DateTime.now(),
          version: appVersion,
          platform: platform,
          form: formName,
          source: CrashSource.engine,
          error: '引擎进程退出了（退出码 $exitCode）',
          stack: redact(lastLines.join('\n')),
        ),
        origin: 'engine',
      );
    } catch (_) {
      // As above.
    }
  }

  void _keep(CrashRecord r, {String origin = 'dart'}) {
    final seen = _seen[r.signature];
    if (seen != null) {
      seen.record.repeated++;
      // Every time would be every frame for an error in build; once in a while is enough.
      if (DateTime.now().difference(seen.saved) < const Duration(seconds: 2)) return;
      _seen[r.signature] = (id: seen.id, record: seen.record, saved: DateTime.now());
      _save(seen.record, seen.id, origin);
      return;
    }
    if (_written >= maxPerRun) {
      _dropped++;
      return;
    }
    _written++;
    _seen[r.signature] = (id: null, record: r, saved: DateTime.now());
    _save(r, null, origin, onSaved: (id) => _seen[r.signature] = (id: id, record: r, saved: DateTime.now()));
  }

  void _save(CrashRecord r, String? id, String origin, {void Function(String? id)? onSaved}) {
    _saving = _saving
        .then((_) async {
          final saved = await store.save(r, id: id ?? _seen[r.signature]?.id, origin: origin);
          onSaved?.call(saved);
        })
        .catchError((Object _) {});
  }

  /// Waits until the records made so far are written (tests, and before showing the list).
  Future<void> flush() async {
    await _saving;
    await store.flush();
  }

  /// How many errors this run did not get a record of, because there were already [maxPerRun].
  int get dropped => _dropped;

  // ---- Android ----

  /// Android's own answer about the device, and the records its side has kept are already in the same folder.
  Future<void> _askAndroid() async {
    try {
      final info = await host.androidChannel.invokeMapMethod<String, Object?>('info');
      if (info == null) return;
      final model = [info['manufacturer'], info['model']].whereType<String>().where((s) => s.isNotEmpty).join(' ');
      _platform = 'Android ${info['release'] ?? ''} (API ${info['sdk'] ?? '?'})${model.isEmpty ? '' : ' · $model'}';
    } on PlatformException {
      // Keep the generic description.
    } on MissingPluginException {
      // An engine without the channel (tests).
    }
  }

  /// The last lines of this app's own log on Android (`logcat`), where the embedded engine writes; empty elsewhere.
  Future<String> androidLog({int lines = 300}) async {
    if (!host.isAndroid) return '';
    try {
      return await host.androidChannel.invokeMethod<String>('logcat', {'lines': lines}) ?? '';
    } on PlatformException {
      return '';
    } on MissingPluginException {
      return '';
    }
  }

  /// Opens a web address in the browser: [openUrlWithSystem] unless swapped (tests must never open a real browser).
  static Future<bool> Function(String url) openUrl = openUrlWithSystem;

  /// Opens [url] in the browser: a process on desktop, an intent on Android. False when there is nothing to open it
  /// with (a TV without a browser).
  static Future<bool> openUrlWithSystem(String url) async {
    if (host.isDesktop) return host.openUrlOnDesktop(url);
    if (host.isAndroid) {
      try {
        return await host.androidChannel.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
      } on PlatformException {
        return false;
      } on MissingPluginException {
        return false;
      }
    }
    return false;
  }

  /// True on the desktop, where the bundled engine's output is kept.
  static bool get keepsEngineLog => host.isDesktop;

  static bool get onAndroid => host.isAndroid;
}
