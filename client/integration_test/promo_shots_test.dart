// Screenshots of the real app for the promo film and the portfolio (tools/promo), in every device form.
//
//   node tools/promo/server.mjs                                   the promo source: fictional titles, generated posters
//   tvbox-engine --port 19979 --data <scratch> --subscribe http://127.0.0.1:5199/config.json
//   flutter test integration_test/promo_shots_test.dart -d windows --dart-define=SHOT_DIR=<dir>
//
// In the TV run the app is also a screen of the engine's remote control (「允许手机遥控」 on, named 客厅电视). With
// --dart-define=REMOTE_HOLD=<seconds> it prints MARK:remote-ready once the film plays and keeps playing that long,
// for tools/remote/screenshots.mjs to photograph the web remote driving it (the page is opened on this machine).
//
// The window itself is not what is captured: each test lays the app out at a device's size and pixel ratio and
// renders its layer tree to a PNG, so a 4K-sized phone or TV shot does not need a 4K screen.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/remote/remote_agent.dart';
import 'package:tvbox_client/settings.dart';
import 'package:tvbox_client/ui/device_form.dart';

const engineUrl = String.fromEnvironment('ENGINE_URL', defaultValue: 'http://127.0.0.1:19979');
const shotDir = String.fromEnvironment('SHOT_DIR');

/// `--dart-define=THEME=light` (or `dark`): every form in that theme, whatever its default is.
const theme = String.fromEnvironment('THEME');

