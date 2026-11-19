import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/pages/cache_settings.dart';
import 'package:tvbox_client/ui/poster_cache.dart';

import 'fake_engine.dart';

/// The fake engine with a data cache: `/config` tells how old the config is and whether it is the kept copy,
/// `/config/reload` downloads it "again" (or fails while [offline]), `/cache` has a size. Every request is noted.
class _CachingEngine extends http.BaseClient {
  _CachingEngine({this.stored = false, this.refreshing = 0, this.offline = false});

  /// Started from the kept copy.
  bool stored;

  /// How many more times `/config` says the copy is still being checked against the network.
  int refreshing;
  bool offline;
  String refreshError = '';
  int fetchedAt = DateTime(2026, 11, 3, 21, 40).millisecondsSinceEpoch;
  int cacheBytes = 3 * 1024 * 1024;
  final requests = <String>[];
  final http.Client _inner = fakeEngine(hasConfig: true);

  http.StreamedResponse _json(Object body, [int status = 200]) =>
      http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(body))), status, headers: {'content-type': 'application/json; charset=utf-8'});

  Map<String, Object?> _summary() => {
    'subscriptionId': 's1',
    'url': 'http://example.test/tv.json',
    'repos': <Object>[],
    'sites': 2,
    'parses': 0,
    'lives': 0,
    'spider': '',
    'wallpaper': '',
    'fetchedAt': fetchedAt,
    'stored': stored,
    'refreshing': refreshing > 0,
    'refreshError': refreshError,
  };

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final query = request.url.query;
    requests.add('${request.method} ${request.url.path.replaceFirst('/api/v1', '')}${query.isEmpty ? '' : '?$query'}');
    switch ((request.method, request.url.path)) {
      case ('GET', '/api/v1/config'):
        final answer = _summary();
        if (refreshing > 0 && --refreshing == 0) {
          // The check is over: the network confirmed the copy, or could not be reached.
          if (offline) {
            refreshError = 'example.test: timeout';
          } else {
            stored = false;
            fetchedAt = DateTime.now().millisecondsSinceEpoch;
          }
        }
        return _json(answer);
      case ('POST', '/api/v1/config/reload'):
        if (offline) {
          refreshError = 'example.test: timeout';
          return _json({
            'error': {'code': 'CONFIG_LOAD_FAILED', 'message': 'example.test: timeout'},
          }, 502);
        }
        stored = false;
        refreshError = '';
        fetchedAt = DateTime.now().millisecondsSinceEpoch;
        return _json(_summary());
      case ('GET', '/api/v1/cache'):
        return _json({'bytes': cacheBytes, 'entries': cacheBytes == 0 ? 0 : 12, 'areas': <String, Object>{}});
      case ('DELETE', '/api/v1/cache'):
        cacheBytes = 0;
        return _json({'bytes': 0, 'entries': 0, 'areas': <String, Object>{}});
    }
    return _inner.send(request);
  }
}

/// A poster cache of a given size that touches no disk (widget tests run on a fake clock).
class _MemoryPosters implements PosterCache {
  int bytes = 0;

  @override
  Future<Uint8List> load(String url, {Map<String, String>? headers}) async => Uint8List(0);

  @override
  Future<int> size() async => bytes;

  @override
  Future<void> clear() async => bytes = 0;
}

