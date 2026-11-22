// The LAN remote control, end to end on this machine: the real desktop app in the TV layout as the screen, the demo
// engine as the hub, and this test as the phone, over the engine's WebSocket.
//   engine: tvbox-engine --demo --port 19990
//   flutter test integration_test/remote_test.dart -d windows --dart-define=ENGINE_URL=http://127.0.0.1:19990
// The app registers as a screen (as with 「允许手机遥控」 on); the test finds it in /api/v1/remote/screens, opens
// /api/v1/remote/control and sends what the web remote sends: keys, then pause, seek and another episode while
// 《慢速源演示》 plays (a film the engine makes itself, so nothing here needs the internet). It prints "MARK:<step>"
// and, with --dart-define=SHOT_DIR=<dir>, saves a screenshot at each step.
//
// The window goes full screen for the run: the TV layout on a desktop does. No phone and no browser are involved;
// the page's side is covered by the engine's tests and by looking at it (docs/development.md).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/desktop/desktop_window.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/player_backend.dart';
import 'package:tvbox_client/remote/remote_agent.dart';
import 'package:tvbox_client/remote/remote_socket.dart';
import 'package:tvbox_client/settings.dart';
import 'package:tvbox_client/ui/device_form.dart';
import 'package:tvbox_client/ui/tv/tv_shell.dart';

const engineUrl = String.fromEnvironment('ENGINE_URL', defaultValue: 'http://127.0.0.1:19990');
const shotDir = String.fromEnvironment('SHOT_DIR');
const screenId = 'integration-test-screen';

/// The phone's end: a WebSocket to the hub, what came in over it, and commands with their answers.
class Phone {
  Phone(this._socket) {
    _socket.listen((data) {
      final msg = jsonDecode(data as String) as Map<String, dynamic>;
      switch (msg['type']) {
        case 'screen':
          screen = msg['screen'] as Map<String, dynamic>;
        case 'state':
          state = msg['state'] as Map<String, dynamic>;
          states++;
        case 'result':
          results[msg['id'] as String] = msg;
        case 'gone':
          gone = true;
      }
    });
  }

  static Future<Phone> connect(String id) async =>
      Phone(await WebSocket.connect(remoteSocketUri(engineUrl, 'control?screen=$id').toString(), protocols: const [remoteProtocol]));

  final WebSocket _socket;
  Map<String, dynamic>? screen;
  Map<String, dynamic> state = const {};
  int states = 0;
  final results = <String, Map<String, dynamic>>{};
  bool gone = false;
  int _seq = 0;

  Map<String, dynamic>? get player => state['player'] as Map<String, dynamic>?;

  String send(String name, [Map<String, Object?> args = const {}]) {
    final id = '${++_seq}';
    _socket.add(jsonEncode({'type': 'command', 'id': id, 'name': name, 'args': args}));
    return id;
  }

  Future<void> close() => _socket.close();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<T> real<T>(WidgetTester tester, Future<T> Function() action) async => (await tester.runAsync(action)) as T;

  Future<void> wait(WidgetTester tester, Duration d) async {
    final end = DateTime.now().add(d);
    while (DateTime.now().isBefore(end)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
  }

  Future<void> until(WidgetTester tester, bool Function() done, String what, {Duration timeout = const Duration(seconds: 40)}) async {
    final end = DateTime.now().add(timeout);
    while (!done()) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
      await wait(tester, const Duration(milliseconds: 100));
    }
  }

