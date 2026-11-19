import 'engine_client.dart';
import 'models.dart';

const bool supported = false;

Future<String> saveExport(EngineClient client, String id, {void Function(int bytes)? onProgress}) async =>
    throw const EngineException('UNSUPPORTED', '这个平台不能保存文件');

Future<void> reveal(String path) async {}
