import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';

import 'fake_engine.dart';
import 'fake_player.dart';

/// The fake engine with the downloads API: a list kept here that the test moves along ([set]), every request to
/// it noted in [sent], and `/play/resolve` answering a finished download with the engine's own address, like the
/// engine does. With [available] false it is an engine without downloads (404, like one from before them).
class _DownloadEngine extends http.BaseClient {
  _DownloadEngine({this.available = true, List<Map<String, dynamic>> items = const []}) {
    for (final i in items) {
      this.items[i['id'] as String] = {..._blank, ...i};
    }
  }

  final bool available;
  final http.Client _inner = fakeEngine(hasConfig: true, lines: [fakeLine('线路一', 'a', count: 4), fakeLine('线路二', 'b', count: 2)]);
  final items = <String, Map<String, dynamic>>{};
  final sent = <(String, String, Object?)>[];
  var settings = <String, dynamic>{
    'available': true,
    'dir': '',
    'path': r'C:\data\cache\stream',
    'defaultPath': r'C:\data\cache\stream',
    'concurrency': 2,
    'maxConcurrency': 5,
    'freeBytes': 50 * 1024 * 1024 * 1024,
    'reserveBytes': 500 * 1024 * 1024,
    'bytes': 1288490189,
  };
  var _ids = 0;

  static const _blank = <String, dynamic>{
    'site': 'cms',
    'line': '线路一',
    'vodId': '7',
    'title': '片名',
    'pic': '',
    'state': 'queued',
    'kind': 'hls',
    'bytes': 0,
    'totalBytes': -1,
    'progress': 0.0,
    'speed': 0,
    'partsDone': 0,
    'parts': 0,
    'durationMs': 0,
    'error': '',
    'createdAt': 1,
    'finishedAt': 0,
  };

  /// Moves the download of [episodeId] along.
  void set(String episodeId, Map<String, dynamic> fields) {
    final item = items.values.firstWhere((i) => i['episodeId'] == episodeId);
    item.addAll(fields);
  }

  http.StreamedResponse _json(Object? body, [int status = 200]) => http.StreamedResponse(
    Stream.value(utf8.encode(body == null ? '' : jsonEncode(body))),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    final body = request is http.Request && request.body.isNotEmpty ? jsonDecode(request.body) : null;
    if (path == '/api/v1/play/resolve') {
      final b = body as Map<String, dynamic>;
      for (final i in items.values) {
        if (i['state'] == 'done' && i['site'] == b['site'] && i['line'] == b['line'] && i['episodeId'] == b['episodeId']) {
          return _json({'kind': 'direct', 'url': 'http://127.0.0.1:9978/dl/${i['id']}/index.m3u8', 'headers': <String, String>{}, 'parsedBy': '', 'cache': '', 'download': i['id']});
        }
      }
      return _inner.send(request);
    }
    if (!path.startsWith('/api/v1/downloads')) return _inner.send(request);
    sent.add((request.method, path, body));
    if (!available) return _json({'error': {'code': 'NOT_FOUND', 'message': path}}, 404);
    final m = RegExp(r'^/api/v1/downloads/([^/]+)(?:/(\w+))?$').firstMatch(path);
    switch ((request.method, path)) {
      case ('GET', '/api/v1/downloads'):
        return _json({'available': true, 'items': items.values.toList()});
      case ('POST', '/api/v1/downloads'):
        final added = <Map<String, dynamic>>[];
        for (final req in ((body as Map<String, dynamic>)['items'] as List).cast<Map<String, dynamic>>()) {
          final known = items.values.where((i) => i['episodeId'] == req['episodeId'] && i['line'] == req['line']).firstOrNull;
          if (known != null) {
            added.add(known);
            continue;
          }
          final id = 'd${++_ids}';
          items[id] = {..._blank, ...req, 'id': id, 'state': 'queued', 'createdAt': 100 + _ids};
          added.add(items[id]!);
        }
        return _json({'available': true, 'items': added});
      case ('GET', '/api/v1/downloads/settings'):
        return _json(settings);
      case ('PUT', '/api/v1/downloads/settings'):
        final b = body as Map<String, dynamic>;
        if (b['dir'] == 'relative') return _json({'error': {'code': 'BAD_REQUEST', 'message': '下载位置要写完整的路径（引擎所在设备上的文件夹）'}}, 400);
        settings = {...settings, if (b.containsKey('dir')) 'dir': b['dir'], if (b['dir'] != null && b['dir'] != '') 'path': b['dir'], ...{if (b['concurrency'] != null) 'concurrency': b['concurrency']}};
        return _json(settings);
    }
    if (m != null) {
      final item = items[m.group(1)];
      if (item == null) return _json({'error': {'code': 'NOT_FOUND', 'message': 'no download'}}, 404);
      switch ((request.method, m.group(2))) {
        case ('POST', 'pause'):
          item['state'] = 'paused';
          item['speed'] = 0;
          return _json(item);
        case ('POST', 'resume'):
          item['state'] = 'queued';
          item['error'] = '';
          return _json(item);
        case ('DELETE', null):
          items.remove(m.group(1));
          return _json(null, 204);
        case ('POST', 'export'):
          return _json({'path': r'C:\Users\me\Downloads\片名 第1集.ts', 'bytes': 31016240, 'format': 'ts'});
      }
    }
    return _json({'error': {'code': 'NOT_FOUND', 'message': path}}, 404);
  }
}

