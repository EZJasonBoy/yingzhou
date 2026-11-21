import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'open_url.dart' as os;
import 'release_info.dart';
import 'update_backend.dart';
import 'update_client.dart';
import 'update_models.dart';

UpdateBackend createBackend() => IoUpdateBackend(UpdateClient());

class IoUpdateBackend implements UpdateBackend {
  IoUpdateBackend(this.client);

  final UpdateClient client;

  @override
  bool get supported => Platform.isWindows || Platform.isMacOS || Platform.isLinux || Platform.isAndroid;

  @override
  Future<UpdateCheckResult> check({String mirror = '', String proxy = ''}) => client.check(mirror: mirror, proxy: proxy);

  @override
  List<String> get assetKeys {
    final m = os.currentMachine();
    return assetKeysFor(os: m.os, abi: m.abi, installed: m.installed);
  }

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
  }) async {
    final dir = Platform.isAndroid
        ? Directory('${(await getApplicationSupportDirectory()).path}/updates')
        : await getDownloadsDirectory() ?? await getTemporaryDirectory();
    // Only the file's own name: nothing from the manifest decides the folder.
    final last = fileName.split(RegExp(r'[\\/]')).last;
    final name = last.isEmpty || last.startsWith('.') ? 'yingzhou-update' : last;
    final file = await client.download(
      url,
      File('${dir.path}${Platform.pathSeparator}$name'),
      expectedSha256: expectedSha256,
      mirror: mirror,
      proxy: proxy,
      expectedSize: expectedSize,
      progress: progress,
      cancelled: cancelled,
    );
    return file.path;
  }

  @override
  Future<bool> openInBrowser(String url) => os.openInBrowser(url);

  @override
  Future<void> reveal(String path) => os.revealFile(path);

  @override
  String describe(Object error) => describeFailure(error);
}
