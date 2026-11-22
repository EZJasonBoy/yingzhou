import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/diagnostics/dev_log.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/settings.dart';
import 'package:tvbox_client/ui/device_form.dart';
import 'package:tvbox_client/ui/user_mode.dart';

import 'fake_engine.dart';
import 'fake_player.dart';

/// Simple, standard and developer mode (ui/user_mode.dart): what each shows, the lock on 设置, and the first start.
void main() {
  late FakePlayer player;

  const watched = {
    'site': 'cms',
    'vodId': '7',
    'name': '片名',
    'line': '线路一',
    'episodeId': 'https://cdn.test/2.m3u8',
    'episodeName': '第2集',
    'episodeIndex': 1,
    'positionMs': 61000,
    'durationMs': 1200000,
  };

  setUp(() => DevLog.instance = DevLog());

  Future<SettingsStore> storeWith(UserMode? mode, {String? pin}) async {
    final store = MemorySettings();
    if (mode != null) await store.setString(UserModeController.key, mode.name);
    if (pin != null) await UserModeController(store).setPin(pin);
    return store;
  }

  Future<void> pumpApp(
    WidgetTester tester,
    SettingsStore store, {
    Size size = const Size(1400, 900),
    DeviceForm form = DeviceForm.desktop,
    List<Map<String, Object>> history = const [],
    List<Map<String, Object>>? lines,
    Set<String> deadLines = const {},
    bool ask = false,
    List<Map<String, Object>> extraSites = const [],
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    player = FakePlayer();
    final engine = fakeEngine(hasConfig: true, history: history, lines: lines, deadLines: deadLines, extraSites: extraSites);
    await tester.pumpWidget(
      DeviceFormScope.fixed(
        form,
        child: TvboxApp(
          key: UniqueKey(),
          askUserMode: ask,
          state: AppState(clientFactory: (url) => EngineClient(url, httpClient: engine), settings: store, playerBackend: () => player.backend()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Lets [time] go by, a frame every 100 ms (a playing page never settles).
  Future<void> pass(WidgetTester tester, Duration time) async {
    for (var t = Duration.zero; t < time; t += const Duration(milliseconds: 100)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// An entry of the navigation rail.
  Finder entry(String label) => find.descendant(of: find.byType(NavigationRail), matching: find.text(label));

  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('standard is what the app is until a mode is chosen', (tester) async {
    await pumpApp(tester, await storeWith(null));
    for (final e in ['首页', '直播', '搜索', '我的', '源', '网盘', '设置']) {
      expect(entry(e), findsOneWidget, reason: e);
    }
    expect(entry('日志'), findsNothing);
    expect(find.text('继续看'), findsOneWidget, reason: '继续看 is a tab of 首页 in every mode');
    expect(find.text('推荐片'), findsOneWidget, reason: 'nothing watched yet: the site\'s recommendations come first');
    expect(find.byKey(const Key('home-switcher')), findsOneWidget);
  });

  testWidgets('standard: 首页 opens on 继续看 once something was watched, and 继续播放 carries on there', (tester) async {
    await pumpApp(tester, await storeWith(null), history: [watched]);
    expect(find.text('第2集 · 还剩 19 分钟'), findsOneWidget);
    expect(find.byKey(const Key('home-switcher')), findsOneWidget, reason: 'the standard header stays');
    await tester.tap(find.byKey(const Key('simple-resume')));
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened, ['https://cdn.test/2.m3u8']);
    await leave(tester);
  });

  testWidgets('the app opens on what 设置 says: 站点推荐, 我的, or 继续看', (tester) async {
    Future<SettingsStore> starting(String page, [UserMode? mode]) async {
      final store = await storeWith(mode);
      await store.setString(UserModeController.startKey, page);
      return store;
    }

    await pumpApp(tester, await starting('home'), history: [watched]);
    expect(find.text('推荐片'), findsOneWidget, reason: 'the site\'s recommendations, although something was watched');
    expect(find.byKey(const Key('simple-resume')), findsNothing);
    expect(find.text('继续看'), findsOneWidget, reason: 'still a tab');

    await pumpApp(tester, await starting('library'), history: [watched]);
    expect(tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex, 3, reason: '我的 is the page showing');
    expect(find.byKey(const Key('simple-resume')), findsNothing);

    // Simple mode has no 我的: 继续看 stands in for it.
    await pumpApp(tester, await starting('library', UserMode.simple), history: [watched]);
    expect(tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex, 0);
    expect(find.byKey(const Key('simple-resume')), findsOneWidget);
  });

  testWidgets('设置 → 外观: what the app opens on is chosen there; simple mode is not offered 我的', (tester) async {
    final store = await storeWith(null);
    await pumpApp(tester, store);
    await tester.tap(entry('设置'));
    await tester.pumpAndSettle();
    final choice = find.byKey(const Key('start-page'));
    await tester.ensureVisible(choice);
    await tester.pumpAndSettle();
    expect(find.descendant(of: choice, matching: find.text('我的')), findsOneWidget);
    await tester.tap(find.descendant(of: choice, matching: find.text('站点推荐')));
    await tester.pumpAndSettle();
    expect(store.getString(UserModeController.startKey), 'home');
    expect(find.textContaining('下次打开映舟时生效'), findsOneWidget);

    await tester.tap(find.descendant(of: find.byKey(const Key('user-mode')), matching: find.text('简单')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const Key('start-page')), matching: find.text('我的')), findsNothing);
  });

  testWidgets('simple: three entries and 设置; 首页 opens on what was being watched, and 继续播放 carries on there', (tester) async {
    await pumpApp(tester, await storeWith(UserMode.simple), history: [watched]);
    for (final e in ['首页', '直播', '搜索', '设置']) {
      expect(entry(e), findsOneWidget, reason: e);
    }
    for (final e in ['我的', '源', '网盘', '日志']) {
      expect(entry(e), findsNothing, reason: e);
    }
    expect(find.byKey(const Key('home-switcher')), findsNothing, reason: 'one button instead of three menus');
    expect(find.byKey(const Key('home-source-panel')), findsOneWidget);
    expect(find.text('推荐'), findsOneWidget, reason: 'the site\'s recommendations are still a tab');
    expect(find.text('电影'), findsOneWidget, reason: 'and so are its categories');
    expect(find.text('第2集 · 还剩 19 分钟'), findsOneWidget);

    await tester.tap(find.byKey(const Key('simple-resume')));
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened, ['https://cdn.test/2.m3u8'], reason: 'straight into the episode, not the detail page');
    expect(player.seeks, contains(const Duration(seconds: 61)));

    // The player keeps speed, danmaku, subtitles and episodes; the developer's tools are not there.
    expect(find.byKey(const Key('tracks-button')), findsOneWidget);
    expect(find.text('选集'), findsOneWidget);
    expect(find.byKey(const Key('danmaku-button')), findsOneWidget);
    expect(find.byKey(const Key('danmaku-toggle')), findsOneWidget);
    expect(find.text('倍速'), findsOneWidget);
    expect(find.byKey(const Key('stats-button')), findsNothing);
    // One line only: nothing to choose, so the row is left out.
    await tester.tap(find.text('选集'));
    await tester.pump();
    expect(find.byType(ChoiceChip), findsNothing);
    await leave(tester);
  });

  testWidgets('simple: the lines are there to choose, by their numbers, on the detail page and in the player', (tester) async {
    await pumpApp(tester, await storeWith(UserMode.simple), lines: [fakeLine('超级无敌4k', 'a'), fakeLine('ikm3u8', 'b')]);
    await tester.tap(find.text('推荐片'));
    await tester.pumpAndSettle();
    expect(find.text('线路'), findsOneWidget);
    expect(find.text('线路 1'), findsOneWidget);
    expect(find.text('线路 2'), findsOneWidget);
    expect(find.textContaining('超级无敌4k'), findsNothing, reason: 'what the site calls its lines is not shown in simple mode');

    await tester.tap(find.byKey(const Key('detail-line-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('播放'));
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened, ['https://cdn.test/b/1.m3u8'], reason: 'the line chosen on the detail page plays');
    expect(find.text('线路 2'), findsOneWidget, reason: 'the bar says which line');

    // In the player: 选集 has the lines on top.
    await tester.tap(find.text('选集'));
    await tester.pump();
    expect(find.byKey(const Key('player-line-0')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('player-line-0')), matching: find.text('线路 1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('player-line-0')));
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened.last, 'https://cdn.test/a/1.m3u8', reason: 'the same episode on the line chosen');
    await leave(tester);
  });

  testWidgets('播放信息 is in every mode: plain words, the line, and the way to another line', (tester) async {
    await pumpApp(
      tester,
      await storeWith(UserMode.simple),
      lines: [fakeLine('超级无敌4k', 'a'), fakeLine('ikm3u8', 'b')],
      deadLines: {'超级无敌4k'},
    );
    await tester.tap(find.text('推荐片'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('播放'));
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened, ['https://cdn.test/b/1.m3u8'], reason: 'the first line is dead: the second plays');
    player.playTo(const Duration(minutes: 5));
    player.bufferTo(const Duration(minutes: 5, seconds: 28));
    await pass(tester, const Duration(milliseconds: 300));

    await tester.tap(find.byKey(const Key('info-button')));
    await pass(tester, const Duration(milliseconds: 1500));
    final info = find.byKey(const Key('play-info'));
    expect(info, findsOneWidget);
    expect(find.descendant(of: info, matching: find.text('很顺')), findsOneWidget);
    expect(find.descendant(of: info, matching: find.text('已缓冲 28 秒')), findsOneWidget);
    expect(find.descendant(of: info, matching: find.text('采集站')), findsOneWidget, reason: 'the site it comes from');
    expect(find.descendant(of: info, matching: find.textContaining('线路 2（共 2 条）')), findsOneWidget);
    expect(find.descendant(of: info, matching: find.text('这一集换过的线路')), findsOneWidget);
    expect(find.descendant(of: info, matching: find.textContaining('线路 1：')), findsOneWidget, reason: 'the line given up on, and why');
    expect(find.descendant(of: info, matching: find.textContaining('http')), findsNothing, reason: 'no addresses outside the developer mode');
    expect(find.byKey(const Key('play-info-stats')), findsNothing);
    expect(find.byKey(const Key('play-info-chain')), findsNothing);

    // The buffer running dry is said in words too.
    player.bufferTo(const Duration(minutes: 5, seconds: 1));
    await pass(tester, const Duration(milliseconds: 1500));
    expect(find.descendant(of: info, matching: find.text('快见底了，可能会卡')), findsOneWidget);

    // 换线路 leads to the lines.
    await tester.tap(find.byKey(const Key('play-info-lines')));
    await tester.pump();
    expect(info, findsNothing, reason: 'the episodes replace it');
    expect(find.byKey(const Key('player-line-0')), findsOneWidget);
    await leave(tester);
  });

  testWidgets('播放信息 in the developer mode leads on to the statistics and 链路', (tester) async {
    await pumpApp(tester, await storeWith(UserMode.developer), lines: [fakeLine('线路一', 'a'), fakeLine('线路二', 'b')]);
    await tester.tap(find.text('推荐片'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('播放'));
    await pass(tester, const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('info-button')));
    await pass(tester, const Duration(milliseconds: 300));
    final info = find.byKey(const Key('play-info'));
    expect(find.descendant(of: info, matching: find.textContaining('线路一（共 2 条）')), findsOneWidget, reason: 'the site\'s own names outside simple mode');
    await tester.tap(find.byKey(const Key('play-info-stats')));
    await pass(tester, const Duration(milliseconds: 300));
    expect(find.byKey(const Key('player-stats')), findsOneWidget);
    expect(find.text('收起完整统计'), findsOneWidget);
    await tester.tap(find.byKey(const Key('play-info-chain')));
    await pass(tester, const Duration(milliseconds: 300));
    expect(find.byKey(const Key('player-chain')), findsOneWidget);
    expect(info, findsNothing, reason: 'one panel at a time');
    await leave(tester);
  });

  testWidgets('simple: the site button opens the sources from the right; a site chosen there is browsed', (tester) async {
    await pumpApp(tester, await storeWith(UserMode.simple), extraSites: [
      {'key': 'cms2', 'name': '第二个采集站', 'type': 1, 'searchable': true, 'quickSearch': true, 'filterable': true, 'runtime': 'cms'},
    ]);
    await tester.tap(find.byKey(const Key('home-source-panel')));
    await tester.pumpAndSettle();
    final panel = find.byKey(const Key('source-panel'));
    expect(panel, findsOneWidget);
    expect(tester.getRect(panel).right, tester.view.physicalSize.width, reason: 'against the right edge');
    expect(find.descendant(of: panel, matching: find.text('选择站点')), findsOneWidget);
    await tester.tap(find.byKey(const Key('sheet-site-cms2')));
    await tester.pumpAndSettle();
    expect(panel, findsNothing, reason: 'choosing closes it');
    expect(find.descendant(of: find.byKey(const Key('home-source-panel')), matching: find.text('第二个采集站')), findsOneWidget);
  });

  testWidgets('simple: with nothing watched yet 首页 opens on the recommendations', (tester) async {
    await pumpApp(tester, await storeWith(UserMode.simple));
    expect(find.text('继续看'), findsOneWidget);
    expect(find.text('推荐片'), findsOneWidget);
    expect(find.byKey(const Key('simple-resume')), findsNothing);

    await tester.tap(find.text('推荐片'));
    await tester.pumpAndSettle();
    expect(find.text('线路'), findsNothing, reason: 'one line: nothing to choose from');
    expect(find.byKey(const Key('detail-refresh')), findsNothing);
    expect(find.widgetWithText(OutlinedButton, '第1集'), findsOneWidget);
  });

  testWidgets('simple: a line that fails is replaced with a plain sentence', (tester) async {
    await pumpApp(
      tester,
      await storeWith(UserMode.simple),
      lines: [fakeLine('线路一', 'a'), fakeLine('线路二', 'b')],
      deadLines: {'线路一'},
    );
    await tester.tap(find.text('推荐片'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('播放'));
    await pass(tester, const Duration(seconds: 1));
    expect(find.text('线路 1 打不开，已换到线路 2'), findsOneWidget);
    expect(player.opened, ['https://cdn.test/b/1.m3u8']);
    await leave(tester);
  });

  testWidgets('simple: 设置 leads to the subscriptions, and can be locked with four digits', (tester) async {
    final store = await storeWith(UserMode.simple, pin: '2580');
    await pumpApp(tester, store);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-lock')), findsOneWidget);
    expect(find.byKey(const Key('settings-list')), findsNothing);

    for (final d in [1, 1, 1, 1]) {
      await tester.tap(find.byKey(Key('pin-$d')));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pin-error')), findsOneWidget);
    expect(find.byKey(const Key('settings-list')), findsNothing);

    // Watching is never behind the lock.
    await tester.tap(entry('首页'));
    await tester.pumpAndSettle();
    expect(find.text('推荐片'), findsOneWidget);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    for (final d in [2, 5, 8, 0]) {
      await tester.tap(find.byKey(Key('pin-$d')));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-list')), findsOneWidget);
    expect(find.byKey(const Key('lock-change')), findsOneWidget);

    await tester.tap(find.byKey(const Key('open-sources')));
    await tester.pumpAndSettle();
    expect(find.text('订阅地址'), findsWidgets, reason: '源 as a page of its own');
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Leaving 设置 locks it again.
    await tester.tap(entry('首页'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-lock')), findsOneWidget);
  });

  testWidgets('the mode is changed in 设置 → 外观, and the entries follow at once', (tester) async {
    final store = await storeWith(null);
    await pumpApp(tester, store);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const Key('user-mode')), matching: find.text('开发者')));
    await tester.pumpAndSettle();
    expect(store.getString(UserModeController.key), 'developer');
    expect(find.text('日志'), findsWidgets);
    expect(find.byKey(const Key('open-log')), findsOneWidget);

    await tester.tap(find.descendant(of: find.byKey(const Key('user-mode')), matching: find.text('简单')));
    await tester.pumpAndSettle();
    expect(find.text('我的'), findsNothing);
    expect(find.byKey(const Key('lock-set')), findsOneWidget, reason: 'simple mode offers the lock');
    expect(find.byKey(const Key('settings-list')), findsOneWidget, reason: 'still on 设置');
  });

  testWidgets('the first start asks which way to use the app; later starts do not', (tester) async {
    final store = MemorySettings();
    await pumpApp(tester, store, ask: true);
    expect(find.text('选一种用法'), findsOneWidget);
    expect(find.text('首页'), findsNothing);
    await tester.tap(find.byKey(const Key('mode-developer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mode-start')));
    await tester.pumpAndSettle();
    expect(store.getString(UserModeController.key), 'developer');
    expect(entry('首页'), findsOneWidget);
    expect(entry('日志'), findsOneWidget);

    await pumpApp(tester, store, ask: true);
    expect(find.text('选一种用法'), findsNothing);

    // Someone who used the app before the modes existed keeps what they had.
    final old = MemorySettings();
    await old.setString('engineUrl', defaultEngineUrl);
    await pumpApp(tester, old, ask: true);
    expect(find.text('选一种用法'), findsNothing);
    expect(entry('我的'), findsOneWidget);
  });

  testWidgets('the first start on a TV: OK on a card picks it', (tester) async {
    final store = MemorySettings();
    await pumpApp(tester, store, ask: true, form: DeviceForm.tv, size: const Size(960, 540));
    expect(find.text('选一种用法'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(store.getString(UserModeController.key), 'standard', reason: 'one to the right of 简单');
    expect(find.text('选一种用法'), findsNothing);
  });

  testWidgets('developer: statistics over the picture, where the video comes from, and the log', (tester) async {
    await pumpApp(tester, await storeWith(UserMode.developer));
    expect(find.text('日志'), findsOneWidget);
    await tester.tap(find.text('推荐片'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('detail-dev-info')), findsOneWidget);
    await tester.tap(find.text('播放'));
    await pass(tester, const Duration(seconds: 1));

    expect(find.byKey(const Key('player-stats')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await pass(tester, const Duration(milliseconds: 300));
    expect(find.byKey(const Key('player-stats')), findsOneWidget);
    expect(find.byKey(const Key('player-stats-buffer')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.pump();
    expect(find.byKey(const Key('player-stats')), findsNothing);

    await tester.tap(find.byKey(const Key('chain-button')));
    await tester.pump();
    expect(find.byKey(const Key('player-chain')), findsOneWidget);
    expect(find.text('https://cdn.test/1.m3u8'), findsWidgets, reason: 'the address the player was given');
    expect(find.text('首帧'), findsOneWidget, reason: 'a picture has come');

    final lines = [for (final e in DevLog.instance.entries) '${e.module} ${e.message}'];
    expect(lines.any((l) => l.startsWith('解析 ') && l.contains('第1集')), isTrue, reason: '$lines');
    expect(lines.any((l) => l.contains('出画面')), isTrue, reason: '$lines');
    await leave(tester);
  });

  testWidgets('developer on a TV: the eighth entry fits (the column of entries scrolls) and opens 日志', (tester) async {
    await pumpApp(tester, await storeWith(UserMode.developer), form: DeviceForm.tv, size: const Size(960, 540));
    expect(find.byKey(const Key('tv-rail-7')), findsOneWidget);
    for (var i = 0; i < 7; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('log-copy')), findsOneWidget);
  });

  testWidgets('developer: 日志 lists what happened, newest first, and a line shows what belongs to it', (tester) async {
    DevLog.instance
      ..info('解析', '「线路一」第1集 → 直链 · 12 ms', detail: {'播放地址': 'https://cdn.test/1.m3u8'})
      ..warn('线路', '「线路一」无法播放：播放出错')
      ..error('播放器', '所有 2 条线路都试过了，都没能播放');
    await pumpApp(tester, await storeWith(UserMode.developer));
    await tester.tap(find.text('日志'));
    await tester.pumpAndSettle();
    final rows = find.descendant(of: find.byKey(const Key('log-list')), matching: find.textContaining('线路'));
    expect(rows, findsWidgets);
    final error = tester.getTopLeft(find.text('所有 2 条线路都试过了，都没能播放'));
    final info = tester.getTopLeft(find.text('「线路一」第1集 → 直链 · 12 ms'));
    expect(error.dy, lessThan(info.dy), reason: 'newest first');

    await tester.tap(find.byKey(const Key('log-level-error')));
    await tester.pumpAndSettle();
    expect(find.text('「线路一」第1集 → 直链 · 12 ms'), findsNothing);
    await tester.tap(find.byKey(const Key('log-level-all')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('「线路一」第1集 → 直链 · 12 ms'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const Key('log-detail')), matching: find.text('https://cdn.test/1.m3u8')), findsOneWidget);
  });
}
