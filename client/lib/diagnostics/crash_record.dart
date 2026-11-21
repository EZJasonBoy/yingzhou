/// Where a crash record came from.
enum CrashSource {
  /// `FlutterError.onError`: an error while building, laying out or painting a widget.
  flutter,

  /// `PlatformDispatcher.onError`: an error nobody caught outside the guarded zone (platform callbacks, isolates).
  platform,

  /// The guarded zone around the app: an asynchronous error nobody caught.
  zone,

  /// The uncaught-exception handler of the Android app (`CrashRecorder.kt`): the app or its embedded engine died.
  android,

  /// The desktop app's bundled engine process ended by itself (`local_engine_io.dart`).
  engine;

  String get label => switch (this) {
    flutter => '界面错误',
    platform => '未处理的错误',
    zone => '未处理的异步错误',
    android => '安卓崩溃',
    engine => '引擎退出',
  };
}

/// One crash record: a small text file in the diagnostics folder, readable as it is and parsed back for the list.
///
/// ```
/// 映舟崩溃记录
/// time: 2026-11-20 12:34:56.789 +08:00
/// version: 0.4.0+5
/// platform: Windows 10 Education 10.0.19045
/// form: desktop
/// source: flutter
/// repeated: 3                      (only when the same error came again in that run)
///
/// error:
/// <the error>
///
/// stack:
/// <the stack, or the engine's last lines>
/// ```
///
/// The Android side writes the same format (`CrashRecorder.kt`).
class CrashRecord {
  CrashRecord({
    required this.time,
    required this.version,
    required this.platform,
    required this.form,
    required this.source,
    required this.error,
    this.stack = '',
    this.repeated = 1,
  });

  static const title = '映舟崩溃记录';

  final DateTime time;
  final String version;
  final String platform;
  final String form;
  final CrashSource source;
  final String error;
  final String stack;
  int repeated;

  /// The first line of the error, for the list.
  String get summary {
    final line = error.trim().split('\n').first.trim();
    return line.length > 160 ? '${line.substring(0, 160)}…' : line;
  }

  /// Same error from the same place: counted instead of written again.
  String get signature => '${source.name}|${error.trim().split('\n').first}|${stack.trim().split('\n').take(3).join('|')}';

  String format() {
    final b = StringBuffer()
      ..writeln(title)
      ..writeln('time: ${formatTime(time)}')
      ..writeln('version: $version')
      ..writeln('platform: $platform')
      ..writeln('form: $form')
      ..writeln('source: ${source.name}');
    if (repeated > 1) b.writeln('repeated: $repeated');
    b
      ..writeln()
      ..writeln('error:')
      ..writeln(error.trimRight());
    if (stack.trim().isNotEmpty) {
      b
        ..writeln()
        ..writeln('stack:')
        ..writeln(stack.trimRight());
    }
    return b.toString();
  }

  /// Reads a record back; null when [text] is not one.
  static CrashRecord? parse(String text) {
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    if (lines.isEmpty || lines.first.trim() != title) return null;
    final header = <String, String>{};
    var i = 1;
    for (; i < lines.length && lines[i].trim().isNotEmpty; i++) {
      final colon = lines[i].indexOf(':');
      if (colon > 0) header[lines[i].substring(0, colon).trim()] = lines[i].substring(colon + 1).trim();
    }
    final body = lines.skip(i).join('\n');
    String section(String name) {
      final m = RegExp('(?:^|\\n)$name:\\n([\\s\\S]*?)(?=\\n\\n(?:error|stack):\\n|\$)').firstMatch(body);
      return m?[1]?.trimRight() ?? '';
    }

    return CrashRecord(
      time: parseTime(header['time'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
      version: header['version'] ?? '',
      platform: header['platform'] ?? '',
      form: header['form'] ?? '',
      source: CrashSource.values.asNameMap()[header['source']] ?? CrashSource.platform,
      error: section('error'),
      stack: section('stack'),
      repeated: int.tryParse(header['repeated'] ?? '') ?? 1,
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// `2026-11-20 12:34:56.789 +08:00`, local time with its offset.
  static String formatTime(DateTime t) {
    final local = t.toLocal();
    final offset = local.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final minutes = offset.inMinutes.abs();
    return '${local.year}-${_two(local.month)}-${_two(local.day)} ${_two(local.hour)}:${_two(local.minute)}:${_two(local.second)}.'
        '${local.millisecond.toString().padLeft(3, '0')} $sign${_two(minutes ~/ 60)}:${_two(minutes % 60)}';
  }

  static DateTime? parseTime(String s) {
    final m = RegExp(r'^(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)(?:\.(\d{1,3}))?(?: ([+-])(\d\d):(\d\d))?').firstMatch(s.trim());
    if (m == null) return null;
    int g(int i) => int.parse(m[i]!);
    final ms = m[7] == null ? 0 : int.parse(m[7]!.padRight(3, '0'));
    if (m[8] == null) return DateTime(g(1), g(2), g(3), g(4), g(5), g(6), ms);
    final utc = DateTime.utc(g(1), g(2), g(3), g(4), g(5), g(6), ms);
    final offset = Duration(hours: g(9), minutes: g(10));
    return (m[8] == '-' ? utc.add(offset) : utc.subtract(offset)).toLocal();
  }

  /// The file name for a record made at [time] by [origin] (`dart`, `android`, `engine`): sorts by time.
  static String fileName(DateTime time, String origin) {
    final t = time.toLocal();
    return 'crash-${t.year}${_two(t.month)}${_two(t.day)}-${_two(t.hour)}${_two(t.minute)}${_two(t.second)}-'
        '${t.millisecond.toString().padLeft(3, '0')}-$origin.txt';
  }
}
