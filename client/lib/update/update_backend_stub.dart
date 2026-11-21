import 'update_backend.dart';
import 'update_models.dart';

UpdateBackend createBackend() => _NoUpdates();

/// The web build: the page is as new as the server that serves it.
class _NoUpdates implements UpdateBackend {
  @override
  bool get supported => false;

  @override
  Future<UpdateCheckResult> check({String mirror = '', String proxy = ''}) async =>
      UpdateCheckResult(current: '', at: DateTime.now(), failures: const ['网页版不检查更新']);

  @override
  List<String> get assetKeys => const [];

  @override
  Future<String> download(
    String url,
    String fileName, {
    required String expectedSha256,
    String mirror = '',
    String proxy = '',
    int expectedSize = 0,
    void Function(int, int)? progress,
    bool Function()? cancelled,
  }) => throw UnsupportedError('no downloads on the web');

  @override
  Future<bool> openInBrowser(String url) async => false;

  @override
  Future<void> reveal(String path) async {}

  @override
  String describe(Object error) => '$error';
}
