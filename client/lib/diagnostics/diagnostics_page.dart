import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../engine/source_diagnostic.dart';
import '../pages/cache_settings.dart' show formatFetchedAt;
import '../ui/device_form.dart';
import '../ui/phone_input.dart' show QrView;
import '../ui/tv/tv_focus.dart' show TvAutofocus, tvOwnFocusLook;
import 'crash_record.dart';
import 'dev_log.dart';
import 'diagnostics.dart';
import 'diagnostics_store.dart';
import 'feedback.dart';
import 'redact.dart';

/// Everything the diagnostics card and pages show is collected here and passed through [Diagnostics.redact], with
/// the subscription addresses the app knows of, before it reaches the screen or the clipboard.
class _Collected {
  _Collected(this.diagnostics, this.env, this.secrets);

  final Diagnostics diagnostics;
  final DiagnosticEnvironment env;
  final List<String> secrets;

  String redact(String text) => diagnostics.redactForSharing(text, secrets: secrets);

  late final _redactor = Redactor(homes: diagnostics.homes, secrets: secrets);

  CrashRecord shareRecord(CrashRecord record) => CrashRecord(
    time: record.time, version: record.version, platform: record.platform, form: record.form, source: record.source, repeated: record.repeated,
    error: _redactor.sharedError(record.error), stack: _redactor.sharedLog(record.stack),
  );

  static _Collected of(BuildContext context, Diagnostics d) {
    final state = context.getInheritedWidgetOfExactType<AppScope>()?.notifier;
    return _Collected(d, _environment(context, d, state), _secrets(state));
  }

  static DiagnosticEnvironment _environment(BuildContext context, Diagnostics d, AppState? state) {
    final info = state?.info;
    var engine = '未连接';
    if (state != null && info != null) {
      final host = Uri.tryParse(state.engineUrl)?.host ?? '';
      final where = host == '127.0.0.1' || host == 'localhost' || host == '::1'
          ? '本机'
          : state.engineOnLan
          ? '局域网里的另一台设备'
          : '远程';
      final can = ['jar', 'js', 'py', 'sniff'].where((name) => info.capabilities[name] == true);
      final name = info.name == 'tvbox-engine' ? info.name : '自定义引擎';
      final version = RegExp(r'^\d+(?:\.\d+){1,3}(?:\+\d+)?$').hasMatch(info.version) ? ' ${info.version}' : '';
      final platform = RegExp(r'^(?:jvm-)?(?:windows|linux|mac|macos|darwin|android|ios|test)$').hasMatch(info.platform) ? info.platform : '其他平台';
      engine = '$name$version（$platform，协议 v${info.protocol}${can.isEmpty ? '' : '，${can.join(' ')}'}）· $where';
    }
    return DiagnosticEnvironment(appVersion: d.appVersion, platform: d.platform, form: DeviceFormScope.of(context).name, engine: engine);
  }

  static List<String> _secrets(AppState? state) {
    if (state == null) return const [];
    final summary = state.summary;
    return [
      if (summary != null) ...[summary.url, summary.fetchedUrl, for (final r in summary.repos) r.url],
      for (final s in state.subscriptions) s.url,
    ];
  }

  /// The log that goes with the records: the desktop engine's output, Android's logcat of this app, or nothing.
  Future<(String, String)> log({int lines = 150}) async {
    if (Diagnostics.keepsEngineLog) return ('引擎日志', await diagnostics.store.engineLogTail(lines: lines));
    if (Diagnostics.onAndroid) return ('应用日志（logcat）', await diagnostics.androidLog(lines: lines));
    return ('日志', '');
  }

  /// 「复制诊断信息」 and the feedback page: redacted.
  Future<String> report() async {
    await diagnostics.flush();
    final records = [for (final r in await diagnostics.store.list()) shareRecord(r.record)];
    final (title, text) = await log();
    return redact(buildDiagnosticReport(env: env, records: records, logTitle: title, log: _redactor.sharedLog(text), sourceIssues: DevLog.instance.recentSourceIssues));
  }
}

class SourceReportButton extends StatelessWidget {
  const SourceReportButton({super.key, required this.issues});

  final Iterable<SourceDiagnostic> issues;

