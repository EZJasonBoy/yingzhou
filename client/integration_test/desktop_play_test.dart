// Drives the real desktop app against the demo engine:
//   engine: tvbox-engine --demo --port 19978 (see .claude/launch.json "demo-engine")
//   flutter test integration_test/desktop_play_test.dart -d windows
// It prints "MARK:<step>" at each step and, with --dart-define=SHOT_DIR=<dir>, saves a screenshot of the UI there
// (the video picture itself is a platform texture and may not appear in it).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/desktop/desktop_window.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/pages/danmaku_layer.dart';
import 'package:tvbox_client/player_backend.dart';
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

  // 字幕演示 and 弹幕演示 on the demo's JS site. 字幕演示: three subtitles from the spider (GBK SRT, ASS, one behind a Referer) and two
  // audio renditions. libmpv draws the subtitles; what it shows is also read back from the player (`sub-text`).
  testWidgets('subtitles, audio tracks and danmaku in the real player', (tester) async {
    MediaKit.ensureInitialized();
    final settings = MemorySettings();
    await settings.setString('siteKey', 'demo_js');
    // An earlier run's history would bring back its subtitle and position (that is the feature): start without.
    await tester.runAsync(() async {
      final engine = EngineClient(Uri.parse(engineUrl));
      for (final id in ['98', '99']) {
        await engine.removeHistory('demo_js', id).catchError((Object _) {});
      }
      engine.close();
    });
    late Player player;
    await tester.pumpWidget(
      TvboxApp(
        state: AppState(
          clientFactory: (url) => EngineClient(url),
          engineUrl: engineUrl,
          settings: settings,
          playerBackend: () {
            final backend = mediaKitBackend();
            player = backend.player;
            return backend;
          },
        ),
      ),
    );
    await until(tester, find.text('星河往事 第二季'));
    await tester.scrollUntilVisible(find.text('字幕演示'), 300, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.text('字幕演示'));
    await wait(tester, const Duration(milliseconds: 500));
    await tester.tap(find.text('字幕演示'));
    await until(tester, playButton);
    await tester.tap(playButton.first);
    final end = DateTime.now().add(const Duration(seconds: 40));
    while ((clock() ?? Duration.zero) < const Duration(seconds: 3)) {
      if (DateTime.now().isAfter(end)) fail('playback did not start (clock: ${clock()})');
      await wait(tester, const Duration(milliseconds: 500));
    }
    // The site's first subtitle is on by itself (the stream has none): GBK, turned into UTF-8 by the engine.
    final shown = <String>[];
    final sub = player.stream.subtitle.listen((lines) => shown.addAll(lines.where((l) => l.isNotEmpty)));
    await wait(tester, const Duration(seconds: 4));
    expect(shown.any((l) => l.contains('（GBK 编码）') && l.contains('分片')), isTrue, reason: 'subtitle text the player showed: $shown');
    expect(player.state.track.subtitle.title, '简体中文（GBK）');
    await mark(tester, 'subs-gbk');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp); // any key brings the controls back
    await wait(tester, const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('tracks-button')));
    await wait(tester, const Duration(milliseconds: 500));
    expect(find.text('简体中文（GBK）'), findsOneWidget);
    expect(find.text('双语特效（ASS）'), findsOneWidget);
    // Two audio renditions in the playlist: 国语 (mono) and English (stereo).
    final audioChips = find.textContaining(RegExp(r'^音轨 '));
    expect(audioChips, findsNWidgets(2), reason: 'audio tracks: ${player.state.tracks.audio}');
    await mark(tester, 'subs-panel');
    await tester.tap(find.textContaining('立体声'));
    await wait(tester, const Duration(milliseconds: 500));
    expect(player.state.track.audio.channelscount ?? player.state.tracks.audio.firstWhere((a) => a.id == player.state.track.audio.id).channelscount, 2);
    await tester.tap(find.text('双语特效（ASS）'));
    await wait(tester, const Duration(milliseconds: 500));
    await tester.tap(find.text('English (needs Referer)'));
    await wait(tester, const Duration(milliseconds: 500));
    await tester.tap(find.text('双语特效（ASS）'));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    shown.clear();
    await wait(tester, const Duration(seconds: 5));
    expect(shown.any((l) => l.contains('双语字幕')), isTrue, reason: 'the ASS file: $shown');
    await mark(tester, 'subs-ass');

    // ignore: avoid_print
    print('KEYS:${HardwareKeyboard.instance.logicalKeysPressed} FOCUS:${FocusManager.instance.primaryFocus}');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await wait(tester, const Duration(milliseconds: 300));
    expect(find.text('字幕延后 0.5 秒'), findsOneWidget);
    await sub.cancel();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await until(tester, playButton);

    // 弹幕演示: the spider names a danmaku file, 3000 comments in three minutes (Bilibili XML, raw deflate).
    Navigator.of(tester.element(playButton.first)).pop();
    await until(tester, find.text('星河往事 第二季'));
    await tester.scrollUntilVisible(find.text('弹幕演示'), 300, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.text('弹幕演示'));
    await wait(tester, const Duration(milliseconds: 500));
    await tester.tap(find.text('弹幕演示'));
    await until(tester, playButton);
    await tester.tap(playButton.first);
    await until(tester, find.byKey(const Key('danmaku-overlay')));
    final started = DateTime.now().add(const Duration(seconds: 40));
    while ((clock() ?? Duration.zero) < const Duration(seconds: 3)) {
      if (DateTime.now().isAfter(started)) fail('playback did not start (clock: ${clock()})');
      await wait(tester, const Duration(milliseconds: 500));
    }

    // Frame times, measured the way the app runs: every frame the engine draws, not only the ones the test pumps.
    final binding = IntegrationTestWidgetsFlutterBinding.instance;
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    Future<Map<String, Object>> frames(Duration time) async {
      final timings = <FrameTiming>[];
      void collect(List<FrameTiming> t) => timings.addAll(t);
      SchedulerBinding.instance.addTimingsCallback(collect);
      DanmakuOverlay.stats.reset();
      await wait(tester, time);
      SchedulerBinding.instance.removeTimingsCallback(collect);
      double pct(List<double> v, double p) => v.isEmpty ? 0 : v[((v.length - 1) * p).round()];
      final build = [for (final t in timings) t.buildDuration.inMicroseconds / 1000]..sort();
      final raster = [for (final t in timings) t.rasterDuration.inMicroseconds / 1000]..sort();
      String ms(double v) => v.toStringAsFixed(2);
      return {
        'frames': timings.length,
        'buildMs': {'p50': ms(pct(build, .5)), 'p90': ms(pct(build, .9)), 'p99': ms(pct(build, .99)), 'max': ms(build.isEmpty ? 0 : build.last)},
        'rasterMs': {'p50': ms(pct(raster, .5)), 'p90': ms(pct(raster, .9)), 'p99': ms(pct(raster, .99)), 'max': ms(raster.isEmpty ? 0 : raster.last)},
        'over16ms': timings.where((t) => t.buildDuration + t.rasterDuration > const Duration(microseconds: 16667)).length,
        'danmaku': DanmakuOverlay.stats.toJson(),
      };
    }

    final withDanmaku = await frames(const Duration(seconds: 20));
    // ignore: avoid_print
    print('DANMAKU_FRAMES:${jsonEncode({'danmaku': 'on', ...withDanmaku})}');
    expect(DanmakuOverlay.stats.maxOnScreen, greaterThan(10), reason: 'a dense file fills the screen: $withDanmaku');
    await mark(tester, 'danmaku');

    // ignore: avoid_print
    print('KEYS:${HardwareKeyboard.instance.logicalKeysPressed} FOCUS:${FocusManager.instance.primaryFocus}');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await wait(tester, const Duration(seconds: 2));
    expect(DesktopWindow.instance.isFullScreen, isTrue);
    expect(find.byKey(const Key('danmaku-overlay')), findsOneWidget);
    final fullscreen = await frames(const Duration(seconds: 10));
    // ignore: avoid_print
    print('DANMAKU_FRAMES:${jsonEncode({'danmaku': 'on, fullscreen', ...fullscreen})}');
    await mark(tester, 'danmaku-fullscreen');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await wait(tester, const Duration(seconds: 1));

    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    await wait(tester, const Duration(milliseconds: 500));
    expect(find.byKey(const Key('danmaku-overlay')), findsNothing);
    final without = await frames(const Duration(seconds: 10));
    // ignore: avoid_print
    print('DANMAKU_FRAMES:${jsonEncode({'danmaku': 'off', ...without})}');
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fadePointers;

    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    await wait(tester, const Duration(milliseconds: 500));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await wait(tester, const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('danmaku-button')));
    await wait(tester, const Duration(milliseconds: 500));
    expect(find.text('共 3000 条 · 来自站点'), findsOneWidget);
    await mark(tester, 'danmaku-panel');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await until(tester, playButton);
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
