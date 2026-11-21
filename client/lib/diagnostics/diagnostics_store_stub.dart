import 'diagnostics_store.dart';
import 'diagnostics_store_memory.dart';

/// The web build has no files: records stay in memory for the session.
DiagnosticsStore createFileStore(
  Future<String?> Function()? directory, {
  int maxRecords = 20,
  int maxRecordBytes = 64 * 1024,
  int maxLogBytes = 512 * 1024,
  int keepLogs = 3,
}) => MemoryDiagnosticsStore(maxRecords: maxRecords);
