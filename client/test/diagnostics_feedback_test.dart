import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_client/diagnostics/crash_record.dart';
import 'package:tvbox_client/diagnostics/feedback.dart';
import 'package:tvbox_client/diagnostics/platform_io.dart';

void main() {
  const env = DiagnosticEnvironment(appVersion: '0.4.0+5', platform: 'Android 14 (API 34) · Xiaomi MiBox4', form: 'tv', engine: '未连接');

  test('the issue form has a field for everything the app fills in', () {
    final form = File('../.github/ISSUE_TEMPLATE/$issueTemplate').readAsStringSync();
    final url = issueUrl(env: env, logs: 'x', title: 't');
    for (final field in url.queryParameters.keys.where((k) => k != 'template' && k != 'title')) {
      expect(form, contains('id: $field\n'), reason: 'the app fills in "$field"');
    }
    expect(url.toString(), startsWith('https://github.com/Sa1koro/yingzhou/issues/new?template=bug_report.yml&'));
    expect(url.queryParameters['platform'], 'Android 14 (API 34) · Xiaomi MiBox4 · 电视');
  });

  test('long diagnostics are cut so the address stays short enough, with a note to paste the rest', () {
    final logs = List.generate(2000, (i) => '第 $i 行：java.lang.IllegalStateException at tvbox.Foo.bar(Foo.kt:$i)').join('\n');
    final url = issueUrl(env: env, logs: logs, maxLength: 7000);
    expect(url.toString().length, lessThanOrEqualTo(7000));
    final filled = url.queryParameters['logs']!;
    expect(filled, startsWith('第 0 行'));
    expect(filled, endsWith('完整的诊断信息已复制到剪贴板，可以粘贴在这里替换这一段）'));
    expect(issueUrl(env: env, logs: 'short').queryParameters['logs'], 'short');
  });

  test('the diagnostic text: environment, newest records first with their stack cut, the end of the log', () {
    final records = [
      for (var i = 3; i >= 1; i--)
        CrashRecord(
          time: DateTime(2026, 11, 20, 10, i),
          version: i == 1 ? '0.3.14+4' : '0.4.0+5',
          platform: env.platform,
          form: 'tv',
          source: CrashSource.android,
          error: 'java.lang.RuntimeException: $i',
          stack: List.generate(50, (j) => '\tat Frame$j').join('\n'),
        ),
    ];
    final text = buildDiagnosticReport(
      env: env,
      records: records,
      logTitle: '应用日志（logcat）',
      log: List.generate(300, (i) => 'line $i').join('\n'),
      now: DateTime(2026, 11, 20, 12),
      maxRecords: 2,
    );
    expect(text, startsWith('映舟诊断信息\n应用版本：0.4.0+5\n系统：Android 14 (API 34) · Xiaomi MiBox4\n设备形态：电视（tv）\n引擎：未连接\n'));
    expect(text, contains('== 最近的崩溃记录（共 3 条，这里是最新的 2 条，新的在前）=='));
    expect(text.indexOf('RuntimeException: 3'), lessThan(text.indexOf('RuntimeException: 2')));
    expect(text, isNot(contains('RuntimeException: 1')));
    expect(text, contains('…（还有 10 行）'));
    expect(text, contains('== 应用日志（logcat）（最后 150 行）=='));
    expect(text, contains('line 150\n'));
    expect(text, isNot(contains('line 149\n')));
    expect(text.trimRight(), endsWith('line 299'));
  });

  test('the browser is opened without a shell, so & in the address stays as it is', () {
    const url = 'https://github.com/Sa1koro/yingzhou/issues/new?template=bug_report.yml&version=0.4.0';
    expect([desktopOpenCommand(url, os: 'windows').$1, ...desktopOpenCommand(url, os: 'windows').$2], ['rundll32', 'url.dll,FileProtocolHandler', url]);
    expect([desktopOpenCommand(url, os: 'macos').$1, ...desktopOpenCommand(url, os: 'macos').$2], ['open', url]);
    expect([desktopOpenCommand(url, os: 'linux').$1, ...desktopOpenCommand(url, os: 'linux').$2], ['xdg-open', url]);
  });

  test('flutter test never opens a real browser, and only web addresses are opened', () async {
    expect(await openUrlOnDesktop('https://example.com'), isFalse);
    final started = <List<String>>[];
    Future<Process> fake(String exe, List<String> args) async {
      started.add([exe, ...args]);
      throw const ProcessException('fake', []);
    }

    expect(await openUrlOnDesktop('file:///C:/Windows/System32/calc.exe', start: fake), isFalse);
    expect(started, isEmpty);
    expect(await openUrlOnDesktop('https://example.com', start: fake), isFalse);
    expect(started.single.last, 'https://example.com');
  });
}
