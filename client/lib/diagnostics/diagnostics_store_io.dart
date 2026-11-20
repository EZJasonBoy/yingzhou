import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'crash_record.dart';
import 'diagnostics_store.dart';
import 'diagnostics_store_memory.dart';

DiagnosticsStore createFileStore(
  Future<String?> Function()? directory, {
  int maxRecords = 20,
  int maxRecordBytes = 64 * 1024,
  int maxLogBytes = 512 * 1024,
  int keepLogs = 3,
}) => directory == null
    ? MemoryDiagnosticsStore(maxRecords: maxRecords)
    : FileDiagnosticsStore(directory, maxRecords: maxRecords, maxRecordBytes: maxRecordBytes, maxLogBytes: maxLogBytes, keepLogs: keepLogs);

/// Crash records as `crash-<time>-<origin>.txt` and the engine's output as `engine.log` (the run before as
/// `engine.1.log`, and so on), in one folder.
///
/// - At most [maxRecords] records: the oldest go when a new one is written. A record longer than [maxRecordBytes] is
///   cut. Records are written synchronously once the folder is known, so one written just before the app dies is
///   on disk; until then (an error before Flutter can tell where the folder is) they wait in memory.
/// - The engine log starts a new file each time the engine starts, and again when it passes [maxLogBytes]; [keepLogs]
///   files are kept. Lines are written in batches every 200 ms, and at once when the engine exits.
class FileDiagnosticsStore implements DiagnosticsStore {
  FileDiagnosticsStore(this._resolve, {this.maxRecords = 20, this.maxRecordBytes = 64 * 1024, this.maxLogBytes = 512 * 1024, this.keepLogs = 3})
    : _memory = MemoryDiagnosticsStore(maxRecords: maxRecords);

  final Future<String?> Function() _resolve;
  final int maxRecords;
  final int maxRecordBytes;
  final int maxLogBytes;
  final int keepLogs;
  final MemoryDiagnosticsStore _memory;

  Directory? _dir;
  Future<Directory?>? _resolving;

  /// Records first kept in memory, by their memory id, once they are on disk.
  final _moved = <String, String>{};

  static final _recordName = RegExp(r'^crash-[A-Za-z0-9_\-]+\.txt$');
  static const logName = 'engine';

  Future<Directory?> _directory() async {
    final known = _dir;
    if (known != null) return known;
    final dir = await (_resolving ??= _open());
    _resolving = null;
    if (dir != null && _dir == null) {
      _dir = dir;
      _moveFromMemory(dir);
    }
    return _dir;
  }

  Future<Directory?> _open() async {
    try {
      final path = await _resolve();
      if (path == null) return null;
      return Directory(path)..createSync(recursive: true);
    } catch (_) {
      // Too early (no binding yet) or not writable: memory for now, ask again next time.
      return null;
    }
  }

  void _moveFromMemory(Directory dir) {
    for (final e in _memory.records.entries) {
      try {
        _moved[e.key] = _write(dir, e.value, null, e.key.split('-').last);
        _memory.forget(e.key);
      } on FileSystemException {
        // Stays in memory.
      }
    }
    _prune(dir);
  }

  @override
  Future<String?> save(CrashRecord record, {String? id, String origin = 'dart'}) async {
    final dir = await _directory();
    if (dir == null) return _memory.save(record, id: id, origin: origin);
    final target = id == null ? null : (_moved[id] ?? id);
    try {
      final name = _write(dir, record, target != null && _recordName.hasMatch(target) ? target : null, origin);
      if (target == null) _prune(dir);
      return name;
    } on FileSystemException {
      return _memory.save(record, id: id, origin: origin);
    }
  }

  String _write(Directory dir, CrashRecord record, String? name, String origin) {
    var file = name ?? CrashRecord.fileName(record.time, origin);
    if (name == null) {
      for (var i = 2; File('${dir.path}${Platform.pathSeparator}$file').existsSync(); i++) {
        file = CrashRecord.fileName(record.time, '$origin$i');
      }
    }
    File('${dir.path}${Platform.pathSeparator}$file').writeAsStringSync(capText(record.format(), maxRecordBytes), flush: true);
    return file;
  }

  /// [text] cut to [maxBytes] of UTF-8, with a note that it was.
  static String capText(String text, int maxBytes) {
    if (utf8.encode(text).length <= maxBytes) return text;
    const note = '\n…（记录太长，后面的部分没有保存）\n';
    var cut = text.substring(0, text.length > maxBytes ? maxBytes : text.length);
    while (cut.isNotEmpty && utf8.encode(cut).length + utf8.encode(note).length > maxBytes) {
      cut = cut.substring(0, (cut.length * 0.9).floor());
    }
    return '$cut$note';
  }