  static void open(BuildContext context, Iterable<SourceDiagnostic> issues) {
    final collected = _Collected.of(context, Diagnostics.instance);
    final env = collected.env;
    final text = collected.redact([
      '映舟 ${env.appVersion} · ${env.platformAndForm}',
      '引擎：${env.engine}',
      for (final issue in issues) '\n${issue.report}',
    ].join('\n'));
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DiagnosticTextPage(title: '源故障报告', text: text)));
  }

  @override
  Widget build(BuildContext context) => TextButton.icon(
    key: const Key('source-issue-report'),
    icon: const Icon(Icons.article_outlined, size: 18),
    label: const Text('查看故障报告'),
    onPressed: () => open(context, issues),
  );
}

Future<void> _copyReport(BuildContext context, Diagnostics d) async {
  final collected = _Collected.of(context, d);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final navigator = Navigator.of(context);
  final text = await collected.report();
  await Clipboard.setData(ClipboardData(text: text));
  messenger?.showSnackBar(
    SnackBar(
      content: const Text('已复制诊断信息（订阅地址、令牌、签名参数和用户目录已遮掉）'),
      action: SnackBarAction(
        label: '查看',
        onPressed: () => navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => DiagnosticTextPage(title: '诊断信息', text: text),
          ),
        ),
      ),
    ),
  );
}

void _openFeedback(BuildContext context, Diagnostics d) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FeedbackPage(diagnostics: d)));

const _privacyNote = '崩溃记录和日志只保存在这台设备上，映舟不会自己上传任何东西。复制或反馈时只保留排障字段，地址、请求头和未经识别的原始日志留在本机。';

/// 诊断与反馈: how many crash records there are, and the way to them, to 「复制诊断信息」 and to 「反馈问题」. Self-contained:
/// put it on any settings page.
class DiagnosticsSettings extends StatefulWidget {
  const DiagnosticsSettings({super.key, this.diagnostics});

  /// [Diagnostics.instance] when null.
  final Diagnostics? diagnostics;

  @override
  State<DiagnosticsSettings> createState() => _DiagnosticsSettingsState();
}

class _DiagnosticsSettingsState extends State<DiagnosticsSettings> {
  List<StoredRecord>? _records;

