import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/discovery.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/remote/remote_page.dart';
import 'package:tvbox_client/settings.dart';

import 'fake_lan_engine.dart';
import 'fake_remote_hub.dart';

class _FakeDiscovery implements EngineDiscovery {
  _FakeDiscovery(this.engines);

  final List<DiscoveredEngine> engines;

  @override
  Future<void> start(void Function(List<DiscoveredEngine> engines) onChange) async => onChange(engines);

  @override
  Future<void> stop() async {}
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The 「遥控另一台映舟」 pages of the app on a phone: finding the engine and a screen, pairing, and the remote itself.
/// The engine's hub is [FakeRemoteHub]: the test plays the screen through it.
void main() {
  void phoneSize(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
  }

  testWidgets('find the engine, pair once, pick a screen, and the remote opens with the token', (tester) async {
    phoneSize(tester);
    final screens = MockClient((request) async {
      if (request.url.path == '/api/v1/remote/screens') {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode([
              {'id': 'tv-1', 'name': '客厅电视', 'platform': 'windows', 'form': 'tv', 'title': '星河往事', 'controllers': 0},
            ]),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{}', 404);
    });
    final engine = FakeLanEngine(screens);
    final hub = FakeRemoteHub();
    final state = AppState(clientFactory: (url) => EngineClient(url, httpClient: engine), settings: MemorySettings());
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(
          home: RemoteFinderPage(
            discovery: _FakeDiscovery([const DiscoveredEngine(name: '书房电脑', url: 'http://192.168.1.7:9978')]),
            connector: hub.connect,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('书房电脑'), findsOneWidget);
    await tester.tap(find.text('书房电脑'));
    await _frames(tester);
    // Not paired yet: the engine is asked to show a code, and the code is asked for here.
    expect(find.byKey(const Key('remote-code')), findsOneWidget);
    expect(engine.codeRequests, 1);
    await tester.enterText(find.byKey(const Key('remote-code')), '000000');
    await tester.tap(find.byKey(const Key('remote-pair')));
    await _frames(tester);
    expect(find.textContaining('配对码不对'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('remote-code')), '123456');
    await tester.tap(find.byKey(const Key('remote-pair')));
    await _frames(tester);
    expect(engine.tokens, hasLength(1));
    expect(state.settings.getString('remote.token|http://192.168.1.7:9978'), engine.tokens.single, reason: 'kept for next time');
    expect(find.text('客厅电视'), findsOneWidget);

    await tester.tap(find.text('客厅电视'));
    await _frames(tester);
    expect(hub.connections.single.url.toString(), 'ws://192.168.1.7:9978/api/v1/remote/control?screen=tv-1');
    expect(hub.screen.token, engine.tokens.single);
    expect(find.byType(RemoteControlPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('the remote shows what plays, sends keys and commands, types into the screen, and reconnects', (tester) async {
    phoneSize(tester);
    final hub = FakeRemoteHub();
    await tester.pumpWidget(
      MaterialApp(
        home: RemoteControlPage(engineUrl: 'http://192.168.1.7:9978', screenId: 'tv-1', screenName: '客厅电视', token: 'dev1.secret', connector: hub.connect),
      ),
    );
    await tester.pump();
    final link = hub.screen;
    expect(link.token, 'dev1.secret');
    expect(find.text('客厅电视'), findsOneWidget);
    link.deliver({
      'type': 'screen',
      'screen': {'id': 'tv-1', 'name': '客厅电视', 'form': 'tv'},
    });
    await _frames(tester);
    // The D-pad has one place, whatever the screen does: nothing playing, a text field to type into, playing.
    final okKey = find.byKey(const Key('remote-key-ok'));
    final okAt = tester.getCenter(okKey);
    expect(find.text('屏幕上没有在播放'), findsOneWidget);
    link.deliver({
      'type': 'state',
      'state': {
        'title': '',
        'text': {'value': '', 'hint': '搜索', 'secret': false},
      },
    });
    await _frames(tester);
    expect(find.byKey(const Key('remote-text')), findsOneWidget);
    expect(tester.getCenter(okKey), okAt, reason: 'the text bar lies over 正在播放, it does not push the D-pad down');
    link.deliver({
      'type': 'state',
      'state': {
        'title': '星河往事',
        'page': 'player',
        'form': 'tv',
        'canTv': true,
        'player': {
          'kind': 'vod',
          'title': '星河往事',
          'subtitle': '第3集 · 线路一',
          'position': 60000,
          'duration': 2400000,
          'seekable': true,
          'paused': false,
          'speed': 1.0,
          'speeds': [1.0, 1.5],
          'volume': 80,
          'lines': ['线路一', '线路二'],
          'line': 0,
          'episodes': ['第1集', '第2集', '第3集'],
          'episode': 2,
        },
      },
    });
    await _frames(tester);
    expect(find.byKey(const Key('remote-title')), findsOneWidget);
    expect(find.byKey(const Key('remote-text')), findsNothing);
    expect(tester.getCenter(okKey), okAt, reason: 'playing does not move the D-pad');
    expect(find.text('第3集 · 线路一'), findsOneWidget);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget, reason: 'it plays');
    expect(find.text('电视模式：开'), findsOneWidget);

    List<Map<String, dynamic>> commands() => [
      for (final m in link.sent)
        if (m['type'] == 'command') m,
    ];
    await tester.tap(find.byKey(const Key('remote-key-up')));
    await tester.pump();
    expect(commands().map((c) => '${c['name']} ${c['args']['key']} ${c['args']['action']}'), ['key up down', 'key up up']);
    // Held: repeats until let go, like a remote's key.
    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const Key('remote-key-ok'))));
    for (var i = 0; i < 7; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await gesture.up();
    await tester.pump();
    final ok = [
      for (final c in commands())
        if (c['args']['key'] == 'ok') c['args']['action'],
    ];
    expect(ok.first, 'down');
    expect(ok.last, 'up');
    expect(ok.where((a) => a == 'repeat').length, greaterThanOrEqualTo(2), reason: '$ok');

    await tester.tap(find.byKey(const Key('remote-toggle')));
    await tester.tap(find.byKey(const Key('remote-home')));
    await tester.tap(find.byKey(const Key('remote-back')));
    await tester.pump();
    expect(commands().skip(commands().length - 3).map((c) => c['name']), ['toggle', 'home', 'key']);

    // The choices of the player.
    await tester.ensureVisible(find.byKey(const Key('remote-choices')));
    await tester.tap(find.byKey(const Key('remote-choices')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第1集'));
    await tester.tap(find.text('线路二'));
    await tester.tap(find.text('1.5x'));
    await tester.pump();
    expect(commands().skip(commands().length - 3).map((c) => '${c['name']} ${c['args']}'), ['episode {index: 0}', 'line {index: 1}', 'speed {value: 1.5}']);
    Navigator.of(tester.element(find.text('第1集'))).pop();
    await tester.pumpAndSettle();

    // A text field has the focus on the screen: typing here goes there, Enter submits.
    link.deliver({
      'type': 'state',
      'state': {
        'title': '',
        'text': {'value': '', 'hint': '搜索', 'secret': false},
      },
    });
    await _frames(tester);
    expect(find.byKey(const Key('remote-text')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('remote-text')), '星河');
    await tester.pump(const Duration(milliseconds: 100));
    expect(commands().last['name'], 'text');
    expect(commands().last['args']['value'], '星河');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(commands().last['name'], 'submit');

    // What the screen could not do is said.
    link.deliver({'type': 'result', 'id': '1', 'ok': false, 'message': '屏幕上现在没有在播放'});
    await _frames(tester);
    expect(find.text('屏幕上现在没有在播放'), findsOneWidget);

    // The connection drops: the remote says so and connects again by itself.
    link.drop();
    await tester.pump();
    expect(find.textContaining('正在重连'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(hub.connections, hasLength(2));
    expect(find.textContaining('正在重连'), findsNothing);
    // The screen goes away: said so, and the remote waits for it to come back.
    hub.screen.deliver({'type': 'gone'});
    await _frames(tester);
    expect(find.textContaining('屏幕不在线'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
