import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'local_engine.dart';

LocalEngine? createLocalEngine() =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux ? DesktopEngine() : null;

/// Runs `tvbox.engine.server.MainKt` from the engine bundled next to the app:
///
/// - packaged: `<app dir>/engine/lib/*.jar` with a trimmed runtime in `<app dir>/engine/jre`;
/// - development: the repo's `engine/server/build/install/tvbox-engine` (from `./gradlew :server:installDist`),
///   with `JAVA_HOME` or `java` on PATH.
///
/// The engine gets a pipe on stdin and `--exit-with-stdin`, so it ends with the app, even after a crash.
class DesktopEngine implements LocalEngine {
  Process? _process;
  final _output = <String>[];

  @override
  List<String> get recentOutput => List.unmodifiable(_output);

  @override
  Future<bool> start(int port) async {
    if (_process != null) return true;
    final engineDir = _findEngineDir();
    if (engineDir == null) {
      _remember('找不到内置引擎（engine/lib）');
      return false;
    }
    final java = _findJava(engineDir);
    try {
      final process = await Process.start(java, [
        '-Xss1m',
        '-XX:+UseSerialGC',
        '-cp',
        '${engineDir.path}${Platform.pathSeparator}lib${Platform.pathSeparator}*',
        'tvbox.engine.server.MainKt',
        '--port',
        '$port',
        '--exit-with-stdin',
      ]);
      _process = process;
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_remember);
      process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(_remember);
      unawaited(process.exitCode.then((code) {
        _remember('引擎已退出（$code）');
        _process = null;
      }));
      // process.stdin stays open for the life of the app; the engine exits when it closes.
      return true;
    } on ProcessException catch (e) {
      _remember('无法启动 Java：${e.message}');
      return false;
    }
  }

  @override
  void stop() {
    _process?.kill();
    _process = null;
  }

  void _remember(String line) {
    _output.add(line);
    if (_output.length > 50) _output.removeAt(0);
  }

  Directory? _findEngineDir() {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final packaged = Directory('${exeDir.path}${Platform.pathSeparator}engine');
    if (Directory('${packaged.path}${Platform.pathSeparator}lib').existsSync()) return packaged;
    // Development: walk up to the repo and use the Gradle distribution.
    var dir = exeDir;
    for (var i = 0; i < 10; i++) {
      final dev = Directory([dir.path, 'engine', 'server', 'build', 'install', 'tvbox-engine'].join(Platform.pathSeparator));
      if (Directory('${dev.path}${Platform.pathSeparator}lib').existsSync()) return dev;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  /// The bundled runtime first; `javaw` on Windows so no console window flashes up.
  String _findJava(Directory engineDir) {
    final exe = Platform.isWindows ? 'javaw.exe' : 'java';
    final s = Platform.pathSeparator;
    final bundled = File('${engineDir.path}${s}jre${s}bin$s$exe');
    if (bundled.existsSync()) return bundled.path;
    final home = Platform.environment['JAVA_HOME'];
    if (home != null && File('$home${s}bin$s$exe').existsSync()) return '$home${s}bin$s$exe';
    return Platform.isWindows ? 'javaw' : 'java';
  }
}
