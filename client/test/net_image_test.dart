import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/ui/common.dart';
import 'package:tvbox_client/ui/image_address.dart';
import 'package:tvbox_client/ui/poster_cache.dart';

import 'fake_engine.dart';
import 'fake_lan_engine.dart';
import 'fake_player.dart';

/// Covers and channel logos go through [NetImage]'s path: the address as configs write it becomes the URL and the
/// headers the disk cache downloads with. The downloads are recorded, not made; the engine addresses are made up.
const _remote = 'http://192.168.1.5:19978';

/// A 1×1 PNG.
final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=');

/// The fake engine, with logos on its live channels.
class _LogoEngine extends http.BaseClient {
  _LogoEngine(this._inner);

  final http.Client _inner;

  static const logo = 'https://logo.example/a.png@Referer=https://tv.example/@User-Agent=TVBox';

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'GET' && request.url.path == '/api/v1/live/0') {
      final body = jsonEncode({
        'source': 0,
        'name': '测试直播',
        'groups': [
          {
            'name': '测试组',
            'channels': [
              {'name': '台标台', 'logo': logo, 'catchupDays': 0, 'urls': [{'url': 'https://cdn.test/live/a.m3u8', 'label': '', 'headers': <String, String>{}}]},
              {'name': '内嵌台', 'logo': 'data:image/png;base64,${base64Encode(_png)}', 'catchupDays': 0, 'urls': [{'url': 'https://cdn.test/live/b.m3u8', 'label': '', 'headers': <String, String>{}}]},
            ],
          },
        ],
      });
      return http.StreamedResponse(Stream.value(utf8.encode(body)), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    }
    return _inner.send(request);
  }
}

