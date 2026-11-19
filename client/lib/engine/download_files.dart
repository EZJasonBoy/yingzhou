import 'download_files_stub.dart' if (dart.library.io) 'download_files_io.dart' as impl;
import 'engine_client.dart';

/// Files on this device for downloads: saving an export the engine streams, and showing a file in the system's
/// file manager. Neither exists on the web.
abstract final class DownloadFiles {
  /// Whether this device can save exports and show files.
  static bool get supported => impl.supported;

  /// Saves the engine's export of download [id] into this device's downloads folder; answers the file's path.
  static Future<String> saveExport(EngineClient client, String id, {void Function(int bytes)? onProgress}) =>
      impl.saveExport(client, id, onProgress: onProgress);

  /// Opens the folder [path] is in, with the file selected where the system can do that.
  static Future<void> reveal(String path) => impl.reveal(path);
}
