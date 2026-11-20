import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_client/diagnostics/crash_record.dart';
import 'package:tvbox_client/diagnostics/diagnostics_store.dart';
import 'package:tvbox_client/diagnostics/diagnostics_store_io.dart';

CrashRecord record(int i, {String stack = 'at main (x.dart:1)'}) => CrashRecord(
  time: DateTime(2026, 11, 20, 12, 0, i, i),
  version: '0.4.0+5',
  platform: 'Windows 10 · windows_x64',
  form: 'desktop',
  source: CrashSource.flutter,
  error: 'StateError: boom $i\n（while building Foo）',
  stack: stack,
);

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('yingzhou-diag-'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a record reads back as it was written', () {
    final r = record(3, stack: '#0 main (x.dart:1)\n#1 run (y.dart:2)')..repeated = 4;
    final back = CrashRecord.parse(r.format())!;
    expect(back.time, r.time);
    expect(back.version, '0.4.0+5');
    expect(back.platform, r.platform);
    expect(back.form, 'desktop');
    expect(back.source, CrashSource.flutter);
    expect(back.error, r.error);
    expect(back.stack, r.stack);
    expect(back.repeated, 4);
    expect(back.summary, 'StateError: boom 3');
    expect(CrashRecord.parse('not a record'), isNull);
  });

  test('a record written by the Android side (CrashRecorder.kt) parses too', () {
    const text = '映舟崩溃记录\n'
        'time: 2026-11-20 08:05:01.250 +08:00\n'
        'version: 0.4.0+5\n'
        'platform: Android 14 (API 34) · Google sdk_gphone64_x86_64\n'
        'form: tv\n'
        'source: android\n'
        '\n'
        'error:\n'
        'java.lang.IllegalStateException: boom\n'
        '（线程 main 里没有被处理的异常）\n'
        '\n'
        'stack:\n'
        'java.lang.IllegalStateException: boom\n'
        '\tat tvbox.next.Foo.bar(Foo.kt:3)\n';
    final r = CrashRecord.parse(text)!;
    expect(r.time.toUtc(), DateTime.utc(2026, 11, 20, 0, 5, 1, 250));
    expect(r.source, CrashSource.android);
    expect(r.form, 'tv');
    expect(r.summary, 'java.lang.IllegalStateException: boom');
    expect(r.stack, contains('Foo.kt:3'));
  });

  test('keeps the newest records only, and cuts a record that is too long', () async {
    final store = FileDiagnosticsStore(() async => dir.path, maxRecords: 5, maxRecordBytes: 4096);
    for (var i = 0; i < 8; i++) {
      await store.save(record(i));
    }
    await store.save(record(9, stack: 'x' * 20000));
    final files = dir.listSync().whereType<File>().map((f) => f.uri.pathSegments.last).toList()..sort();
    expect(files, hasLength(5));
    expect(files.every((f) => f.startsWith('crash-20261120-') && f.endsWith('-dart.txt')), isTrue);
    final list = await store.list();
    expect(list.map((s) => s.record.error.split('\n').first), ['StateError: boom 9', 'StateError: boom 7', 'StateError: boom 6', 'StateError: boom 5', 'StateError: boom 4']);
    final longest = File('${dir.path}/${list.first.id}');
    expect(longest.lengthSync(), lessThanOrEqualTo(4096));
    expect(longest.readAsStringSync(), endsWith('（记录太长，后面的部分没有保存）\n'));
    expect(await store.read(list.first.id), startsWith(CrashRecord.title));
    // Nothing outside the folder can be read through an id.
    expect(await store.read(r'..\..\secret.txt'), isNull);
  });

  test('the same record saved again replaces its file', () async {
    final store = FileDiagnosticsStore(() async => dir.path);
    final r = record(1);
    final id = await store.save(r);
    r.repeated = 7;
    expect(await store.save(r, id: id), id);
    expect(dir.listSync(), hasLength(1));
    expect((await store.list()).single.record.repeated, 7);
  });

  test('records made before the folder is known wait in memory and move there', () async {
    String? path;
    final store = FileDiagnosticsStore(() async => path);
    final early = await store.save(record(1));
    expect(early, startsWith('mem-'));
    expect(await store.read(early!), contains('boom 1'));
    path = dir.path;
    await store.save(record(2));
    final files = dir.listSync().whereType<File>().toList();
    expect(files, hasLength(2));
    expect(await store.read(early), contains('boom 1'));
    expect((await store.list()).map((s) => s.record.summary), ['StateError: boom 2', 'StateError: boom 1']);
  });

  test('a folder that cannot be found keeps everything in memory', () async {
    final store = FileDiagnosticsStore(() async => throw StateError('no binding yet'));
    await store.save(record(1));
    store.engineOutput('hello');
    expect((await store.list()).single.record.summary, 'StateError: boom 1');
    expect(await store.engineLogTail(), 'hello');
    expect(await store.location(), isNull);
  });

  group('engine log', () {
    test('each start begins a new file and the run before is kept; only so many files', () async {
      final store = FileDiagnosticsStore(() async => dir.path, keepLogs: 3);
      for (var run = 1; run <= 4; run++) {
        store.engineStarted('java -cp lib/* tvbox.engine.server.MainKt --port 1999$run');
        store.engineOutput('run $run line 1');
        store.engineOutput('run $run line 2');
        store.engineExited(run == 4 ? 1 : 0);
        await store.flush();
      }
      String log(String name) => File('${dir.path}/$name').readAsStringSync();
      expect(log('engine.log'), contains('run 4 line 2'));
      expect(log('engine.log'), contains('引擎已退出（1）'));
      expect(log('engine.log'), isNot(contains('run 3')));
      expect(log('engine.1.log'), contains('run 3 line 1'));
      expect(log('engine.2.log'), contains('run 2 line 1'));
      expect(File('${dir.path}/engine.3.log').existsSync(), isFalse);
      final tail = await store.engineLogTail(lines: 5);
      expect(tail.split('\n'), hasLength(5));
      expect(tail, endsWith('引擎已退出（1）'));
      // A tail longer than this run reaches into the one before.
      expect(await store.engineLogTail(lines: 8), contains('run 3 line 2'));
    });

    test('a run that prints a lot rotates at the cap', () async {
      final store = FileDiagnosticsStore(() async => dir.path, maxLogBytes: 2000, keepLogs: 2);
      store.engineStarted('java');
      for (var i = 0; i < 200; i++) {
        store.engineOutput('line $i ${'x' * 40}');
        if (i % 20 == 19) await store.flush();
      }
      await store.flush();
      final current = File('${dir.path}/engine.log');
      expect(current.lengthSync(), lessThanOrEqualTo(2000));
      expect(current.readAsStringSync(), contains('line 199'));
      expect(File('${dir.path}/engine.1.log').lengthSync(), lessThanOrEqualTo(2000));
      expect(File('${dir.path}/engine.2.log').existsSync(), isFalse);
    });
  });

  test('without a folder the store is memory', () async {
    final store = DiagnosticsStore.files(null, maxRecords: 2);
    for (var i = 0; i < 3; i++) {
      await store.save(record(i));
    }
    expect((await store.list()).map((s) => s.record.summary), ['StateError: boom 2', 'StateError: boom 1']);
  });
}
