import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/pages/player_tracks.dart';
import 'package:tvbox_client/ui/device_form.dart';
import 'package:tvbox_client/ui/tv/tv_focus.dart';

import 'fake_engine.dart';
import 'fake_player.dart';

/// The player and live TV with a remote control: keys as Android sends them (DPAD_CENTER is `select`, BACK
/// `goBack`, MENU `contextMenu`), the player is [FakePlayer].
void main() {
  late FakePlayer player;

  Future<void> pass(WidgetTester tester, Duration time) async {
    for (var t = Duration.zero; t < time; t += const Duration(milliseconds: 100)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// A key as Android sends it. The test's key simulator has no physical key named like BACK's logical one, so BACK
  /// borrows Escape's (the app only looks at the logical key, `goBack`).
  Future<void> key(WidgetTester tester, LogicalKeyboardKey k, {int times = 1}) async {
    for (var i = 0; i < times; i++) {
      await tester.sendKeyEvent(k, platform: 'android', physicalKey: k == LogicalKeyboardKey.goBack ? PhysicalKeyboardKey.escape : null);
      await pass(tester, const Duration(milliseconds: 300));
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

  Future<void> pumpTv(WidgetTester tester, {List<Map<String, Object>>? lines}) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    player = FakePlayer();
    final engine = fakeEngine(hasConfig: true, lines: lines);
    await tester.pumpWidget(
      DeviceFormScope.fixed(
        DeviceForm.tv,
        child: TvboxApp(
          state: AppState(
            clientFactory: (url) => EngineClient(url, httpClient: engine),
            playerBackend: () => player.backend(),
          ),
        ),
      ),
    );
    await pass(tester, const Duration(seconds: 1));
  }

  /// 首页 → the first poster → 播放, all with the remote.
  Future<void> openPlayer(WidgetTester tester) async {
    await pumpTv(tester, lines: [fakeLine('线路一', 'a', count: 4), fakeLine('线路二', 'b', count: 4)]);
    await key(tester, LogicalKeyboardKey.arrowRight);
    await key(tester, LogicalKeyboardKey.select);
    await pass(tester, const Duration(seconds: 1));
    await key(tester, LogicalKeyboardKey.select);
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened, ['https://cdn.test/a/1.m3u8'], reason: 'the first episode plays');
    player.playTo(const Duration(minutes: 5));
    await pass(tester, const Duration(milliseconds: 500));
  }

  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('player: OK pauses, ← / → seek, holding → runs ahead and seeks once on release', (tester) async {
    await openPlayer(tester);
    expect(player.state.playing, isTrue);
    await key(tester, LogicalKeyboardKey.select);
    expect(player.state.playing, isFalse, reason: 'OK pauses');
    await key(tester, LogicalKeyboardKey.select);
    expect(player.state.playing, isTrue, reason: 'OK again plays');

    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(player.seeks.last, const Duration(minutes: 5, seconds: 10), reason: 'a tap seeks 10 s');
    player.playTo(const Duration(minutes: 5, seconds: 10));
    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(player.seeks.last, const Duration(minutes: 5), reason: '← goes back 10 s');
    player.playTo(const Duration(minutes: 5));
    await pass(tester, const Duration(milliseconds: 500));

    final before = player.seeks.length;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight, platform: 'android');
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight, platform: 'android');
    }
    await tester.pump(const Duration(milliseconds: 50));
    expect(player.seeks.length, before, reason: 'nothing is sought while the key is held');
    expect(find.textContaining('+02:00'), findsOneWidget, reason: 'the target is shown: 10+10+10+20+20+20+30 s ahead');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight, platform: 'android');
    await pass(tester, const Duration(milliseconds: 300));
    expect(player.seeks.length, before + 1, reason: 'one seek, on release');
    expect(player.seeks.last, const Duration(minutes: 7));
    await leave(tester);
  });

  testWidgets('player: ↑ opens the episodes on the one playing, ↓ the bar, the menu key the settings; BACK closes each', (tester) async {
    await openPlayer(tester);

    await key(tester, LogicalKeyboardKey.arrowUp);
    expect(find.byKey(const Key('tv-episode-0')), findsOneWidget, reason: '↑ opens the episode list');
    expect(focusIsIn(find.byKey(const Key('tv-episode-0'))), isTrue, reason: 'the episode playing has the focus');
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(focusIsIn(find.byKey(const Key('tv-episode-1'))), isTrue);
    await key(tester, LogicalKeyboardKey.goBack);
    expect(find.byKey(const Key('tv-episode-0')), findsNothing, reason: 'BACK closes the list');
    expect(find.text('片名 · 第1集'), findsOneWidget, reason: 'still in the player');

    await key(tester, LogicalKeyboardKey.contextMenu);
    expect(find.text('倍速'), findsOneWidget, reason: 'the menu key opens the settings');
    expect(focusIsIn(find.byKey(const Key('tv-speed-1.0'))), isTrue, reason: 'on the current speed');
    await key(tester, LogicalKeyboardKey.arrowRight);
    await key(tester, LogicalKeyboardKey.select);
    expect(player.state.rate, 1.25);
    // ↓ walks down the panel (the speeds take two rows) to the lines.
    bool onLine() => focusIsIn(find.byKey(const Key('tv-set-line-0'))) || focusIsIn(find.byKey(const Key('tv-set-line-1')));
    for (var i = 0; i < 3 && !onLine(); i++) {
      await key(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(onLine(), isTrue, reason: '↓ reaches the lines');
    await key(tester, LogicalKeyboardKey.arrowRight);
    await key(tester, LogicalKeyboardKey.select);
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened.last, 'https://cdn.test/b/1.m3u8', reason: 'OK on 线路二 plays the same episode there');
    expect(find.text('倍速'), findsNothing, reason: 'picking a line closes the settings');
    await key(tester, LogicalKeyboardKey.contextMenu);
    await key(tester, LogicalKeyboardKey.goBack);
    expect(find.text('倍速'), findsNothing, reason: 'BACK closes the settings');

    // ↓: the bar, with the focus on play / pause; the D-pad walks its buttons.
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(focused().context!.findAncestorWidgetOfExactType<IconButton>()?.tooltip, '播放 / 暂停 (空格)');
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(focused().context!.findAncestorWidgetOfExactType<IconButton>()?.tooltip, '下一集 (N)');
    await key(tester, LogicalKeyboardKey.select);
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened.last, 'https://cdn.test/b/2.m3u8', reason: 'OK on 下一集 plays it');

    // The channel keys change the episode too.
    await key(tester, LogicalKeyboardKey.channelDown);
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened.last, 'https://cdn.test/b/3.m3u8');
    await key(tester, LogicalKeyboardKey.mediaTrackPrevious);
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened.last, 'https://cdn.test/b/2.m3u8');

    // BACK: the bar first (it is up after the change of episode), then out of the player.
    await key(tester, LogicalKeyboardKey.goBack);
    expect(find.text('片名 · 第2集'), findsOneWidget, reason: 'the first BACK only hides the bar');
    await key(tester, LogicalKeyboardKey.goBack);
    await pass(tester, const Duration(seconds: 1));
    expect(find.text('片名 · 第2集'), findsNothing, reason: 'the second leaves the player');
    expect(find.byKey(const Key('detail-play')), findsOneWidget, reason: 'back on the detail page');
    await leave(tester);
  });

  testWidgets('player: the focus stays in the panel or the bar that is open, at every edge', (tester) async {
    await openPlayer(tester);
    const left = LogicalKeyboardKey.arrowLeft, right = LogicalKeyboardKey.arrowRight;
    const up = LogicalKeyboardKey.arrowUp, down = LogicalKeyboardKey.arrowDown;
    final panel = find.byType(PlayerSidePanel);
    final seeks = player.seeks.length;

    /// Every key of [keys], each pressed past the edge: the focus never leaves the panel, nothing is sought, no
    /// second panel opens.
    Future<void> stayIn(String name, List<LogicalKeyboardKey> keys) async {
      for (final k in keys) {
        for (var i = 0; i < 8; i++) {
          await key(tester, k);
          expect(panel, findsOneWidget, reason: '$name: one panel after ${k.keyLabel} ×${i + 1}');
          expect(focusIsIn(panel), isTrue, reason: '$name: the focus is still in the panel after ${k.keyLabel} ×${i + 1}');
          expect(player.seeks.length, seeks, reason: '$name: ${k.keyLabel} does not seek behind the panel');
        }
      }
    }

    /// From the settings (menu key), ↓ to [chip] and OK.
    Future<void> fromSettings(Key chip) async {
      await key(tester, LogicalKeyboardKey.contextMenu);
      // The chips further down the panel are built as the list scrolls to them.
      bool onChip() => find.byKey(chip).evaluate().isNotEmpty && focusIsIn(find.byKey(chip));
      for (var i = 0; i < 12 && !onChip(); i++) {
        await key(tester, down);
      }
      expect(onChip(), isTrue, reason: '↓ reaches $chip');
      await key(tester, LogicalKeyboardKey.select);
      expect(panel, findsOneWidget, reason: 'the panel from the settings replaces them');
      expect(focusIsIn(panel), isTrue, reason: 'and takes the focus');
    }

    await key(tester, LogicalKeyboardKey.contextMenu);
    await stayIn('设置', [left, down, right, up]);
    await key(tester, LogicalKeyboardKey.goBack);
    expect(panel, findsNothing);

    await key(tester, up);
    await stayIn('选集', [left, down, right, up]);
    await key(tester, LogicalKeyboardKey.goBack);

    await fromSettings(const Key('tv-set-tracks'));
    await stayIn('字幕与音轨', [down, left, right, up]);
    await key(tester, LogicalKeyboardKey.goBack);

    await fromSettings(const Key('tv-set-danmaku'));
    await stayIn('弹幕设置', [down, left, right, up]);
    await key(tester, LogicalKeyboardKey.goBack);

    await fromSettings(const Key('tv-set-info'));
    expect(find.byKey(const Key('play-info')), findsOneWidget, reason: '播放信息 is in the settings of the remote');
    await stayIn('播放信息', [down, left, right, up]);
    await key(tester, LogicalKeyboardKey.goBack);
    expect(panel, findsNothing);
    expect(focused(), isNot(isA<FocusScopeNode>()), reason: 'BACK gives the focus back to the picture');

    // The bar (↓): its ends stop the D-pad; the picture does not seek under it.
    await key(tester, down);
    bool onButton() {
      var found = false;
      focused().context!.visitAncestorElements((e) {
        found = e.widget is IconButton || e.widget is ButtonStyleButton;
        return !found;
      });
      return found;
    }
    for (final k in [right, left]) {
      for (var i = 0; i < 12; i++) {
        await key(tester, k);
        expect(onButton(), isTrue, reason: '${k.keyLabel} ×${i + 1} stays on a button of the bar');
      }
    }
    expect(player.seeks.length, seeks, reason: 'walking the bar does not seek');

    // The bar fades out under the focus: the picture has the keys again, ↑ opens one panel with the focus in it.
    await pass(tester, const Duration(seconds: 5));
    await key(tester, right);
    expect(player.seeks.length, seeks + 1, reason: '→ seeks once the bar is gone');
    await key(tester, up);
    expect(panel, findsOneWidget);
    expect(focusIsIn(find.byKey(const Key('tv-episode-0'))), isTrue);
    await leave(tester);
  });

  testWidgets('live: opens full screen; ↑/↓ change channel, OK the list, menu the guide, number keys, BACK out step by step', (tester) async {
    await pumpTv(tester);
    await key(tester, LogicalKeyboardKey.arrowDown);
    await key(tester, LogicalKeyboardKey.select);
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened, ['https://cdn.test/live/a.m3u8'], reason: 'the first channel plays');
    expect(find.byKey(const Key('tv-rail-1')).hitTestable(), findsNothing, reason: 'full screen: no rail');

    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(player.opened.last, 'https://cdn.test/live/b.m3u8', reason: '↓ next channel');
    expect(find.text('普通台'), findsOneWidget, reason: 'its name shows');
    await key(tester, LogicalKeyboardKey.channelUp);
    expect(player.opened.last, 'https://cdn.test/live/a.m3u8', reason: 'channel up: back');

    await key(tester, LogicalKeyboardKey.select);
    expect(find.byKey(const Key('tv-channel-0-0')), findsOneWidget, reason: 'OK opens the channel list');
    expect(focusIsIn(find.byKey(const Key('tv-channel-0-0'))), isTrue, reason: 'on the channel playing');
    await key(tester, LogicalKeyboardKey.arrowDown);
    await key(tester, LogicalKeyboardKey.select);
    expect(player.opened.last, 'https://cdn.test/live/b.m3u8', reason: 'OK on a channel plays it');
    expect(find.byKey(const Key('tv-channel-0-0')), findsNothing, reason: 'and closes the list');

    // Number keys: 1 → the first channel, after a moment.
    await key(tester, LogicalKeyboardKey.digit1);
    expect(find.text('1'), findsWidgets);
    await pass(tester, const Duration(seconds: 2));
    expect(player.opened.last, 'https://cdn.test/live/a.m3u8', reason: 'channel 1');

    // The guide of 回看台 (catch-up): an ended programme plays back.
    await key(tester, LogicalKeyboardKey.contextMenu);
    expect(find.textContaining('节目单'), findsWidgets, reason: 'the menu key opens the guide');
    expect(focused().context!.findAncestorWidgetOfExactType<TvFocusable>(), isNotNull, reason: 'a programme has the focus');
    await key(tester, LogicalKeyboardKey.arrowUp);
    await key(tester, LogicalKeyboardKey.select);
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened.last, startsWith('https://cdn.test/catchup/a.m3u8'), reason: 'OK on an ended programme plays it back');
    expect(find.text('回看'), findsWidgets);

    // BACK: out of full screen to the lists, then the rail.
    await key(tester, LogicalKeyboardKey.goBack);
    expect(find.byKey(const Key('tv-rail-1')).hitTestable(), findsOneWidget, reason: 'the first BACK leaves full screen');
    expect(focused().context!.findAncestorWidgetOfExactType<TvFocusable>(), isNotNull, reason: 'a channel in the list has the focus');
    await tester.binding.handlePopRoute();
    await pass(tester, const Duration(milliseconds: 500));
    expect(focusIsIn(find.byKey(const Key('tv-rail-1'))), isTrue, reason: 'the second goes to 直播 in the rail');
    await leave(tester);
  });

  testWidgets('desktop keys in the player are unchanged: ↑/↓ volume, Enter pauses', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    player = FakePlayer();
    final engine = fakeEngine(hasConfig: true);
    await tester.pumpWidget(
      DeviceFormScope.fixed(
        DeviceForm.desktop,
        child: TvboxApp(
          state: AppState(
            clientFactory: (url) => EngineClient(url, httpClient: engine),
            playerBackend: () => player.backend(),
          ),
        ),
      ),
    );
    await pass(tester, const Duration(seconds: 1));
    await tester.tap(find.text('推荐片'));
    await pass(tester, const Duration(seconds: 1));
    await tester.tap(find.textContaining('播放').first);
    await pass(tester, const Duration(seconds: 1));
    final volume = player.state.volume;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await pass(tester, const Duration(milliseconds: 300));
    expect(player.state.volume, volume - 5, reason: '↓ is the volume on a desktop, not a panel');
    expect(find.byKey(const Key('tv-episode-0')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await pass(tester, const Duration(milliseconds: 300));
    expect(find.text('倍速'), findsOneWidget, reason: 'the speed button of the bar, no TV settings panel');
    expect(find.byKey(const Key('tv-settings-button')), findsNothing);
    await leave(tester);
  });
}
