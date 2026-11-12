import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// Client for engine protocol v1. The same client talks to the built-in engine and to remote ones.
class EngineClient {
  EngineClient(this.baseUrl, {http.Client? httpClient, this.token})
      : _http = httpClient ?? http.Client();

  /// e.g. `http://127.0.0.1:9978`
  final Uri baseUrl;
  final String? token;
  final http.Client _http;

  static const timeout = Duration(seconds: 60);

  Future<EngineInfo> info() async => EngineInfo.fromJson(await _send('GET', 'info'));

  Future<List<Subscription>> subscriptions() async => [
        for (final s in await _send('GET', 'subscriptions') as List<dynamic>)
          Subscription.fromJson(s as Map<String, dynamic>),
      ];

  Future<Subscription> addSubscription(String url, {String? name}) async =>
      Subscription.fromJson(await _send('POST', 'subscriptions', body: {
        'url': url,
        if (name != null && name.isNotEmpty) 'name': name,
      }));

  Future<void> removeSubscription(String id) => _send('DELETE', 'subscriptions/$id');

  /// Loads a subscription. For a multi-repository subscription, [repo] picks the entry (default: first).
  Future<ConfigSummary> activate(String id, {String? repo}) async =>
      ConfigSummary.fromJson(await _send('POST', 'subscriptions/$id/activate', body: {
        'repo': ?repo,
      }));

  Future<ConfigSummary> config() async => ConfigSummary.fromJson(await _send('GET', 'config'));

  Future<List<SiteInfo>> sites() async => [
        for (final s in await _send('GET', 'sites') as List<dynamic>)
          SiteInfo.fromJson(s as Map<String, dynamic>),
      ];

  void close() => _http.close();

  Future<dynamic> _send(String method, String path, {Object? body}) async {
    final request = http.Request(method, baseUrl.resolve('/api/v1/$path'));
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    final http.Response response;
    try {
      response = await http.Response.fromStream(await _http.send(request).timeout(timeout));
    } on Exception catch (e) {
      throw EngineException('UNREACHABLE', '无法连接引擎：$e');
    }

    final text = utf8.decode(response.bodyBytes);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return text.isEmpty ? null : jsonDecode(text);
    }
    try {
      final error = (jsonDecode(text) as Map<String, dynamic>)['error'] as Map<String, dynamic>;
      throw EngineException(
        error['code'] as String,
        error['message'] as String,
        statusCode: response.statusCode,
      );
    } on EngineException {
      rethrow;
    } catch (_) {
      throw EngineException('HTTP_${response.statusCode}', text, statusCode: response.statusCode);
    }
  }
}
