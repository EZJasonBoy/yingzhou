// Python spiders in the real desktop app, against the demo engine (see desktop_play_test.dart for how to run; the
// engine needs a Python 3.8+ on the machine). 演示Python站: browse, play the line that goes through the spider's
// localProxy, search; 演示Python依赖站: the missing-package message; 演示Python直播: channels from liveContent.
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
import 'package:tvbox_client/pages/sources_page.dart';
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
      File('$shotDir/py-$step.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  bool shows(String text) => find.textContaining(text).evaluate().isNotEmpty;

  Duration? clock() {
    final texts = find.byType(Text).evaluate().map((e) => (e.widget as Text).data ?? '');
    final m = texts.map(RegExp(r'^(\d+):(\d\d) / \d+:\d\d').firstMatch).whereType<RegExpMatch>().firstOrNull;
    return m == null ? null : Duration(minutes: int.parse(m[1]!), seconds: int.parse(m[2]!));
  }

  final playButton = find.byWidgetPredicate((w) => w is Text && (w.data == '播放' || (w.data ?? '').startsWith('继续播放')));

  testWidgets('python spiders: browse, play through localProxy, search, a missing package, live', (tester) async {
    MediaKit.ensureInitialized();
    final settings = MemorySettings();
    // These tests start from the site's recommendations, whatever an earlier one left in the history.
    await settings.setString('ui.startPage', 'home');
    await settings.setString('siteKey', 'demo_py');
    await tester.pumpWidget(
      TvboxApp(
        state: AppState(clientFactory: (url) => EngineClient(url), engineUrl: engineUrl, settings: settings),
      ),
    );

    // The Python site's home page.
    await until(tester, () => shows('白蛇新传') && shows('蟒山奇谈'), 'the Python site home page', timeout: const Duration(seconds: 60));
    await mark(tester, 'home');

    // Its detail, and the line served through the spider's own proxy.
    await tester.tap(find.text('白蛇新传').first);
    await until(tester, () => playButton.evaluate().isNotEmpty && shows('代理'), 'the detail page');
    expect(shows('Python'), isTrue, reason: 'the director field the spider fills in');
    await mark(tester, 'detail');
    // The line chips read "<name>  <episodes>".
    final proxyLine = find.textContaining(RegExp(r'^代理\s'));
    await tester.ensureVisible(proxyLine.first);
    await wait(tester, const Duration(milliseconds: 300));
    await tester.tap(proxyLine.first);
    await wait(tester, const Duration(milliseconds: 500));
    await tester.ensureVisible(find.text('第2集'));
    await wait(tester, const Duration(milliseconds: 300));
    await tester.tap(find.text('第2集'));
    final end = DateTime.now().add(const Duration(seconds: 60));
    while ((clock() ?? Duration.zero) < const Duration(seconds: 2)) {
      if (DateTime.now().isAfter(end)) fail('the proxied line did not start (clock: ${clock()})');
      await wait(tester, const Duration(milliseconds: 500));
    }
    expect(find.text('代理'), findsWidgets, reason: 'the line in use, at the top right');
    await mark(tester, 'playing-proxy');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    if (DesktopWindow.instance.isFullScreen) await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await wait(tester, const Duration(seconds: 1));
    if (playButton.evaluate().isEmpty) {
      // The key went elsewhere (focus stayed on the detail page's chips): the player's own back arrow then.
      await tester.tapAt(tester.getCenter(find.byType(Scaffold).last));
      await wait(tester, const Duration(milliseconds: 500));
      await tester.tap(find.byIcon(Icons.arrow_back).last);
    }
    await until(tester, () => playButton.evaluate().isNotEmpty, 'back on the detail page');
    await mark(tester, 'detail-again');
    await tester.tap(find.byIcon(Icons.arrow_back).last);
    await wait(tester, const Duration(seconds: 1));

    // Search: the Python site answers with its own titles.
    await tester.tap(find.text('搜索').last);
    await wait(tester, const Duration(seconds: 1));
    await tester.enterText(find.byType(TextField).first, '蟒');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await until(tester, () => shows('青蟒传') && shows('蟒河往事'), 'search results from the Python site');
    await mark(tester, 'search');

    // 源: which Python the engine uses; the site that needs lxml says what it lacks.
    // The page is a lazily built list: scroll to what is further down before looking for it.
    await tester.tap(find.text('源').last);
    await until(tester, () => shows('引擎地址'), 'the 源 page');
    // The page's own list (text fields have scrollables of their own, sideways).
    final page = find
        .descendant(of: find.byType(SourcesPage), matching: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down))
        .first;
    await tester.scrollUntilVisible(find.byKey(const Key('python-settings')), 300, scrollable: page);
    await until(tester, () => find.byKey(const Key('python-found')).evaluate().isNotEmpty, 'the Python settings');
    await mark(tester, 'sources');
    final pkgSite = find.text('演示Python依赖站');
    await tester.scrollUntilVisible(pkgSite, 300, scrollable: page);
    await wait(tester, const Duration(milliseconds: 300));
    await tester.tap(pkgSite);
    await wait(tester, const Duration(seconds: 1));
    await tester.tap(find.text('首页').last);
    await until(tester, () => shows('缺少 Python 包「lxml」') || shows('依赖演示一'), 'the site that needs lxml');
    await mark(tester, 'missing-package');

    // Live: the Python live source lists its channels; the one behind getProxyUrl plays.
    await tester.tap(find.text('直播').last);
    await until(tester, () => find.byType(DropdownButton<int>).evaluate().isNotEmpty, 'the live sources');
    await tester.tap(find.byType(DropdownButton<int>).first);
    await wait(tester, const Duration(seconds: 1));
    await tester.tap(find.text('演示Python直播').last);
    await until(tester, () => shows('Python 直连台') && shows('Python 代理台') && shows('Python 协议台'), 'the Python channels');
    await tester.tap(find.text('Python 代理台').first);
    // The channel's name shows twice (list and now bar) once it is the one tuned to; playing once nothing is pending.
    await until(tester, () => find.text('Python 代理台').evaluate().length >= 2, 'the proxied channel in the now bar');
    await until(tester, () => !shows('正在打开') && !shows('无法播放') && !shows('没有画面'), 'the proxied channel to play', timeout: const Duration(seconds: 60));
    await mark(tester, 'live');
  });
}
