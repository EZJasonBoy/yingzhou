import 'update_backend_stub.dart' if (dart.library.io) 'update_backend_io.dart' as impl;
import 'update_models.dart';

/// What updating needs from the device: requests (with the user's proxy), files, the browser. The web build has
/// none of it ([supported] is false there).
abstract class UpdateBackend {
  /// The real one for this platform.
  factory UpdateBackend() => impl.createBackend();

  bool get supported;

  /// Fetches `latest.json`: GitHub first, then through [mirror] when it is set.
  Future<UpdateCheckResult> check({String mirror = '', String proxy = ''});

  /// Keys of [ReleaseInfo.assets] for this machine, best first (see `assetKeysFor`).
  List<String> get assetKeys;

  /// Whether packages are downloaded by the app ([download]) rather than by the browser.
  bool get downloadsInApp;

  /// Saves [url] as [fileName] in the downloads folder; answers the file's path. A file not of [expectedSize]
  /// (when known) is refused.
  Future<String> download(
    String url,
    String fileName, {
    String proxy = '',
    int expectedSize = 0,
    void Function(int received, int total)? progress,
    bool Function()? cancelled,
  });

  Future<bool> openInBrowser(String url);

  Future<void> reveal(String path);

  /// A failure of [download] the way the user is told about it.
  String describe(Object error);
}