void main() {
  late Directory dir;
  late List<(Uri, Map<String, String>)> fetched;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('net_image');
    fetched = [];
    PosterCache.instance = PosterCache.at(
      dir.path,
      fetch: (url, headers) async {
        fetched.add((url, Map.of(headers)));
        return Uint8List.fromList(_png);
      },
    );
  });

  tearDown(() {
    PosterCache.instance = null;
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // A trim still listing it; the system cleans its temp folder.
    }
  });

  /// Lets the disk cache, the recorded download and the decoder run: real I/O, which the fake clock does not move.
  Future<void> settle(WidgetTester tester, {bool Function()? until}) async {
    for (var i = 0; i < 60 && !(until?.call() ?? false); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  bool painted(WidgetTester tester, Finder of) =>
      tester.widgetList<RawImage>(find.descendant(of: of, matching: find.byType(RawImage))).any((r) => r.image != null);

  Future<void> pumpCovers(WidgetTester tester, List<String> addresses, {AppState? state}) async {
    final covers = Directionality(
      textDirection: TextDirection.ltr,
      child: Column(
        children: [
          for (final a in addresses) SizedBox(width: 40, height: 60, child: NetImage(a, key: ValueKey(a))),
        ],
      ),
    );
    await tester.pumpWidget(state == null ? covers : AppScope(state: state, child: covers));
    await settle(tester, until: () => fetched.length >= addresses.length && addresses.every((a) => painted(tester, find.byKey(ValueKey(a)))));
  }

  Map<String, String> sentTo(String url) => fetched.firstWhere((f) => f.$1.toString() == url, orElse: () => throw StateError('$url not fetched: $fetched')).$2;

  testWidgets('a cover with header suffixes is downloaded from the bare address with those headers, and painted', (tester) async {
    const raw = 'https://img.example/a.jpg@Referer=https://site.example/@User-Agent=UA1@Headers={"X-Token":"t1"}';
    await pumpCovers(tester, [raw]);
    expect(fetched, hasLength(1));
    expect(fetched.single.$1, Uri.parse('https://img.example/a.jpg'));
    expect(fetched.single.$2, {'X-Token': 't1', 'Referer': 'https://site.example/', 'User-Agent': 'UA1'});
    final image = tester.widget<Image>(find.byType(Image)).image as CachedPoster;
    expect(image.key, raw, reason: 'kept under the address as written');
    expect(painted(tester, find.byType(NetImage)), isTrue);
  });

  testWidgets('a Douban cover is asked for with a Douban Referer and a browser User-Agent', (tester) async {
    await pumpCovers(tester, ['https://img1.doubanio.com/view/photo/s_ratio_poster/public/p1.jpg']);
    expect(fetched.single.$2, {'Referer': ImageAddress.doubanReferer, 'User-Agent': ImageAddress.browserUserAgent});
  });

  testWidgets('the pairing token goes only to the paired engine, proxy and loopback addresses included', (tester) async {
    final engine = FakeLanEngine(fakeEngine(hasConfig: true));
    final state = AppState(clientFactory: (url) => EngineClient(url, httpClient: engine), engineUrl: _remote, waitStep: const Duration(milliseconds: 1));
    await state.start();
    await state.pair('123456');
    final token = state.engineToken;
    expect(token, isNotNull);

    await pumpCovers(tester, [
      '$_remote/demo/poster/1.png',
      'proxy://do=img&id=2',
      'http://127.0.0.1:19978/proxy?do=img&id=3',
      'https://img.example/x.png@Referer=https://site.example/',
      'http://192.168.1.5:19979/x.png',
    ], state: state);
    expect(sentTo('$_remote/demo/poster/1.png'), {'Authorization': 'Bearer $token'});
    expect(sentTo('$_remote/proxy?do=img&id=2'), {'Authorization': 'Bearer $token'});
    expect(sentTo('$_remote/proxy?do=img&id=3'), {'Authorization': 'Bearer $token'});
    expect(sentTo('https://img.example/x.png'), {'Referer': 'https://site.example/'});
    expect(sentTo('http://192.168.1.5:19979/x.png'), isEmpty, reason: 'same host, another port: not the engine');
  });

  testWidgets('without pairing, engine addresses carry no token', (tester) async {
    final state = AppState(clientFactory: (url) => EngineClient(url, httpClient: fakeEngine(hasConfig: true)), engineUrl: _remote);
    await pumpCovers(tester, ['$_remote/demo/poster/1.png', 'proxy://do=img'], state: state);
    expect(sentTo('$_remote/demo/poster/1.png'), isEmpty);
    expect(sentTo('$_remote/proxy?do=img'), isEmpty);
  });

  testWidgets('a data: cover is painted from the address itself, with no download and nothing on disk', (tester) async {
    final raw = 'data:image/png;base64,${base64Encode(_png)}';
    await pumpCovers(tester, [raw]);
    expect(tester.widget<Image>(find.byType(Image)).image, isA<DataUriImage>());
    expect(painted(tester, find.byType(NetImage)), isTrue);
    expect(fetched, isEmpty);
    expect(dir.listSync(), isEmpty);
  });

  testWidgets('addresses with nothing to load show the placeholder', (tester) async {
    await pumpCovers(tester, ['', 'assets://img/a.png']);
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.movie_outlined), findsNWidgets(2));
    expect(fetched, isEmpty);
  });

  testWidgets('live channel logos go the same way: headers from the address, data: logos painted in place', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final player = FakePlayer();
    final engine = _LogoEngine(fakeEngine(hasConfig: true));
    await tester.pumpWidget(
      TvboxApp(
        state: AppState(clientFactory: (url) => EngineClient(url, httpClient: engine), engineUrl: 'http://127.0.0.1:19978', playerBackend: () => player.backend()),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('直播').first);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final logos = find.byWidgetPredicate((w) => w is Image && w.fit == BoxFit.contain && (w.image is CachedPoster || w.image is DataUriImage));
    expect(logos, findsNWidgets(2));
    await settle(tester, until: () => fetched.isNotEmpty && painted(tester, logos.first) && painted(tester, logos.last));

    expect(fetched.single.$1, Uri.parse('https://logo.example/a.png'));
    expect(fetched.single.$2, {'Referer': 'https://tv.example/', 'User-Agent': 'TVBox'});
    expect((tester.widget<Image>(logos.first).image as CachedPoster).key, _LogoEngine.logo);
    expect(tester.widget<Image>(logos.last).image, isA<DataUriImage>());
    expect(painted(tester, logos.first), isTrue);
    expect(painted(tester, logos.last), isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
