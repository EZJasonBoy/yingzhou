import 'crash_record.dart';
import 'diagnostics_store_stub.dart' if (dart.library.io) 'diagnostics_store_io.dart' as impl;

/// A crash record as kept: [id] names it in its folder (the file name).
class StoredRecord {
  const StoredRecord(this.id, this.record);

  final String id;
  final CrashRecord record;
}

/// Where crash records and the desktop engine's output are kept: files in the app's support directory
/// (`<support>/diagnostics`), or memory when there is none (tests, the web build).
abstract class DiagnosticsStore {
  /// Files in the folder [directory] answers (asked when first needed, and again later while it answers null);
  /// without it, or on the web, everything stays in memory. At most [maxRecords] records of [maxRecordBytes] each
  /// are kept, and [keepLogs] engine logs of about [maxLogBytes] each.
  factory DiagnosticsStore.files(
    Future<String?> Function()? directory, {
    int maxRecords = 20,
    int maxRecordBytes = 64 * 1024,
    int maxLogBytes = 512 * 1024,
    int keepLogs = 3,
  }) => impl.createFileStore(directory, maxRecords: maxRecords, maxRecordBytes: maxRecordBytes, maxLogBytes: maxLogBytes, keepLogs: keepLogs);

  /// Saves [record]; with [id], over that earlier record (the same error again). Returns the record's id.
  Future<String?> save(CrashRecord record, {String? id, String origin = 'dart'});

  /// Every record kept, newest first.
  Future<List<StoredRecord>> list();

  /// The text of record [id] as it is on disk; null when it is gone.
  Future<String?> read(String id);

  /// The folder, to tell the user where to look; null when records are only in memory.
  Future<String?> location();

  /// A line the engine printed (stdout or stderr); kept in a rotating file.
  void engineOutput(String line);

  /// The engine is starting with [commandLine]: the previous run's file is kept as `engine.1.log`.
  void engineStarted(String commandLine);

  /// The engine process ended with [exitCode].
  void engineExited(int exitCode);

  /// The last [lines] lines of the engine's output, this run and the one before; empty when there is none.
  Future<String> engineLogTail({int lines = 200});

  /// Writes out what is still buffered.
  Future<void> flush();
}