void main() {
  Future<void> pumpApp(WidgetTester tester, http.Client engine) async {
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TvboxApp(
        state: AppState(clientFactory: (url) => EngineClient(url, httpClient: engine), waitStep: const Duration(milliseconds: 10)),
      ),
    );
    await tester.pumpAndSettle();
  }

  String freshness(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('config-freshness'))).data!;

  testWidgets('the home page comes from the engine\'s cache until the refresh button asks the site again', (tester) async {
    final engine = _CachingEngine();
    await pumpApp(tester, engine);
    expect(find.text('推荐片'), findsOneWidget);
    await tester.tap(find.text('电影'));
    await tester.pumpAndSettle();
    expect(engine.requests.where((r) => r.contains('refresh')), isEmpty, reason: 'browsing never forces a refresh');

    engine.requests.clear();
    await tester.tap(find.byKey(const Key('home-refresh')));
    await tester.pumpAndSettle();
    expect(engine.requests, contains('GET /sites/cms/home?refresh=1'));
    expect(find.text('推荐片'), findsOneWidget);
    await tester.tap(find.text('电影'));
    await tester.pumpAndSettle();
    expect(engine.requests.where((r) => r.startsWith('GET /sites/cms/category')).single, contains('refresh=1'), reason: 'the categories are fetched anew too');
    expect(find.text('分类片'), findsOneWidget);

    // A detail has its own button.
    await tester.tap(find.text('分类片'));
    await tester.pumpAndSettle();
    expect(engine.requests.last.contains('refresh'), isFalse);
    engine.requests.clear();
    await tester.tap(find.byKey(const Key('detail-refresh')));
    await tester.pumpAndSettle();
    expect(engine.requests.where((r) => r.startsWith('GET /sites/cms/detail')).single, contains('refresh=1'));
    expect(find.text('片名'), findsOneWidget);
  });

  testWidgets('a kept copy of the subscription is named as one, and 刷新 downloads it again', (tester) async {
    final engine = _CachingEngine(stored: true, offline: true)..refreshError = 'example.test: timeout';
    await pumpApp(tester, engine);
    expect(find.text('推荐片'), findsOneWidget, reason: 'the app works from the copy');
    await tester.tap(find.text('源'));
    await tester.pumpAndSettle();
    expect(freshness(tester), startsWith('没能获取到最新的订阅，用的是'));
    expect(freshness(tester), contains('11-03 21:40'));
    expect(freshness(tester), contains('example.test: timeout'));

    // Still offline: the reason is shown, the config stays.
    await tester.tap(find.byKey(const Key('config-refresh')));
    await tester.pumpAndSettle();
    expect(engine.requests, contains('POST /config/reload'));
    expect(find.text('2 个站点 · 0 个解析 · 0 组直播'), findsOneWidget);
    expect(freshness(tester), startsWith('没能获取到最新的订阅'));

    // Back online.
    engine.offline = false;
    await tester.tap(find.byKey(const Key('config-refresh')));
    await tester.pumpAndSettle();
    expect(freshness(tester), matches(RegExp(r'^今天 \d\d:\d\d 获取$')));
  });

  testWidgets('while the engine checks its copy against the network the app waits for the outcome', (tester) async {
    final engine = _CachingEngine(stored: true, refreshing: 3);
    await tester.runAsync(() async {
      await pumpApp(tester, engine);
      await tester.tap(find.text('源'));
      await tester.pump();
      for (var i = 0; i < 50 && engine.refreshing > 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    });
    expect(engine.requests.where((r) => r == 'GET /config').length, greaterThanOrEqualTo(4));
    expect(freshness(tester), matches(RegExp(r'^今天 \d\d:\d\d 获取$')), reason: 'confirmed by the network');
  });

  testWidgets('the caches have a size and one button that clears them', (tester) async {
    addTearDown(() => PosterCache.instance = null);
    PosterCache.instance = _MemoryPosters()..bytes = 2048;
    final engine = _CachingEngine();
    await pumpApp(tester, engine);
    await tester.tap(find.text('源'));
    await tester.pumpAndSettle();
    expect(find.text('订阅副本和站点数据：3.0 MB（12 项，在引擎里）'), findsOneWidget);
    expect(find.text('海报图片：2 KB（在这台设备上）'), findsOneWidget);

    await tester.tap(find.byKey(const Key('cache-clear')));
    await tester.pumpAndSettle();
    expect(engine.requests, contains('DELETE /cache'));
    expect(find.text('订阅副本和站点数据：0 B（0 项，在引擎里）'), findsOneWidget);
    expect(find.text('海报图片：0 B（在这台设备上）'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('cache-clear'))).onPressed, isNull, reason: 'nothing left to clear');
  });

  test('posters are downloaded once, kept on disk, and the oldest go when the folder is full', () async {
    final dir = Directory.systemTemp.createTempSync('posters');
    addTearDown(() => dir.deleteSync(recursive: true));
    final fetched = <String>[];
    Future<Uint8List> fetch(Uri url, Map<String, String> headers) async {
      fetched.add('$url ${headers['Referer'] ?? ''}'.trim());
      if (url.path.contains('missing')) throw const HttpException('HTTP 404');
      return Uint8List.fromList(List.filled(1000, url.path.codeUnitAt(1)));
    }

    final cache = PosterCache.at(dir.path, maxBytes: 5000, fetch: fetch)!;
    final first = await Future.wait([cache.load('http://img.test/a.png', headers: {'Referer': 'r'}), cache.load('http://img.test/a.png')]);
    expect(first[0], first[1]);
    expect(fetched, ['http://img.test/a.png r'], reason: 'asked for twice at once, downloaded once');
    expect(await cache.size(), 1000);

    // Another instance on the same folder (the next start): no network.
    final again = PosterCache.at(dir.path, maxBytes: 5000, fetch: (u, h) => throw const SocketException('offline'))!;
    expect((await again.load('http://img.test/a.png')).length, 1000);
    await expectLater(again.load('http://img.test/b.png'), throwsA(isA<SocketException>()));
    await expectLater(cache.load('http://img.test/missing.png'), throwsA(isA<HttpException>()));
    expect(await cache.size(), 1000, reason: 'a failed download leaves nothing behind');

    // Past the limit the least recently used files are deleted.
    for (final name in ['b', 'c', 'd', 'e', 'f', 'g', 'h']) {
      await cache.load('http://img.test/$name.png');
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(await cache.size(), lessThanOrEqualTo(5000));
    expect(await cache.size(), greaterThan(0));

    await cache.clear();
    expect(await cache.size(), 0);
  });

  test('times and sizes read naturally', () {
    final now = DateTime(2026, 11, 19, 10, 0);
    expect(formatFetchedAt(DateTime(2026, 11, 19, 8, 5).millisecondsSinceEpoch, now: now), '今天 08:05');
    expect(formatFetchedAt(DateTime(2026, 11, 3, 21, 40).millisecondsSinceEpoch, now: now), '11-03 21:40');
    expect(formatFetchedAt(DateTime(2025, 12, 31, 23, 59).millisecondsSinceEpoch, now: now), '2025-12-31 23:59');
    expect(formatBytes(512), '512 B');
    expect(formatBytes(2048), '2 KB');
    expect(formatBytes(5 * 1024 * 1024 + 1), '5.0 MB');
  });
}
