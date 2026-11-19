import 'downloads.dart';
import 'engine_client.dart';
import 'models.dart';

const bool supported = false;

const bool canShare = false;

Future<DownloadExportResult> saveExportToDownloads(EngineClient client, String id) async =>
    throw const EngineException('UNSUPPORTED', '这个平台不能保存文件');

Future<void> share(String uri, String title) async {}

Future<String> saveExport(EngineClient client, String id, {void Function(int bytes)? onProgress}) async =>
    throw const EngineException('UNSUPPORTED', '这个平台不能保存文件');

Future<void> reveal(String path) async {}
