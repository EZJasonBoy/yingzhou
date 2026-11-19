import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'downloads.dart';
import 'engine_client.dart';
import 'models.dart';

bool get supported => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

bool get canShare => Platform.isAndroid;

/// Android's side: client/android/.../engine/AndroidChannel.kt.
const _android = MethodChannel('yingzhou/android');

Future<DownloadExportResult> saveExportToDownloads(EngineClient client, String id) async {
  if (!Platform.isAndroid) {
    final path = await saveExport(client, id);
    return DownloadExportResult(path: path, bytes: await File(path).length(), format: path.substring(path.lastIndexOf('.') + 1));
  }
  try {
    final r = await _android.invokeMapMethod<String, Object?>('saveExport', {'url': client.downloadExportUri(id).toString(), 'token': client.token});
    final path = r?['path'] as String? ?? '';
    return DownloadExportResult(
      path: path,
      bytes: (r?['bytes'] as num?)?.toInt() ?? 0,
      format: path.contains('.') ? path.substring(path.lastIndexOf('.') + 1) : '',
      uri: r?['uri'] as String? ?? '',
    );
  } on PlatformException catch (e) {
    throw EngineException('EXPORT_FAILED', e.message ?? e.code);
  }
}

Future<void> share(String uri, String title) async {
  try {
    await _android.invokeMethod<void>('share', {'uri': uri, 'title': title});
  } on PlatformException catch (e) {
    throw EngineException('SHARE_FAILED', e.message ?? e.code);
  }
}

Future<String> saveExport(EngineClient client, String id, {void Function(int bytes)? onProgress}) async {
  final folder = await getDownloadsDirectory() ?? Directory('${Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.'}/Downloads');
  await folder.create(recursive: true);
  final http.Client transport = http.Client();
  try {
    final response = await transport.send(client.exportRequest(id));
    if (response.statusCode != 200) {
      final text = await response.stream.bytesToString();
      String message = 'HTTP ${response.statusCode}';
      try {
        message = ((jsonDecode(text) as Map<String, dynamic>)['error'] as Map<String, dynamic>)['message'] as String;
      } catch (_) {}
      throw EngineException('EXPORT_FAILED', message, statusCode: response.statusCode);
    }
    final file = _unused(folder, _fileName(response.headers['content-disposition'], id));
    final part = File('${file.path}.part');
    var written = 0;
    final sink = part.openWrite();
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        written += chunk.length;
        onProgress?.call(written);
      }
      await sink.close();
    } catch (_) {
      await sink.close();
      if (await part.exists()) await part.delete();
      rethrow;
    }
    await part.rename(file.path);
    return file.path;
  } finally {
    transport.close();
  }
}

/// `filename*=UTF-8''<name>` (the real name) or `filename="..."`.
String _fileName(String? disposition, String id) {
  final header = disposition ?? '';
  final star = RegExp(r"filename\*=UTF-8''([^;]+)", caseSensitive: false).firstMatch(header);
  final plain = RegExp(r'filename="([^"]*)"').firstMatch(header);
  final name = star != null ? Uri.decodeComponent(star.group(1)!.trim()) : plain?.group(1) ?? 'video-$id.ts';
  return name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
}

File _unused(Directory folder, String name) {
  final dot = name.lastIndexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  var file = File('${folder.path}${Platform.pathSeparator}$name');
  for (var i = 2; file.existsSync(); i++) {
    file = File('${folder.path}${Platform.pathSeparator}$base ($i)$ext');
  }
  return file;
}

Future<void> reveal(String path) async {
  if (Platform.isWindows) {
    await Process.run('explorer.exe', ['/select,', path]);
  } else if (Platform.isMacOS) {
    await Process.run('open', ['-R', path]);
  } else if (Platform.isLinux) {
    await Process.run('xdg-open', [File(path).parent.path]);
  }
}
