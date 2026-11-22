import 'crash_record.dart';

/// Where 「反馈问题」 sends the user: a new issue on the project's GitHub, with the form in
/// `.github/ISSUE_TEMPLATE/bug_report.yml`. Its field ids are the query parameters below.
const issueBaseUrl = 'https://github.com/Sa1koro/yingzhou/issues/new';
const issueTemplate = 'bug_report.yml';

/// What the diagnostic text says about the device and the engine.
class DiagnosticEnvironment {
  const DiagnosticEnvironment({required this.appVersion, required this.platform, required this.form, required this.engine});

  final String appVersion;
  final String platform;

  /// `desktop`, `phone`, `tablet` or `tv`.
  final String form;

  /// `tvbox-engine 0.4.0（windows，协议 v1）· 本机`, or `未连接`.
  final String engine;

  static String formLabel(String form) => const {'desktop': '桌面', 'phone': '手机', 'tablet': '平板', 'tv': '电视'}[form] ?? form;

  String get platformAndForm => '$platform · ${formLabel(form)}';
}

/// 「复制诊断信息」: the device, the engine, the recent crash records and the last lines of the log, as plain text.
/// Not redacted here: the page passes it through `Diagnostics.redact` before it shows or copies it.
String buildDiagnosticReport({
  required DiagnosticEnvironment env,
  required List<CrashRecord> records,
  String logTitle = '引擎日志',
  String log = '',
  Iterable<String> sourceIssues = const [],
  DateTime? now,
  int maxRecords = 5,
  int maxStackLines = 40,
  int maxLogLines = 150,
}) {
  final b = StringBuffer()
    ..writeln('映舟诊断信息')
    ..writeln('应用版本：${env.appVersion}')
    ..writeln('系统：${env.platform}')
    ..writeln('设备形态：${DiagnosticEnvironment.formLabel(env.form)}（${env.form}）')
    ..writeln('引擎：${env.engine}')
    ..writeln('生成时间：${CrashRecord.formatTime(now ?? DateTime.now())}');
  if (sourceIssues.isNotEmpty) {
    b
      ..writeln()
      ..writeln('== 本次运行最近的源故障（新的在前）==')
      ..writeln(sourceIssues.join('\n'));
  }
  b
    ..writeln()
    ..writeln(
      records.isEmpty
          ? '== 崩溃记录：没有 =='
          : '== 最近的崩溃记录（${records.length > maxRecords ? '共 ${records.length} 条，这里是最新的 $maxRecords 条' : '${records.length} 条'}，新的在前）==',
    );
  for (final r in records.take(maxRecords)) {
    b
      ..writeln()
      ..writeln(
        '[${CrashRecord.formatTime(r.time)}] ${r.source.label}（${r.source.name}）${r.repeated > 1 ? ' · 重复 ${r.repeated} 次' : ''}'
        '${r.version != env.appVersion && r.version.isNotEmpty ? ' · 版本 ${r.version}' : ''}',
      )
      ..writeln(r.error.trimRight());
    final stack = r.stack.trimRight().split('\n');
    if (r.stack.trim().isNotEmpty) {
      b.writeln(stack.take(maxStackLines).join('\n'));
      if (stack.length > maxStackLines) b.writeln('…（还有 ${stack.length - maxStackLines} 行）');
    }
  }
  final lines = log.trimRight().isEmpty ? const <String>[] : log.trimRight().split('\n');
  b
    ..writeln()
    ..writeln(lines.isEmpty ? '== $logTitle：没有 ==' : '== $logTitle（最后 ${lines.length > maxLogLines ? maxLogLines : lines.length} 行）==');
  if (lines.isNotEmpty) b.writeln(lines.skip(lines.length > maxLogLines ? lines.length - maxLogLines : 0).join('\n'));
  return b.toString();
}

/// The new-issue address with the form filled in from [env] and [logs]. [logs] is cut so the whole address stays
/// under [maxLength] (browsers and GitHub refuse much longer ones), with a note to paste the rest from the clipboard.
Uri issueUrl({required DiagnosticEnvironment env, String logs = '', String title = '', int maxLength = 7000}) {
  Uri build(String text) => Uri.parse(issueBaseUrl).replace(
    queryParameters: {
      'template': issueTemplate,
      if (title.isNotEmpty) 'title': title,
      'version': env.appVersion,
      'platform': env.platformAndForm,
      'engine': env.engine,
      if (text.isNotEmpty) 'logs': text,
    },
  );
  var uri = build(logs);
  if (uri.toString().length <= maxLength) return uri;
  const note = '\n…（太长，后面的部分没有填进来。完整的诊断信息已复制到剪贴板，可以粘贴在这里替换这一段）';
  var lo = 0, hi = logs.length;
  while (lo < hi) {
    final mid = (lo + hi + 1) ~/ 2;
    if (build('${logs.substring(0, mid)}$note').toString().length <= maxLength) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  uri = build(lo == 0 ? note.trim() : '${logs.substring(0, lo)}$note');
  return uri;
}
