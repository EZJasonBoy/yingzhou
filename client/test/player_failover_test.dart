import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/engine/vod_models.dart';
import 'package:tvbox_client/main.dart';

import 'fake_engine.dart';
import 'fake_player.dart';

/// The video-on-demand player changing line by itself: 推荐片 has three lines, and each test says which of them
/// work. The player is [FakePlayer]; the engine is the fake one, which notes every line it is asked to resolve.
void main() {
  late FakePlayer player;
  late List<String> resolved;
  late Set<String> deadLines;
  late Map<String, Map<String, dynamic>> saved;

  const a = 'https://cdn.test/a';
  const b = 'https://cdn.test/b';
  const c = 'https://cdn.test/c';
  final threeLines = [fakeLine('线路一', 'a'), fakeLine('线路二', 'b'), fakeLine('线路三', 'c')];

  /// Lets [time] go by, a frame every 100 ms.
  Future<void> pass(WidgetTester tester, Duration time) async {
    for (var t = Duration.zero; t < time; t += const Duration(milliseconds: 100)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Opens 推荐片 and presses the detail page's play button ("播放", or "继续播放 …" when there is history).
  /// [dead] lines do not resolve; [broken] and [silent] addresses resolve but the player gets nowhere with them.
  Future<void> play(
    WidgetTester tester, {
    List<Map<String, Object>>? lines,
    Set<String> dead = const {},
    Set<String> broken = const {},
    Set<String> silent = const {},
    List<Map<String, Object>> history = const [],
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    player = FakePlayer()
      ..broken.addAll(broken)
      ..silent.addAll(silent);
    resolved = [];
    deadLines = {...dead};
    saved = {};
    final engine = fakeEngine(hasConfig: true, history: history, lines: lines ?? threeLines, deadLines: deadLines, resolved: resolved, savedHistory: saved);
    await tester.pumpWidget(
      TvboxApp(
        state: AppState(
          clientFactory: (url) => EngineClient(url, httpClient: engine),
          playerBackend: () => player.backend(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('推荐片'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('播放').first);
    await pass(tester, const Duration(seconds: 1));
  }

  /// Leaves the player page, so its timers stop.
  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  /// Moves the mouse over the picture, which brings the controls back.
  Future<void> showControls(WidgetTester tester) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(600, 300));
    await mouse.moveTo(const Offset(620, 320));
    await tester.pump();
    await mouse.removePointer();
  }

  /// Presses a button of the player and draws the next frame. Buttons act at once: only the picture waits to see
  /// whether a click becomes a double click (0.3 s), which a button must not have to.
  Future<void> press(WidgetTester tester, Finder button) async {
    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Picks a line in the 选集 panel, the way the user changes line by hand.
  Future<void> pickLine(WidgetTester tester, String name, {bool openPanel = true}) async {
    if (openPanel) {
      await showControls(tester);
      await press(tester, find.text('选集'));
    }
    await press(tester, find.widgetWithText(ChoiceChip, name));
    await pass(tester, const Duration(seconds: 1));
  }

  /// The line named at the top right of the player.
  void expectOnLine(String name) => expect(find.text(name), findsOneWidget, reason: 'the player should be on $name');

  testWidgets('a line that does not resolve is skipped; the next one carries on from the saved position', (tester) async {
    await play(
      tester,
      lines: [
        fakeLine('线路一', 'a'),
        // Laid out differently: a trailer first, so the episodes sit one place further on.
        {
          'name': '线路二',
          'episodes': [
            {'id': '$b/trailer.m3u8', 'name': '预告'},
            for (var i = 1; i <= 3; i++) {'id': '$b/$i.m3u8', 'name': '第$i集'},
          ],
        },
        fakeLine('线路三', 'c'),
      ],
      dead: {'线路一'},
      history: [
        {
          'site': 'cms',
          'vodId': '7',
          'name': '推荐片',
          'line': '线路一',
          'episodeId': '$a/2.m3u8',
          'episodeName': '第2集',
          'episodeIndex': 1,
          'positionMs': 61000,
          'durationMs': 2400000,
          'updatedAt': 1,
        },
      ],
    );

    expect(resolved, ['线路一', '线路二']);
    expect(player.opened, ['$b/2.m3u8'], reason: 'the same episode, found by its name');
    expect(player.seeks, [const Duration(seconds: 61)], reason: 'the history position, not the beginning');
    expect(find.text('「线路一」解析失败，已切到「线路二」'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    expectOnLine('线路二');

    // The notice goes away; the history follows the line that plays.
    player.playTo(const Duration(minutes: 2));
    await pass(tester, const Duration(seconds: 11));
    expect(find.textContaining('已切到'), findsNothing);
    expect(saved['7'], containsPair('line', '线路二'));
    expect(saved['7'], containsPair('episodeName', '第2集'));
    expect(saved['7'], containsPair('positionMs', 120000));
    expect(resolved, ['线路一', '线路二'], reason: 'a line that plays is left alone');
    await leave(tester);
  });

  testWidgets('when every line fails the error stays, with retry and the lines to choose from', (tester) async {
    await play(tester, dead: {'线路一', '线路二', '线路三'});

    expect(resolved, ['线路一', '线路二', '线路三'], reason: 'each line once');
    expect(player.opened, isEmpty);
    expect(find.textContaining('所有 3 条线路都试过了'), findsOneWidget);
    expect(find.textContaining('最后一条「线路三」：解析失败：线路三 取不到播放地址'), findsOneWidget);
    expectOnLine('线路一');

    // Nothing more happens by itself.
    await pass(tester, const Duration(seconds: 40));
    expect(resolved, hasLength(3));

    // 重试 is the same round again.
    await press(tester, find.text('重试'));
    await pass(tester, const Duration(seconds: 1));
    expect(resolved, ['线路一', '线路二', '线路三', '线路一', '线路二', '线路三']);
    expect(find.textContaining('所有 3 条线路都试过了'), findsOneWidget);

    // 换线路 opens the list; a line that has come back plays.
    deadLines.remove('线路二');
    await press(tester, find.text('换线路'));
    expect(find.byType(ChoiceChip), findsNWidgets(3));
    await pickLine(tester, '线路二', openPanel: false);
    expect(player.opened, ['$b/1.m3u8']);
    expect(find.text('重试'), findsNothing);
    expectOnLine('线路二');
    await leave(tester);
  });

  testWidgets('a line the user picked is not switched away from when it fails', (tester) async {
    await play(tester, dead: {'线路二'});
    expect(player.opened, ['$a/1.m3u8']);
    player.playTo(const Duration(minutes: 5));
    await tester.pump();

    await pickLine(tester, '线路二');
    expect(resolved, ['线路一', '线路二']);
    expect(find.textContaining('解析失败：线路二 取不到播放地址'), findsOneWidget);
    expect(find.textContaining('「线路二」是手动选的，不会自动换线路'), findsOneWidget);
    expectOnLine('线路二');

    await pass(tester, const Duration(seconds: 40));
    expect(resolved, ['线路一', '线路二'], reason: 'no other line is tried behind the user\'s back');

    await press(tester, find.text('重试'));
    await pass(tester, const Duration(seconds: 1));
    expect(resolved, ['线路一', '线路二', '线路二'], reason: 'retry stays on the picked line');
    expectOnLine('线路二');

    // The next pick by hand plays, from where the first line had got to.
    await press(tester, find.text('换线路'));
    await pickLine(tester, '线路三', openPanel: false);
    expect(player.opened, ['$a/1.m3u8', '$c/1.m3u8']);
    expect(player.seeks, [const Duration(minutes: 5)]);
    expect(find.text('重试'), findsNothing);
    await leave(tester);
  });

  testWidgets('a pick by hand overrides a change of line that is under way', (tester) async {
    await play(tester, dead: {'线路一'}, silent: {'$b/1.m3u8'});
    expect(resolved, ['线路一', '线路二']);
    expect(player.opened, ['$b/1.m3u8'], reason: 'on the second line, which shows nothing');

    await pickLine(tester, '线路三');
    expect(player.opened, ['$b/1.m3u8', '$c/1.m3u8']);

    // The 15 seconds the second line had been given run out: the page stays where the user put it.
    await pass(tester, const Duration(seconds: 20));
    expect(resolved, ['线路一', '线路二', '线路三']);
    expect(find.text('重试'), findsNothing);
    expectOnLine('线路三');

    // And when that line breaks off later, it is not replaced either.
    player.playTo(const Duration(minutes: 10));
    player.end();
    await pass(tester, const Duration(seconds: 1));
    expect(resolved, ['线路一', '线路二', '线路三']);
    expect(find.textContaining('播放中途断开（10:00 / 40:00）'), findsOneWidget);
    expect(find.textContaining('「线路三」是手动选的'), findsOneWidget);
    await leave(tester);
  });

  testWidgets('a line the player cannot open, or that shows nothing for 15 seconds, is skipped too', (tester) async {
    await play(tester, broken: {'$a/1.m3u8'}, silent: {'$b/1.m3u8'});
    expect(resolved, ['线路一'], reason: 'an error alone is not the end: the line gets a moment to load');

    await pass(tester, const Duration(seconds: 2));
    expect(resolved, ['线路一', '线路二']);
    expect(find.text('「线路一」无法播放，已切到「线路二」'), findsOneWidget);

    await pass(tester, const Duration(seconds: 13));
    expect(resolved, ['线路一', '线路二'], reason: 'still within its 15 seconds');
    await pass(tester, const Duration(seconds: 3));
    expect(resolved, ['线路一', '线路二', '线路三']);
    expect(find.text('「线路二」没有画面，已切到「线路三」'), findsOneWidget);
    expect(player.opened, ['$a/1.m3u8', '$b/1.m3u8', '$c/1.m3u8']);
    expect(find.text('重试'), findsNothing);
    await leave(tester);
  });

  testWidgets('a stream that breaks off carries on where it stopped, on the next line; a real end goes to the next episode', (tester) async {
    await play(tester);
    player.playTo(const Duration(minutes: 20));
    player.end();
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened, ['$a/1.m3u8', '$b/1.m3u8'], reason: 'the same episode, not the next one');
    expect(player.seeks, [const Duration(minutes: 20)]);
    expect(find.text('「线路一」播放中断，已切到「线路二」'), findsOneWidget);

    player.playTo(const Duration(minutes: 39, seconds: 58));
    player.end();
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened.last, '$b/2.m3u8');
    expect(player.seeks, hasLength(1), reason: 'the next episode starts at its beginning');
    await leave(tester);
  });

  testWidgets('an error the stream gets over changes nothing; one it does not get over changes line', (tester) async {
    await play(tester);
    player.playTo(const Duration(minutes: 3));
    await tester.pump();

    // A bad frame: the picture keeps moving.
    player.fail('Error while decoding frame');
    await pass(tester, const Duration(seconds: 5));
    player.advance(const Duration(seconds: 5));
    await pass(tester, const Duration(seconds: 6));
    expect(resolved, ['线路一']);
    expect(find.text('重试'), findsNothing);

    // The connection goes: nothing moves for ten seconds.
    player.fail('tcp: connection reset');
    await pass(tester, const Duration(seconds: 11));
    expect(resolved, ['线路一', '线路二']);
    expect(find.text('「线路一」播放中断，已切到「线路二」'), findsOneWidget);
    expect(player.seeks, [const Duration(minutes: 3, seconds: 5)]);
    await leave(tester);
  });

  testWidgets('buttons act at once, and the picture still takes clicks between them', (tester) async {
    await play(tester, dead: {'线路二'});
    expect(player.state.playing, isTrue);

    // 选集, then a line: each within one frame of the click, not after the time a double click is given.
    await showControls(tester);
    await tester.tap(find.text('选集'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(ChoiceChip), findsNWidgets(3), reason: 'the panel is open');
    await tester.tap(find.widgetWithText(ChoiceChip, '线路二'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(ChoiceChip), findsNothing, reason: 'the panel is closed');
    expect(resolved, ['线路一', '线路二']);

    // So does 重试, under the error that line ends in.
    await pass(tester, const Duration(seconds: 1));
    await tester.tap(find.text('重试'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(resolved, ['线路一', '线路二', '线路二']);

    // Back on a line that plays. A double click in the middle of the picture, with the controls showing and the
    // notice layers above it, still reaches the picture (on a touch device that is play / pause).
    await pass(tester, const Duration(seconds: 1));
    await press(tester, find.text('换线路'));
    await press(tester, find.widgetWithText(ChoiceChip, '线路三'));
    await pass(tester, const Duration(seconds: 1));
    expect(player.state.playing, isTrue);
    await showControls(tester);
    const middle = Offset(700, 450);
    await tester.tapAt(middle);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(middle);
    await tester.pump(const Duration(milliseconds: 50));
    expect(player.state.playing, isFalse, reason: 'the double click paused');
    await leave(tester);
  });

  test('an episode is found on another line by its place, unless the names say otherwise', () {
    PlayLine line(List<String> names) => PlayLine(
      name: 'x',
      episodes: [for (final n in names) Episode(id: n, name: n)],
    );

    expect(line(['第1集', '第2集', '第3集']).findEpisode(index: 1, name: '第2集'), 1);
    expect(line(['预告', '第1集', '第2集']).findEpisode(index: 1, name: '第2集'), 2, reason: 'shifted by a trailer');
    expect(line(['第3集', '第2集', '第1集']).findEpisode(index: 0, name: '第1集'), 2, reason: 'newest first');
    expect(line(['01', '02', '03']).findEpisode(index: 1, name: '第2集'), 1, reason: 'named differently: the same place');
    expect(line(['正片']).findEpisode(index: 0, name: 'HD'), 0);
    expect(line(['第1集', '第2集']).findEpisode(index: 5, name: '第6集'), isNull, reason: 'this line stops earlier');
    expect(line([]).findEpisode(index: 0, name: '第1集'), isNull);
  });
}
