// Live TV in the real desktop app, against the demo engine's "演示直播" (see desktop_play_test.dart for how to run).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/desktop/desktop_window.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/settings.dart';

const engineUrl = String.fromEnvironment('ENGINE_URL', defaultValue: 'http://127.0.0.1:19978');
const shotDir = String.fromEnvironment('SHOT_DIR');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> wait(WidgetTester tester, Duration d) async {
    final end = DateTime.now().add(d);
    while (DateTime.now().isBefore(end)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
  }

  Future<void> until(WidgetTester tester, bool Function() done, String what, {Duration timeout = const Duration(seconds: 30)}) async {
    final end = DateTime.now().add(timeout);
    while (!done()) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
      await wait(tester, const Duration(milliseconds: 200));
    }
  }

  Future<void> mark(WidgetTester tester, String step) async {
    // ignore: avoid_print
    print('MARK:$step');
    await wait(tester, const Duration(seconds: 2));
    if (shotDir.isEmpty) return;
    final element = find.byType(MaterialApp).evaluate().first;
    await tester.runAsync(() async {
      final image = await captureImage(element);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$shotDir/live-$step.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  bool shows(String text) => find.textContaining(text).evaluate().isNotEmpty;
  bool opening() => shows('正在打开');
  // Playing: neither opening nor reporting a dead line.
  bool playing() => !opening() && !shows('无法播放') && !shows('没有画面');

  testWidgets('live TV: tune in, guide, change channel, dead line fallback, fullscreen', (tester) async {
    MediaKit.ensureInitialized();
    final settings = MemorySettings();
    await tester.pumpWidget(TvboxApp(state: AppState(clientFactory: (url) => EngineClient(url), engineUrl: engineUrl, settings: settings)));
    await until(tester, () => shows('直播'), 'the shell');
    await tester.tap(find.text('直播').first);

    // The first channel plays on its own and its guide shows what is on.
    await until(tester, () => shows('演示直播台') && shows('直播中'), 'channel list and guide');
    await until(tester, playing, 'the live stream to start', timeout: const Duration(seconds: 40));
    expect(shows('正在播放：'), isTrue);
    await mark(tester, 'tuned');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await until(tester, () => find.text('CCTV-1 综合').evaluate().length >= 2, 'the next channel in the now bar');
    await until(tester, playing, 'CCTV-1 to start', timeout: const Duration(seconds: 40));
    await mark(tester, 'next');

    // The 测试 group's channel has a dead first line: the page moves to the second by itself.
    await tester.tap(find.text('测试').first);
    await until(tester, () => shows('备用线路演示'), 'the 测试 group');
    await tester.tap(find.text('备用线路演示').first);
    await until(tester, () => shows('线路 2/2'), 'the fallback to line 2', timeout: const Duration(seconds: 40));
    await until(tester, playing, 'line 2 to start', timeout: const Duration(seconds: 40));
    await mark(tester, 'fallback');

    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await wait(tester, const Duration(seconds: 1));
    expect(DesktopWindow.instance.isFullScreen, isTrue);
    expect(find.byType(NavigationRail), findsNothing, reason: 'fullscreen live TV hides the navigation');
    await mark(tester, 'fullscreen');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await wait(tester, const Duration(seconds: 1));
    expect(DesktopWindow.instance.isFullScreen, isFalse);
    expect(find.byType(NavigationRail), findsOneWidget);

    // Catch-up: 回看演示台 offers three days back; a programme of yesterday plays from the demo's catch-up address
    // (the VOD test stream), with a seek bar, until 回到直播.
    await tester.tap(find.text('演示频道').first);
    await until(tester, () => shows('回看演示台'), 'the 演示频道 group');
    await tester.tap(find.text('回看演示台').first);
    await until(tester, () => find.widgetWithText(ChoiceChip, '昨天').evaluate().isNotEmpty, 'the days of catch-up');
    await until(tester, playing, '回看演示台 live', timeout: const Duration(seconds: 40));
    await tester.tap(find.widgetWithText(ChoiceChip, '昨天'));
    // A programme marked 回看 that is on screen (the channel's own name contains the word too).
    final playable = find.text('回看').hitTestable();
    // Yesterday's list has no programme on air; until it has loaded, today's is still on screen.
    await until(tester, () => find.text('直播中').evaluate().isEmpty && playable.evaluate().isNotEmpty, 'yesterday\'s guide');
    await tester.tap(playable.first);
    await until(tester, () => find.byKey(const Key('back-to-live')).evaluate().isNotEmpty, 'the 回看 state');
    await until(tester, playing, 'the programme to play back', timeout: const Duration(seconds: 40));
    await until(tester, () => tester.widget<Slider>(find.byKey(const Key('catchup-seek'))).max > 1, 'a seek bar with the programme\'s length');
    expect(find.text('回看中'), findsOneWidget, reason: 'the programme played back is marked in the guide');
    await mark(tester, 'catchup');

    await tester.tap(find.byKey(const Key('back-to-live')));
    await until(tester, () => find.byKey(const Key('back-to-live')).evaluate().isEmpty, 'live again');
    await until(tester, playing, '回看演示台 live again', timeout: const Duration(seconds: 40));
    await mark(tester, 'back-to-live');
  });
}
