import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

enum DevLevel { info, warn, error }

/// One line of the [DevLog].
@immutable
class DevLogEntry {
  const DevLogEntry({required this.time, required this.level, required this.module, required this.message, this.detail = const {}, this.seq = 0});

  /// Its place in the log, counted from 1 and never used twice while the app runs (clearing the log does not start
  /// it again): a remote asks for what came after the last one it has.
  final int seq;

  final DateTime time;
  final DevLevel level;

  /// Who says it: 引擎, 订阅, 站点, 线路, 播放器.
  final String module;
  final String message;

  /// What belongs to it (the address asked for, the answer, the headers), shown when the line is selected.
  final Map<String, String> detail;

  /// `20:41:42.905`
  String get clock {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}.${time.millisecond.toString().padLeft(3, '0')}';
  }

  String get levelLabel => switch (level) {
    DevLevel.info => '信息',
    DevLevel.warn => '警告',
    DevLevel.error => '错误',
  };

  /// As one line of text, for copying.
  String get line => '$clock $levelLabel $module $message${detail.isEmpty ? '' : '  ${detail.entries.map((e) => '${e.key}=${e.value}').join('  ')}'}';
}

/// What this client did to get a video on the screen: which engine and subscription it talked to, how an episode's
/// address was found, which line failed and what took its place. Kept in memory (the last [capacity] lines) whatever
/// the mode, so the log already has the story when the developer mode is switched on to look at it; shown on the 日志
/// page.
class DevLog extends ChangeNotifier {
  DevLog({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static DevLog instance = DevLog();

  static const capacity = 500;

  final DateTime Function() _now;
  final _entries = ListQueue<DevLogEntry>();
  bool _telling = false;
  int _seq = 0;

  /// Oldest first.
  List<DevLogEntry> get entries => _entries.toList(growable: false);

  int get length => _entries.length;

  /// The [DevLogEntry.seq] of the newest line; 0 before the first.
  int get lastSeq => _seq;

  void add(DevLevel level, String module, String message, {Map<String, String> detail = const {}}) {
    _entries.addLast(DevLogEntry(seq: ++_seq, time: _now(), level: level, module: module, message: message, detail: detail));
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
    // Lines are written from anywhere, also while widgets build: listeners hear of them afterwards, once.
    if (_telling) return;
    _telling = true;
    scheduleMicrotask(() {
      _telling = false;
      notifyListeners();
    });
  }

  void info(String module, String message, {Map<String, String> detail = const {}}) => add(DevLevel.info, module, message, detail: detail);
  void warn(String module, String message, {Map<String, String> detail = const {}}) => add(DevLevel.warn, module, message, detail: detail);
  void error(String module, String message, {Map<String, String> detail = const {}}) => add(DevLevel.error, module, message, detail: detail);

  void clear() {
    _entries.clear();
    notifyListeners();
  }
}
