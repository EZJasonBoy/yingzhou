import 'download_files_stub.dart' if (dart.library.io) 'download_files_io.dart' as impl;
import 'downloads.dart';
import 'engine_client.dart';

/// Files on this device for downloads: saving an export the engine streams, showing a file in the system's file
/// manager (desktop), handing it to the share sheet (Android). None of it exists on the web.
abstract final class DownloadFiles {
  /// Whether this device can save exports and show files.
  static bool get supported => impl.supported;

  /// Saves the engine's export of download [id] into this device's downloads folder; answers the file's path.
  static Future<String> saveExport(EngineClient client, String id, {void Function(int bytes)? onProgress}) =>
      impl.saveExport(client, id, onProgress: onProgress);

  /// Opens the folder [path] is in, with the file selected where the system can do that.
  static Future<void> reveal(String path) => impl.reveal(path);

  /// Whether exports end up in the system's Downloads and can be shared from there (Android).
  static bool get canShare => impl.canShare;

  /// Android: saves the export of download [id] of an engine on another device into the system's Downloads
  /// (`Download/映舟`), streamed straight there; the answer carries the address for [share].
  static Future<DownloadExportResult> saveExportToDownloads(EngineClient client, String id) => impl.saveExportToDownloads(client, id);

  /// Android: the share sheet for an exported file (its `content://` [uri]).
  static Future<void> share(String uri, {String title = '分享'}) => impl.share(uri, title);
}
