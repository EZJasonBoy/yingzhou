import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/pages/seek_bar.dart';
import 'package:tvbox_client/player_cache.dart';

import 'fake_engine.dart';
import 'fake_player.dart';

/// The player's seek bar: on its own, and in the player page with the fake player (a film of forty minutes).
void main() {
  Duration at(int minutes, [int seconds = 0]) => Duration(minutes: minutes, seconds: seconds);

  group('the bar by itself', () {
    late List<Duration> sought;
    late int interactions;

    /// A bar 1028 wide: with the 14 at either end taken off, 1000 pixels stand for the 2000 seconds of the film.
    Future<void> pumpBar(WidgetTester tester, {Duration position = Duration.zero, Duration? duration, List<BufferedRange> buffered = const []}) async {
      tester.view.physicalSize = const Size(1200, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.bottomLeft,
            child: SizedBox(
              width: 1028,
              child: SeekBar(
                key: const Key('seek-bar'),
                position: position,
                duration: duration ?? const Duration(seconds: 2000),
                buffered: buffered,
                onSeek: sought.add,
                onInteraction: () => interactions++,
              ),
            ),
          ),
        ),
      );
    }

    /// The point on the bar that stands for [seconds].
    Offset point(WidgetTester tester, double seconds) {
      final rect = tester.getRect(find.byKey(const Key('seek-bar')));
      return Offset(rect.left + SeekBar.inset + seconds / 2, rect.center.dy);
    }

    String? label(WidgetTester tester) {
      final found = find.byKey(const Key('seek-target')).evaluate();
      return found.isEmpty ? null : (found.single.widget as Text).data;
    }

    setUp(() {
      sought = [];
      interactions = 0;
    });

    testWidgets('a drag seeks once, when it is let go, and says where it would land meanwhile', (tester) async {
      await pumpBar(tester, position: const Duration(seconds: 100));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: point(tester, 400));
      await mouse.down(point(tester, 400));
      await tester.pump();
      expect(label(tester), '06:40');
      for (final seconds in [500.0, 800.0, 1200.0, 1500.0]) {
        await mouse.moveTo(point(tester, seconds));
        await tester.pump();
      }
      expect(label(tester), '25:00');
      expect(sought, isEmpty, reason: 'nothing is asked of the player while the button is down');

      await mouse.up();
      await tester.pump();
      expect(sought, [const Duration(seconds: 1500)]);
      expect(interactions, greaterThan(4), reason: 'the page hears that the bar is in use');
      await tester.pump(const Duration(seconds: 3));
      await mouse.removePointer();
    });

    testWidgets('a click seeks to the place clicked, and the ends of the bar are the ends of the film', (tester) async {
      await pumpBar(tester);
      await tester.tapAt(point(tester, 730));
      expect(sought.single, const Duration(seconds: 730));
      // Beyond the track, on the bar's own margins.
      final rect = tester.getRect(find.byKey(const Key('seek-bar')));
      await tester.tapAt(Offset(rect.left + 2, rect.center.dy));
      await tester.tapAt(Offset(rect.right - 2, rect.center.dy));
      expect(sought.sublist(1), [Duration.zero, const Duration(seconds: 2000)]);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('after a seek the thumb stays where it was put until the player reports from there', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpBar(tester, position: const Duration(seconds: 100));
      await tester.tapAt(point(tester, 1000));
      await tester.pump();
      String shown() => tester.getSemantics(find.bySemanticsLabel('播放进度')).value;
      expect(shown(), startsWith('16:40'));
      // The player is still where it was for a moment: the thumb does not jump back there.
      await pumpBar(tester, position: const Duration(seconds: 101));
      expect(shown(), startsWith('16:40'));
      // It reports the new place: from here on the bar follows the player.
      await pumpBar(tester, position: const Duration(seconds: 1001));
      expect(shown(), startsWith('16:41'));
      await pumpBar(tester, position: const Duration(seconds: 1005));
      expect(shown(), startsWith('16:45'));

      // A player that never gets there: after two seconds the bar shows where the player really is.
      await tester.tapAt(point(tester, 300));
      await tester.pump();
      expect(shown(), startsWith('05:00'));
      await tester.pump(const Duration(seconds: 3));
      expect(shown(), startsWith('16:45'));
      semantics.dispose();
    });

    testWidgets('a hovering mouse is told the time under it; a bar without a film does nothing', (tester) async {
      await pumpBar(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(5, 5));
      await mouse.moveTo(point(tester, 3 * 60 + 20));
      await tester.pump();
      expect(label(tester), '03:20');
      await mouse.moveTo(const Offset(5, 5));
      await tester.pump();
      expect(label(tester), isNull);
      expect(sought, isEmpty);

      await pumpBar(tester, duration: Duration.zero);
      await mouse.moveTo(point(tester, 100));
      await tester.pump();
      await tester.tapAt(point(tester, 100));
      expect(label(tester), isNull);
      expect(sought, isEmpty);
      await mouse.removePointer();
    });

    testWidgets('times of an hour and more show the hour', (tester) async {
      expect(SeekBar.format(const Duration(seconds: 59)), '00:59');
      expect(SeekBar.format(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
    });
  });

  test('buffered ranges from the player and from the engine are joined into one list', () {
    BufferedRange r(int from, int to) => (start: Duration(seconds: from), end: Duration(seconds: to));
    expect(PlayerCache.merge([r(100, 160), r(0, 30), r(150, 200), r(30, 40), r(500, 500), r(900, 960)]), [r(0, 40), r(100, 200), r(900, 960)]);
    expect(PlayerCache.merge(const []), isEmpty);
  });

  group('in the player page', () {
    late FakePlayer player;

    Future<void> pass(WidgetTester tester, Duration time) async {
      for (var t = Duration.zero; t < time; t += const Duration(milliseconds: 100)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    /// Opens 推荐片 and plays it. With [coverage] the engine has a stream cache that holds those parts of the film.
    Future<void> play(WidgetTester tester, {List<List<int>>? coverage}) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      player = FakePlayer();
      final engine = fakeEngine(
        hasConfig: true,
        lines: [fakeLine('线路一', 'a')],
        streamCache: coverage == null ? null : {'available': true, 'bytes': 0, 'files': 0, 'streams': 0, 'path': ''},
        coverage: coverage ?? const [],
      );
      await tester.pumpWidget(TvboxApp(state: AppState(clientFactory: (url) => EngineClient(url, httpClient: engine), playerBackend: () => player.backend())));
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

    final bar = find.byKey(const Key('seek-bar'));

    /// The point on the page's seek bar that stands for [position] of the forty minutes.
    Offset point(WidgetTester tester, Duration position) {
      final rect = tester.getRect(bar);
      return Offset(rect.left + SeekBar.inset + (rect.width - 2 * SeekBar.inset) * position.inMilliseconds / (40 * 60 * 1000), rect.center.dy);
    }

    testWidgets('dragging the bar sends the player there once', (tester) async {
      await play(tester);
      player.playTo(at(1));
      await tester.pump();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: point(tester, at(5)));
      await mouse.down(point(tester, at(5)));
      for (var minute = 6; minute <= 30; minute += 2) {
        await mouse.moveTo(point(tester, at(minute)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(player.seeks, isEmpty);
      expect(find.byKey(const Key('seek-target')), findsOneWidget);
      // Four seconds with the button down: the controls (and the bar) are still there.
      await pass(tester, const Duration(seconds: 4));
      expect(find.byIcon(Icons.pause_rounded).hitTestable(), findsOneWidget);

      await mouse.up();
      await tester.pump();
      expect(player.seeks.length, 1);
      expect((player.seeks.single - at(30)).abs(), lessThan(const Duration(seconds: 2)));
      await mouse.removePointer();
      await leave(tester);
    });

    testWidgets('steps with the arrow keys add up, also while the player has not caught up', (tester) async {
      await play(tester);
      player.playTo(at(10));
      await tester.pump();
      // A player that takes its time to report where it was sent.
      player.seekDelay = const Duration(milliseconds: 600);
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(player.seeks, [at(10, 10), at(10, 20), at(10, 30)], reason: 'each press starts from where the one before sent the player');
      expect(find.textContaining('10:30 / 40:00'), findsOneWidget);

      // Once the player is there, steps start from its position again.
      await pass(tester, const Duration(seconds: 1));
      player.playTo(at(12));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump(const Duration(milliseconds: 100));
      expect(player.seeks.length, 4);
      expect(player.seeks.last, at(11, 50));
      await pass(tester, const Duration(seconds: 1));
      await leave(tester);
    });

    testWidgets('the bar shows what the player and the engine have buffered', (tester) async {
      // The engine holds the first four minutes and two minutes from 20:00.
      await play(
        tester,
        coverage: [
          [0, 240000],
          [1200000, 1320000],
        ],
      );
      player.playTo(at(3));
      player.bufferTo(at(5));
      await pass(tester, const Duration(seconds: 3));
      final shown = tester.widget<SeekBar>(bar).buffered;
      expect(shown, [(start: Duration.zero, end: at(5)), (start: at(20), end: at(22))], reason: 'the two lists joined: $shown');
      await leave(tester);
    });

    testWidgets('without a stream cache the bar shows the player\'s own read-ahead', (tester) async {
      await play(tester);
      player.playTo(at(3));
      player.bufferTo(at(4, 30));
      await pass(tester, const Duration(seconds: 2));
      expect(tester.widget<SeekBar>(bar).buffered, [(start: at(3), end: at(4, 30))]);
      await leave(tester);
    });
  });
}
