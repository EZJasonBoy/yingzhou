import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'release_info.dart';
import 'update_models.dart';

/// Asks for `latest.json` and downloads packages. GitHub directly first; when that fails, through the user's
/// GitHub accelerating prefix (the engine's setting, when it is on). Everything goes through the HTTP proxy when
/// one is set — only these requests, nothing else in the app.
class UpdateClient {
  UpdateClient({
    this.latestUrl = latestJsonUrl,
    this.currentVersion = appVersion,
    this.timeout = const Duration(seconds: 15),
    HttpClient Function()? httpClient,
  }) : _newClient = httpClient ?? HttpClient.new;

  final String latestUrl;
  final String currentVersion;

  /// For each try at `latest.json`, and for a download to start answering.
  final Duration timeout;
  final HttpClient Function() _newClient;

  static const _maxJson = 1024 * 1024;

  HttpClient _client(String proxy) {
    final client = _newClient()
      ..connectionTimeout = timeout
      ..userAgent = 'Yingzhou/$currentVersion';
    if (proxy.isNotEmpty) client.findProxy = (_) => 'PROXY $proxy';
    return client;
  }

  Future<UpdateCheckResult> check({String mirror = '', String proxy = ''}) async {
    final prefix = normalizeMirror(mirror);
    final routes = [(UpdateRoute.direct, latestUrl), if (prefix.isNotEmpty) (UpdateRoute.mirror, '$prefix$latestUrl')];
    final failures = <String>[];
    final client = _client(proxy);
    try {
      for (final (route, url) in routes) {
        try {
          final release = ReleaseInfo.fromJson(jsonDecode(await _getText(client, Uri.parse(url))));
          return UpdateCheckResult(current: currentVersion, at: DateTime.now(), release: release, route: route, mirror: prefix, proxy: proxy, failures: failures);
        } on Object catch (e) {
          failures.add('${route == UpdateRoute.direct ? '直连 GitHub' : '经加速前缀 ${mirrorHost(prefix)}'}：${describeFailure(e)}');
        }
      }
    } finally {
      client.close(force: true);
    }
    return UpdateCheckResult(current: currentVersion, at: DateTime.now(), mirror: prefix, proxy: proxy, failures: failures);
  }

  Future<String> _getText(HttpClient client, Uri url) async {
    final request = await client.getUrl(url).timeout(timeout);
    final response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>().catchError((_) {});
      throw HttpException('HTTP ${response.statusCode}', uri: url);
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > _maxJson) throw const FormatException('too large');
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Saves [url] as [target] (through `<target>.part`, so a half-done file never has the real name). [progress]
  /// gets bytes so far and the total (0 when unknown); [cancelled] is asked between chunks. With [expectedSize]
  /// (the manifest's), a file of another size is refused: a proxy's error page answered with 200, a cut transfer.
  Future<File> download(
    String url,
    File target, {
    String proxy = '',
    int expectedSize = 0,
    void Function(int received, int total)? progress,
    bool Function()? cancelled,
  }) async {
    final client = _client(proxy);
    final part = File('${target.path}.part');
    IOSink? sink;
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>().catchError((_) {});
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      }
      final total = response.contentLength < 0 ? 0 : response.contentLength;
      await part.parent.create(recursive: true);
      sink = part.openWrite();
      var received = 0;
      // A stalled transfer counts as failed after a minute without a byte.
      await for (final chunk in response.timeout(const Duration(minutes: 1))) {
        if (cancelled?.call() ?? false) throw const UpdateCancelled();
        sink.add(chunk);
        received += chunk.length;
        progress?.call(received, total);
      }
      await sink.close();
      sink = null;
      if (total > 0 && received != total) throw HttpException('incomplete: $received of $total bytes', uri: Uri.parse(url));
      if (expectedSize > 0 && received != expectedSize) throw HttpException('wrong size: $received bytes, not $expectedSize', uri: Uri.parse(url));
      if (await target.exists()) await target.delete();
      return await part.rename(target.path);
    } catch (_) {
      await sink?.close().catchError((_) {});
      if (await part.exists()) await part.delete().catchError((_) => part);
      rethrow;
    } finally {
      client.close(force: true);
    }
  }
}

class UpdateCancelled implements Exception {
  const UpdateCancelled();
}

/// A failure the way the user is told about it.
String describeFailure(Object e) => switch (e) {
  TimeoutException() => '超时',
  HandshakeException() => '安全连接失败',
  SocketException() => '连不上',
  HttpException(:final message) when message.startsWith('HTTP 404') => '没有找到更新信息（HTTP 404）',
  HttpException(:final message) when message.startsWith('incomplete') => '下载不完整',
  HttpException(:final message) when message.startsWith('wrong size') => '下载到的文件大小不对，可能不是安装包（换一条路再试）',
  HttpException(:final message) => message,
  FormatException() => '更新信息的格式不对',
  UpdateCancelled() => '已取消',
  FileSystemException(:final message, :final path) => '无法保存文件：$message${path == null ? '' : '（$path）'}',
  _ => '$e',
};
