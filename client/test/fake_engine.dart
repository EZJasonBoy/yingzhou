import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A line of [count] episodes named 第1集, 第2集, … whose addresses carry the line's [tag].
Map<String, Object> fakeLine(String name, String tag, {int count = 3}) => {
  'name': name,
  'episodes': [
    for (var i = 1; i <= count; i++) {'id': 'https://cdn.test/$tag/$i.m3u8', 'name': '第$i集'},
  ],
};

/// A tiny in-memory stand-in for the engine's HTTP API.
///
/// [lines] replaces the play lines every detail comes with. `/play/resolve` hands back the episode's own address,
/// except on the lines named in [deadLines], which fail; it notes each line it is asked about in [resolved]. The
/// history the app saves ends up in [savedHistory], by video id.
///
/// With [streamCache] the engine has a stream cache: the map is its `/api/v1/stream-cache` answer (emptied by
/// DELETE), `/play/resolve` names the cache key `k1`, and [coverage] is what the cache holds of that film, as
/// `[startMs, endMs]` pairs. [settingsSent] collects the bodies of `PUT /api/v1/settings`.
///
/// [subtitles] are what `/play/resolve` says the site gave for an episode, by episode id (`*` for every episode).
/// `POST /api/v1/subtitle/convert` answers SRT text that names the file.
///
/// [danmaku] are the site's danmaku by episode id (`*` for every episode), as `GET /api/v1/danmaku` items; the
/// requests for them are noted in [danmakuAsked]. With [danmakuConfigApi] (the config's `danmaku` field, '' for
/// none) the engine answers `/danmaku/services`, so the 弹幕 card shows on the 源 page. `POST /api/v1/danmaku/parse` gives one comment that names the file.
///
/// Several sites, for looking a title up elsewhere: [cmsSite] is laid over the `cms` site's entry (e.g.
/// `{'changeable': false}`), [extraSites] come after the two default sites, [homeList] replaces the cards of
/// `cms`'s home. [details] are detail answers by `'<site>/<id>'` (for `cms` they replace the default one; any
/// other site without an entry answers SITE_BAD_RESULT). With [searchHits] (cards by site, in the order the sites
/// answer) `/search/stream` answers those, only for the sites in `sites=` when it is given. [searchAsked] notes
/// each search as `'<keyword>|<sites>'`, [detailAsked] each detail as `'<site>/<id>'`, [resolvedAt] each resolve
/// as `'<site>:<line>'`. History and favourites work for any site (stored by id for `cms`, else `'<site>/<id>'`).
///
/// A multi-repository config: [repos] are the summary's entries; `activate` with `{"repo": url}` makes that entry
/// the summary's url (502 for one in [failRepos]). [homeByConfig] gives `cms`'s home cards by the summary's url.
MockClient fakeEngine({
  bool hasConfig = false,
  List<Map<String, Object>> history = const [],
  List<Map<String, Object>>? lines,
  Set<String> deadLines = const {},
  List<String>? resolved,
  Map<String, Map<String, dynamic>>? savedHistory,
  Map<String, Object>? streamCache,
  List<List<int>> coverage = const [],
  List<Map<String, dynamic>>? settingsSent,
  Map<String, List<Map<String, Object>>> subtitles = const {},
  Map<String, List<Map<String, Object>>> danmaku = const {},
  List<Uri>? danmakuAsked,
  String? danmakuConfigApi,
  List<Map<String, Object>>? savedSubscriptions,
  bool relays = false,
  List<bool>? directAsked,
  int filterRows = 1,
  Map<String, Object> cmsSite = const {},
  List<Map<String, Object>> extraSites = const [],
  List<Map<String, Object>>? homeList,
  Map<String, Map<String, Object>> details = const {},
  Map<String, List<Map<String, Object>>> searchHits = const {},
  List<String>? searchAsked,
  List<String>? detailAsked,
  List<String>? resolvedAt,
  List<Map<String, Object>>? repos,
  Set<String> failRepos = const {},
  Map<String, List<Map<String, Object>>> homeByConfig = const {},
}) {
  var configured = hasConfig;
  // With [savedSubscriptions] the engine keeps a list like the real one: `GET`, rename (`PUT`), `DELETE`, and
  // `activate` of any of them (which stamps `usedAt` and makes it the summary's subscription).
  final subs = savedSubscriptions;
  var clock = 1000;
  final historyById = <String, Map<String, dynamic>>{for (final h in history) h['vodId'] as String: h};
  final favoritesById = <String, Map<String, dynamic>>{};

  http.Response json(Object body, [int status = 200]) => http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  final summary = {
    'subscriptionId': 's1',
    'url': 'http://example.test/tv.json',
    'repos': repos ?? <Object>[],
    'sites': 2,
    'parses': 0,
    'lives': 0,
    'spider': '',
    'wallpaper': '',
  };
  final sites = [
    {'key': 'cms', 'name': '采集站', 'type': 1, 'searchable': true, 'quickSearch': true, 'filterable': true, 'runtime': 'cms', ...cmsSite},
    {'key': 'js1', 'name': '脚本站', 'type': 3, 'searchable': false, 'quickSearch': true, 'filterable': true, 'runtime': 'js'},
    ...extraSites,
  ];
  // activate's body: `{"repo": url}` picks an entry of a multi-repository config.
  http.Response? activateRepo(http.Request request) {
    if (repos == null || request.body.isEmpty) return null;
    final repo = (jsonDecode(request.body) as Map<String, dynamic>)['repo'] as String?;
    if (repo == null) return null;
    if (failRepos.contains(repo)) {
      return http.Response.bytes(utf8.encode(jsonEncode({'error': {'code': 'CONFIG_LOAD_FAILED', 'message': '$repo 打不开'}})), 502, headers: {'content-type': 'application/json; charset=utf-8'});
    }
    summary['url'] = repo;
    return null;
  }
  // What the engine would fetch: with the GitHub proxy off, a proxy in front of a GitHub address is taken off.
  var settings = <String, dynamic>{'githubProxy': false, 'githubProxyPrefix': 'https://ghfast.top/', 'streamCache': true, 'streamCacheMaxMB': 2048};
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

    final subPath = RegExp(r'^/api/v1/subscriptions(?:/([^/]+)(/activate)?)?$').firstMatch(path);
    if (subs != null && subPath != null) {
      final id = subPath.group(1);
      Map<String, Object>? find() => subs.where((s) => s['id'] == id).firstOrNull;
      final missing = json({'error': {'code': 'NOT_FOUND', 'message': 'subscription $id'}}, 404);
      switch ((request.method, id, subPath.group(2))) {
        case ('GET', null, null):
          return json(subs);
        case ('POST', null, null):
          final url = (jsonDecode(request.body) as Map<String, dynamic>)['url'] as String;
          final existing = subs.where((s) => s['url'] == url).firstOrNull;
          final sub = existing ?? {'id': 'n${subs.length + 1}', 'name': url, 'url': url, 'usedAt': 0};
          if (existing == null) subs.add(sub);
          return json(sub, 201);
        case ('POST', _, '/activate'):
          final sub = find();
          if (sub == null) return missing;
          sub['usedAt'] = clock++;
          summary['subscriptionId'] = sub['id']!;
          summary['url'] = sub['url']!;
          final failed = activateRepo(request);
          if (failed != null) return failed;
          configured = true;
          return json(summarised());
        case ('PUT', _, null):
          final sub = find();
          if (sub == null) return missing;
          final name = ((jsonDecode(request.body) as Map<String, dynamic>)['name'] as String).trim();
          sub['name'] = name.isEmpty ? sub['url']! : name;
          return json(sub);
        case ('DELETE', _, null):
          if (find() == null) return missing;
          subs.removeWhere((s) => s['id'] == id);
          if (summary['subscriptionId'] == id) configured = false;
          return http.Response('', 204);
      }
    }

    // Library: /history[/<site>/<id>] and /favorites[/<site>/<id>]
    final lib = RegExp(r'^/api/v1/(history|favorites)(?:/([^/]+)/(.+))?$').firstMatch(path);
    if (lib != null) {
      final store = lib.group(1) == 'history' ? historyById : favoritesById;
      final libSite = lib.group(2) == null ? 'cms' : Uri.decodeComponent(lib.group(2)!);
      final vodId = lib.group(3) == null ? null : Uri.decodeComponent(lib.group(3)!);
      final id = vodId == null ? null : (libSite == 'cms' ? vodId : '$libSite/$vodId');
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
          store[id] = {...body, 'site': libSite, 'vodId': vodId!};
          if (lib.group(1) == 'history') savedHistory?[id] = store[id]!;
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
        // Like the engine: what is sent is laid over what is there.
        final sent = jsonDecode(request.body) as Map<String, dynamic>;
        settingsSent?.add(sent);
        settings = {...settings, ...sent};
        return json(settings);
      case ('GET', '/api/v1/stream-cache') when streamCache != null:
        return json({...streamCache, 'enabled': settings['streamCache'] ?? true, 'maxBytes': ((settings['streamCacheMaxMB'] ?? 2048) as int) * 1024 * 1024});
      case ('DELETE', '/api/v1/stream-cache') when streamCache != null:
        streamCache['bytes'] = 0;
        streamCache['files'] = 0;
        streamCache['streams'] = 0;
        return json({...streamCache, 'enabled': settings['streamCache'] ?? true, 'maxBytes': ((settings['streamCacheMaxMB'] ?? 2048) as int) * 1024 * 1024});
      case ('GET', '/api/v1/stream-cache/coverage') when streamCache != null:
        return json({'durationMs': 2400000, 'ranges': request.url.queryParameters['key'] == 'k1' ? coverage : <Object>[]});
      case ('GET', '/api/v1/config'):
        return configured ? json(summarised()) : json(noConfig, 409);
      case ('GET', '/api/v1/sites'):
        return json(sites);
      case ('POST', '/api/v1/subscriptions'):
        final url = (jsonDecode(request.body) as Map<String, dynamic>)['url'];
        return json({'id': 's1', 'name': url, 'url': url}, 201);
      case ('POST', '/api/v1/subscriptions/s1/activate'):
        final failed = activateRepo(request);
        if (failed != null) return failed;
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
              // More rows, as sites with many filters have (area, language, sort …).
              for (var i = 2; i <= filterRows; i++)
                {
                  'key': 'f$i',
                  'name': '筛选$i',
                  'values': [
                    {'name': '全部', 'value': ''},
                    for (var v = 1; v <= 5; v++) {'name': '选项$i-$v', 'value': '$v'},
                  ],
                },
            ],
          },
          'list': homeByConfig[summary['url']] ?? homeList ?? [card('7', '推荐片')],
        });
      case ('GET', '/api/v1/sites/cms/category'):
        return json({'page': 1, 'pageCount': 1, 'total': 1, 'list': [card('8', '分类片')]});
      case ('GET', '/api/v1/sites/cms/detail') when details.containsKey('cms/${request.url.queryParameters['id']}'):
        detailAsked?.add('cms/${request.url.queryParameters['id']}');
        return json(details['cms/${request.url.queryParameters['id']}']!);
      case ('GET', '/api/v1/sites/cms/detail'):
        detailAsked?.add('cms/${request.url.queryParameters['id']}');
        return json({
          'site': 'cms',
          'id': request.url.queryParameters['id'],
          'name': '片名',
          'year': '2024',
          'content': '<p>简介</p>',
          'lines':
              lines ??
              [
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
      case ('POST', '/api/v1/play/resolve'):
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final line = body['line'] as String;
        resolved?.add(line);
        resolvedAt?.add('${body['site']}:$line');
        // With [relays], a resolve that asks for `direct` gets the address plus `?d=1`, and as the relay through the
        // engine the address plus `?relay=1` (cache key k1), like an engine with its stream cache on.
        final direct = body['direct'] == true;
        directAsked?.add(direct);
        if (deadLines.contains(line)) {
          return json({
            'error': {'code': 'PLAY_FAILED', 'message': '$line 取不到播放地址'},
          }, 502);
        }
        if (relays && direct) {
          return json({'kind': 'direct', 'url': '${body['episodeId']}?d=1', 'relay': '${body['episodeId']}?relay=1', 'cache': 'k1'});
        }
        return json({
          'kind': 'direct',
          'url': body['episodeId'],
          'headers': <String, String>{},
          'parsedBy': '',
          'cache': streamCache == null ? '' : 'k1',
          'subtitles': subtitles[body['episodeId']] ?? subtitles['*'] ?? const <Object>[],
        });
      case ('GET', '/api/v1/danmaku'):
        danmakuAsked?.add(request.url);
        final items = danmaku[request.url.queryParameters['episodeId']] ?? danmaku['*'];
        return json({'source': items == null ? '' : 'site', 'from': '', 'count': items?.length ?? 0, 'items': items ?? const <Object>[]});
      case ('POST', '/api/v1/danmaku/parse'):
        final name = (jsonDecode(request.body) as Map<String, dynamic>)['name'];
        return json({
          'source': 'file',
          'from': name,
          'count': 1,
          'items': [
            {'time': 0, 'mode': 'scroll', 'color': 16777215, 'size': 25, 'text': 'file:$name'},
          ],
        });
      case ('GET', '/api/v1/danmaku/services') when danmakuConfigApi != null:
        return json({'configApi': danmakuConfigApi, 'configApiEnabled': settings['danmakuConfigApi'] ?? false, 'customApi': settings['danmakuApi'] ?? ''});
      case ('POST', '/api/v1/subtitle/convert'):
        final name = (jsonDecode(request.body) as Map<String, dynamic>)['name'];
        return json({'format': 'srt', 'text': '1\n00:00:01,000 --> 00:00:02,000\n$name\n'});
      // Live TV: one source; 回看台 has two days of catch-up, 普通台 none. The guide has a programme every two hours
      // of the China-time day asked for (today when no date), titled "<MM-dd> 节目 <n>".
      case ('GET', '/api/v1/live'):
        return json([
          {'index': 0, 'name': '测试直播', 'hasEpg': true, 'supported': true, 'spider': ''},
        ]);
      case ('GET', '/api/v1/live/0'):
        return json({
          'source': 0,
          'name': '测试直播',
          'groups': [
            {
              'name': '测试组',
              'channels': [
                {'name': '回看台', 'logo': '', 'catchupDays': 2, 'urls': [{'url': 'https://cdn.test/live/a.m3u8', 'label': '', 'headers': <String, String>{}}]},
                {'name': '普通台', 'logo': '', 'catchupDays': 0, 'urls': [{'url': 'https://cdn.test/live/b.m3u8', 'label': '', 'headers': <String, String>{}}]},
              ],
            },
          ],
        });
      case ('GET', '/api/v1/live/0/epg'):
        final now = DateTime.now().toUtc().add(const Duration(hours: 8));
        final today = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
        final date = request.url.queryParameters['date'] ?? today;
        final parts = date.split('-').map(int.parse).toList();
        final midnight = DateTime.utc(parts[0], parts[1], parts[2]).subtract(const Duration(hours: 8));
        return json({
          'channel': request.url.queryParameters['channel'],
          'date': date,
          // From two hours before midnight (节目 0), as guides that list the programme running into the day do: so
          // at any time of day, the first two hours included, a programme that has ended sits above the one on air.
          'programs': [
            for (var i = -1; i < 12; i++)
              {
                'start': midnight.add(Duration(hours: 2 * i)).millisecondsSinceEpoch,
                'end': midnight.add(Duration(hours: 2 * i + 2)).millisecondsSinceEpoch,
                'title': '${date.substring(5)} 节目 ${i + 1}',
              },
          ],
        });
      case ('GET', '/api/v1/live/0/catchup'):
        final q = request.url.queryParameters;
        if (q['channel'] != '回看台') {
          return json({
            'error': {'code': 'BAD_REQUEST', 'message': 'no catch-up'},
          }, 400);
        }
        return json({'url': 'https://cdn.test/catchup/a.m3u8?start=${q['start']}&end=${q['end']}', 'headers': <String, String>{}, 'line': 0, 'alternates': <Object>[]});
      case ('GET', '/api/v1/search/stream') when searchHits.isNotEmpty:
        final wd = request.url.queryParameters['wd'] ?? '';
        final only = request.url.queryParameters['sites']?.split(',').toSet();
        searchAsked?.add('$wd|${request.url.queryParameters['sites'] ?? ''}');
        final asked = [for (final site in searchHits.keys) if (only == null || only.contains(site)) site];
        final sse = StringBuffer();
        for (final site in asked) {
          sse.write('event: site\ndata: ${jsonEncode({'site': site, 'status': 'started'})}\n\n');
          final items = searchHits[site]!;
          if (items.isNotEmpty) sse.write('event: results\ndata: ${jsonEncode({'site': site, 'items': items})}\n\n');
          sse.write('event: site\ndata: ${jsonEncode({'site': site, 'status': 'done', 'count': items.length, 'ms': 5})}\n\n');
        }
        sse.write('event: end\ndata: ${jsonEncode({'sites': asked.length, 'ms': 6})}\n\n');
        return http.Response.bytes(utf8.encode(sse.toString()), 200, headers: {'content-type': 'text/event-stream'});
      case ('GET', '/api/v1/search/stream'):
        searchAsked?.add('${request.url.queryParameters['wd'] ?? ''}|${request.url.queryParameters['sites'] ?? ''}');
        final sse = StringBuffer()
          ..write('event: site\ndata: {"site":"cms","status":"started"}\n\n')
          ..write('event: results\ndata: ${jsonEncode({'site': 'cms', 'items': [card('7', '推荐片')]})}\n\n')
          ..write('event: site\ndata: {"site":"cms","status":"done","count":1,"ms":5}\n\n')
          ..write('event: end\ndata: {"sites":1,"ms":6}\n\n');
        return http.Response.bytes(utf8.encode(sse.toString()), 200, headers: {'content-type': 'text/event-stream'});
    }
    final otherDetail = RegExp(r'^/api/v1/sites/([^/]+)/detail$').firstMatch(path);
    if (request.method == 'GET' && otherDetail != null) {
      final key = '${Uri.decodeComponent(otherDetail.group(1)!)}/${request.url.queryParameters['id']}';
      detailAsked?.add(key);
      final body = details[key];
      return body != null ? json(body) : json({'error': {'code': 'SITE_BAD_RESULT', 'message': 'detail is empty'}}, 502);
    }
    return json({
      'error': {'code': 'NOT_FOUND', 'message': path},
    }, 404);
  });
}