  List<File> _recordFiles(Directory dir) {
    final files = <File>[
      for (final e in dir.listSync())
        if (e is File && _recordName.hasMatch(e.uri.pathSegments.last)) e,
    ];
    files.sort((a, b) => b.uri.pathSegments.last.compareTo(a.uri.pathSegments.last));
    return files;
  }

  void _prune(Directory dir) {
    try {
      for (final old in _recordFiles(dir).skip(maxRecords)) {
        old.deleteSync();
      }
    } on FileSystemException {
      // Tried again with the next record.
    }
  }

  @override
  Future<List<StoredRecord>> list() async {
    final dir = await _directory();
    final out = <StoredRecord>[...await _memory.list()];
    if (dir != null) {
      for (final f in _recordFiles(dir)) {
        try {
          final record = CrashRecord.parse(await f.readAsString());
          if (record != null) out.add(StoredRecord(f.uri.pathSegments.last, record));
        } on FileSystemException {
          // Deleted meanwhile.
        } on FormatException {
          // Not text.
        }
      }
    }
    out.sort((a, b) => b.record.time.compareTo(a.record.time));
    return out;
  }

  @override
  Future<String?> read(String id) async {
    final inMemory = await _memory.read(id);
    if (inMemory != null) return inMemory;
    final dir = await _directory();
    final name = _moved[id] ?? id;
    if (dir == null || !_recordName.hasMatch(name)) return null;
    try {
      return await File('${dir.path}${Platform.pathSeparator}$name').readAsString();
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<String?> location() async => (await _directory())?.path;

  // ---- the engine log ----

  final _pending = <String>[];
  Timer? _flushTimer;
  Future<void> _queue = Future.value();
  int? _logSize;

  File _log(Directory dir, int i) => File('${dir.path}${Platform.pathSeparator}${i == 0 ? '$logName.log' : '$logName.$i.log'}');

  List<String> _take() {
    final lines = List.of(_pending);
    _pending.clear();
    return lines;
  }

  Future<void> _enqueue(Future<void> Function() op) => _queue = _queue.then((_) => op()).catchError((Object _) {});

  void _schedule() {
    _flushTimer ??= Timer(const Duration(milliseconds: 200), () {
      _flushTimer = null;
      flush();
    });
  }

  @override
  void engineOutput(String line) {
    _pending.add(line);
    _schedule();
  }

  @override
  void engineStarted(String commandLine) {
    final before = _take();
    _enqueue(() => _append(before));
    _enqueue(_rotate);
    _pending.add('== ${CrashRecord.formatTime(DateTime.now())} 启动引擎：$commandLine');
    _schedule();
  }

  @override
  void engineExited(int exitCode) {
    _pending.add('== ${CrashRecord.formatTime(DateTime.now())} 引擎已退出（$exitCode）');
    flush();
  }

  @override
  Future<void> flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    final lines = _take();
    if (lines.isEmpty) return _queue;
    return _enqueue(() => _append(lines));
  }

  Future<void> _append(List<String> lines) async {
    if (lines.isEmpty) return;
    final dir = await _directory();
    if (dir == null) {
      lines.forEach(_memory.engineOutput);
      return;
    }
    final bytes = utf8.encode('${lines.join('\n')}\n');
    final file = _log(dir, 0);
    var size = _logSize ??= file.existsSync() ? file.lengthSync() : 0;
    if (size > 0 && size + bytes.length > maxLogBytes) {
      await _rotate();
      size = 0;
    }
    try {
      await file.writeAsBytes(bytes, mode: FileMode.append, flush: true);
      _logSize = size + bytes.length;
    } on FileSystemException {
      lines.forEach(_memory.engineOutput);
    }
  }

  /// `engine.log` becomes `engine.1.log`, and so on; the oldest goes.
  Future<void> _rotate() async {
    final dir = await _directory();
    if (dir == null) return;
    try {
      final oldest = _log(dir, keepLogs - 1);
      if (oldest.existsSync()) oldest.deleteSync();
      for (var i = keepLogs - 2; i >= 0; i--) {
        final f = _log(dir, i);
        if (f.existsSync()) f.renameSync(_log(dir, i + 1).path);
      }
    } on FileSystemException {
      // The next write appends to the current file.
    }
    _logSize = 0;
  }

  @override
  Future<String> engineLogTail({int lines = 200}) async {
    await flush();
    final dir = await _directory();
    final out = <String>[];
    if (dir != null) {
      for (var i = 0; i < keepLogs && out.length < lines; i++) {
        final f = _log(dir, i);
        if (!f.existsSync()) continue;
        try {
          out.insertAll(0, const LineSplitter().convert(await f.readAsString()));
        } on FileSystemException {
          break;
        } on FormatException {
          break;
        }
      }
    }
    final memory = await _memory.engineLogTail(lines: lines);
    if (memory.isNotEmpty) out.addAll(memory.split('\n'));
    return out.skip(out.length > lines ? out.length - lines : 0).join('\n');
  }
}
