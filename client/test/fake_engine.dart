import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A tiny in-memory stand-in for the engine's HTTP API.
MockClient fakeEngine({bool hasConfig = false, List<Map<String, Object>> history = const []}) {
  var configured = hasConfig;
  final historyById = {for (final h in history) h['vodId'] as String: h};
  final favoritesById = <String, Map<String, dynamic>>{};

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
  // What the engine would fetch: with the GitHub proxy off, a proxy in front of a GitHub address is taken off.
  var settings = <String, dynamic>{'githubProxy': false, 'githubProxyPrefix': 'https://ghfast.top/'};
  // The summary as the engine would give it: with the proxy on, the config is fetched through it.
  Map<String, Object?> summarised() => {
    ...summary,
    'fetchedUrl': settings['githubProxy'] == true ? '${settings['githubProxyPrefix']}${summary['url']}' : summary['url'],
  };
  final noConfig = {
    'error': {'code': 'NO_CONFIG', 'message': 'no subscription is active'},
  };
  Map<String, Object> card(String id, String name) => {'site': 'cms', 'id': id, 'name': name, 'pic': '', 'remarks': 'HD'};

  return MockClient((request) async {
    final path = request.url.path;
    if (!configured && path.startsWith('/api/v1/sites')) return json(noConfig, 409);

    // Library: /history[/cms/<id>] and /favorites[/cms/<id>]
    final lib = RegExp(r'^/api/v1/(history|favorites)(?:/cms/(.+))?$').firstMatch(path);
    if (lib != null) {
      final store = lib.group(1) == 'history' ? historyById : favoritesById;
      final id = lib.group(2) == null ? null : Uri.decodeComponent(lib.group(2)!);
      if (id == null) {
        if (request.method == 'DELETE') {
          store.clear();
          return http.Response('', 204);
        }
        return json(store.values.toList());
      }
      switch (request.method) {
        case 'GET':
          return store.containsKey(id) ? json(store[id]!) : json({'error': {'code': 'NOT_FOUND', 'message': 'none'}}, 404);
        case 'PUT':
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          store[id] = {...body, 'site': 'cms', 'vodId': id};
          return json(store[id]!);
        case 'DELETE':
          store.remove(id);
          return http.Response('', 204);
      }
    }

    switch ((request.method, path)) {
      case ('GET', '/api/v1/info'):
        return json({
          'name': 'tvbox-engine',
          'version': '0.1.0',
          'protocol': 1,
          'platform': 'test',
          'capabilities': {'jar': false, 'js': false, 'py': false, 'sniff': false},
        });
      case ('GET', '/api/v1/settings'):
        return json(settings);
      case ('PUT', '/api/v1/settings'):
        settings = jsonDecode(request.body) as Map<String, dynamic>;
        return json(settings);
      case ('GET', '/api/v1/config'):
        return configured ? json(summarised()) : json(noConfig, 409);
      case ('GET', '/api/v1/sites'):
        return json(sites);
      case ('POST', '/api/v1/subscriptions'):
        final url = (jsonDecode(request.body) as Map<String, dynamic>)['url'];
        return json({'id': 's1', 'name': url, 'url': url}, 201);
      case ('POST', '/api/v1/subscriptions/s1/activate'):
        configured = true;
        return json(summarised());
      case ('GET', '/api/v1/sites/cms/home'):
        return json({
          'classes': [
            {'id': '1', 'name': '电影'},
          ],
          'filters': {
            '1': [
              {
                'key': 'year',
                'name': '年份',
                'values': [
                  {'name': '全部', 'value': ''},
                  {'name': '2024', 'value': '2024'},
                ],
              },
            ],
          },
          'list': [card('7', '推荐片')],
        });
      case ('GET', '/api/v1/sites/cms/category'):
        return json({'page': 1, 'pageCount': 1, 'total': 1, 'list': [card('8', '分类片')]});
      case ('GET', '/api/v1/sites/cms/detail'):
        return json({
          'site': 'cms',
          'id': request.url.queryParameters['id'],
          'name': '片名',
          'year': '2024',
          'content': '<p>简介</p>',
          'lines': [
            {
              'name': '线路一',
              'episodes': [
                {'id': 'https://cdn.test/1.m3u8', 'name': '第1集'},
                {'id': 'https://cdn.test/2.m3u8', 'name': '第2集'},
                // Sites sometimes reuse one url for several episodes.
                {'id': 'https://cdn.test/2.m3u8', 'name': '第3集'},
              ],
            },
          ],
        });
      case ('GET', '/api/v1/search/stream'):
        final sse = StringBuffer()
          ..write('event: site\ndata: {"site":"cms","status":"started"}\n\n')
          ..write('event: results\ndata: ${jsonEncode({'site': 'cms', 'items': [card('7', '推荐片')]})}\n\n')
          ..write('event: site\ndata: {"site":"cms","status":"done","count":1,"ms":5}\n\n')
          ..write('event: end\ndata: {"sites":1,"ms":6}\n\n');
        return http.Response.bytes(utf8.encode(sse.toString()), 200, headers: {'content-type': 'text/event-stream'});
    }
    return json({
      'error': {'code': 'NOT_FOUND', 'message': path},
    }, 404);
  });
}
