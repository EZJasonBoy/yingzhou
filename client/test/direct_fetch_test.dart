import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/settings.dart';

import 'fake_engine.dart';
import 'fake_player.dart';

/// An engine on another device: the player fetches the video from the source itself when the engine is far away
/// (Tailscale and the like), and falls back to the engine's relay when that does not work.
void main() {
  test('which hosts count as this network', () {
    for (final host in ['192.168.1.5', '10.0.0.2', '172.16.3.4', '172.31.255.1', 'nas', 'nas.local', 'box.lan', 'fe80::1', '[fd00::5]']) {
      expect(AppState.isLanHost(host), isTrue, reason: host);
    }
    for (final host in ['100.101.102.103', '100.64.0.1', 'nas.tail1234.ts.net', '8.8.8.8', '172.32.0.1', 'tv.example.com', '2001:db8::1', '']) {
      expect(AppState.isLanHost(host), isFalse, reason: host);
    }
  });

  test('fetching directly: automatic for far engines, never for this device, the user can choose', () async {
    AppState at(String url, [SettingsStore? settings]) => AppState(clientFactory: (u) => throw UnimplementedError(), engineUrl: url, settings: settings);
    expect(at('http://127.0.0.1:9978').fetchDirect, isFalse);
    expect(at('http://192.168.1.5:9978').fetchDirect, isFalse, reason: 'on this network: through the engine and its cache');
    expect(at('http://100.100.1.2:9978').fetchDirect, isTrue, reason: 'over Tailscale: from the source');
    expect(at('http://nas.tail1234.ts.net:9978').fetchDirect, isTrue);

    final settings = MemorySettings();
    final lan = at('http://192.168.1.5:9978', settings);
    await lan.setStreamSource(StreamSource.direct);
    expect(lan.fetchDirect, isTrue);
    expect(at('http://127.0.0.1:9978', settings).fetchDirect, isFalse, reason: 'the engine on this device serves the video itself');
    await lan.setStreamSource(StreamSource.engine);
    expect(at('http://100.100.1.2:9978', settings).fetchDirect, isFalse);
    expect(settings.getString('play.source'), 'engine');
  });

  group('the player', () {
    late FakePlayer player;
    late List<String> resolved;
    late List<bool> direct;
    const a = 'https://cdn.test/a';
    const b = 'https://cdn.test/b';

    Future<void> pass(WidgetTester tester, Duration time) async {
      for (var t = Duration.zero; t < time; t += const Duration(milliseconds: 100)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> play(WidgetTester tester, {required String engineUrl, Set<String> broken = const {}}) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      player = FakePlayer()..broken.addAll(broken);
      resolved = [];
      direct = [];
      final engine = fakeEngine(
        hasConfig: true,
        lines: [fakeLine('线路一', 'a'), fakeLine('线路二', 'b')],
        resolved: resolved,
        relays: true,
        directAsked: direct,
      );
      await tester.pumpWidget(
        TvboxApp(
          state: AppState(clientFactory: (url) => EngineClient(url, httpClient: engine), engineUrl: engineUrl, playerBackend: () => player.backend()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('推荐片'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('播放').first);
      await pass(tester, const Duration(seconds: 1));
    }

    Future<void> leave(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('far engine: the video comes from the source', (tester) async {
      await play(tester, engineUrl: 'http://100.100.1.2:9978');
      expect(direct, [true]);
      expect(player.opened, ['$a/1.m3u8?d=1']);
      expect(find.text('线路一 · 直连片源'), findsOneWidget);
      await leave(tester);
    });

    testWidgets('when the source does not play directly, the same episode goes through the engine before any other line', (tester) async {
      await play(tester, engineUrl: 'http://100.100.1.2:9978', broken: {'$a/1.m3u8?d=1'});
      await pass(tester, const Duration(seconds: 2));
      expect(player.opened, ['$a/1.m3u8?d=1', '$a/1.m3u8?relay=1']);
      expect(resolved, ['线路一'], reason: 'no second resolve, no other line');
      expect(find.text('直连片源没能播放，改为经引擎播放'), findsOneWidget);
      expect(find.text('线路一 · 经引擎'), findsOneWidget);
      await leave(tester);
    });

    testWidgets('when the relay fails too, the next line is tried (directly again)', (tester) async {
      await play(tester, engineUrl: 'http://100.100.1.2:9978', broken: {'$a/1.m3u8?d=1', '$a/1.m3u8?relay=1'});
      // Each address that does not load is given up after the player's 2 s grace.
      await pass(tester, const Duration(seconds: 6));
      expect(player.opened, ['$a/1.m3u8?d=1', '$a/1.m3u8?relay=1', '$b/1.m3u8?d=1']);
      expect(resolved, ['线路一', '线路二']);
      await leave(tester);
    });

    testWidgets('engine on this device or this network: through the engine as before', (tester) async {
      await play(tester, engineUrl: 'http://127.0.0.1:9978');
      expect(direct, [false]);
      expect(player.opened, ['$a/1.m3u8']);
      expect(find.textContaining('直连片源'), findsNothing);
      await leave(tester);

      await play(tester, engineUrl: 'http://192.168.1.5:9978');
      expect(direct, [false]);
      await leave(tester);
    });
  });

  testWidgets('源 → 局域网 offers the choice only for an engine on another device', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<void> sources(String url) async {
      await tester.pumpWidget(TvboxApp(state: AppState(clientFactory: (u) => EngineClient(u, httpClient: fakeEngine()), engineUrl: url)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('源').first);
      await tester.pumpAndSettle();
    }

    await sources('http://100.100.1.2:9978');
    expect(find.byKey(const Key('stream-source')), findsOneWidget);
    expect(find.textContaining('自动：这台引擎不在这个局域网里'), findsOneWidget);
    await tester.tap(find.text('经引擎'));
    await tester.pumpAndSettle();
    expect(find.textContaining('经引擎：视频由引擎取来'), findsOneWidget);

    await sources('http://127.0.0.1:9978');
    expect(find.byKey(const Key('stream-source')), findsNothing);
  });
}
