import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/pages/danmaku_panel.dart';
import 'package:tvbox_client/pages/osd_clock_settings.dart';
import 'package:tvbox_client/pages/player_dial.dart';
import 'package:tvbox_client/pages/player_tracks.dart';
import 'package:tvbox_client/settings.dart';
import 'package:tvbox_client/ui/device_form.dart';
import 'package:tvbox_client/ui/tv/tv_focus.dart';
import 'package:tvbox_client/ui/user_mode.dart';

import 'fake_engine.dart';
import 'fake_player.dart';

/// The player and live TV with a remote control: keys as Android sends them (DPAD_CENTER is `select`, BACK
/// `goBack`, MENU `contextMenu`), the player is [FakePlayer]. The player's keys are the table of
/// docs/design/ux-review.md 2.2: nothing over the picture, the dial, a panel next to the dial.
void main() {
  late FakePlayer player;
  const left = LogicalKeyboardKey.arrowLeft, right = LogicalKeyboardKey.arrowRight;
  const up = LogicalKeyboardKey.arrowUp, down = LogicalKeyboardKey.arrowDown;
  const ok = LogicalKeyboardKey.select, back = LogicalKeyboardKey.goBack, menu = LogicalKeyboardKey.contextMenu;

  setUp(TvDialMemory.reset);

  Future<void> pass(WidgetTester tester, Duration time) async {
    for (var t = Duration.zero; t < time; t += const Duration(milliseconds: 100)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// A key as Android sends it. The test's key simulator has no physical key named like BACK's logical one, so BACK
  /// borrows Escape's (the app only looks at the logical key, `goBack`).
  Future<void> key(WidgetTester tester, LogicalKeyboardKey k, {int times = 1}) async {
    for (var i = 0; i < times; i++) {
      await tester.sendKeyEvent(k, platform: 'android', physicalKey: k == back ? PhysicalKeyboardKey.escape : null);
      await pass(tester, const Duration(milliseconds: 300));
    }
  }

  /// OK held down long enough for the remote to repeat it.
  Future<void> holdOk(WidgetTester tester) async {
    await tester.sendKeyDownEvent(ok, platform: 'android');
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyRepeatEvent(ok, platform: 'android');
    }
    await tester.sendKeyUpEvent(ok, platform: 'android');
    await pass(tester, const Duration(milliseconds: 300));
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

  final dial = find.byKey(const Key('tv-dial'));
  final panel = find.byType(TvDialPanel);
  Finder panelOf(String name) => find.byKey(Key('tv-panel-$name'));
  bool onDial() => focused().debugLabel == 'tv-dial';

  Future<SettingsStore> pumpTv(WidgetTester tester, {List<Map<String, Object>>? lines, Set<String> deadLines = const {}, SettingsStore? settings}) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    player = FakePlayer();
    final store = settings ?? MemorySettings();
    final engine = fakeEngine(hasConfig: true, lines: lines, deadLines: deadLines);
    await tester.pumpWidget(
      DeviceFormScope.fixed(
        DeviceForm.tv,
        child: TvboxApp(
          state: AppState(
            clientFactory: (url) => EngineClient(url, httpClient: engine),
            settings: store,
            playerBackend: () => player.backend(),
          ),
        ),
      ),
    );
    await pass(tester, const Duration(seconds: 1));
    return store;
  }

  /// 首页 → the first poster → 播放, all with the remote. [ready] runs before 播放 (what the stream will hold).
  Future<SettingsStore> openPlayer(WidgetTester tester, {SettingsStore? settings, Set<String> deadLines = const {}, void Function()? ready}) async {
    final store = await pumpTv(tester, lines: [fakeLine('线路一', 'a', count: 4), fakeLine('线路二', 'b', count: 4)], deadLines: deadLines, settings: settings);
    ready?.call();
    await key(tester, right);
    await key(tester, ok);
    await pass(tester, const Duration(seconds: 1));
    await key(tester, ok);
    await pass(tester, const Duration(seconds: 1));
    if (deadLines.isEmpty) expect(player.opened, ['https://cdn.test/a/1.m3u8'], reason: 'the first episode plays');
    player.playTo(const Duration(minutes: 5));
    await pass(tester, const Duration(milliseconds: 500));
    return store;
  }

  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  TvDialRow row(WidgetTester tester, DialEntry e) => tester.widget<TvDialRow>(find.byKey(Key('tv-dial-${e.name}')));

  /// What an entry of the dial shows on its right.
  String valueOf(WidgetTester tester, DialEntry e) =>
      tester.widgetList<Text>(find.descendant(of: find.byKey(Key('tv-dial-${e.name}-value')), matching: find.byType(Text))).map((t) => t.data).join();

  /// ↑ / ↓ on the dial until [e] is lit.
  Future<void> dialTo(WidgetTester tester, DialEntry e) async {
    for (var i = 0; i < 8 && !row(tester, e).selected; i++) {
      await key(tester, TvDialMemory.last.index < e.index ? down : up);
    }
    expect(row(tester, e).selected, isTrue, reason: 'the dial reaches ${e.label}');
  }

  // ---------------------------------------------------------------- nothing over the picture

  testWidgets('player: OK pauses and shows the info bar, which takes no focus; ← / → seek; held, → runs ahead and seeks once', (tester) async {
    await openPlayer(tester);
    expect(player.state.playing, isTrue);
    await key(tester, ok);
    expect(player.state.playing, isFalse, reason: 'OK pauses');

    final bar = find.byKey(const Key('tv-info-bar'));
    expect(bar, findsOneWidget, reason: 'and shows the info bar');
    expect(find.descendant(of: bar, matching: find.text('片名 · 第1集')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('tv-caption'))).data, '线路一 · 弹幕开', reason: 'the line, the picture, subtitles and danmaku');
    expect(find.byKey(const Key('tv-clock')), findsOneWidget, reason: 'the time of day comes with it');
    expect(tester.widget<Text>(find.byKey(const Key('tv-remaining'))).data, startsWith('还剩 35 分钟 · 约 '));
    expect(tester.widget<Text>(find.byKey(const Key('tv-time'))).textSpan!.toPlainText(), '05:00 / 40:00');
    expect(find.byKey(const Key('tv-paused')), findsOneWidget);
    expect(find.descendant(of: bar, matching: find.text('继续')), findsOneWidget, reason: 'the keys: OK 继续 …');
    expect(find.descendant(of: bar, matching: find.text('按两次退出')), findsOneWidget);
    expect(focusIsIn(bar), isFalse, reason: 'nothing in the info bar takes the focus');
    expect(find.descendant(of: bar, matching: find.byType(TvFocusable)), findsNothing);

    await key(tester, ok);
    expect(player.state.playing, isTrue, reason: 'OK again plays');

    await key(tester, right);
    expect(player.seeks.last, const Duration(minutes: 5, seconds: 10), reason: 'a tap seeks 10 s');
    player.playTo(const Duration(minutes: 5, seconds: 10));
    await key(tester, left);
    expect(player.seeks.last, const Duration(minutes: 5), reason: '← goes back 10 s');
    player.playTo(const Duration(minutes: 5));
    await pass(tester, const Duration(milliseconds: 500));

    final before = player.seeks.length;
    await tester.sendKeyDownEvent(right, platform: 'android');
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.sendKeyRepeatEvent(right, platform: 'android');
    }
    await tester.pump(const Duration(milliseconds: 50));
    expect(player.seeks.length, before, reason: 'nothing is sought while the key is held');
    expect(find.textContaining('+02:00'), findsOneWidget, reason: 'the target is shown: 10+10+10+20+20+20+30 s ahead');
    await tester.sendKeyUpEvent(right, platform: 'android');
    await pass(tester, const Duration(milliseconds: 300));
    expect(player.seeks.length, before + 1, reason: 'one seek, on release');
    expect(player.seeks.last, const Duration(minutes: 7));
    await leave(tester);
  });

  testWidgets('player: BACK on the picture says how to leave; a second BACK within two seconds leaves', (tester) async {
    await openPlayer(tester);
    await key(tester, back);
    expect(find.text('再按一次退出'), findsOneWidget);
    expect(find.text('片名 · 第1集'), findsOneWidget, reason: 'still in the player');
    await pass(tester, const Duration(milliseconds: 2500));
    expect(find.text('再按一次退出'), findsNothing);
    await key(tester, back);
    expect(find.text('片名 · 第1集'), findsOneWidget, reason: 'too late: the first press counts again');
    expect(find.text('再按一次退出'), findsOneWidget);
    await key(tester, back);
    await pass(tester, const Duration(seconds: 1));
    expect(find.text('片名 · 第1集'), findsNothing, reason: 'the second press within two seconds leaves');
    expect(find.byKey(const Key('detail-play')), findsOneWidget, reason: 'back on the detail page');
    await leave(tester);
  });

  testWidgets('player: channel and track keys change the episode, also with the dial out', (tester) async {
    await openPlayer(tester);
    await key(tester, LogicalKeyboardKey.channelDown);
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened.last, 'https://cdn.test/a/2.m3u8');
    await key(tester, up);
    await key(tester, LogicalKeyboardKey.mediaTrackNext);
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened.last, 'https://cdn.test/a/3.m3u8');
    expect(valueOf(tester, DialEntry.episodes), '第 3 集 · 共 4 集', reason: 'the dial follows');
    await key(tester, LogicalKeyboardKey.mediaTrackPrevious);
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened.last, 'https://cdn.test/a/2.m3u8');
    final seeks = player.seeks.length;
    await key(tester, LogicalKeyboardKey.mediaFastForward);
    expect(player.seeks.length, seeks, reason: 'fast-forward does not seek behind the dial');
    await key(tester, back);
    await key(tester, LogicalKeyboardKey.mediaFastForward);
    expect(player.seeks.length, seeks + 1, reason: 'on the picture it does');
    await leave(tester);
  });

  // ---------------------------------------------------------------- the dial

  testWidgets('player: ↑ or ↓ call up the dial on the entry used last; ↑ / ↓ walk it and stop at the ends; BACK puts it away', (tester) async {
    await openPlayer(tester);
    final seeks = player.seeks.length;
    await key(tester, up);
    expect(dial, findsOneWidget, reason: '↑ calls up the dial');
    expect(find.byType(TvDialRow), findsNWidgets(7));
    expect(row(tester, DialEntry.episodes).selected, isTrue, reason: 'on 选集 the first time');
    expect(onDial(), isTrue, reason: 'the dial has the focus');
    expect(find.text('片名 · 第1集'), findsOneWidget, reason: 'the title stays in sight');
    expect(find.byKey(const Key('tv-clock')), findsOneWidget, reason: 'and the time');

    expect(valueOf(tester, DialEntry.episodes), '第 1 集 · 共 4 集');
    expect(valueOf(tester, DialEntry.lines), '线路一');
    expect(valueOf(tester, DialEntry.speed), '1.0×');
    expect(valueOf(tester, DialEntry.subtitles), '没有字幕');
    expect(valueOf(tester, DialEntry.danmaku), '开');
    expect(['很顺', '够用', '快见底了', '正在缓冲'], contains(valueOf(tester, DialEntry.info)), reason: 'how playback goes, in a word');
    expect(valueOf(tester, DialEntry.more), '画面、音轨、屏显时间');

    for (var i = 0; i < 3; i++) {
      await key(tester, up);
      expect(row(tester, DialEntry.episodes).selected, isTrue, reason: '↑ ×${i + 1} at the top stays there');
    }
    for (var i = 1; i < 10; i++) {
      await key(tester, down);
      final at = DialEntry.values[i.clamp(0, 6)];
      expect(row(tester, at).selected, isTrue, reason: '↓ ×$i lights ${at.label}');
      expect(onDial(), isTrue);
    }
    expect(player.seeks.length, seeks, reason: 'walking the dial does not seek');
    expect(panel, findsNothing, reason: 'nor open anything');

    await key(tester, back);
    expect(dial, findsNothing, reason: 'BACK puts the dial away');
    expect(find.text('片名 · 第1集'), findsOneWidget, reason: 'still in the player');
    expect(find.text('再按一次退出'), findsNothing, reason: 'that BACK was the dial\'s');
    await key(tester, down);
    expect(row(tester, DialEntry.more).selected, isTrue, reason: '↓ brings it back on the entry used last');
    await key(tester, back);
    await key(tester, right);
    expect(player.seeks.length, seeks + 1, reason: 'with the dial away ← / → seek again');
    await leave(tester);
  });

  testWidgets('player: ← / → on the dial change the lit entry right there', (tester) async {
    await openPlayer(
      tester,
      ready: () => player.subtitleTracksInStream = const [SubtitleTrack('1', '中文', 'chi'), SubtitleTrack('2', 'English', 'eng')],
    );
    await key(tester, up);

    // 选集: the next and the previous episode.
    await key(tester, right);
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened.last, 'https://cdn.test/a/2.m3u8', reason: '→ on 选集 plays the next episode');
    expect(valueOf(tester, DialEntry.episodes), '第 2 集 · 共 4 集');
    await key(tester, left);
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened.last, 'https://cdn.test/a/1.m3u8');
    await key(tester, left);
    expect(find.text('已经是第一集'), findsOneWidget, reason: 'and says so at the first');
    expect(player.opened.where((u) => u == 'https://cdn.test/a/1.m3u8'), hasLength(2), reason: 'nothing before the first');

    // 线路: the next line, chosen by hand.
    await dialTo(tester, DialEntry.lines);
    player.playTo(const Duration(minutes: 5));
    await key(tester, right);
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened.last, 'https://cdn.test/b/1.m3u8', reason: '→ on 线路 changes to 线路二');
    expect(valueOf(tester, DialEntry.lines), '线路二');
    await key(tester, left);
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened.last, 'https://cdn.test/a/1.m3u8');

    // 倍速: one step at a time. (A change of line carries on where it was, which is a seek of its own; from here on
    // nothing seeks.)
    final seeks = player.seeks.length;
    await dialTo(tester, DialEntry.speed);
    await key(tester, right);
    expect(player.state.rate, 1.25);
    expect(valueOf(tester, DialEntry.speed), '1.25×');
    await key(tester, left, times: 2);
    expect(player.state.rate, 0.75);
    await key(tester, right);
    expect(player.state.rate, 1.0);

    // 字幕: round the subtitles and 关.
    await dialTo(tester, DialEntry.subtitles);
    expect(valueOf(tester, DialEntry.subtitles), '关');
    await key(tester, right);
    expect(player.subtitleChoices.last.id, '1');
    expect(valueOf(tester, DialEntry.subtitles), '中文');
    await key(tester, right);
    expect(player.subtitleChoices.last.id, '2');
    expect(valueOf(tester, DialEntry.subtitles), 'English（英语）');
    await key(tester, right);
    expect(player.subtitleChoices.last.id, 'no', reason: 'after the last one, off');
    expect(valueOf(tester, DialEntry.subtitles), '关');
    await key(tester, left);
    expect(player.subtitleChoices.last.id, '2', reason: '← goes round the other way');

    // 弹幕: on and off.
    await dialTo(tester, DialEntry.danmaku);
    await key(tester, right);
    expect(valueOf(tester, DialEntry.danmaku), '关');
    await key(tester, left);
    expect(valueOf(tester, DialEntry.danmaku), '开');

    // 信息 and 更多设置 have nothing to change.
    final opened = player.opened.length;
    for (final e in [DialEntry.info, DialEntry.more]) {
      await dialTo(tester, e);
      await key(tester, left);
      await key(tester, right);
      expect(panel, findsNothing, reason: '← / → on ${e.label} open nothing');
    }
    expect(player.opened.length, opened);
    expect(player.seeks.length, seeks, reason: 'nothing on the dial seeks');
    await leave(tester);
  });

  // ---------------------------------------------------------------- panels next to the dial

  testWidgets('player: OK opens the entry\'s panel right next to the dial; ← at its left edge and BACK return to the dial on that entry', (tester) async {
    await openPlayer(tester);
    final seeks = player.seeks.length;
    await key(tester, up);
    final dialRect = tester.getRect(dial);
    for (final e in DialEntry.values) {
      await dialTo(tester, e);
      await key(tester, ok);
      final opened = panelOf(e.name);
      expect(opened, findsOneWidget, reason: 'OK on ${e.label} opens its panel');
      expect(panel, findsOneWidget, reason: 'one panel');
      expect(dial, findsOneWidget, reason: '${e.label}: the dial stays in sight');
      expect(row(tester, e).selected && row(tester, e).open, isTrue, reason: '${e.label} stays lit');
      for (final other in DialEntry.values.where((o) => o != e)) {
        expect(row(tester, other).selected, isFalse);
      }
      final rect = tester.getRect(opened);
      expect(rect.left, greaterThanOrEqualTo(dialRect.right), reason: '${e.label}: right of the dial');
      expect(rect.left - dialRect.right, lessThan(30), reason: '${e.label}: next to it');
      expect(rect.right, lessThan(960 - 150), reason: '${e.label}: not against the right edge');
      expect(focusIsIn(opened), isTrue, reason: 'the ${e.label} panel takes the focus');

      for (var i = 0; i < 6 && panel.evaluate().isNotEmpty; i++) {
        await key(tester, left);
        if (panel.evaluate().isNotEmpty) expect(focusIsIn(opened), isTrue, reason: '${e.label}: ← walks the panel first');
      }
      expect(panel, findsNothing, reason: '← at the left edge of ${e.label} goes back to the dial');
      expect(row(tester, e).selected && !row(tester, e).open, isTrue, reason: 'on ${e.label}');
      expect(onDial(), isTrue, reason: 'the dial has the focus again');

      await key(tester, ok);
      expect(opened, findsOneWidget);
      await key(tester, back);
      expect(panel, findsNothing, reason: 'BACK goes back to the dial from ${e.label}');
      expect(dial, findsOneWidget);
      expect(row(tester, e).selected, isTrue);
      expect(onDial(), isTrue);
    }
    expect(player.seeks.length, seeks, reason: 'nothing seeks behind the dial or a panel');
    await key(tester, back);
    expect(dial, findsNothing);
    await leave(tester);
  });

  testWidgets('player: what each panel holds, and where its focus starts', (tester) async {
    await openPlayer(tester);
    await key(tester, up);

    await key(tester, ok);
    expect(focusIsIn(find.byKey(const Key('tv-episode-0'))), isTrue, reason: '选集: on the episode playing');
    expect(find.byKey(const Key('tv-line-1')), findsOneWidget, reason: 'with the lines on top');
    await key(tester, right);
    expect(focusIsIn(find.byKey(const Key('tv-episode-1'))), isTrue);
    await key(tester, ok);
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened.last, 'https://cdn.test/a/2.m3u8', reason: 'OK on an episode plays it');
    expect(dial, findsNothing, reason: 'and puts the dial away');

    await key(tester, up);
    await dialTo(tester, DialEntry.speed);
    await key(tester, ok);
    expect(focusIsIn(find.byKey(const Key('tv-speed-1.0'))), isTrue, reason: '倍速: on the current speed');
    await key(tester, left);
    expect(focusIsIn(find.byKey(const Key('tv-speed-0.75'))), isTrue, reason: '← walks the speeds');
    await key(tester, ok);
    expect(player.state.rate, 0.75);
    expect(panelOf('speed'), findsOneWidget, reason: 'the speed panel stays open');
    await key(tester, back);
    expect(valueOf(tester, DialEntry.speed), '0.75×');

    for (final (e, inside) in [(DialEntry.subtitles, TracksPanel), (DialEntry.danmaku, DanmakuPanel)]) {
      await dialTo(tester, e);
      await key(tester, ok);
      expect(find.descendant(of: panelOf(e.name), matching: find.byType(inside)), findsOneWidget, reason: '${e.label}: $inside');
      await key(tester, back);
    }

    await dialTo(tester, DialEntry.info);
    await key(tester, ok);
    expect(find.descendant(of: panelOf('info'), matching: find.byKey(const Key('play-info'))), findsOneWidget, reason: '信息: 播放信息');
    expect(focusIsIn(find.byKey(const Key('play-info-lines'))), isTrue);
    await key(tester, ok);
    expect(panelOf('lines'), findsOneWidget, reason: '换线路 in 播放信息 leads to the dial\'s 线路');
    expect(row(tester, DialEntry.lines).open, isTrue);
    await key(tester, back);

    await dialTo(tester, DialEntry.more);
    await key(tester, ok);
    for (final chip in ['tv-aspect--1', 'tv-audio-1', 'tv-clock-off', 'tv-clock-withOsd', 'tv-clock-always']) {
      expect(find.byKey(Key(chip)), findsOneWidget, reason: '更多设置: $chip');
    }
    expect(find.byKey(const Key('tv-more-chain')), findsNothing, reason: '片源从哪来 only in developer mode');
    expect(focusIsIn(find.byKey(const Key('tv-aspect--1'))), isTrue, reason: 'on the first choice');
    await key(tester, right);
    await key(tester, ok);
    expect(player.mpv['video-aspect-override'], '16:9', reason: 'the shape of the picture goes to libmpv');
    await leave(tester);
  });

  testWidgets('player: 线路 lists every line, the one playing marked; OK changes line by hand and puts the dial away', (tester) async {
    await openPlayer(tester, deadLines: {'线路一'});
    await pass(tester, const Duration(seconds: 3));
    expect(player.opened.last, 'https://cdn.test/b/1.m3u8', reason: '线路一 does not resolve: 线路二 plays');
    await key(tester, up);
    await dialTo(tester, DialEntry.lines);
    await key(tester, ok);
    String status(int i) => tester.widget<Text>(find.byKey(Key('tv-panel-line-$i-status'))).data!;
    expect(status(1), '正在播');
    expect(focusIsIn(find.byKey(const Key('tv-panel-line-1'))), isTrue, reason: 'on the line playing');
    expect(status(0), '刚才打不开', reason: 'what this round found out about 线路一');
    await key(tester, up);
    expect(focusIsIn(find.byKey(const Key('tv-panel-line-0'))), isTrue);
    await key(tester, ok);
    await pass(tester, const Duration(milliseconds: 500));
    expect(dial, findsNothing, reason: 'the dial goes away to watch');
    expect(find.textContaining('不会自动换线路'), findsOneWidget, reason: 'a line chosen by hand that does not play is only reported');
    await leave(tester);
  });

  testWidgets('player: the focus stays in the layer that is open, at every edge, and nothing seeks behind it', (tester) async {
    await openPlayer(tester);
    final seeks = player.seeks.length;

    await key(tester, down);
    for (final k in [up, down, up]) {
      for (var i = 0; i < 8; i++) {
        await key(tester, k);
        expect(onDial(), isTrue, reason: 'dial: the focus stays after ${k.keyLabel} ×${i + 1}');
        expect(panel, findsNothing);
        expect(player.seeks.length, seeks);
      }
    }

    /// Every key of [keys], each pressed past the edge: the focus never leaves the panel, nothing is sought, no
    /// second panel opens. (← walks back to the dial: the test above.)
    for (final e in DialEntry.values) {
      await dialTo(tester, e);
      await key(tester, ok);
      final opened = panelOf(e.name);
      for (final k in [down, right, up, down]) {
        for (var i = 0; i < 8; i++) {
          await key(tester, k);
          expect(panel, findsOneWidget, reason: '${e.label}: one panel after ${k.keyLabel} ×${i + 1}');
          expect(opened, findsOneWidget, reason: '${e.label}: the same panel after ${k.keyLabel} ×${i + 1}');
          expect(focusIsIn(opened), isTrue, reason: '${e.label}: the focus is still in the panel after ${k.keyLabel} ×${i + 1}');
          expect(player.seeks.length, seeks, reason: '${e.label}: ${k.keyLabel} does not seek behind the panel');
        }
      }
      await key(tester, back);
      expect(onDial(), isTrue, reason: 'BACK from ${e.label}: the dial');
    }
    await key(tester, back);
    expect(dial, findsNothing);
    expect(focused(), isNot(isA<FocusScopeNode>()), reason: 'the picture has the focus again');
    await leave(tester);
  });

  testWidgets('player: holding OK or the menu key opens 更多设置 next to the dial, from the picture and from the dial', (tester) async {
    await openPlayer(tester);
    await holdOk(tester);
    expect(panelOf('more'), findsOneWidget, reason: 'held, OK opens 更多设置');
    expect(dial, findsOneWidget);
    expect(player.state.playing, isTrue, reason: 'and does not pause');
    expect(focusIsIn(panelOf('more')), isTrue);
    expect(player.mpv['video-aspect-override'], isNull, reason: 'its repeats do not press what the panel focused');
    await key(tester, back);
    expect(row(tester, DialEntry.more).selected, isTrue, reason: 'BACK: the dial, on 更多设置');
    await key(tester, back);
    expect(dial, findsNothing);

    await key(tester, menu);
    expect(panelOf('more'), findsOneWidget, reason: 'the menu key opens it too');
    await key(tester, menu);
    expect(panelOf('more'), findsOneWidget, reason: 'and again it stays');
    await key(tester, back);
    await dialTo(tester, DialEntry.episodes);
    await holdOk(tester);
    expect(panelOf('more'), findsOneWidget, reason: 'held on the dial, OK opens 更多设置, not the lit entry');
    await key(tester, back);
    await dialTo(tester, DialEntry.speed);
    await key(tester, menu);
    expect(panelOf('more'), findsOneWidget, reason: 'the menu key on the dial');
    expect(row(tester, DialEntry.more).open, isTrue);
    await leave(tester);
  });

  testWidgets('player: developer mode has the statistics and 片源从哪来 in 更多设置, next to the dial as well', (tester) async {
    final store = MemorySettings();
    await store.setString(UserModeController.key, UserMode.developer.name);
    await openPlayer(tester, settings: store);
    await key(tester, menu);
    bool onChip(String k) => find.byKey(Key(k)).evaluate().isNotEmpty && focusIsIn(find.byKey(Key(k)));
    for (var i = 0; i < 12 && !onChip('tv-more-stats'); i++) {
      await key(tester, down);
    }
    expect(onChip('tv-more-stats'), isTrue);
    await key(tester, ok);
    expect(find.byKey(const Key('player-stats')), findsOneWidget, reason: '播放统计 over the picture');
    await key(tester, right);
    await key(tester, ok);
    expect(panelOf('chain'), findsOneWidget, reason: '片源从哪来 opens in its place');
    expect(find.byKey(const Key('player-chain')), findsOneWidget);
    expect(row(tester, DialEntry.more).open, isTrue, reason: 'the dial keeps 更多设置 lit');
    await key(tester, back);
    expect(panel, findsNothing);
    expect(row(tester, DialEntry.more).selected, isTrue);
    await leave(tester);
  });

  // ---------------------------------------------------------------- 屏显时间

  test('屏显时间 is kept as off / osd / always (what the web console reads and writes), osd when unset', () async {
    final store = MemorySettings();
    expect(OsdClock.read(store), OsdClock.withOsd);
    for (final (clock, text) in [(OsdClock.off, 'off'), (OsdClock.withOsd, 'osd'), (OsdClock.always, 'always')]) {
      await clock.save(store);
      expect(store.getString('player.osdClock'), text);
      expect(OsdClock.read(store), clock);
    }
    await store.setString('player.osdClock', 'something else');
    expect(OsdClock.read(store), OsdClock.withOsd);
  });

  testWidgets('player: 屏显时间 in 更多设置: 一直显示 keeps the time in a corner, 关 takes it off', (tester) async {
    final store = await openPlayer(tester);
    await key(tester, menu);
    /// ↓ to the row of 屏显时间, along it to [clock], OK.
    Future<void> choose(OsdClock clock) async {
      int at() => OsdClock.values.indexWhere((c) => focusIsIn(find.byKey(Key('tv-clock-${c.name}'))));
      for (var i = 0; i < 8 && at() < 0; i++) {
        await key(tester, down);
      }
      expect(at(), isNonNegative, reason: '↓ reaches 屏显时间');
      for (var i = 0; i < 4 && at() != clock.index; i++) {
        await key(tester, at() < clock.index ? right : left);
      }
      expect(at(), clock.index);
      await key(tester, ok);
    }

    await choose(OsdClock.always);
    expect(store.getString(OsdClock.key), 'always', reason: 'kept on this device');
    await key(tester, back, times: 2);
    await pass(tester, const Duration(seconds: 4));
    expect(find.byKey(const Key('tv-corner-clock')), findsOneWidget, reason: 'with nothing over the picture, the time in a corner');
    await key(tester, ok);
    expect(find.byKey(const Key('tv-corner-clock')), findsNothing, reason: 'the info bar has its own');
    expect(find.byKey(const Key('tv-clock')), findsOneWidget);
    await key(tester, ok);

    await key(tester, menu);
    await choose(OsdClock.off);
    expect(store.getString(OsdClock.key), 'off');
    await key(tester, back, times: 2);
    await key(tester, ok);
    expect(find.byKey(const Key('tv-clock')), findsNothing, reason: '关: no time of day');
    expect(tester.widget<Text>(find.byKey(const Key('tv-remaining'))).data, '还剩 35 分钟', reason: 'how long is left still shows');
    await key(tester, ok);
    await pass(tester, const Duration(seconds: 4));
    expect(find.byKey(const Key('tv-corner-clock')), findsNothing);
    await leave(tester);
  });

  testWidgets('设置 → 播放 has 屏显时间 on a TV, and the player follows it', (tester) async {
    final store = await pumpTv(tester);
    await tester.tap(find.byKey(const Key('tv-rail-6')));
    await pass(tester, const Duration(seconds: 1));
    final list = find.byKey(const Key('settings-list'));
    await tester.dragUntilVisible(find.byKey(const Key('osd-clock')), list, const Offset(0, -200));
    await pass(tester, const Duration(milliseconds: 300));
    await tester.tap(find.descendant(of: find.byKey(const Key('osd-clock')), matching: find.text('一直显示')));
    await pass(tester, const Duration(milliseconds: 300));
    expect(store.getString(OsdClock.key), 'always');
    await leave(tester);

    await openPlayer(tester, settings: store);
    await pass(tester, const Duration(seconds: 4));
    expect(find.byKey(const Key('tv-corner-clock')), findsOneWidget, reason: 'the player reads it');
    await leave(tester);
  });

  // ---------------------------------------------------------------- live TV and the desktop

  testWidgets('live: opens full screen; ↑/↓ change channel, OK the list, menu the guide, number keys, BACK out step by step', (tester) async {
    await pumpTv(tester);
    await key(tester, down);
    await key(tester, ok);
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened, ['https://cdn.test/live/a.m3u8'], reason: 'the first channel plays');
    expect(find.byKey(const Key('tv-rail-1')).hitTestable(), findsNothing, reason: 'full screen: no rail');

    await key(tester, down);
    expect(player.opened.last, 'https://cdn.test/live/b.m3u8', reason: '↓ next channel');
    expect(find.text('普通台'), findsOneWidget, reason: 'its name shows');
    await key(tester, LogicalKeyboardKey.channelUp);
    expect(player.opened.last, 'https://cdn.test/live/a.m3u8', reason: 'channel up: back');

    await key(tester, ok);
    expect(find.byKey(const Key('tv-channel-0-0')), findsOneWidget, reason: 'OK opens the channel list');
    expect(focusIsIn(find.byKey(const Key('tv-channel-0-0'))), isTrue, reason: 'on the channel playing');
    await key(tester, down);
    await key(tester, ok);
    expect(player.opened.last, 'https://cdn.test/live/b.m3u8', reason: 'OK on a channel plays it');
    expect(find.byKey(const Key('tv-channel-0-0')), findsNothing, reason: 'and closes the list');

    // Number keys: 1 → the first channel, after a moment.
    await key(tester, LogicalKeyboardKey.digit1);
    expect(find.text('1'), findsWidgets);
    await pass(tester, const Duration(seconds: 2));
    expect(player.opened.last, 'https://cdn.test/live/a.m3u8', reason: 'channel 1');

    // The guide of 回看台 (catch-up): an ended programme plays back.
    await key(tester, menu);
    expect(find.textContaining('节目单'), findsWidgets, reason: 'the menu key opens the guide');
    expect(focused().context!.findAncestorWidgetOfExactType<TvFocusable>(), isNotNull, reason: 'a programme has the focus');
    await key(tester, up);
    await key(tester, ok);
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened.last, startsWith('https://cdn.test/catchup/a.m3u8'), reason: 'OK on an ended programme plays it back');
    expect(find.text('回看'), findsWidgets);

    // BACK: out of full screen to the lists, then the rail.
    await key(tester, back);
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
    expect(player.state.volume, volume - 5, reason: '↓ is the volume on a desktop, not the dial');
    expect(dial, findsNothing);
    await tester.sendKeyEvent(menu);
    await pass(tester, const Duration(milliseconds: 300));
    expect(find.text('倍速'), findsOneWidget, reason: 'the speed button of the bar, no 更多设置');
    expect(panel, findsNothing);
    expect(find.byKey(const Key('osd-clock')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await pass(tester, const Duration(milliseconds: 300));
    expect(player.state.playing, isFalse, reason: 'Enter pauses at once');
    await leave(tester);
  });
}
