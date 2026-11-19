// Drives the real desktop app against the demo engine:
//   engine: tvbox-engine --demo --port 19978 (see .claude/launch.json "demo-engine")
//   flutter test integration_test/desktop_play_test.dart -d windows
// It prints "MARK:<step>" at each step and, with --dart-define=SHOT_DIR=<dir>, saves a screenshot of the UI there
// (the video picture itself is a platform texture and may not appear in it).
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

  Future<void> until(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 30)}) async {
    final end = DateTime.now().add(timeout);
    while (finder.evaluate().isEmpty) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting for $finder');
      await wait(tester, const Duration(milliseconds: 200));
    }
  }

  Future<void> mark(WidgetTester tester, String step) async {
    // ignore: avoid_print
    print('MARK:$step');
    await wait(tester, const Duration(seconds: 2));
    if (shotDir.isNotEmpty) {
      final element = find.byType(MaterialApp).evaluate().first;
      await tester.runAsync(() async {
        final image = await captureImage(element);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$shotDir/it-$step.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }
  }

  Duration? clock() {
    final texts = find.byType(Text).evaluate().map((e) => (e.widget as Text).data ?? '');
    final m = texts.map(RegExp(r'^(\d+):(\d\d) / \d+:\d\d').firstMatch).whereType<RegExpMatch>().firstOrNull;
    return m == null ? null : Duration(minutes: int.parse(m[1]!), seconds: int.parse(m[2]!));
  }

  /// The detail page's main button: "播放", or "继续播放 …" when there is history.
  final playButton = find.byWidgetPredicate((w) => w is Text && (w.data == '播放' || (w.data ?? '').startsWith('继续播放')));

  testWidgets('browse, play, fullscreen, seek and volume in the desktop app', (tester) async {
    MediaKit.ensureInitialized();
    final settings = MemorySettings();
    await settings.setString('siteKey', 'demo');
    await tester.pumpWidget(TvboxApp(state: AppState(clientFactory: (url) => EngineClient(url), engineUrl: engineUrl, settings: settings)));
    await until(tester, find.text('星河往事 第二季'));
    await mark(tester, 'home');

    await tester.tap(find.text('星河往事 第二季').first);
    await until(tester, playButton);
    await mark(tester, 'detail');

    await tester.tap(playButton.first);
    // Playing once the clock moves.
    final end = DateTime.now().add(const Duration(seconds: 40));
    while ((clock() ?? Duration.zero) < const Duration(seconds: 2)) {
      if (DateTime.now().isAfter(end)) fail('playback did not start (clock: ${clock()})');
      await wait(tester, const Duration(milliseconds: 500));
    }
    await mark(tester, 'playing');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await wait(tester, const Duration(milliseconds: 300));
    expect(find.textContaining('⏩ 10 秒'), findsOneWidget);
    await mark(tester, 'seek');

    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await wait(tester, const Duration(milliseconds: 300));
    expect(find.textContaining('静音'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await wait(tester, const Duration(seconds: 1));
    expect(DesktopWindow.instance.isFullScreen, isTrue);
    await mark(tester, 'fullscreen');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await wait(tester, const Duration(seconds: 1));
    expect(DesktopWindow.instance.isFullScreen, isFalse, reason: 'Esc leaves fullscreen before leaving the player');
    expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget);
    await mark(tester, 'windowed');

    // A button reacts at once; it does not wait to see whether the click becomes a double click.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp); // any key brings the controls back
    await wait(tester, const Duration(milliseconds: 300));
    await tester.tap(find.text('选集'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(ChoiceChip), findsWidgets, reason: 'the side panel opens right after the click');
    await mark(tester, 'panel');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await wait(tester, const Duration(milliseconds: 300));
    expect(find.byType(ChoiceChip), findsNothing, reason: 'Esc closes the panel before leaving the player');

    // A click on the picture still pauses and resumes, between the bars and under the notices.
    final middle = tester.getCenter(find.byType(Scaffold).last);
    await tester.tapAt(middle);
    await wait(tester, const Duration(milliseconds: 800));
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget, reason: 'paused');
    await tester.tapAt(middle);
    await wait(tester, const Duration(milliseconds: 800));
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget, reason: 'playing again');
    await mark(tester, 'clicked');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await until(tester, playButton);
    await mark(tester, 'back');
  });

  // The demo's 白昼迷踪 第二季 has a line in front, 失效线路, whose addresses nothing answers.
  testWidgets('a dead line is replaced by the next one, which plays', (tester) async {
    MediaKit.ensureInitialized();
    final settings = MemorySettings();
    await settings.setString('siteKey', 'demo');
    await tester.pumpWidget(TvboxApp(state: AppState(clientFactory: (url) => EngineClient(url), engineUrl: engineUrl, settings: settings)));
    await until(tester, find.text('白昼迷踪 第二季'));
    await tester.tap(find.text('白昼迷踪 第二季').first);
    await until(tester, playButton);

    // Pick the dead line and its first episode by hand: after an earlier run the history points at the line that
    // played, and the play button would start there.
    final deadLine = find.textContaining('失效线路');
    await tester.ensureVisible(deadLine);
    await wait(tester, const Duration(milliseconds: 500));
    await tester.tap(deadLine);
    await wait(tester, const Duration(milliseconds: 500));
    await mark(tester, 'deadline-detail');
    await tester.ensureVisible(find.text('第1集'));
    await wait(tester, const Duration(milliseconds: 500));
    await tester.tap(find.text('第1集'));

    await until(tester, find.textContaining('已切到「演示直链」'));
    await mark(tester, 'deadline-switched');
    final end = DateTime.now().add(const Duration(seconds: 40));
    while ((clock() ?? Duration.zero) < const Duration(seconds: 2)) {
      if (DateTime.now().isAfter(end)) fail('the second line did not start (clock: ${clock()})');
      await wait(tester, const Duration(milliseconds: 500));
    }
    expect(find.text('演示直链'), findsOneWidget, reason: 'the line named at the top right');
    expect(find.text('重试'), findsNothing);
    await mark(tester, 'deadline-playing');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await until(tester, playButton);
  });
}
