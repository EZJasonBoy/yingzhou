import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/pages/ui_mode_settings.dart';
import 'package:tvbox_client/remote/remote_agent.dart';
import 'package:tvbox_client/remote/remote_host.dart';
import 'package:tvbox_client/remote/remote_keys.dart';
import 'package:tvbox_client/remote/remote_screen.dart';
import 'package:tvbox_client/settings.dart';
import 'package:tvbox_client/ui/device_form.dart';
import 'package:tvbox_client/ui/phone_input.dart' show QrView;
import 'package:tvbox_client/ui/tv/tv_focus.dart';
import 'package:tvbox_client/ui/tv/tv_shell.dart';

import 'fake_engine.dart';
import 'fake_lan_engine.dart';
import 'fake_player.dart';
import 'fake_remote_hub.dart';

/// The LAN remote control on the client: the agent's connection, a phone's keys in the TV layout, the player's
/// commands, text into the focused field, the TV layout on a desktop, and the switch in the 局域网 card. The engine's
/// hub is [FakeRemoteHub]: the test reads what the screen sent and plays the phone.
void main() {
  late FakePlayer player;

  Future<void> pass(WidgetTester tester, Duration time) async {
    for (var t = Duration.zero; t < time; t += const Duration(milliseconds: 100)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  FocusNode focused() => FocusManager.instance.primaryFocus!;

  bool focusIsIn(Finder finder) {
    final element = finder.evaluate().single;
    var inside = false;
    focused().context!.visitAncestorElements((e) {
      if (e == element) inside = true;
      return !inside;
    });
    return inside || focused().context == element;
  }

  bool focusOnText(String text) => focusIsIn(find.ancestor(of: find.text(text), matching: find.byType(TvFocusable)).first);

  /// The whole app with 「允许手机遥控」 on, registered with a hub the test holds.
  Future<FakeRemoteHub> pumpApp(
    WidgetTester tester, {
    DeviceForm form = DeviceForm.tv,
    List<Map<String, Object>>? lines,
    http.Client? engine,
    bool enabled = true,
    SettingsStore? settings,
  }) async {
    tester.view.physicalSize = form == DeviceForm.tv ? const Size(1920, 1080) : const Size(1400, 1600);
    tester.view.devicePixelRatio = form == DeviceForm.tv ? 2 : 1;
    addTearDown(tester.view.reset);
    final hub = FakeRemoteHub();
    RemoteScreen.debugConnector = hub.connect;
    addTearDown(() => RemoteScreen.debugConnector = null);
    final store = settings ?? MemorySettings();
    if (enabled) await store.setString(RemoteAgent.enabledKey, '1');
    player = FakePlayer();
    final client = engine ?? fakeEngine(hasConfig: true, lines: lines);
    await tester.pumpWidget(
      DeviceFormScope.fixed(
        form,
        child: TvboxApp(
          state: AppState(clientFactory: (url) => EngineClient(url, httpClient: client), settings: store, playerBackend: () => player.backend()),
        ),
      ),
    );
    await pass(tester, const Duration(seconds: 1));
    if (enabled) {
      hub.screen.deliver({'type': 'welcome', 'id': hub.screen.hello['id'], 'controllers': 0});
      await tester.pump();
    }
    return hub;
  }

  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  }

  /// A key pressed on the phone, and the frames until the screen has settled.
  Future<Map<String, dynamic>> press(WidgetTester tester, FakeRemoteHub hub, String key, {int times = 1}) async {
    late Map<String, dynamic> result;
    for (var i = 0; i < times; i++) {
      result = await hub.screen.command(tester, 'key', {'key': key, 'action': 'press'});
      await pass(tester, const Duration(milliseconds: 400));
    }
    return result;
  }

  // ---------------------------------------------------------------- the agent

  testWidgets('the agent registers only while the switch is on, publishes the state, answers commands and comes back', (tester) async {
    final hub = FakeRemoteHub();
    final settings = MemorySettings();
    var state = <String, Object?>{'title': '首页', 'page': 'browse'};
    final commands = <String>[];
    var gone = 0;
    final agent = RemoteAgent(
      settings: settings,
      connector: hub.connect,
      collect: () => state,
      perform: (name, args) async {
        commands.add('$name $args');
        return name == 'bad' ? '不行' : null;
      },
      platform: 'windows',
      retryBase: const Duration(milliseconds: 200),
    )..onControllersGone = () => gone++;

    // Off by default: the engine never hears of this screen.
    agent.bind(engineUrl: 'http://127.0.0.1:9978', connected: true);
    await tester.pump();
    expect(agent.enabled, isFalse);
    expect(hub.connections, isEmpty);
    expect(agent.status, RemoteAgentStatus.off);

    await agent.setEnabled(true);
    await tester.pump();
    expect(hub.connections.single.url.toString(), 'ws://127.0.0.1:9978/api/v1/remote/screen');
    expect(hub.screen.token, isNull);
    final id = hub.screen.hello['id'] as String;
    expect(id, settings.getString(RemoteAgent.idKey), reason: 'made once and kept');
    expect(hub.screen.hello['name'], isNotEmpty);
    expect(hub.screen.hello['platform'], 'windows');
    expect(hub.screen.hello['form'], 'desktop');
    expect(agent.status, RemoteAgentStatus.connecting);
    expect(hub.screen.sent.where((m) => m['type'] == 'state'), isEmpty, reason: 'nothing before the hub took the hello');

    hub.screen.deliver({'type': 'welcome', 'id': id, 'controllers': 0});
    await tester.pump();
    expect(agent.status, RemoteAgentStatus.online);
    expect(hub.screen.state['title'], '首页');

    // A change is sent once, a little later; no change, nothing.
    state = {'title': '片名', 'page': 'player'};
    RemoteHost.instance.changed();
    RemoteHost.instance.changed();
    await tester.pump(const Duration(milliseconds: 100));
    expect(hub.screen.states, 2);
    expect(hub.screen.state['title'], '片名');
    RemoteHost.instance.changed();
    await tester.pump(const Duration(milliseconds: 100));
    expect(hub.screen.states, 2);

    // Commands are done and answered to the remote that sent them.
    final ok = await hub.screen.command(tester, 'key', {'key': 'up'});
    expect(ok['ok'], isTrue);
    expect(ok['to'], 'c1');
    expect(commands.single, 'key {key: up}');
    final bad = await hub.screen.command(tester, 'bad');
    expect(bad['ok'], isFalse);
    expect(bad['message'], '不行');

    // Remotes come and go; while one watches, the state is sent again every few seconds (the position moves on).
    hub.screen.deliver({'type': 'controllers', 'count': 1, 'names': ['我的手机']});
    await tester.pump();
    expect(agent.controllers, ['我的手机']);
    final before = hub.screen.states;
    state = {'title': '片名', 'page': 'player', 'position': 5000};
    await tester.pump(RemoteAgent.refresh);
    expect(hub.screen.states, before + 1);
    hub.screen.deliver({'type': 'controllers', 'count': 0, 'names': <String>[]});
    await tester.pump();
    expect(agent.controllers, isEmpty);
    expect(gone, 1, reason: 'what a remote held down is let go');

    // The engine goes away: the agent tries again, with the same id.
    hub.screen.drop();
    await tester.pump();
    expect(agent.status, RemoteAgentStatus.offline);
    await tester.pump(const Duration(milliseconds: 250));
    expect(hub.connections.length, 2);
    expect(hub.screen.hello['id'], id);

    // Another layout is another hello.
    agent.form = 'tv';
    await tester.pump();
    expect(hub.connections.length, 3);
    expect(hub.connections[1].closed, isTrue);
    expect(hub.screen.hello['form'], 'tv');

    // A name of the user's own.
    await agent.setScreenName('客厅电视');
    await tester.pump();
    expect(hub.screen.hello['name'], '客厅电视');

    // Off: the connection ends, and with it everything a remote could do.
    await agent.setEnabled(false);
    await tester.pump();
    expect(hub.screen.closed, isTrue);
    expect(agent.status, RemoteAgentStatus.off);
    final made = hub.connections.length;
    await tester.pump(const Duration(seconds: 30));
    expect(hub.connections.length, made);
    agent.dispose();
  });

  testWidgets('the agent carries the token to an engine on another device, and tells an old engine from a missing one', (tester) async {
    final hub = FakeRemoteHub();
    final settings = MemorySettings();
    await settings.setString(RemoteAgent.enabledKey, '1');
    var status = 404;
    final agent = RemoteAgent(
      settings: settings,
      connector: hub.connect,
      collect: () => const {},
      perform: (_, _) async => null,
      probe: () async => status,
      retryBase: const Duration(milliseconds: 200),
    );
    agent.bind(engineUrl: 'http://192.168.1.5:9978', connected: true, token: 'dev1.secret');
    await tester.pump();
    expect(hub.screen.url.toString(), 'ws://192.168.1.5:9978/api/v1/remote/screen');
    expect(hub.screen.token, 'dev1.secret');

    // No engine connected: nothing to register with.
    agent.bind(engineUrl: 'http://192.168.1.5:9978', connected: false, token: 'dev1.secret');
    await tester.pump();
    expect(hub.screen.closed, isTrue);
    expect(agent.status, RemoteAgentStatus.off);

    // An engine from before the remote control: said so, and asked again only once in a long while.
    hub.refuse = true;
    agent.bind(engineUrl: 'http://192.168.1.5:9978', connected: true, token: 'dev1.secret');
    await tester.pump();
    await tester.pump();
    expect(agent.status, RemoteAgentStatus.unsupported);
    // An engine that does not answer: tried again soon.
    status = 0;
    await tester.pump(const Duration(seconds: 13));
    expect(agent.status, RemoteAgentStatus.offline);
    hub.refuse = false;
    await tester.pump(const Duration(seconds: 2));
    expect(hub.connections.length, 2);
    agent.dispose();
  });

  // ---------------------------------------------------------------- keys

  testWidgets('a phone drives the TV layout: its keys move the focus, OK opens, BACK and 主页 go back', (tester) async {
    final hub = await pumpApp(tester);
    expect(hub.screen.hello['form'], 'tv');
    expect(hub.screen.state['form'], 'tv');
    expect(hub.screen.state['page'], 'browse');
    expect(hub.screen.state['player'], isNull);
    expect(focusIsIn(find.byKey(const Key('tv-rail-0'))), isTrue, reason: 'starts on 首页');

    expect((await press(tester, hub, 'down'))['ok'], isTrue);
    expect(focusIsIn(find.byKey(const Key('tv-rail-1'))), isTrue, reason: '↓ on the phone is ↓ on a remote');
    await press(tester, hub, 'up');
    expect(focusIsIn(find.byKey(const Key('tv-rail-0'))), isTrue);

    // A key that is held repeats, like a remote's; let go, it is up again.
    await hub.screen.command(tester, 'key', {'key': 'down', 'action': 'down'});
    expect(HardwareKeyboard.instance.logicalKeysPressed, contains(LogicalKeyboardKey.arrowDown));
    await hub.screen.command(tester, 'key', {'key': 'down', 'action': 'repeat'});
    await hub.screen.command(tester, 'key', {'key': 'down', 'action': 'repeat'});
    await hub.screen.command(tester, 'key', {'key': 'down', 'action': 'up'});
    await pass(tester, const Duration(milliseconds: 400));
    expect(HardwareKeyboard.instance.logicalKeysPressed, isEmpty);
    expect(focusIsIn(find.byKey(const Key('tv-rail-3'))), isTrue, reason: 'down and two repeats: three entries on');
    await press(tester, hub, 'up', times: 3);

    // A phone that vanishes with a finger on the pad does not leave the key down for ever.
    await hub.screen.command(tester, 'key', {'key': 'right', 'action': 'down'});
    expect(HardwareKeyboard.instance.logicalKeysPressed, contains(LogicalKeyboardKey.arrowRight));
    await tester.pump(RemoteKeyboard.holdTimeout);
    expect(HardwareKeyboard.instance.logicalKeysPressed, isEmpty);
    await pass(tester, const Duration(milliseconds: 400));
    expect(focusOnText('推荐片'), isTrue, reason: '→ went into the page, to the first poster');

    await press(tester, hub, 'ok');
    await pass(tester, const Duration(seconds: 1));
    expect(find.text('片名'), findsOneWidget, reason: 'OK opens the detail page');
    expect(focusIsIn(find.byKey(const Key('detail-play'))), isTrue);

    // BACK: no page takes the key, so the page closes, as Android's own back does for a box's remote.
    await press(tester, hub, 'back');
    await pass(tester, const Duration(seconds: 1));
    expect(find.text('片名'), findsNothing);
    expect(focusOnText('推荐片'), isTrue, reason: 'the poster that opened it has the focus again');

    // 主页: out of whatever is open, to 首页.
    await press(tester, hub, 'ok');
    await pass(tester, const Duration(seconds: 1));
    expect(find.text('片名'), findsOneWidget);
    expect((await hub.screen.command(tester, 'home'))['ok'], isTrue);
    await pass(tester, const Duration(seconds: 1));
    expect(find.text('片名'), findsNothing);
    expect(focusIsIn(find.byKey(const Key('tv-rail-0'))), isTrue);
    // From another tab too.
    await press(tester, hub, 'down', times: 3);
    await press(tester, hub, 'ok');
    await pass(tester, const Duration(milliseconds: 500));
    expect(tester.widget<TvShell>(find.byType(TvShell)).index, 3);
    await hub.screen.command(tester, 'home');
    await pass(tester, const Duration(milliseconds: 500));
    expect(tester.widget<TvShell>(find.byType(TvShell)).index, 0);
    expect(focusIsIn(find.byKey(const Key('tv-rail-0'))), isTrue);

    // BACK on 首页 asks before quitting (the shell's own back); BACK again closes the question, once.
    await press(tester, hub, 'back');
    expect(find.text('退出映舟？'), findsOneWidget);
    await press(tester, hub, 'back');
    expect(find.text('退出映舟？'), findsNothing);
    expect(find.byType(TvShell), findsOneWidget);

    final unknown = await hub.screen.command(tester, 'key', {'key': 'f13'});
    expect(unknown['ok'], isFalse);
    expect(unknown['message'], contains('f13'));
    final nothing = await hub.screen.command(tester, 'pause');
    expect(nothing['ok'], isFalse, reason: 'nothing plays: ${nothing['message']}');
    await leave(tester);
  });

  // ---------------------------------------------------------------- the player

  testWidgets('a phone drives the player: what plays is reported; pause, seek, speed, volume, line and episode whatever has the focus', (tester) async {
    final hub = await pumpApp(tester, lines: [fakeLine('线路一', 'a', count: 4), fakeLine('线路二', 'b', count: 4)]);
    await press(tester, hub, 'right');
    await press(tester, hub, 'ok');
    await pass(tester, const Duration(seconds: 1));
    await press(tester, hub, 'ok');
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened, ['https://cdn.test/a/1.m3u8'], reason: 'the first episode plays');
    player.playTo(const Duration(minutes: 5));
    await pass(tester, const Duration(milliseconds: 500));

    var p = hub.screen.player!;
    expect(hub.screen.state['page'], 'player');
    expect(hub.screen.state['title'], '片名');
    expect(p['kind'], 'vod');
    expect(p['title'], '片名');
    expect(p['subtitle'], '第1集 · 线路一');
    expect(p['lines'], ['线路一', '线路二']);
    expect(p['line'], 0);
    expect(p['episodes'], ['第1集', '第2集', '第3集', '第4集']);
    expect(p['episode'], 0);
    expect(p['duration'], const Duration(minutes: 40).inMilliseconds);
    expect(p['position'], const Duration(minutes: 5).inMilliseconds);
    expect(p['paused'], isFalse);
    expect(p['speed'], 1.0);
    expect(p['speeds'], contains(1.5));

    // The episode list is open on the screen and has the focus: commands do not care.
    await press(tester, hub, 'up');
    expect(find.byKey(const Key('tv-episode-0')), findsOneWidget);

    expect((await hub.screen.command(tester, 'pause'))['ok'], isTrue);
    expect(player.state.playing, isFalse);
    expect(hub.screen.player!['paused'], isTrue);
    await hub.screen.command(tester, 'toggle');
    expect(player.state.playing, isTrue);
    expect(hub.screen.player!['paused'], isFalse);

    await hub.screen.command(tester, 'seek', {'position': 600000});
    expect(player.seeks.last, const Duration(minutes: 10));
    expect(hub.screen.player!['position'], 600000, reason: 'a seek is news for the phone at once');
    await hub.screen.command(tester, 'seekBy', {'delta': -10000});
    expect(player.seeks.last, const Duration(minutes: 9, seconds: 50));
    await hub.screen.command(tester, 'seek', {'position': 99999999});
    expect(player.seeks.last, const Duration(minutes: 40), reason: 'not past the end');

    await hub.screen.command(tester, 'speed', {'value': 1.5});
    expect(player.state.rate, 1.5);
    expect(hub.screen.player!['speed'], 1.5);
    expect((await hub.screen.command(tester, 'speed', {'value': 7}))['ok'], isFalse);

    await hub.screen.command(tester, 'volume', {'value': 30});
    expect(player.state.volume, 30);
    expect(hub.screen.player!['volume'], 30);
    await hub.screen.command(tester, 'volumeBy', {'delta': 5});
    expect(player.state.volume, 35);
    await hub.screen.command(tester, 'mute');
    expect(player.state.volume, 0);
    expect(hub.screen.player!['muted'], isTrue);
    await hub.screen.command(tester, 'mute', {'on': true});
    expect(player.state.volume, 0, reason: 'already muted');
    await hub.screen.command(tester, 'mute');
    expect(player.state.volume, 35);

    final danmaku = hub.screen.player!['danmaku'] as bool;
    await hub.screen.command(tester, 'danmaku');
    expect(hub.screen.player!['danmaku'], !danmaku);

    await hub.screen.command(tester, 'episode', {'index': 2});
    await pass(tester, const Duration(milliseconds: 500));
    expect(player.opened.last, 'https://cdn.test/a/3.m3u8');
    p = hub.screen.player!;
    expect(p['episode'], 2);
    expect(p['subtitle'], '第3集 · 线路一');
    await hub.screen.command(tester, 'next');
    await pass(tester, const Duration(milliseconds: 500));
    expect(player.opened.last, 'https://cdn.test/a/4.m3u8');
    final last = await hub.screen.command(tester, 'next');
    expect(last['ok'], isFalse);
    expect(last['message'], '已经是最后一集');
    expect((await hub.screen.command(tester, 'episode', {'index': 9}))['ok'], isFalse);

    await hub.screen.command(tester, 'line', {'index': 1});
    await pass(tester, const Duration(milliseconds: 500));
    expect(player.opened.last, 'https://cdn.test/b/4.m3u8');
    expect(hub.screen.player!['line'], 1);
    expect((await hub.screen.command(tester, 'line', {'index': 5}))['ok'], isFalse);
    expect((await hub.screen.command(tester, 'no-such-command'))['ok'], isFalse);

    // Out of the player: nothing plays any more, and the phone is told.
    await hub.screen.command(tester, 'stop');
    await pass(tester, const Duration(seconds: 1));
    expect(find.byKey(const Key('detail-play')), findsOneWidget);
    expect(hub.screen.player, isNull);
    expect(hub.screen.state['page'], 'browse');
    await leave(tester);
  });

  testWidgets('the desktop layout is driven the same way', (tester) async {
    final hub = await pumpApp(tester, form: DeviceForm.desktop);
    expect(hub.screen.state['form'], 'desktop');
    await tester.tap(find.text('推荐片').first);
    await pass(tester, const Duration(seconds: 1));
    expect(find.text('片名'), findsOneWidget);
    // BACK closes the page: nothing in the desktop layout takes the key either.
    await press(tester, hub, 'back');
    await pass(tester, const Duration(seconds: 1));
    expect(find.text('片名'), findsNothing);

    await tester.tap(find.text('推荐片').first);
    await pass(tester, const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('detail-play')));
    await pass(tester, const Duration(seconds: 1));
    player.playTo(const Duration(minutes: 1));
    await pass(tester, const Duration(milliseconds: 500));
    expect(hub.screen.player!['title'], '片名');
    // The player's own keys: OK pauses; BACK leaves the player (once: the key it took is not acted on twice).
    await press(tester, hub, 'ok');
    expect(player.state.playing, isFalse);
    await press(tester, hub, 'back');
    await pass(tester, const Duration(seconds: 1));
    expect(hub.screen.player, isNull);
    expect(find.byKey(const Key('detail-play')), findsOneWidget, reason: 'one page back, not two');
    await hub.screen.command(tester, 'home');
    await pass(tester, const Duration(seconds: 1));
    expect(find.byKey(const Key('detail-play')), findsNothing);
    await leave(tester);
  });

  // ---------------------------------------------------------------- text

  testWidgets('a text field with the focus is told to the phone; what is typed there lands in it, Enter submits', (tester) async {
    final hub = await pumpApp(tester, form: DeviceForm.desktop);
    expect(hub.screen.state['text'], isNull);
    await tester.tap(find.text('搜索'));
    await pass(tester, const Duration(milliseconds: 500));
    await tester.tap(find.byType(TextField).first);
    await pass(tester, const Duration(milliseconds: 500));
    final text = hub.screen.state['text'] as Map<String, dynamic>;
    expect(text['value'], '');
    expect(text['secret'], isFalse);

    expect((await hub.screen.command(tester, 'text', {'value': '星河'}))['ok'], isTrue);
    expect(tester.widget<EditableText>(find.byType(EditableText).first).controller.text, '星河');
    expect((hub.screen.state['text'] as Map)['value'], '星河');
    await hub.screen.command(tester, 'text', {'value': '星河往事'});
    expect(tester.widget<EditableText>(find.byType(EditableText).first).controller.text, '星河往事');

    // Enter on the phone: the field's own action, here the search.
    expect((await hub.screen.command(tester, 'submit'))['ok'], isTrue);
    await pass(tester, const Duration(seconds: 1));
    expect(find.text('推荐片'), findsWidgets, reason: 'the search ran and shows what it found');

    // No field has the focus: said so.
    FocusManager.instance.primaryFocus?.unfocus();
    await pass(tester, const Duration(milliseconds: 300));
    expect(hub.screen.state['text'], isNull);
    final refused = await hub.screen.command(tester, 'text', {'value': 'x'});
    expect(refused['ok'], isFalse);
    await leave(tester);
  });

  // ---------------------------------------------------------------- the TV layout on a desktop

  test('a desktop is a desktop unless the user chose the TV layout', () async {
    for (final p in [TargetPlatform.windows, TargetPlatform.macOS, TargetPlatform.linux]) {
      final settings = MemorySettings();
      final c = DeviceFormController(info: const DeviceInfo(tvMode: true), settings: settings, platform: p);
      expect(c.canOverride, isTrue);
      expect(c.isTv, isFalse, reason: 'what Android would say about TVs means nothing here');
      expect(c.formFor(const Size(1920, 1080)), DeviceForm.desktop);
      await c.setOverride(DeviceFormOverride.tv);
      expect(c.isTv, isTrue);
      expect(c.formFor(const Size(1920, 1080)), DeviceForm.tv);
      expect(c.formFor(const Size(900, 600)), DeviceForm.tv, reason: 'whatever the window size');
      // Kept for the next start.
      expect(DeviceFormController(settings: settings, platform: p).formFor(const Size(1920, 1080)), DeviceForm.tv);
      // The touch layout is not for desktops.
      await c.setOverride(DeviceFormOverride.touch);
      expect(c.formFor(const Size(400, 800)), DeviceForm.desktop);
    }
  });

  testWidgets('界面模式 on a desktop offers the TV layout, and a phone can switch it', (tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final hub = FakeRemoteHub();
    RemoteScreen.debugConnector = hub.connect;
    addTearDown(() => RemoteScreen.debugConnector = null);
    final settings = MemorySettings();
    await settings.setString(RemoteAgent.enabledKey, '1');
    final forms = DeviceFormController(settings: settings, platform: TargetPlatform.windows);
    final engine = fakeEngine(hasConfig: true);
    await tester.pumpWidget(
      DeviceFormScope(
        controller: forms,
        child: TvboxApp(state: AppState(clientFactory: (url) => EngineClient(url, httpClient: engine), settings: settings)),
      ),
    );
    await pass(tester, const Duration(seconds: 1));
    hub.screen.deliver({'type': 'welcome', 'id': 'x', 'controllers': 0});
    await tester.pump();
    expect(hub.screen.state['canTv'], isTrue);
    expect(hub.screen.state['form'], 'desktop');
    expect(find.byType(NavigationRail), findsOneWidget);

    await tester.tap(find.text('设置'));
    await pass(tester, const Duration(milliseconds: 500));
    expect(find.descendant(of: find.byType(UiModeSettings), matching: find.text('电视模式')), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(UiModeSettings), matching: find.text('电视模式')));
    await pass(tester, const Duration(seconds: 1));
    expect(forms.override, DeviceFormOverride.tv);
    expect(find.byType(TvShell), findsOneWidget, reason: 'the TV layout, on a desktop');
    expect(hub.screen.hello['form'], 'tv', reason: 'registered again as a TV');
    hub.screen.deliver({'type': 'welcome', 'id': 'x', 'controllers': 0});
    await tester.pump();
    expect(hub.screen.state['form'], 'tv');

    // Back to the desktop from the phone.
    expect((await hub.screen.command(tester, 'uiMode', {'mode': 'auto'}))['ok'], isTrue);
    await pass(tester, const Duration(seconds: 1));
    expect(forms.override, DeviceFormOverride.auto);
    expect(find.byType(NavigationRail), findsOneWidget);
    await leave(tester);
  });

  // ---------------------------------------------------------------- the switch

  testWidgets('允许手机遥控 is off by default; on, it switches LAN sharing on with it and shows a QR code with the pairing code', (tester) async {
    final engine = FakeLanEngine(fakeEngine(hasConfig: true), local: true, code: '654321');
    final settings = MemorySettings();
    final hub = await pumpApp(tester, form: DeviceForm.desktop, engine: engine, enabled: false, settings: settings);
    expect(hub.connections, isEmpty, reason: 'off: this app is not a screen of anything');
    await tester.tap(find.text('设置'));
    await pass(tester, const Duration(milliseconds: 500));
    final toggle = find.byKey(const Key('remote-switch'));
    await tester.ensureVisible(toggle);
    await pass(tester, const Duration(milliseconds: 300));
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(engine.sharing, isFalse);
    expect(find.byKey(const Key('remote-qr')), findsNothing);

    await tester.tap(toggle);
    await pass(tester, const Duration(seconds: 1));
    expect(engine.sharing, isTrue, reason: 'a phone comes in through LAN sharing');
    expect(find.textContaining('局域网共享也随它一起开启了'), findsOneWidget, reason: 'and the user is told');
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('lan-sharing-switch'))).value, isTrue);
    expect(settings.getString(RemoteAgent.enabledKey), '1');
    expect(hub.connections.length, 1, reason: 'registered with the engine');
    // The QR code leads to the engine's web remote on the LAN address, the pairing code in the fragment.
    expect(tester.widget<QrView>(find.byKey(const Key('remote-qr'))).data, 'http://192.168.1.5:9978/remote/#code=654321');
    expect(tester.widget<SelectableText>(find.byKey(const Key('remote-url'))).data, 'http://192.168.1.5:9978/remote/');
    hub.screen.deliver({'type': 'welcome', 'id': 'x', 'controllers': 0});
    hub.screen.deliver({'type': 'controllers', 'count': 1, 'names': ['遥控 · iPhone']});
    await pass(tester, const Duration(milliseconds: 300));
    expect(find.textContaining('遥控 · iPhone'), findsOneWidget);

    // Sharing off: no phone gets in any more, so the remote control goes off with it.
    await tester.ensureVisible(find.byKey(const Key('lan-sharing-switch')));
    await pass(tester, const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('lan-sharing-switch')));
    await pass(tester, const Duration(seconds: 1));
    expect(engine.sharing, isFalse);
    expect(settings.getString(RemoteAgent.enabledKey), '0');
    expect(hub.screen.closed, isTrue);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('remote-switch'))).value, isFalse);
    expect(find.byKey(const Key('remote-qr')), findsNothing);

    // On again, then off by its own switch: sharing stays as it is.
    await tester.tap(find.byKey(const Key('remote-switch')));
    await pass(tester, const Duration(seconds: 1));
    expect(engine.sharing, isTrue);
    await tester.tap(find.byKey(const Key('remote-switch')));
    await pass(tester, const Duration(seconds: 1));
    expect(settings.getString(RemoteAgent.enabledKey), '0');
    expect(engine.sharing, isTrue);
    await leave(tester);
  });

  testWidgets('源 has 遥控另一台映舟 (touch only); 设置 has 允许手机遥控', (tester) async {
    final engine = FakeLanEngine(fakeEngine(hasConfig: true), local: true, code: '123456');
    await pumpApp(tester, form: DeviceForm.tablet, engine: engine, enabled: false);
    await tester.tap(find.text('源'));
    await pass(tester, const Duration(milliseconds: 500));
    expect(find.byKey(const Key('lan-remote-other')), findsOneWidget, reason: 'controlling another 映舟 is about other devices');
    expect(find.byKey(const Key('remote-switch')), findsNothing);
    await tester.tap(find.text('设置'));
    await pass(tester, const Duration(milliseconds: 500));
    expect(find.byKey(const Key('remote-switch')), findsOneWidget, reason: 'being controlled is a setting of this device');
    expect(find.byKey(const Key('lan-remote-other')), findsNothing);
    expect(find.text('共享与遥控'), findsOneWidget);
    await leave(tester);
  });

  // ------------------------------------------------------------------- macOS

  // Flutter's default shortcuts make select (a remote's OK, what the phone sends) activate the focused item on Android,
  // Windows and Linux, but not on macOS and iOS: there a phone's OK did nothing outside the pages that read the key
  // themselves (the player, live TV).
  testWidgets('on macOS the phone\'s OK opens what has the focus, in the TV layout', (tester) async {
    final hub = await pumpApp(tester);
    await press(tester, hub, 'right');
    await pass(tester, const Duration(milliseconds: 400));
    expect(focusOnText('推荐片'), isTrue, reason: '→ goes into the page on macOS too (arrows are in its table)');
    await press(tester, hub, 'ok');
    await pass(tester, const Duration(seconds: 1));
    expect(find.text('片名'), findsOneWidget, reason: 'OK opens the detail page');
    await press(tester, hub, 'back');
    await pass(tester, const Duration(seconds: 1));
    expect(find.text('片名'), findsNothing, reason: 'BACK closes it');
    await hub.screen.command(tester, 'home');
    await pass(tester, const Duration(milliseconds: 500));
    await press(tester, hub, 'down', times: 3);
    await press(tester, hub, 'ok');
    await pass(tester, const Duration(milliseconds: 500));
    expect(tester.widget<TvShell>(find.byType(TvShell)).index, 3, reason: 'OK on a rail entry opens its page');
    await leave(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('on macOS the phone\'s OK opens what has the focus, in the desktop layout', (tester) async {
    final hub = await pumpApp(tester, form: DeviceForm.desktop);
    await pass(tester, const Duration(seconds: 1));
    final poster = find.ancestor(of: find.text('推荐片'), matching: find.byType(Focus)).first;
    Focus.of(tester.element(find.descendant(of: poster, matching: find.text('推荐片')))).requestFocus();
    await tester.pump();
    await press(tester, hub, 'ok');
    await pass(tester, const Duration(seconds: 1));
    expect(find.text('片名'), findsOneWidget, reason: 'OK opens the detail page');
    await leave(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