void main() {
  late _DownloadEngine engine;
  late FakePlayer player;

  Future<void> openApp(WidgetTester tester, _DownloadEngine e) async {
    tester.view.physicalSize = const Size(1400, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    engine = e;
    player = FakePlayer();
    await tester.pumpWidget(TvboxApp(state: AppState(clientFactory: (url) => EngineClient(url, httpClient: engine), playerBackend: () => player.backend())));
    await tester.pumpAndSettle();
  }

  Future<void> openDetail(WidgetTester tester) async {
    await tester.tap(find.text('推荐片'));
    await tester.pumpAndSettle();
  }

  /// Lets [time] go by, a frame every 100 ms (the download list is asked again every second while something runs).
  Future<void> pass(WidgetTester tester, Duration time) async {
    for (var t = Duration.zero; t < time; t += const Duration(milliseconds: 100)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  String mark(WidgetTester tester, int episode) =>
      tester.widgetList<Text>(find.descendant(of: find.byKey(Key('download-mark-$episode')), matching: find.byType(Text))).single.data!;

  FilterChip chip(WidgetTester tester, int episode) => tester.widget<FilterChip>(find.byKey(Key('download-pick-$episode')));

  /// Whether the app made that request of the downloads API, and what it sent the last time.
  bool asked(String method, String path) => engine.sent.any((s) => s.$1 == method && s.$2 == path);
  Object? lastBody(String method, String path) => engine.sent.lastWhere((s) => s.$1 == method && s.$2 == path).$3;

  const ep = 'https://cdn.test/a/';

  testWidgets('the detail page downloads this episode, more of them or the whole line, and marks each episode', (tester) async {
    await openApp(tester, _DownloadEngine());
    await openDetail(tester);
    expect(find.byKey(const Key('download-mark-0')), findsNothing);

    await tester.tap(find.byKey(const Key('download-button')));
    await tester.pumpAndSettle();
    expect(find.text('下载 · 片名'), findsOneWidget);
    expect(chip(tester, 0).selected, isTrue, reason: 'this episode is picked to begin with');
    await tester.tap(find.byKey(const Key('download-pick-2')));
    await tester.pumpAndSettle();
    expect(find.text('下载 2 集'), findsOneWidget);
    await tester.tap(find.byKey(const Key('download-start')));
    await tester.pumpAndSettle();

    final post = engine.sent.lastWhere((s) => s.$1 == 'POST' && s.$2 == '/api/v1/downloads');
    final requested = ((post.$3 as Map<String, dynamic>)['items'] as List).cast<Map<String, dynamic>>();
    expect(requested.map((r) => r['episodeId']), ['${ep}1.m3u8', '${ep}3.m3u8']);
    expect(requested.first, {'site': 'cms', 'line': '线路一', 'episodeId': '${ep}1.m3u8', 'vodId': '7', 'title': '片名', 'pic': '', 'episodeName': '第1集', 'episodeIndex': 0});
    expect(find.textContaining('已加入下载：2 集'), findsOneWidget);
    expect(mark(tester, 0), '排队中');
    expect(mark(tester, 2), '排队中');
    expect(find.byKey(const Key('download-mark-1')), findsNothing);

    // The engine gets on with it; the page asks again every second while something is under way.
    engine.set('${ep}1.m3u8', {'state': 'running', 'progress': 0.42, 'bytes': 13000000});
    await pass(tester, const Duration(milliseconds: 1500));
    expect(mark(tester, 0), '42%');
    engine.set('${ep}1.m3u8', {'state': 'done', 'progress': 1.0});
    engine.set('${ep}3.m3u8', {'state': 'failed', 'error': '片源拒绝了分片（HTTP 403）'});
    await pass(tester, const Duration(milliseconds: 1500));
    expect(mark(tester, 0), '已下载');
    expect(mark(tester, 2), '失败');

    // Again: what is downloaded cannot be picked, what failed can, and 整条线路 picks the rest.
    await tester.tap(find.byKey(const Key('download-button')));
    await tester.pumpAndSettle();
    expect(chip(tester, 0).onSelected, isNull);
    expect(chip(tester, 2).onSelected, isNotNull);
    await tester.tap(find.byKey(const Key('download-pick-all')));
    await tester.pumpAndSettle();
    expect([for (var i = 0; i < 4; i++) chip(tester, i).selected], [false, true, true, true]);
    await tester.tap(find.byKey(const Key('download-start')));
    await tester.pumpAndSettle();
    final added = ((engine.sent.lastWhere((s) => s.$1 == 'POST' && s.$2 == '/api/v1/downloads').$3 as Map<String, dynamic>)['items'] as List).cast<Map<String, dynamic>>();
    expect(added.map((r) => r['episodeName']), ['第2集', '第4集']);
    expect(engine.sent.where((s) => s.$2 == '/api/v1/downloads/d2/resume'), hasLength(1), reason: 'the failed one is tried again');
    expect(mark(tester, 2), '排队中');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a downloaded episode plays from the engine, offline', (tester) async {
    await openApp(tester, _DownloadEngine(items: [
      {'id': 'd9', 'episodeId': '${ep}2.m3u8', 'episodeName': '第2集', 'episodeIndex': 1, 'state': 'done', 'progress': 1.0, 'bytes': 31016240},
    ]));
    await openDetail(tester);
    expect(mark(tester, 1), '已下载');
    await tester.tap(find.widgetWithText(OutlinedButton, '第2集'));
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened.last, 'http://127.0.0.1:9978/dl/d9/index.m3u8');
    expect(find.text('线路一 · 离线播放（已下载）'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('我的 → 下载: by title, with progress, speed, and pause, retry, export and delete', (tester) async {
    await openApp(tester, _DownloadEngine(items: [
      {'id': 'r', 'episodeId': '${ep}1.m3u8', 'episodeName': '第1集', 'episodeIndex': 0, 'state': 'running', 'progress': 0.42, 'bytes': 13 * 1024 * 1024, 'speed': 1536 * 1024, 'createdAt': 5},
      {'id': 'q', 'episodeId': '${ep}2.m3u8', 'episodeName': '第2集', 'episodeIndex': 1, 'state': 'queued', 'createdAt': 6},
      {'id': 'f', 'episodeId': '${ep}3.m3u8', 'episodeName': '第3集', 'episodeIndex': 2, 'state': 'failed', 'error': '这是直播流（播放列表没有结尾），不能下载', 'createdAt': 7},
      {'id': 'o', 'site': 'cms', 'vodId': '8', 'title': '别的片', 'line': '线路', 'episodeId': 'https://cdn.test/o.mp4', 'episodeName': '正片', 'kind': 'file', 'state': 'done', 'progress': 1.0, 'bytes': 700 * 1024 * 1024, 'totalBytes': 700 * 1024 * 1024, 'createdAt': 3},
    ]));
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, '下载'));
    await tester.pumpAndSettle();

    expect(find.text('片名'), findsOneWidget);
    expect(find.text('别的片'), findsOneWidget);
    expect(find.text('已下载 0 / 3 集 · 13 MB'), findsOneWidget);
    String status(String id) => tester.widget<Text>(find.byKey(Key('download-status-$id'))).data!;
    expect(status('r'), '下载中 42% · 1.5 MB/s · 13 MB / 约 31 MB');
    expect(status('q'), '排队中');
    expect(status('f'), '失败：这是直播流（播放列表没有结尾），不能下载');
    expect(status('o'), '已下载 · 700 MB · 不用网络也能播放');
    expect(tester.widget<Text>(find.byKey(const Key('downloads-summary'))).data, '4 集 · 1 集在下载 · 1.5 MB/s · 1 集排队 · 已下载 1 集');

    await tester.tap(find.byKey(const Key('download-pause-r')));
    await tester.pumpAndSettle();
    expect(asked('POST', '/api/v1/downloads/r/pause'), isTrue);
    expect(status('r'), startsWith('已暂停 · 42%'));
    await tester.tap(find.byKey(const Key('download-resume-r')));
    await tester.pumpAndSettle();
    expect(asked('POST', '/api/v1/downloads/r/resume'), isTrue);
    await tester.tap(find.byKey(const Key('download-retry-f')));
    await tester.pumpAndSettle();
    expect(asked('POST', '/api/v1/downloads/f/resume'), isTrue);
    expect(status('f'), '排队中');

    // Export: what it gives is said first, ffmpeg included.
    await tester.tap(find.byKey(const Key('download-export-o')));
    await tester.pumpAndSettle();
    expect(find.textContaining('ffmpeg'), findsOneWidget);
    expect(find.textContaining('直链下载的文件原样导出'), findsOneWidget);
    await tester.tap(find.byKey(const Key('download-export-confirm')));
    await tester.pumpAndSettle();
    expect(asked('POST', '/api/v1/downloads/o/export'), isTrue);
    expect(find.text(r'已导出：C:\Users\me\Downloads\片名 第1集.ts'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('download-delete-o')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('download-delete-confirm')));
    await tester.pumpAndSettle();
    expect(asked('DELETE', '/api/v1/downloads/o'), isTrue);
    expect(find.text('别的片'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the 源 page: where downloads go, how many at once, the room left', (tester) async {
    await openApp(tester, _DownloadEngine());
    await tester.tap(find.text('源'));
    await tester.pumpAndSettle();
    expect(find.text('离线下载'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('download-settings-usage'))).data, '已下载 1.2 GB · 剩余空间 50.0 GB');
    expect(find.textContaining(r'现在：C:\data\cache\stream'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('download-concurrency')));
    await tester.tap(find.byKey(const Key('download-concurrency')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('3 集').last);
    await tester.pumpAndSettle();
    expect(lastBody('PUT', '/api/v1/downloads/settings'), {'concurrency': 3});

    await tester.enterText(find.byKey(const Key('download-folder')), 'relative');
    await tester.tap(find.byKey(const Key('download-folder-save')));
    await tester.pumpAndSettle();
    expect(find.text('下载位置要写完整的路径（引擎所在设备上的文件夹）'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('download-folder')), r'D:\Videos');
    await tester.tap(find.byKey(const Key('download-folder-save')));
    await tester.pumpAndSettle();
    expect(lastBody('PUT', '/api/v1/downloads/settings'), {'dir': r'D:\Videos'});
    expect(find.textContaining(r'现在：D:\Videos'), findsOneWidget);
    expect(find.text('恢复默认'), findsOneWidget);
  });

  testWidgets('an engine that does not download shows none of it', (tester) async {
    await openApp(tester, _DownloadEngine(available: false));
    await openDetail(tester);
    expect(find.byKey(const Key('download-button')), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, '下载'));
    await tester.pumpAndSettle();
    expect(find.textContaining('这台引擎不能下载'), findsOneWidget);
    await tester.tap(find.text('源'));
    await tester.pumpAndSettle();
    expect(find.text('离线下载'), findsNothing);
  });
}
