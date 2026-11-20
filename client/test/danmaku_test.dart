import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/danmaku_models.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/pages/danmaku_layer.dart';
import 'package:tvbox_client/pages/danmaku_service_settings.dart';
import 'package:tvbox_client/pages/player_tracks.dart' show filePicker, pickWithDialog;
import 'package:tvbox_client/settings.dart';

import 'fake_engine.dart';
import 'fake_player.dart';

DanmakuComment c(int ms, String text, [DanmakuMode mode = DanmakuMode.scroll]) => DanmakuComment(timeMs: ms, text: text, mode: mode);

void main() {
  group('scheduler', () {
    // Every comment is 100 wide and 20 high on a 1000 × 100 screen with 25-high lines: four lanes, 9 s to cross.
    DanmakuScheduler scheduler(List<DanmakuComment> items, {double width = 100}) => DanmakuScheduler(measure: (_) => Size(width, 20))
      ..layout(const Size(1000, 100), 25, 9000)
      ..setItems(items, 0);
    bool all(DanmakuComment _) => true;

    test('comments at the same moment take a lane each, and the ones with no lane left are dropped', () {
      final s = scheduler([for (var i = 0; i < 6; i++) c(1000, '$i')]);
      s.advance(1000, area: 1, shows: all);
      expect(s.scroll.map((a) => a.lane), [0, 1, 2, 3]);
      expect(s.dropped, 2);
      expect(s.shown, 4);
    });

    test('a lane takes the next comment once the one before has fully come in', () {
      final s = scheduler([c(0, 'a'), c(500, 'b'), c(2000, 'c')]);
      s.advance(0, area: 1, shows: all);
      s.advance(500, area: 1, shows: all);
      // After 0.5 s the first has moved 1100 / 9000 × 500 ≈ 61 px: not all of its 100 px are in, so lane 1.
      expect(s.scroll.map((a) => a.lane), [0, 1]);
      s.advance(2000, area: 1, shows: all);
      expect(s.scroll.last.lane, 0, reason: 'by 2 s the first has come in and the third is no faster');
    });

    test('a long, faster comment does not go into a lane where it would catch up with the one in front', () {
      final s = DanmakuScheduler(measure: (d) => Size(d.text == 'long' ? 900 : 50, 20))
        ..layout(const Size(1000, 100), 25, 9000)
        ..setItems([c(0, 'short'), c(1500, 'long')], 0);
      s.advance(0, area: 1, shows: (_) => true);
      s.advance(1500, area: 1, shows: (_) => true);
      expect(s.scroll.firstWhere((a) => a.comment.text == 'long').lane, 1);
    });

    test('a large comment, taller than a lane, takes two and the next ones go below it', () {
      final s = DanmakuScheduler(measure: (d) => Size(100, d.size > 25 ? 36 : 20))
        ..layout(const Size(1000, 100), 25, 9000)
        ..setItems([const DanmakuComment(timeMs: 0, text: 'big', size: 36), c(0, 'a'), c(0, 'b'), c(0, 'dropped')], 0);
      s.advance(0, area: 1, shows: (_) => true);
      expect([for (final a in s.scroll) (a.comment.text, a.lane, a.span)], [('big', 0, 2), ('a', 2, 1), ('b', 3, 1)]);
      expect(s.dropped, 1);
    });

    test('scrolling comments cross the screen from right to left and leave', () {
      final s = scheduler([c(0, 'a')]);
      s.advance(0, area: 1, shows: all);
      final a = s.scroll.single;
      expect(s.xOf(a, 0), 1000);
      expect(s.xOf(a, 4500), closeTo(450, 0.01));
      expect(s.xOf(a, 9000), closeTo(-100, 0.01));
      s.advance(9000, area: 1, shows: all);
      expect(s.scroll, isEmpty);
    });

    test('top and bottom comments stay four seconds, each in a lane of its own; the area limits the lanes', () {
      final s = scheduler([c(0, 't1', DanmakuMode.top), c(0, 't2', DanmakuMode.top), c(0, 'b', DanmakuMode.bottom), c(0, 'x', DanmakuMode.top)]);
      s.advance(0, area: 0.5, shows: all);
      expect(s.top.map((a) => a.lane), [0, 1]);
      expect(s.bottom.single.lane, 0);
      expect(s.dropped, 1, reason: 'half the height holds two lanes');
      s.advance(3999, area: 0.5, shows: all);
      expect(s.top, hasLength(2));
      s.advance(4000, area: 0.5, shows: all);
      expect(s.top, isEmpty);
      expect(s.bottom, isEmpty);
    });

    test('after a seek the comments of the last few seconds come back where they would be by now', () {
      final s = scheduler([c(1000, 'early'), c(55000, 'running'), c(59000, 'just'), c(61000, 'later')]);
      s.seek(60000);
      s.advance(60000, area: 1, shows: all);
      expect(s.scroll.map((a) => a.comment.text), ['running', 'just']);
      expect(s.xOf(s.scroll.first, 60000), lessThan(1000), reason: 'already on its way across');
    });

    test('blocked kinds and words', () {
      final prefs = DanmakuPrefs(MemorySettings())..update(blockTop: true, keywords: '剧透, 广告\n/^\\d+\$/');
      expect(prefs.shows(c(0, '好看')), isTrue);
      expect(prefs.shows(c(0, '好看', DanmakuMode.top)), isFalse);
      expect(prefs.shows(c(0, '前方剧透')), isFalse);
      expect(prefs.shows(c(0, 'AD 广告位')), isFalse);
      expect(prefs.shows(c(0, '666')), isFalse);
      expect(prefs.shows(c(0, '666a')), isTrue);
    });

    test('the look is remembered on the device', () {
      final settings = MemorySettings();
      DanmakuPrefs(settings).update(enabled: false, opacity: 0.5, fontScale: 1.5, speed: 1.25, area: 0.25, blockBottom: true, keywords: 'a');
      final again = DanmakuPrefs(settings);
      expect([again.enabled, again.opacity, again.fontScale, again.speed, again.area, again.blockBottom, again.keywords], [false, 0.5, 1.5, 1.25, 0.25, true, 'a']);
    });
  });

  group('overlay', () {
    testWidgets('follows the player: moves while it plays, stops when it pauses, starts over after a seek', (tester) async {
      final fake = FakePlayer();
      final player = Player(platformPlayer: fake);
      final prefs = DanmakuPrefs(MemorySettings());
      await fake.open(Media('https://cdn.test/1.m3u8'));
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 800,
            height: 450,
            child: DanmakuOverlay(player: player, comments: [for (var i = 0; i < 50; i++) c(i * 200, '弹幕 $i'), c(120000, '两分钟')], prefs: prefs),
          ),
        ),
      );
      DanmakuOverlay.stats.reset();
      fake.playTo(const Duration(seconds: 3));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(DanmakuOverlay.stats.onScreen, greaterThan(5));
      final playingFrames = DanmakuOverlay.stats.frames;
      expect(playingFrames, greaterThanOrEqualTo(10), reason: 'a frame each time the screen refreshes');

      await fake.playOrPause();
      await tester.pump(const Duration(milliseconds: 100));
      final pausedAt = DanmakuOverlay.stats.frames;
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(DanmakuOverlay.stats.frames, pausedAt, reason: 'nothing is painted while paused');

      await fake.seek(const Duration(seconds: 119));
      await fake.playOrPause();
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(DanmakuOverlay.stats.onScreen, 1, reason: 'after the seek only what is due there: $DanmakuOverlay.stats');

      // Blocking scrolling ones takes them off at once.
      prefs.update(blockScroll: true);
      await tester.pump(const Duration(milliseconds: 100));
      expect(DanmakuOverlay.stats.onScreen, 0);
      await tester.pumpWidget(const SizedBox());
      await fake.dispose();
    });
  });

  group('player page', () {
    late FakePlayer player;
    late MemorySettings settings;
    late List<Uri> asked;

    final dense = [for (var i = 0; i < 300; i++) {'time': i * 100, 'mode': 'scroll', 'color': 16777215, 'size': 25, 'text': '弹幕$i'}];

    Future<void> pass(WidgetTester tester, Duration time) async {
      for (var t = Duration.zero; t < time; t += const Duration(milliseconds: 100)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> play(WidgetTester tester, {bool enabled = true}) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      player = FakePlayer();
      settings = MemorySettings();
      if (!enabled) await settings.setString('danmaku.enabled', 'false');
      asked = [];
      final engine = fakeEngine(hasConfig: true, danmaku: {'*': dense}, danmakuAsked: asked);
      await tester.pumpWidget(
        TvboxApp(state: AppState(clientFactory: (url) => EngineClient(url, httpClient: engine), playerBackend: () => player.backend(), settings: settings)),
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

    Future<void> showControls(WidgetTester tester) async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(600, 300));
      await mouse.moveTo(const Offset(620, 320));
      await tester.pump();
      await mouse.removePointer();
    }

    testWidgets('the episode\'s danmaku are asked for with its title and shown over the picture', (tester) async {
      await play(tester);
      expect(asked, hasLength(1));
      expect(asked.single.queryParameters, containsPair('title', '片名'));
      expect(asked.single.queryParameters, containsPair('episode', '第1集'));
      expect(asked.single.queryParameters, containsPair('line', '线路一'));
      expect(find.byKey(const Key('danmaku-overlay')), findsOneWidget);
      player.playTo(const Duration(seconds: 5));
      await pass(tester, const Duration(milliseconds: 500));
      expect(DanmakuOverlay.stats.onScreen, greaterThan(0));

      // The next episode has danmaku of its own.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await pass(tester, const Duration(seconds: 1));
      expect(asked.last.queryParameters['episode'], '第2集');
      await leave(tester);
    });

    testWidgets('D turns them off and on, remembered; nothing is asked for while they are off', (tester) async {
      await play(tester, enabled: false);
      expect(asked, isEmpty);
      expect(find.byKey(const Key('danmaku-overlay')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await pass(tester, const Duration(milliseconds: 300));
      expect(asked, hasLength(1), reason: 'asked for once turned on');
      expect(find.byKey(const Key('danmaku-overlay')), findsOneWidget);
      expect(settings.getString('danmaku.enabled'), 'true');
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('danmaku-overlay')), findsNothing);
      expect(find.text('弹幕已关闭'), findsOneWidget);
      expect(settings.getString('danmaku.enabled'), 'false');
      await leave(tester);
    });

    testWidgets('the panel says where they came from, loads a file, and keeps the settings', (tester) async {
      await play(tester);
      await showControls(tester);
      await tester.tap(find.byKey(const Key('danmaku-button')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('共 300 条 · 来自站点'), findsOneWidget);

      await tester.tap(find.text('半屏'));
      await tester.tap(find.text('顶部'));
      await tester.pump();
      expect(settings.getString('danmaku.area'), '0.5');
      expect(settings.getString('danmaku.blockTop'), 'true');
      await tester.enterText(find.byKey(const Key('danmaku-keywords')), '剧透');
      await tester.pump(const Duration(milliseconds: 500));
      expect(settings.getString('danmaku.keywords'), '剧透');

      filePicker = (label, extensions) async {
        expect(extensions, containsAll(['xml', 'json', 'ass']));
        return (name: '本地弹幕.xml', bytes: Uint8List.fromList([60]));
      };
      addTearDown(() => filePicker = pickWithDialog);
      await tester.tap(find.text('加载弹幕文件…'));
      await pass(tester, const Duration(milliseconds: 300));
      expect(find.text('共 1 条 · 来自本地文件'), findsOneWidget);
      expect(find.text('已加载 1 条弹幕'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('共 1 条 · 来自本地文件'), findsNothing, reason: 'Esc closes the panel first');
      await leave(tester);
    });
  });

  group('services on the 源 page', () {
    Future<List<Map<String, dynamic>>> open(WidgetTester tester, {String configApi = ''}) async {
      tester.view.physicalSize = const Size(1400, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final sent = <Map<String, dynamic>>[];
      final engine = fakeEngine(hasConfig: true, danmakuConfigApi: configApi, settingsSent: sent);
      await tester.pumpWidget(
        TvboxApp(state: AppState(clientFactory: (url) => EngineClient(url, httpClient: engine), playerBackend: () => FakePlayer().backend(), settings: MemorySettings())),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byType(DanmakuServiceSettings), 300, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      return sent;
    }

    testWidgets('the config\'s API is off until switched on, and says where it goes', (tester) async {
      final sent = await open(tester, configApi: 'https://dm.example.com/api?name={name}');
      expect(find.text('接口：dm.example.com'), findsOneWidget);
      final toggle = find.byKey(const Key('danmaku-config-api'));
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(sent.last, {'danmakuConfigApi': true});
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);

      await tester.enterText(find.byKey(const Key('danmaku-custom-api')), ' https://my.dandan/token ');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(sent.last, {'danmakuApi': 'https://my.dandan/token'});
    });

    testWidgets('without an API in the config there is nothing to switch on', (tester) async {
      await open(tester);
      expect(find.text('当前订阅没有提供弹幕接口'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('danmaku-config-api'))).onChanged, isNull);
    });
  });
}