  Diagnostics get _d => widget.diagnostics ?? Diagnostics.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _d.flush();
    final records = await _d.store.list();
    if (mounted) setState(() => _records = records);
  }

  Future<void> _openPage() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DiagnosticsPage(diagnostics: _d)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final records = _records;
    final latest = records == null || records.isEmpty ? null : records.first.record;
    final status = records == null
        ? '正在读取…'
        : latest == null
        ? '没有崩溃记录'
        : '${records.length} 条崩溃记录，最近一次：${formatFetchedAt(latest.time.millisecondsSinceEpoch)} ${latest.source.label}';
    return Padding(
      key: const Key('diag-card'),
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('诊断与反馈', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
              const SizedBox(height: 10),
              Text(status, key: const Key('diag-status'), style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(_privacyNote, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonal(key: const Key('diag-open'), onPressed: _openPage, child: const Text('查看记录')),
                  OutlinedButton(key: const Key('diag-copy'), onPressed: () => _copyReport(context, _d), child: const Text('复制诊断信息')),
                  OutlinedButton(key: const Key('diag-feedback'), onPressed: () => _openFeedback(context, _d), child: const Text('反馈问题')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 诊断与反馈 page: this device and its engine, the crash records (open one to read it), the log, and the two actions.
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key, this.diagnostics});

  final Diagnostics? diagnostics;

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  List<StoredRecord>? _records;
  String? _location;

  Diagnostics get _d => widget.diagnostics ?? Diagnostics.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _d.flush();
    final records = await _d.store.list();
    final location = await _d.store.location();
    if (mounted) {
      setState(() {
        _records = records;
        _location = location;
      });
    }
  }

  Future<void> _openRecord(_Collected c, StoredRecord r) async {
    final text = await _d.store.read(r.id) ?? r.record.format();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiagnosticTextPage(title: '${r.record.source.label} · ${CrashRecord.formatTime(r.record.time)}', text: c.redact(text), shareText: c.redact(c.shareRecord(r.record).format())),
      ),
    );
  }

  Future<void> _openLog(_Collected c) async {
    final (title, text) = await c.log(lines: 400);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiagnosticTextPage(title: title, text: text.trim().isEmpty ? '（还没有内容）' : c.redact(text), shareText: text.trim().isEmpty ? null : c._redactor.sharedLog(text)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final c = _Collected.of(context, _d);
    final records = _records;
    final location = _location;
    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 6),
      child: Text(text, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('诊断与反馈')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              children: [
                header('这台设备'),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('映舟 ${c.env.appVersion}', key: const Key('diag-version'), style: theme.textTheme.titleMedium),
                        const SizedBox(height: 4),
                        Text(c.env.platformAndForm, key: const Key('diag-platform')),
                        Text('引擎：${c.env.engine}', key: const Key('diag-engine')),
                      ],
                    ),
                  ),
                ),
                header(records == null || records.isEmpty ? '崩溃记录' : '崩溃记录（${records.length} 条，保留最近 20 条）'),
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: records == null
                      ? const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator())
                      : records.isEmpty
                      ? const ListTile(key: Key('diag-no-records'), leading: Icon(Icons.check_circle_outline), title: Text('没有崩溃记录'))
                      : TvAutofocus(
                          child: Column(
                            children: [
                              for (final (i, r) in records.indexed)
                                ListTile(
                                  key: Key('diag-record-$i'),
                                  leading: Icon(r.record.source == CrashSource.engine ? Icons.dns_outlined : Icons.bug_report_outlined),
                                  title: Text(
                                    '${r.record.source.label} · ${formatFetchedAt(r.record.time.millisecondsSinceEpoch)}${r.record.repeated > 1 ? ' · ${r.record.repeated} 次' : ''}',
                                  ),
                                  subtitle: Text(c.redact(r.record.summary), maxLines: 2, overflow: TextOverflow.ellipsis),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () => _openRecord(c, r),
                                ),
                            ],
                          ),
                        ),
                ),
                if (Diagnostics.keepsEngineLog || Diagnostics.onAndroid) ...[
                  header('日志'),
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      key: const Key('diag-log'),
                      leading: const Icon(Icons.article_outlined),
                      title: Text(Diagnostics.keepsEngineLog ? '引擎日志' : '应用日志（logcat）'),
                      subtitle: Text(Diagnostics.keepsEngineLog ? '内置引擎的输出。引擎每次启动另起一个文件，保留最近 3 个，每个约 512 KB' : '这个应用自己的系统日志，内置引擎也写在这里'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _openLog(c),
                    ),
                  ),
                ],
                header('反馈'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      key: const Key('diag-page-copy'),
                      onPressed: () => _copyReport(context, _d),
                      icon: const Icon(Icons.copy_rounded),
                      label: const Text('复制诊断信息'),
                    ),
                    FilledButton.icon(
                      key: const Key('diag-page-feedback'),
                      onPressed: () => _openFeedback(context, _d),
                      icon: const Icon(Icons.feedback_outlined),
                      label: const Text('反馈问题'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(_privacyNote, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                if (location != null) ...[
                  const SizedBox(height: 4),
                  SelectableText(
                    '保存位置：${c.redact(location)}',
                    key: const Key('diag-location'),
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A record, the log or the diagnostic text, to read (and copy). On a TV the text takes the focus and ↑ / ↓ scroll it;
/// at either end the focus moves on to what is above or below.
class DiagnosticTextPage extends StatelessWidget {
  const DiagnosticTextPage({super.key, required this.title, required this.text, this.shareText});

  final String title;
  final String text;
  final String? shareText;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            key: const Key('diag-text-copy'),
            tooltip: '复制',
            icon: const Icon(Icons.copy_rounded),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: shareText ?? text));
              if (context.mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('已复制')));
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: ReadableText(text: text, autofocus: true),
        ),
      ),
    );
  }
}

/// Long monospace text in a scroll view. Off TV it is selectable; on a TV it is one focusable block scrolled with
/// ↑ / ↓ (a selectable text would take the arrows for its caret).
class ReadableText extends StatefulWidget {
  const ReadableText({super.key, required this.text, this.autofocus = false});

  final String text;
  final bool autofocus;

  @override
  State<ReadableText> createState() => _ReadableTextState();
}

class _ReadableTextState extends State<ReadableText> {
  final _scroll = ScrollController();
  final _focus = FocusNode(debugLabel: 'ReadableText');
  bool _focused = false;

  static const _step = 96.0;

