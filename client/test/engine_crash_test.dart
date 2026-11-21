// The desktop app's launcher (engine/local_engine_io.dart) with a real engine process: when the engine dies, its
// output stays in engine.log and a crash record names the exit. Runs the demo engine (data in memory) from
// `engine/server/build/install/tvbox-engine` on a free port; skipped when that is not built
// (`cd engine && ./gradlew :server:installDist`) or there is no Java (`JAVA_HOME`, or `java` on PATH).
@TestOn('windows || mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_client/diagnostics/crash_record.dart';
import 'package:tvbox_client/diagnostics/diagnostics.dart';
import 'package:tvbox_client/diagnostics/diagnostics_store.dart';
import 'package:tvbox_client/engine/local_engine_io.dart';

Directory get _engineDir => Directory(['..', 'engine', 'server', 'build', 'install', 'tvbox-engine'].join(Platform.pathSeparator));

String? _skip() {
  if (!Directory('${_engineDir.path}${Platform.pathSeparator}lib').existsSync()) return 'the engine is not built (./gradlew :server:installDist)';
  final home = Platform.environment['JAVA_HOME'];
  final exe = Platform.isWindows ? 'javaw.exe' : 'java';
  if (home != null && File('$home${Platform.pathSeparator}bin${Platform.pathSeparator}$exe').existsSync()) return null;
  try {
    return Process.runSync(Platform.isWindows ? 'where' : 'which', [Platform.isWindows ? 'javaw' : 'java']).exitCode == 0 ? null : 'no Java';
  } on ProcessException {
    return 'no Java';
  }
}

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

Future<bool> _answers(int port) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
  try {
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/api/v1/info'));
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    return res.statusCode == 200 && body.contains('tvbox-engine');
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

void main() {
  final skip = _skip();
  late Directory dir;
  late Diagnostics diagnostics;
  DesktopEngine? engine;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('yingzhou-engine-crash-');
    diagnostics = Diagnostics(store: DiagnosticsStore.files(() async => dir.path), appVersion: 'test', platform: 'test');
  });

  tearDown(() async {
    engine?.stop();
    engine = null;
    // Windows keeps the folder busy for a moment after the process ends.
    for (var i = 0; i < 20; i++) {
      try {
        dir.deleteSync(recursive: true);
        break;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  });

  Future<String> log() async {
    await diagnostics.flush();
    return File('${dir.path}${Platform.pathSeparator}engine.log').readAsStringSync();
  }

  Future<CrashRecord> engineRecord() async {
    await diagnostics.flush();
    final records = await diagnostics.store.list();
    return records.singleWhere((s) => s.record.source == CrashSource.engine).record;
  }

  test('an engine killed while it runs leaves its output and a record of the exit', () async {
    final port = await _freePort();
    final e = engine = DesktopEngine(diagnostics: diagnostics, engineDir: _engineDir, extraArgs: ['--demo']);
    expect(await e.start(port), isTrue);
    final process = e.process!;
    final ready = DateTime.now().add(const Duration(seconds: 60));
    while (!await _answers(port)) {
      if (DateTime.now().isAfter(ready)) fail('the demo engine did not answer on $port:\n${e.recentOutput.join('\n')}');
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    // A crash: the process is ended from outside, not through stop().
    expect(Process.killPid(process.pid, ProcessSignal.sigkill), isTrue);
    final code = await process.exitCode.timeout(const Duration(seconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(code, isNot(0));

    final text = await log();
    expect(text, contains('启动引擎：'));
    expect(text, contains('--demo'));
    expect(text, contains('tvbox-engine listening on http://127.0.0.1:$port'));
    expect(text, contains('引擎已退出（$code）'));
    final r = await engineRecord();
    expect(r.error, '引擎进程退出了（退出码 $code）');
    expect(r.stack, contains('listening on http://127.0.0.1:$port'));
    expect(dir.listSync().map((f) => f.uri.pathSegments.last), contains(matches(RegExp(r'^crash-\d{8}-\d{6}-\d{3}-engine\.txt$'))));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('an engine that dies on start (its port is taken) leaves the reason', () async {
    final blocker = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(blocker.close);
    final e = engine = DesktopEngine(diagnostics: diagnostics, engineDir: _engineDir, extraArgs: ['--demo']);
    expect(await e.start(blocker.port), isTrue);
    final code = await e.process!.exitCode.timeout(const Duration(seconds: 60));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(code, isNot(0));
    final text = await log();
    expect(text, contains('BindException'));
    expect(text, contains('引擎已退出（$code）'));
    final r = await engineRecord();
    expect(r.stack, contains('BindException'));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('stopping the engine is not a crash', () async {
    final port = await _freePort();
    final e = engine = DesktopEngine(diagnostics: diagnostics, engineDir: _engineDir, extraArgs: ['--demo']);
    expect(await e.start(port), isTrue);
    final process = e.process!;
    e.stop();
    await process.exitCode.timeout(const Duration(seconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await diagnostics.flush();
    expect(await diagnostics.store.list(), isEmpty);
    expect(await log(), contains('引擎已退出'));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}
