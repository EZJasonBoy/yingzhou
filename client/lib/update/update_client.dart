import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart' show SimplePublicKey;

import 'manifest_signature.dart';
import 'release_info.dart';
import 'update_models.dart';

/// Fetches the release and its packages, trying the selected mirror before GitHub.
class UpdateClient {
  UpdateClient({
    this.latestUrl = latestJsonUrl,
    this.currentVersion = appVersion,
    this.timeout = const Duration(seconds: 15),
    this.verificationKey,
    HttpClient Function()? httpClient,
  }) : _newClient = httpClient ?? HttpClient.new;

  final String latestUrl;
  final String currentVersion;
  final SimplePublicKey? verificationKey;

  /// For each try at `latest.json`, and for a download to start answering.
  final Duration timeout;
  final HttpClient Function() _newClient;

  static const _maxJson = 1024 * 1024;

  List<(UpdateRoute, String)> _routes(String url, String mirror) => [if (mirror.isNotEmpty) (UpdateRoute.mirror, '$mirror$url'), (UpdateRoute.direct, url)];

  HttpClient _client(String proxy) {
    final client = _newClient()
      ..connectionTimeout = timeout
      ..userAgent = 'Yingzhou/$currentVersion';
    if (proxy.isNotEmpty) client.findProxy = (_) => 'PROXY $proxy';
    return client;
  }

  Future<UpdateCheckResult> check({String mirror = '', String proxy = ''}) async {
    final prefix = normalizeMirror(mirror);
    final failures = <String>[];
    final client = _client(proxy);
    try {
      for (final (route, url) in _routes(latestUrl, prefix)) {
        try {
          final release = await verifyUpdateManifest(await _getText(client, Uri.parse(url)), verificationKey: verificationKey);
          return UpdateCheckResult(
            current: currentVersion,
            at: DateTime.now(),
            release: release,
            route: route,
            mirror: prefix,
            proxy: proxy,
            failures: failures,
          );
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
      await response.listen(null).cancel();
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
    required String expectedSha256,
    String mirror = '',
    String proxy = '',
    int expectedSize = 0,
    void Function(int received, int total)? progress,
    bool Function()? cancelled,
  }) async {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedSha256)) throw const UpdateIntegrityException('更新清单缺少安装包的 SHA-256 摘要');
    for (final (route, address) in _routes(url, normalizeMirror(mirror))) {
      if (cancelled?.call() ?? false) throw const UpdateCancelled();
      try {
        return await _download(address, target, proxy, expectedSize, expectedSha256, progress, cancelled);
      } catch (error) {
        if (route == UpdateRoute.direct || error is UpdateCancelled || error is FileSystemException) rethrow;
      }
    }
    throw StateError('no update route');
  }

  Future<File> _download(
    String url,
    File target,
    String proxy,
    int expectedSize,
    String expectedSha256,
    void Function(int, int)? progress,
    bool Function()? cancelled,
  ) async {
    final client = _client(proxy);
    final part = File('${target.path}.part');
    IOSink? sink;
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.listen(null).cancel();
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
      final digest = await sha256.bind(part.openRead()).first;
      if (digest.toString() != expectedSha256) throw const UpdateIntegrityException('安装包的 SHA-256 与发布清单不符');
      if (cancelled?.call() ?? false) throw const UpdateCancelled();
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
  UpdateIntegrityException(:final message) => message,
  FileSystemException(:final message, :final path) => '无法保存文件：$message${path == null ? '' : '（$path）'}',
  _ => '$e',
};
