import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A tiny in-memory stand-in for the engine's HTTP API.
MockClient fakeEngine({bool hasConfig = false}) {
  var configured = hasConfig;

  http.Response json(Object body, [int status = 200]) => http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  final summary = {
    'subscriptionId': 's1',
    'url': 'http://example.test/tv.json',
    'repos': <Object>[],
    'sites': 2,
    'parses': 0,
    'lives': 0,
    'spider': '',
    'wallpaper': '',
  };
  final sites = [
    {'key': 'cms', 'name': '采集站', 'type': 1, 'searchable': true, 'quickSearch': true, 'filterable': true, 'runtime': 'cms'},
    {'key': 'js1', 'name': '脚本站', 'type': 3, 'searchable': false, 'quickSearch': true, 'filterable': true, 'runtime': 'js'},
  ];
  final noConfig = {
    'error': {'code': 'NO_CONFIG', 'message': 'no subscription is active'},
  };

  return MockClient((request) async {
    final path = request.url.path;
    switch ((request.method, path)) {
      case ('GET', '/api/v1/info'):
        return json({
          'name': 'tvbox-engine',
          'version': '0.1.0',
          'protocol': 1,
          'platform': 'test',
          'capabilities': {'jar': false, 'js': false, 'py': false, 'sniff': false},
        });
      case ('GET', '/api/v1/config'):
        return configured ? json(summary) : json(noConfig, 409);
      case ('GET', '/api/v1/sites'):
        return configured ? json(sites) : json(noConfig, 409);
      case ('POST', '/api/v1/subscriptions'):
        final url = (jsonDecode(request.body) as Map<String, dynamic>)['url'];
        return json({'id': 's1', 'name': url, 'url': url}, 201);
      case ('POST', '/api/v1/subscriptions/s1/activate'):
        configured = true;
        return json(summary);
    }
    return json({
      'error': {'code': 'NOT_FOUND', 'message': path},
    }, 404);
  });
}