  Future<void> mark(WidgetTester tester, String step) async {
    // ignore: avoid_print
    print('MARK:$step');
    if (shotDir.isEmpty) return;
    await wait(tester, const Duration(milliseconds: 600));
    final element = find.byType(MaterialApp).evaluate().first;
    await tester.runAsync(() async {
      final image = await captureImage(element);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$shotDir/remote-$step.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  Future<String> http(String method, String path) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, Uri.parse('$engineUrl$path'));
      final response = await request.close();
      return await response.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }

  String focusLabel() => FocusManager.instance.primaryFocus?.debugLabel ?? '';

  testWidgets('a phone drives the real app in the TV layout through the engine', (tester) async {
    MediaKit.ensureInitialized();
    await real(tester, () => http('GET', '/demo/slow/set?delayMs=0&connectMs=0&kBps=0&totalKBps=0&reset=1'));
    addTearDown(() => http('GET', '/demo/slow/set?delayMs=400&connectMs=300&kBps=300&totalKBps=0&reset=1'));

    final settings = MemorySettings();
    // These tests start from the site's recommendations, whatever an earlier one left in the history.
    await settings.setString('ui.startPage', 'home');
    await settings.setString('siteKey', 'demo');
    // As with 「允许手机遥控」 on; the engine is on this machine, so neither the screen nor the test needs to pair.
    await settings.setString(RemoteAgent.enabledKey, '1');
    await settings.setString(RemoteAgent.idKey, screenId);
    await settings.setString(RemoteAgent.nameKey, '集成测试');
    late Player player;
    var playerMade = false;
    await tester.pumpWidget(
      DeviceFormScope.fixed(
        DeviceForm.tv,
        child: TvboxApp(
          state: AppState(
            clientFactory: (url) => EngineClient(url),
            engineUrl: engineUrl,
            settings: settings,
            playerBackend: () {
              final backend = mediaKitBackend();
              player = backend.player;
              playerMade = true;
              return backend;
            },
          ),
        ),
      ),
    );
    await until(tester, () => find.text('星河往事 第二季').evaluate().isNotEmpty, 'the home page');
    expect(find.byType(TvShell), findsOneWidget);
    await wait(tester, const Duration(seconds: 1));
    expect(DesktopWindow.instance.isFullScreen, isTrue, reason: 'the TV layout on a desktop is full screen');

    // The engine lists the screen once the app's agent has said hello; then the phone connects to it.
    Map<String, dynamic>? listed;
    final listedBy = DateTime.now().add(const Duration(seconds: 20));
    while (listed == null) {
      if (DateTime.now().isAfter(listedBy)) fail('the app never showed up in /api/v1/remote/screens');
      final all = (jsonDecode(await real(tester, () => http('GET', '/api/v1/remote/screens'))) as List).cast<Map<String, dynamic>>();
      listed = all.where((s) => s['id'] == screenId).firstOrNull;
      await wait(tester, const Duration(milliseconds: 300));
    }
    expect(listed['name'], '集成测试');
    expect(listed['form'], 'tv');
    expect(listed['platform'], Platform.operatingSystem);

    final phone = await real(tester, () => Phone.connect(screenId));
    addTearDown(phone.close);
    await until(tester, () => phone.states > 0, 'the first state');
    expect(phone.screen?['name'], '集成测试');
    expect(phone.state['form'], 'tv');
    expect(phone.state['page'], 'browse');
    expect(phone.player, isNull);

    /// Sends a command and waits for the screen's answer.
    Future<Map<String, dynamic>> command(String name, [Map<String, Object?> args = const {}]) async {
      final id = phone.send(name, args);
      await until(tester, () => phone.results.containsKey(id), 'the answer to $name $args', timeout: const Duration(seconds: 10));
      await wait(tester, const Duration(milliseconds: 250));
      return phone.results[id]!;
    }

    Future<void> press(String key) async {
      final result = await command('key', {'key': key, 'action': 'press'});
      expect(result['ok'], isTrue, reason: 'key $key: $result');
      await wait(tester, const Duration(milliseconds: 350));
    }

    // ---- keys: the focus moves as with a box's remote ----
    expect(focusLabel(), 'tv-rail-0', reason: 'the app starts on 首页');
    await press('down');
    expect(focusLabel(), 'tv-rail-1', reason: '↓ from the phone');
    await press('down');
    expect(focusLabel(), 'tv-rail-2');
    await mark(tester, 'rail');
    await press('up');
    await press('up');
    expect(focusLabel(), 'tv-rail-0');
    await press('right');
    expect(focusLabel(), isNot(startsWith('tv-rail')), reason: '→ goes into the page');
    final onPoster = FocusManager.instance.primaryFocus;
    await press('right');
    expect(FocusManager.instance.primaryFocus, isNot(onPoster), reason: '→ again moves to the next poster');
    await press('left');
    expect(FocusManager.instance.primaryFocus, onPoster);
    await mark(tester, 'poster');

    // OK opens what has the focus; BACK closes it again (no page takes the key: the page closes, as on Android).
    await press('ok');
    await until(tester, () => find.byKey(const Key('detail-play')).evaluate().isNotEmpty, 'the detail page');
    await mark(tester, 'detail');
    await press('back');
    await until(tester, () => find.byKey(const Key('detail-play')).evaluate().isEmpty, 'the detail page to close');
    expect(FocusManager.instance.primaryFocus, onPoster, reason: 'back on the poster that opened it');

    // ---- the player: 慢速源演示, opened by hand (it is far down the page), driven from the phone ----
    final grid = find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('慢速源演示'), 300, scrollable: grid);
    await wait(tester, const Duration(milliseconds: 500));
    await tester.tap(find.text('慢速源演示').first);
    await until(tester, () => find.byKey(const Key('detail-play')).evaluate().isNotEmpty, 'the detail page of 慢速源演示');
    final first = find.widgetWithText(OutlinedButton, '普通');
    await until(tester, () => first.evaluate().isNotEmpty, 'the episodes');
    await tester.ensureVisible(first);
    await wait(tester, const Duration(milliseconds: 500));
    await tester.tap(first);
    await until(tester, () => playerMade && player.state.position > const Duration(seconds: 2), 'the first picture', timeout: const Duration(seconds: 60));
    await until(tester, () => (phone.player?['duration'] as num? ?? 0) > 0, 'the player in the state');
    var p = phone.player!;
    expect(phone.state['page'], 'player');
    expect(p['kind'], 'vod');
    expect(p['title'], '慢速源演示');
    expect((p['subtitle'] as String).startsWith('普通'), isTrue, reason: '${p['subtitle']}');
    expect(p['paused'], isFalse);
    expect((p['episodes'] as List).length, greaterThan(4));
    expect(p['episode'], 0);
    expect((p['duration'] as num) > 30 * 60 * 1000, isTrue, reason: 'a 40-minute film: ${p['duration']}');
    await mark(tester, 'playing');

    // Pause and play, as commands (whatever has the focus) and as the OK key (the TV player's own handling).
    expect((await command('pause'))['ok'], isTrue);
    await until(tester, () => !player.state.playing, 'the player to pause');
    await until(tester, () => phone.player?['paused'] == true, 'paused in the state');
    final pausedAt = player.state.position;
    await wait(tester, const Duration(seconds: 1));
    expect((player.state.position - pausedAt).abs() < const Duration(milliseconds: 300), isTrue, reason: 'the picture stands still');
    await mark(tester, 'paused');
    await command('play');
    await until(tester, () => player.state.playing, 'the player to play');
    await press('ok');
    await until(tester, () => !player.state.playing, 'OK to pause');
    await press('ok');
    await until(tester, () => player.state.playing, 'OK to play');

    // Seek to 10:00.
    const target = Duration(minutes: 10);
    expect((await command('seek', {'position': target.inMilliseconds}))['ok'], isTrue);
    await until(tester, () => (player.state.position - target).abs() < const Duration(seconds: 6), 'the player at 10:00', timeout: const Duration(seconds: 30));
    await until(tester, () => player.state.position > target + const Duration(seconds: 1), 'playback from there', timeout: const Duration(seconds: 30));
    await until(tester, () => ((phone.player?['position'] as num? ?? 0) - target.inMilliseconds).abs() < 15000, 'the new position in the state');
    await mark(tester, 'seeked');
    // And 30 seconds back, as the phone's −30 does.
    final before = player.state.position;
    await command('seekBy', {'delta': -30000});
    await until(tester, () => player.state.position < before - const Duration(seconds: 20), 'the player 30 s back', timeout: const Duration(seconds: 30));

    // Another episode: the second one, by its place in the list.
    final second = (p['episodes'] as List)[1] as String;
    expect((await command('episode', {'index': 1}))['ok'], isTrue);
    await until(tester, () => phone.player?['episode'] == 1, 'the episode in the state');
    await until(
      tester,
      () => player.state.position > const Duration(seconds: 1) && player.state.position < const Duration(minutes: 2) && player.state.playing,
      'the second episode to play from its start',
      timeout: const Duration(seconds: 60),
    );
    p = phone.player!;
    expect((p['subtitle'] as String).startsWith(second), isTrue, reason: '${p['subtitle']}');
    expect(find.textContaining('慢速源演示 · $second'), findsWidgets, reason: 'the title on the screen names the episode');
    await mark(tester, 'episode');

    // ---- what the web console asks for (docs/design/web-console.md): answers with data, through the real hub ----
    final summary = await command('diag.summary');
    expect(summary['ok'], isTrue, reason: '$summary');
    final app = (summary['data'] as Map)['app'] as Map;
    expect(app['form'], 'tv');
    expect('${app['version']}', isNotEmpty);
    final log = await command('diag.log', {'limit': 50});
    final entries = ((log['data'] as Map)['entries'] as List).cast<Map>();
    expect(entries, isNotEmpty, reason: 'the steps of opening the film are in the log');
    final report = '${((await command('diag.report'))['data'] as Map)['text']}';
    expect(report, contains(Platform.operatingSystem), reason: 'the full report, not a summary');
    expect(report, isNot(contains(Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '\u0000')), reason: 'the user folder is masked');
    final got = await command('setting.get');
    expect(((got['data'] as Map)['values'] as Map)['remote.screenName'], '集成测试');
    // What 播放信息 says, in the state: the real player's picture.
    await until(tester, () => ((phone.player?['info'] as Map?)?['width'] as num? ?? 0) > 0, 'player.info with the picture size', timeout: const Duration(seconds: 15));
    final info = phone.player!['info'] as Map;
    expect(info['health'], isIn(['waiting', 'smooth', 'enough', 'thin']));
    // ignore: avoid_print
    print('INFO:$info');
    final backup = jsonDecode(await real(tester, () => http('GET', '/api/v1/backup'))) as Map<String, dynamic>;
    expect(backup['format'], 'yingzhou-backup');
    expect(backup['history'], isA<List>());
    await mark(tester, 'console');

    // Speed and volume, read back from the real player.
    await command('speed', {'value': 1.5});
    await until(tester, () => player.state.rate == 1.5, 'the speed');
    await command('speed', {'value': 1.0});
    final volume = player.state.volume;
    await command('volume', {'value': 40});
    await until(tester, () => player.state.volume == 40, 'the volume');
    await command('volume', {'value': volume});
    expect((await command('speed', {'value': 9}))['ok'], isFalse);

    // Out of the player and home, from the phone.
    await command('stop');
    await until(tester, () => phone.player == null, 'the player to close');
    await until(tester, () => find.byKey(const Key('detail-play')).evaluate().isNotEmpty, 'the detail page again');
    final nothing = await command('pause');
    expect(nothing['ok'], isFalse, reason: 'nothing plays now');
    await command('home');
    await until(tester, () => find.byKey(const Key('detail-play')).evaluate().isEmpty, 'the detail page to close');
    await wait(tester, const Duration(milliseconds: 500));
    expect(focusLabel(), 'tv-rail-0');
    expect(DesktopWindow.instance.isFullScreen, isTrue, reason: 'still full screen: leaving the player does not leave the TV layout');
    await mark(tester, 'home');

    // The app goes away: the hub tells the phone, and the screen is off the list.
    await tester.pumpWidget(const SizedBox());
    await until(tester, () => phone.gone, 'the phone to hear that the screen is gone', timeout: const Duration(seconds: 10));
    final left = (jsonDecode(await real(tester, () => http('GET', '/api/v1/remote/screens'))) as List).cast<Map<String, dynamic>>();
    expect(left.where((s) => s['id'] == screenId), isEmpty);
    await wait(tester, const Duration(milliseconds: 500));
    expect(DesktopWindow.instance.isFullScreen, isFalse, reason: 'and the window is a window again');
  });
}
