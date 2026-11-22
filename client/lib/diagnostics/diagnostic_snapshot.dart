import '../app_state.dart';
import 'diagnostics.dart';
import 'feedback.dart';

/// Where the engine the app uses runs, as the diagnostics name it.
enum EngineKind {
  /// In this app's own process: the Android app's engine.
  embedded,

  /// On this machine, beside the app: the desktop's bundled engine (or one the user started there).
  local,

  /// On another device: a NAS, a computer on the LAN, a server.
  remote;

  static EngineKind of(String engineUrl) {
    final host = Uri.tryParse(engineUrl)?.host ?? '';
    if (host != '127.0.0.1' && host != 'localhost' && host != '::1') return EngineKind.remote;
    return Diagnostics.onAndroid ? EngineKind.embedded : EngineKind.local;
  }
}

/// What the diagnostics show and send, put together in one place: the device and its engine, the subscription
/// addresses to take out, the log that goes with the records and the full diagnostic text. Whatever it hands out has
/// been through [Diagnostics.redact] with those addresses. Used by the 诊断与反馈 page (and 「复制诊断信息」) and by the
/// remote's `diag.*` commands (`remote_diagnostics.dart`), so a phone gets exactly what the page would show.
class DiagnosticSnapshot {
  DiagnosticSnapshot(this.diagnostics, this.env, this.secrets, {this.engineKind = EngineKind.local, this.engineVersion = ''});

  /// The diagnostics of [diagnostics] with what [state] knows (null: nothing is connected), in the layout [form].
  factory DiagnosticSnapshot.of(Diagnostics diagnostics, AppState? state, {required String form}) {
    final info = state?.info;
    var engine = '未连接';
    if (state != null && info != null) {
      final host = Uri.tryParse(state.engineUrl)?.host ?? '';
      final where = host == '127.0.0.1' || host == 'localhost' || host == '::1'
          ? '本机'
          : state.engineOnLan
          ? '局域网里的另一台设备'
          : '远程';
      final can = [
        for (final e in info.capabilities.entries)
          if (e.value) e.key,
      ];
      engine = '${info.name} ${info.version}（${info.platform}，协议 v${info.protocol}${can.isEmpty ? '' : '，${can.join(' ')}'}）· $where';
    }
    final summary = state?.summary;
    return DiagnosticSnapshot(
      diagnostics,
      DiagnosticEnvironment(appVersion: diagnostics.appVersion, platform: diagnostics.platform, form: form, engine: engine),
      [
        if (summary != null) ...[summary.url, summary.fetchedUrl, for (final r in summary.repos) r.url],
        for (final s in state?.subscriptions ?? const []) s.url,
      ],
      engineKind: state == null ? EngineKind.local : EngineKind.of(state.engineUrl),
      engineVersion: info?.version ?? '',
    );
  }

  final Diagnostics diagnostics;
  final DiagnosticEnvironment env;

  /// Subscription addresses the app knows of: they go entirely, wherever they show.
  final List<String> secrets;
  final EngineKind engineKind;
  final String engineVersion;

  String redact(String text) => diagnostics.redact(text, secrets: secrets);

  /// The log that goes with the records: the desktop engine's output, Android's logcat of this app, or nothing.
  /// Not redacted (the page redacts what it shows).
  Future<(String, String)> log({int lines = 150}) async {
    if (Diagnostics.keepsEngineLog) return ('引擎日志', await diagnostics.store.engineLogTail(lines: lines));
    if (Diagnostics.onAndroid) return ('应用日志（logcat）', await diagnostics.androidLog(lines: lines));
    return ('日志', '');
  }

  /// Whether there is output of the engine in use to show: the engine is this app's (bundled on a desktop, inside
  /// the app on Android), not one on another device.
  bool get hasEngineLog => engineKind != EngineKind.remote && (Diagnostics.keepsEngineLog || Diagnostics.onAndroid);

  /// The last [lines] lines of the engine's output, redacted, with what it is called; empty when [hasEngineLog] is
  /// false.
  Future<(String, String)> engineLog({int lines = 300}) async {
    if (!hasEngineLog) return ('', '');
    final (title, text) = await log(lines: lines);
    return (title, redact(text));
  }

  /// 「复制诊断信息」 and the feedback page: redacted.
  Future<String> report() async {
    await diagnostics.flush();
    final records = [for (final r in await diagnostics.store.list()) r.record];
    final (title, text) = await log();
    return redact(buildDiagnosticReport(env: env, records: records, logTitle: title, log: text));
  }
}
