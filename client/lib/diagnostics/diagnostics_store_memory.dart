import 'crash_record.dart';
import 'diagnostics_store.dart';

/// Records and engine output kept in memory: tests, the web build, and the app before its folder is known.
class MemoryDiagnosticsStore implements DiagnosticsStore {
  MemoryDiagnosticsStore({this.maxRecords = 20, this.maxLogLines = 1000});

  final int maxRecords;
  final int maxLogLines;
  final _records = <String, CrashRecord>{};
  final _log = <String>[];
  var _next = 0;

  /// Records saved here, oldest first, with their ids (the file store moves them to disk once it has a folder).
  Map<String, CrashRecord> get records => Map.unmodifiable(_records);

  void forget(String id) => _records.remove(id);

  @override
  Future<String?> save(CrashRecord record, {String? id, String origin = 'dart'}) async {
    final key = id ?? 'mem-${_next++}-$origin';
    _records[key] = record;
    while (_records.length > maxRecords) {
      _records.remove(_records.keys.first);
    }
    return key;
  }

  @override
  Future<List<StoredRecord>> list() async => [for (final e in _records.entries.toList().reversed) StoredRecord(e.key, e.value)];

  @override
  Future<String?> read(String id) async => _records[id]?.format();

  @override
  Future<String?> location() async => null;

  @override
  void engineOutput(String line) {
    _log.add(line);
    if (_log.length > maxLogLines) _log.removeRange(0, _log.length - maxLogLines);
  }

  @override
  void engineStarted(String commandLine) => engineOutput('== ${CrashRecord.formatTime(DateTime.now())} 启动引擎：$commandLine');

  @override
  void engineExited(int exitCode) => engineOutput('== ${CrashRecord.formatTime(DateTime.now())} 引擎已退出（$exitCode）');

  @override
  Future<String> engineLogTail({int lines = 200}) async => _log.skip(_log.length > lines ? _log.length - lines : 0).join('\n');

  @override
  Future<void> flush() async {}
}