/// Seconds the TV run keeps playing after MARK:remote-ready; 0 = none.
const remoteHold = int.fromEnvironment('REMOTE_HOLD');

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

  var ratio = 2.0;

  /// Lays the app out as a [width] x [height] screen with [pixelRatio] device pixels per logical pixel.
  Future<void> screen(WidgetTester tester, double width, double height, double pixelRatio) async {
    ratio = pixelRatio;
    tester.view.devicePixelRatio = pixelRatio;
    tester.view.physicalSize = Size(width * pixelRatio, height * pixelRatio);
    addTearDown(tester.view.reset);
    await tester.pump();
  }

  Future<void> shot(WidgetTester tester, String name, {Duration settle = const Duration(milliseconds: 1500)}) async {
    // ignore: avoid_print
    print('SHOT:$name');
    await wait(tester, settle);
    if (shotDir.isEmpty) return;
    RenderObject ro = find.byType(MaterialApp).evaluate().first.renderObject!;
    while (!ro.isRepaintBoundary) {
      ro = ro.parent!;
    }
    // ignore: invalid_use_of_protected_member
    final layer = ro.debugLayer! as OffsetLayer;
    await tester.runAsync(() async {
      // The root's layer is already in device pixels; any boundary below it is in logical ones.
      final image = await layer.toImage(ro.paintBounds, pixelRatio: ro is RenderView ? 1 : ratio);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$shotDir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  Duration? clock() {
    final texts = find.byType(Text).evaluate().map((e) => (e.widget as Text).data ?? '');
    final m = texts.map(RegExp(r'^(\d+):(\d\d) / \d+:\d\d').firstMatch).whereType<RegExpMatch>().firstOrNull;
    return m == null ? null : Duration(minutes: int.parse(m[1]!), seconds: int.parse(m[2]!));
  }

  Future<void> playing(WidgetTester tester, {int seconds = 6}) async {
    final end = DateTime.now().add(const Duration(seconds: 45));
    while ((clock() ?? Duration.zero) < Duration(seconds: seconds)) {
      if (DateTime.now().isAfter(end)) {
        // ignore: avoid_print
        print('NOTE: no clock seen (clock: ${clock()}); going on');
        return;
      }
      await wait(tester, const Duration(milliseconds: 400));
    }
  }

  final playButton = find.byWidgetPredicate((w) => w is Text && (w.data == '播放' || (w.data ?? '').startsWith('继续播放')));

  Future<AppState> start(WidgetTester tester, {DeviceForm? form, Map<String, String> prefs = const {}}) async {
    MediaKit.ensureInitialized();
    final settings = MemorySettings();
    // These tests start from the site's recommendations, whatever an earlier one left in the history.
    await settings.setString('ui.startPage', 'home');
    await settings.setString('siteKey', 'zhou');
    for (final e in prefs.entries) {
      await settings.setString(e.key, e.value);
    }
    if (theme.isNotEmpty) await settings.setString('ui.theme', theme);
    final state = AppState(clientFactory: (url) => EngineClient(url), engineUrl: engineUrl, settings: settings);
    final app = TvboxApp(state: state);
    // A desktop gets the controller the real app has, so 设置 shows 界面模式 (desktop or TV layout) as it does there.
    await tester.pumpWidget(form == null ? DeviceFormScope(controller: DeviceFormController(settings: settings), child: app) : DeviceFormScope.fixed(form, child: app));
    await until(tester, find.text('星垂平野'));
    return state;
  }

  void pop(WidgetTester tester) => tester.state<NavigatorState>(find.byType(Navigator).first).pop();

  testWidgets('desktop', (tester) async {
    await screen(tester, 1600, 900, 2);
    final state = await start(tester);
    await tester.runAsync(() => state.client.patchSettings({'danmakuConfigApi': true}));
    await shot(tester, 'desktop-home', settle: const Duration(seconds: 4));

    await tester.tap(find.text('山海长歌').first);
    await until(tester, playButton);
    await shot(tester, 'desktop-detail', settle: const Duration(seconds: 3));

    await tester.tap(playButton.first);
    await playing(tester, seconds: 9);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(700, 500));
    await mouse.moveTo(const Offset(720, 520));
    await tester.pump();
    await shot(tester, 'desktop-player', settle: const Duration(milliseconds: 600));
    await mouse.moveTo(const Offset(2000, 2000));
    await shot(tester, 'desktop-player-clean', settle: const Duration(seconds: 6));
    await mouse.removePointer();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await until(tester, playButton);
    pop(tester);
    await until(tester, find.text('星垂平野'));

    await tester.tap(find.text('星河往事 第二季').first);
    await until(tester, playButton);
    await shot(tester, 'desktop-detail-series', settle: const Duration(seconds: 3));
    await tester.tap(playButton.first);
    await playing(tester, seconds: 4);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await wait(tester, const Duration(milliseconds: 300));
    if (find.text('选集').evaluate().isNotEmpty) {
      await tester.tap(find.text('选集').first);
      await shot(tester, 'desktop-player-episodes', settle: const Duration(milliseconds: 900));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await wait(tester, const Duration(milliseconds: 300));
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await until(tester, playButton);
    pop(tester);
    await until(tester, find.text('星垂平野'));

    await tester.tap(find.text('动漫').first);
    await until(tester, find.text('云上邮差'));
    await shot(tester, 'desktop-category', settle: const Duration(seconds: 3));

    await tester.tap(find.text('搜索').first);
    await wait(tester, const Duration(milliseconds: 500));
    await tester.enterText(find.byType(TextField).first, '星');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await until(tester, find.text('星屑列车'));
    await shot(tester, 'desktop-search', settle: const Duration(seconds: 4));

    await tester.tap(find.text('我的').first);
    await shot(tester, 'desktop-library', settle: const Duration(seconds: 3));

    await tester.tap(find.text('源').first);
    await shot(tester, 'desktop-sources', settle: const Duration(seconds: 3));

    await tester.tap(find.text('设置').first);
    await shot(tester, 'desktop-settings', settle: const Duration(seconds: 3));

    await tester.tap(find.text('直播').first);
    await until(tester, find.text('江上纪实'));
    await shot(tester, 'desktop-live', settle: const Duration(seconds: 12));
  });

  for (final dark in [false, true]) {
    testWidgets('phone ${dark ? 'dark' : 'light'}', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await screen(tester, 393, 852, 3);
      await start(tester, form: DeviceForm.phone);
      final tag = dark ? 'phone-dark' : 'phone';
      await shot(tester, '$tag-home', settle: const Duration(seconds: 4));

      await tester.tap(find.text('山海长歌').first);
      await until(tester, playButton);
      await shot(tester, '$tag-detail', settle: const Duration(seconds: 3));
      if (dark) return;

      await tester.tap(playButton.first);
      await wait(tester, const Duration(seconds: 10));
      await shot(tester, 'phone-player-clean', settle: const Duration(milliseconds: 300));
      await tester.tapAt(const Offset(196, 200));
      await shot(tester, 'phone-player', settle: const Duration(milliseconds: 700));

      // On its side, as the full-screen player.
      await screen(tester, 852, 393, 3);
      await wait(tester, const Duration(seconds: 1));
      await shot(tester, 'phone-player-landscape-a', settle: const Duration(milliseconds: 500));
      await tester.tapAt(const Offset(426, 180));
      await shot(tester, 'phone-player-landscape-b', settle: const Duration(milliseconds: 700));
    });
  }

  testWidgets('tablet', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await screen(tester, 1180, 820, 2);
    await start(tester, form: DeviceForm.tablet);
    await shot(tester, 'tablet-home', settle: const Duration(seconds: 4));
    await tester.tap(find.text('大江流').first);
    await until(tester, playButton);
    await shot(tester, 'tablet-detail', settle: const Duration(seconds: 3));
  });

  testWidgets('tv', (tester) async {
    await screen(tester, 960, 540, 2);
    await start(tester, form: DeviceForm.tv, prefs: {RemoteAgent.enabledKey: '1', RemoteAgent.nameKey: '客厅电视'});
    await shot(tester, 'tv-home-a', settle: const Duration(seconds: 4));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await wait(tester, const Duration(milliseconds: 400));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await wait(tester, const Duration(milliseconds: 400));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await shot(tester, 'tv-home-b', settle: const Duration(milliseconds: 900));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await shot(tester, 'tv-home-c', settle: const Duration(milliseconds: 900));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await until(tester, playButton);
    await shot(tester, 'tv-detail', settle: const Duration(seconds: 3));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await wait(tester, const Duration(seconds: 10));
    await shot(tester, 'tv-player-clean', settle: const Duration(milliseconds: 300));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await shot(tester, 'tv-player', settle: const Duration(milliseconds: 700));
    if (remoteHold > 0) {
      // ignore: avoid_print
      print('MARK:remote-ready');
      await wait(tester, const Duration(seconds: remoteHold));
    }
  });
}
