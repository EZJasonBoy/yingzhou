// Drives the real desktop app through the demo engine's drives:
//   engine: tvbox-engine --demo --dev-cors --port <port>
//   flutter test integration_test/drive_test.dart -d windows --dart-define=ENGINE_URL=http://127.0.0.1:<port>
// The demo engine has 「演示 WebDAV」 (its own WebDAV server, with an account, so files come through the engine)
// and 「演示本机文件夹」 (a folder on this machine). It prints "MARK:<step>" at each step and, with
// --dart-define=SHOT_DIR=<dir>, saves a screenshot of the app there (video picture included).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tvbox_client/app_state.dart';
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
    await wait(tester, const Duration(seconds: 1));
    if (shotDir.isNotEmpty) {
      final element = find.byType(MaterialApp).evaluate().first;
      await tester.runAsync(() async {
        final image = await captureImage(element);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$shotDir/drive-$step.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }
  }

  Duration? clock() {
    final texts = find.byType(Text).evaluate().map((e) => (e.widget as Text).data ?? '');
    final m = texts.map(RegExp(r'^(\d+):(\d\d) / \d+:\d\d').firstMatch).whereType<RegExpMatch>().firstOrNull;
    return m == null ? null : Duration(minutes: int.parse(m[1]!), seconds: int.parse(m[2]!));
  }

  /// Waits until the player's clock has passed [at]. The clock is part of the controls, which hide while playing:
  /// a mouse move brings them back.
  Future<void> playsTo(WidgetTester tester, Duration at, String what) async {
    final end = DateTime.now().add(const Duration(seconds: 40));
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(400, 300));
    var x = 400.0;
    while ((clock() ?? Duration.zero) < at) {
      if (DateTime.now().isAfter(end)) {
        await mark(tester, 'failed');
        final texts = find.byType(Text).evaluate().map((e) => (e.widget as Text).data).whereType<String>().join(' | ');
        fail('$what did not play (clock: ${clock()}); on screen: $texts');
      }
      x = x == 400 ? 420 : 400;
      await mouse.moveTo(Offset(x, 300));
      await wait(tester, const Duration(milliseconds: 300));
    }
    await mouse.removePointer();
  }

  List<String> shown() => [
    for (final e in find.byWidgetPredicate((w) => w is ListTile && (w.key as ValueKey?)?.value.toString().startsWith('entry-') == true).evaluate())
      ((e.widget as ListTile).title as Text).data!,
  ];

  testWidgets('browse the demo drives and play their videos in the desktop app', (tester) async {
    MediaKit.ensureInitialized();
    final settings = MemorySettings();
    await settings.setString('siteKey', 'demo');
    await tester.pumpWidget(TvboxApp(state: AppState(clientFactory: (url) => EngineClient(url), engineUrl: engineUrl, settings: settings)));
    await until(tester, find.text('星河往事 第二季'));

    await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('网盘')));
    await until(tester, find.text('演示 WebDAV'));
    expect(find.text('演示本机文件夹'), findsOneWidget);
    await mark(tester, 'drives');

    // The WebDAV drive: folders, episodes in number order, the subtitle beside the first one.
    await tester.tap(find.text('演示 WebDAV'));
    await until(tester, find.text('演示剧集'));
    expect(shown(), ['演示剧集', '短片.ts', '说明.txt']);
    await tester.tap(find.text('演示剧集'));
    await until(tester, find.text('第10集.ts'));
    expect(shown().where((n) => n.endsWith('.ts')).toList(), ['第1集.ts', '第2集.ts', '第10集.ts']);
    expect(find.textContaining('有字幕'), findsWidgets);
    await mark(tester, 'folder');

    await tester.tap(find.text('第1集.ts'));
    await playsTo(tester, const Duration(seconds: 2), '第1集 (WebDAV, through the engine)');
    expect(find.text('重试'), findsNothing);
    await mark(tester, 'playing');

    // The folder is the playlist: N plays the next video.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await until(tester, find.textContaining('第2集'));
    await wait(tester, const Duration(seconds: 1));
    await playsTo(tester, const Duration(seconds: 2), '第2集');
    await mark(tester, 'next');

    // Back on the folder page, the history says where playback got to.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await until(tester, find.textContaining('上次看到：第2集'));
    await mark(tester, 'history');

    // The folder on this machine.
    await tester.tap(find.byType(BackButton));
    await wait(tester, const Duration(milliseconds: 500));
    await tester.tap(find.byType(BackButton));
    await until(tester, find.text('演示本机文件夹'));
    await tester.tap(find.text('演示本机文件夹'));
    await until(tester, find.text('短片.ts'));
    expect(shown(), ['演示剧集', '短片.ts', '说明.txt']);
    await mark(tester, 'local-folder');
    await tester.tap(find.text('短片.ts'));
    await playsTo(tester, const Duration(seconds: 2), '短片 (local folder)');
    await mark(tester, 'local');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await until(tester, find.text('短片.ts'));
  });
}
