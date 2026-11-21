import 'package:flutter/widgets.dart';

import '../app_state.dart';
import '../settings.dart';
import 'release_info.dart';
import 'update_backend.dart';
import 'update_models.dart';

/// A package being saved by the app (desktop), or saved.
class UpdateDownload {
  UpdateDownload(this.asset, this.url);

  final ReleaseAsset asset;
  final String url;
  int received = 0;
  int total = 0;

  /// Where it was saved, once it was.
  String? path;

  /// Why it was not.
  String? error;
  bool cancelled = false;

  bool get running => path == null && error == null;

  /// 0..1; null when the size is not known.
  double? get fraction {
    final size = total > 0 ? total : asset.size;
    return size > 0 ? (received / size).clamp(0.0, 1.0) : null;
  }
}

/// Update checking for the whole app: the user's choices (kept on this device, not in the engine), the last
/// result, and a package being downloaded. One per [AppState] ([of]), shared by the settings card, the dialog and
/// the watcher that checks after start.
class UpdateService extends ChangeNotifier {
  UpdateService({required this._settings, UpdateBackend? backend, DateTime Function()? clock})
    : backend = backend ?? UpdateBackend(),
      _clock = clock ?? DateTime.now;

  final SettingsStore _settings;
  final UpdateBackend backend;
  final DateTime Function() _clock;

  static final _byState = Expando<UpdateService>();

  /// The service of the app [context] is in.
  static UpdateService of(BuildContext context) {
    final state = AppScope.read(context);
    return _byState[state] ??= UpdateService(settings: state.settings);
  }

  /// Puts [service] in place for [state] (tests: a fake backend).
  @visibleForTesting
  static void debugUse(AppState state, UpdateService service) => _byState[state] = service;

  static const _autoKey = 'update.auto';
  static const _proxyKey = 'update.proxy';
  static const _lastCheckKey = 'update.lastCheck';
  static const _notifiedKey = 'update.notified';

  /// How often the automatic check asks at most.
  static const interval = Duration(days: 1);

  bool get supported => backend.supported;

  /// Off by default: checking asks GitHub, a third party, so the user turns it on.
  bool get autoCheck => _settings.getString(_autoKey) == '1';

  Future<void> setAutoCheck(bool on) async {
    await _settings.setString(_autoKey, on ? '1' : '');
    notifyListeners();
  }

  /// `host:port` of the HTTP proxy update checks and downloads go through; '' for none.
  String get proxy => _settings.getString(_proxyKey) ?? '';

  /// Saves [text] as the proxy; false (nothing saved) when it is not `host:port`.
  Future<bool> setProxy(String text) async {
    final normalized = normalizeProxy(text);
    if (normalized == null) return false;
    await _settings.setString(_proxyKey, normalized);
    notifyListeners();
    return true;
  }

  DateTime? get lastCheckAt => DateTime.tryParse(_settings.getString(_lastCheckKey) ?? '');

  /// The newer version the user was last told about by the automatic check: not told again.
  String get notifiedVersion => _settings.getString(_notifiedKey) ?? '';

  Future<void> markNotified(String version) => _settings.setString(_notifiedKey, version);

  /// Whether the automatic check is on and a day has passed since the last check.
  bool get due {
    if (!supported || !autoCheck) return false;
    final last = lastCheckAt;
    return last == null || _clock().difference(last) >= interval || _clock().isBefore(last);
  }

  bool checking = false;

  /// The last check in this run of the app.
  UpdateCheckResult? last;

  /// A package being downloaded, or downloaded.
  UpdateDownload? download;

  /// The GitHub accelerating prefix of the engine [state] is connected to, when its switch is on.
  static String mirrorOf(AppState state) {
    final s = state.engineSettings;
    return s != null && s.githubProxy ? s.githubProxyPrefix : '';
  }

  /// Asks for `latest.json` now; null when a check is already running.
  Future<UpdateCheckResult?> check({String mirror = ''}) async {
    if (checking) return null;
    checking = true;
    notifyListeners();
    try {
      final result = await backend.check(mirror: mirror, proxy: proxy);
      last = result;
      // A check that got nothing (offline at start) is tried again at the next chance, not a day later.
      if (result.ok) await _settings.setString(_lastCheckKey, _clock().toIso8601String());
      return result;
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  /// The package of [release] for this device; null when it has none.
  ReleaseAsset? assetOf(ReleaseInfo release) => assetFor(release, backend.assetKeys);

  /// The address [asset] is downloaded from: the way the last check got through.
  String urlOf(ReleaseInfo release, ReleaseAsset asset) {
    final url = release.urlOf(asset);
    final result = last;
    return result != null && identical(result.release, release) ? result.routed(url) : url;
  }

  /// Saves [asset] in the downloads folder (desktop), through the proxy and the way the check got through.
  Future<void> startDownload(ReleaseInfo release, ReleaseAsset asset) async {
    if (download?.running ?? false) return;
    final d = download = UpdateDownload(asset, urlOf(release, asset));
    notifyListeners();
    var lastShown = 0;
    try {
      d.path = await backend.download(
        d.url,
        asset.name,
        proxy: proxy,
        expectedSize: asset.size,
        cancelled: () => d.cancelled,
        progress: (received, total) {
          d
            ..received = received
            ..total = total;
          // Not for every chunk.
          if (received - lastShown >= 256 * 1024 || received == total) {
            lastShown = received;
            notifyListeners();
          }
        },
      );
    } on Object catch (e) {
      d.error = backend.describe(e);
    }
    notifyListeners();
  }

  void cancelDownload() {
    final d = download;
    if (d == null || !d.running) return;
    d.cancelled = true;
    notifyListeners();
  }
}
