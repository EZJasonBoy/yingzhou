import 'dart:convert';

import 'package:http/http.dart' as http;

/// Puts the engine's access rules in front of [inner] (usually `fakeEngine()`): every request except
/// `GET /api/v1/info` and `POST /api/v1/pair` needs `Authorization: Bearer <a token from pairing>`.
///
/// Pairing takes [code]; a wrong code is refused, an empty one answers `PAIR_CODE_REQUIRED`. [revoke] drops a
/// token. With [local] the engine also answers `/api/v1/lan` like the engine on this machine does (no token needed).
/// [authorizations] records the Authorization header of every request, by path.
class FakeLanEngine extends http.BaseClient {
  FakeLanEngine(this.inner, {this.code = '123456', this.local = false});

  final http.Client inner;
  final String code;
  final bool local;
  final tokens = <String>{};
  final authorizations = <(String, String?)>[];
  final pairedNames = <String>[];
  bool sharing = false;
  var devices = <Map<String, Object>>[];
  int codeRequests = 0;

  void revoke(String token) => tokens.remove(token);

  http.StreamedResponse _json(Object body, [int status = 200]) =>
      http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(body))), status, headers: {'content-type': 'application/json; charset=utf-8'});

  http.StreamedResponse _error(String code, String message, int status) => _json({
    'error': {'code': code, 'message': message},
  }, status);

  Map<String, Object> _lan() => {
    'supported': true,
    'enabled': sharing,
    'forced': false,
    'listening': sharing,
    'name': '测试引擎',
    'port': 9978,
    'addresses': sharing ? ['http://192.168.1.5:9978'] : <String>[],
    'discoverable': sharing,
    'code': sharing ? code : '',
    'codeExpiresAt': DateTime.now().add(const Duration(minutes: 10)).millisecondsSinceEpoch,
    'lockedUntil': 0,
    'devices': devices,
  };

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    final auth = request.headers['Authorization'];
    authorizations.add((path, auth));
    final body = request is http.Request && request.body.isNotEmpty ? jsonDecode(request.body) as Map<String, dynamic> : const <String, dynamic>{};

    if (path == '/api/v1/pair' && request.method == 'POST') {
      final entered = body['code'] as String? ?? '';
      if (entered.isEmpty) {
        codeRequests++;
        return _error('PAIR_CODE_REQUIRED', '请输入引擎上显示的配对码', 400);
      }
      if (entered != code) return _error('PAIR_CODE_WRONG', '配对码不对或已过期，还能再试 4 次', 403);
      final token = 'dev${tokens.length + 1}.secret';
      tokens.add(token);
      pairedNames.add(body['name'] as String? ?? '');
      return _json({'token': token, 'deviceId': 'dev${tokens.length}', 'name': body['name'] ?? ''});
    }
    if (local && path.startsWith('/api/v1/lan')) {
      if (request.method == 'PUT') sharing = body['enabled'] == true;
      if (request.method == 'DELETE') {
        final id = path.split('/').last;
        devices = [
          for (final d in devices)
            if (d['id'] != id) d,
        ];
        return http.StreamedResponse(const Stream.empty(), 204);
      }
      return _json(_lan());
    }
    final public = path == '/api/v1/info';
    if (!local && !public) {
      final token = auth != null && auth.startsWith('Bearer ') ? auth.substring(7) : null;
      if (token == null || !tokens.contains(token)) {
        return _error('UNAUTHORIZED', token == null ? '需要先与这台引擎配对' : '令牌无效或已被撤销，请重新配对', 401);
      }
    }
    return inner.send(request);
  }
}