  @override
  void initState() {
    super.initState();
    tvOwnFocusLook(_focus);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || !_scroll.hasClients) return KeyEventResult.ignored;
    final p = _scroll.position;
    double? to;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (p.pixels >= p.maxScrollExtent) return KeyEventResult.ignored;
      to = p.pixels + _step;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (p.pixels <= p.minScrollExtent) return KeyEventResult.ignored;
      to = p.pixels - _step;
    } else if (event.logicalKey == LogicalKeyboardKey.pageDown) {
      to = p.pixels + p.viewportDimension * 0.9;
    } else if (event.logicalKey == LogicalKeyboardKey.pageUp) {
      to = p.pixels - p.viewportDimension * 0.9;
    }
    if (to == null) return KeyEventResult.ignored;
    _scroll.jumpTo(to.clamp(p.minScrollExtent, p.maxScrollExtent));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Consolas', 'Menlo', 'monospace'],
      fontSize: isTv(context) ? 15 : 12.5,
      height: 1.4,
    );
    final tv = isTv(context);
    final content = tv ? Text(widget.text, key: const Key('diag-text'), style: style) : SelectableText(widget.text, key: const Key('diag-text'), style: style);
    return Focus(
      focusNode: _focus,
      autofocus: widget.autofocus && tv,
      canRequestFocus: tv,
      skipTraversal: !tv,
      onKeyEvent: _onKey,
      onFocusChange: (f) => setState(() => _focused = f),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _focused ? scheme.primary : scheme.outlineVariant, width: _focused ? 2 : 1),
        ),
        child: Scrollbar(
          controller: _scroll,
          child: SingleChildScrollView(controller: _scroll, padding: const EdgeInsets.all(12), child: content),
        ),
      ),
    );
  }
}

/// 反馈问题: the full text that would go into the new issue, then the way there. Nothing is sent from the app: the
/// button opens GitHub's new-issue form in the browser with the text filled in, and the user submits it there (or
/// not). On a TV, which often has no browser, a QR code takes the form to a phone.
class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key, this.diagnostics});

  final Diagnostics? diagnostics;


  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  String? _text;
  bool _openFailed = false;

  Diagnostics get _d => widget.diagnostics ?? Diagnostics.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final text = await _Collected.of(context, _d).report();
      if (mounted) setState(() => _text = text);
    });
  }

  Future<void> _open(_Collected c, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    final url = issueUrl(env: c.env, logs: text).toString();
    final ok = await Diagnostics.openUrl(url);
    if (!mounted) return;
    setState(() => _openFailed = !ok);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(ok ? '已在浏览器中打开 GitHub，诊断信息也复制到了剪贴板' : '这台设备上打不开浏览器，用手机扫下面的二维码')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final c = _Collected.of(context, _d);
    final text = _text;
    final tv = isTv(context);
    final showQr = text != null && (tv || _openFailed);
    final explain = Text(
      '下面是将要填进 GitHub 新问题的全部内容，订阅地址、令牌、签名参数和用户目录已经遮掉。'
      '映舟不会自己发送任何东西：点「在浏览器中打开」会打开 GitHub 的新问题页面并填好这些内容（太长时只填前面一部分，完整内容同时复制到剪贴板），'
      '你可以在那里修改、删减，写上遇到了什么问题，再自己提交；需要一个 GitHub 账号。不提交就不会有人看到。',
      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
    );
    final buttons = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.icon(
          key: const Key('feedback-open'),
          autofocus: tv,
          onPressed: text == null ? null : () => _open(c, text),
          icon: const Icon(Icons.open_in_browser_rounded),
          label: const Text('在浏览器中打开'),
        ),
        OutlinedButton.icon(
          key: const Key('feedback-copy'),
          onPressed: text == null
              ? null
              : () async {
                  await Clipboard.setData(ClipboardData(text: text));
                  if (context.mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('已复制')));
                },
          icon: const Icon(Icons.copy_rounded),
          label: const Text('复制全文'),
        ),
      ],
    );
    final qr = showQr
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              QrView(
                key: const Key('feedback-qr'),
                data: issueUrl(env: c.env, logs: text, maxLength: 600).toString(),
                size: tv ? 220 : 200,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  '用手机扫码，在手机上打开填好了设备信息的反馈页面。二维码装不下全部诊断信息，只带了开头一部分；'
                  '可以在手机上补充你看到的情况。',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          )
        : const SizedBox.shrink();
    return Scaffold(
      appBar: AppBar(title: const Text('反馈问题')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              explain,
              const SizedBox(height: 12),
              buttons,
              if (showQr) ...[const SizedBox(height: 12), qr],
              const SizedBox(height: 12),
              Expanded(
                child: text == null ? const Center(child: CircularProgressIndicator()) : ReadableText(text: text),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
