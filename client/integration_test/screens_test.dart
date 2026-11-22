// Screen tour: the screens of the user modes, the settings layout and the episode list, drawn by the real app in
// each device form and saved as pictures for a design review. It needs no engine: the app talks to the tests' fake
// one, so posters are placeholders and the player shows no picture.
//
//   flutter test integration_test/screens_test.dart -d windows --dart-define=SHOT_DIR=<dir>
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/diagnostics/dev_log.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/settings.dart';
import 'package:tvbox_client/ui/device_form.dart';
import 'package:tvbox_client/ui/theme.dart';
import 'package:tvbox_client/ui/user_mode.dart';

import '../test/fake_engine.dart';
import '../test/fake_player.dart';

const shotDir = String.fromEnvironment('SHOT_DIR');

const desktop = (form: DeviceForm.desktop, size: Size(1440, 900), name: 'desktop');
const phone = (form: DeviceForm.phone, size: Size(393, 852), name: 'phone');
const tv = (form: DeviceForm.tv, size: Size(960, 540), name: 'tv');

typedef Device = ({DeviceForm form, Size size, String name});

Map<String, Object> line(String name, List<String> episodes) => {
  'name': name,
  'episodes': [
    for (var i = 0; i < episodes.length; i++) {'id': 'https://cdn.example.com/$name/$i.m3u8', 'name': episodes[i]},
  ],
};

const history = [
  {'site': 'cms', 'vodId': '7', 'name': '星河往事 第二季', 'line': '线路一', 'episodeId': 'https://cdn.test/2.m3u8', 'episodeName': '第2集', 'episodeIndex': 1, 'positionMs': 2530000, 'durationMs': 3270000},
  {'site': 'cms', 'vodId': '8', 'name': '山海长歌', 'line': '线路一', 'episodeId': 'x', 'episodeName': '第12集', 'episodeIndex': 11, 'positionMs': 600000, 'durationMs': 2700000},
  {'site': 'cms', 'vodId': '9', 'name': '纸船远航', 'line': '线路一', 'episodeId': 'y', 'episodeName': '20261113期', 'episodeIndex': 3, 'positionMs': 1200000, 'durationMs': 5400000},
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late FakePlayer player;

  Future<void> pause(WidgetTester tester, [Duration d = const Duration(milliseconds: 500)]) async {
    final end = DateTime.now().add(d);
    while (DateTime.now().isBefore(end)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump();
    }
  }

  Future<void> shot(WidgetTester tester, String name) async {
    await pause(tester);
    // ignore: avoid_print
    print('SHOT:$name');
    if (shotDir.isEmpty) return;
    RenderObject ro = find.byType(MaterialApp).evaluate().first.renderObject!;
    while (!ro.isRepaintBoundary) {
      ro = ro.parent!;
    }
    // ignore: invalid_use_of_protected_member
    final layer = ro.debugLayer! as OffsetLayer;
    await tester.runAsync(() async {
      final image = await layer.toImage(ro.paintBounds, pixelRatio: ro is RenderView ? 1 : 2);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory(shotDir).createSync(recursive: true);
      File('$shotDir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  Future<SettingsStore> start(
    WidgetTester tester,
    Device device, {
    UserMode? mode,
    String? pin,
    bool ask = false,
    bool light = false,
    List<Map<String, Object>> watched = const [],
    List<Map<String, Object>>? lines,
    Map<String, Map<String, Object>> details = const {},
    int extraSites = 0,
  }) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = device.size * 2;
    addTearDown(tester.view.reset);
    final settings = MemorySettings();
    if (mode != null) await settings.setString(UserModeController.key, mode.name);
    if (pin != null) await UserModeController(settings).setPin(pin);
    if (light) await settings.setString(ThemeChoice.key, 'light');
    player = FakePlayer();
    final engine = fakeEngine(
      hasConfig: true,
      history: watched,
      lines: lines,
      details: details,
      homeList: [
        for (final (i, n) in ['推荐片', '星垂平野', '山海长歌', '月面花园', '雾港来信', '纸船远航', '江上纪实', '大江东去'].indexed) {'site': 'cms', 'id': '${7 + i}', 'name': n, 'pic': '', 'remarks': i.isEven ? '更新至12集' : 'HD'},
      ],
      extraSites: [
        for (var i = 0; i < extraSites; i++) {'key': 'x$i', 'name': '示例站 ${i + 1}', 'type': i % 3 == 0 ? 3 : 1, 'searchable': i.isEven, 'quickSearch': true, 'filterable': true, 'runtime': i % 3 == 0 ? 'js' : 'cms'},
      ],
    );
    await tester.pumpWidget(
      DeviceFormScope.fixed(
        device.form,
        child: TvboxApp(
          key: UniqueKey(),
          askUserMode: ask,
          state: AppState(clientFactory: (url) => EngineClient(url, httpClient: engine), settings: settings, playerBackend: () => player.backend()),
        ),
      ),
    );
    await pause(tester, const Duration(seconds: 1));
    return settings;
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.tap(find.text(text).first);
    await pause(tester);
  }

  for (final device in [desktop, phone, tv]) {
    testWidgets('first start: 选一种用法 (${device.name})', (tester) async {
      await start(tester, device, ask: true, light: device == phone);
      await shot(tester, 'mode-chooser-${device.name}');
    });

    testWidgets('simple: 首页 with something watched (${device.name})', (tester) async {
      await start(tester, device, mode: UserMode.simple, watched: history, light: device == phone);
      await shot(tester, 'simple-home-${device.name}');
    });

    testWidgets('设置 (${device.name})', (tester) async {
      await start(tester, device, mode: UserMode.developer);
      if (device == phone) {
        await tapText(tester, '我的');
        await tester.tap(find.byKey(const Key('open-settings')));
        await pause(tester);
      } else if (device == tv) {
        for (var i = 0; i < 6; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump();
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await pause(tester);
        await shot(tester, 'settings-tv-entered');
        for (var i = 0; i < 3; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await pause(tester, const Duration(milliseconds: 300));
        }
      } else {
        await tapText(tester, '设置');
      }
      await shot(tester, 'settings-${device.name}');
    });

    testWidgets('源 with many sites (${device.name})', (tester) async {
      await start(tester, device, extraSites: 22);
      if (device == tv) {
        for (var i = 0; i < 4; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump();
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await pause(tester);
      } else {
        await tapText(tester, '源');
      }
      await shot(tester, 'sources-${device.name}');
    });

    testWidgets('选集 with long titles (${device.name})', (tester) async {
      await start(
        tester,
        device,
        light: device == phone,
        lines: [
          line('超清', ['第1期：先导片 六位朋友再次出发', '第2期：雪山脚下的第一夜', '第3期：迷路也是旅行的一部分', '20261113抢鲜版：下期预告与未播片段', '第4期：湖边的长谈', '20261120加更版：没播出的那些事']),
          line('蓝光', ['1', '2', '3', '4', '5', '6']),
        ],
      );
      if (device != tv) {
        await tapText(tester, '推荐片');
        await pause(tester);
        final page = find.byType(Scrollable).last;
        await tester.scrollUntilVisible(find.text('第4期：湖边的长谈'), 200, scrollable: page);
      } else {
        // → into the posters, OK opens the first; then down to the episodes.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await pause(tester, const Duration(milliseconds: 300));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await pause(tester);
        for (var i = 0; i < 3; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await pause(tester, const Duration(milliseconds: 300));
        }
      }
      await shot(tester, 'episodes-long-${device.name}');
    });
  }

  testWidgets('选集: a site that only numbers a dated show (desktop)', (tester) async {
    await start(
      tester,
      desktop,
      details: {
        'cms/7': {
          'site': 'cms',
          'id': '7',
          'name': '后会友期',
          'year': '2026',
          'area': '内地',
          'remarks': '更新至20261120加更版',
          'content': '延续真实生活的叙事。',
          'lines': [line('超级无敌4k', [for (var i = 1; i <= 18; i++) '$i']), line('高清4k', [for (var i = 1; i <= 18; i++) '$i'])],
        },
      },
    );
    await tapText(tester, '推荐片');
    await shot(tester, 'episodes-numbers-desktop');
  });

  testWidgets('simple: 设置 behind the lock (phone)', (tester) async {
    await start(tester, phone, mode: UserMode.simple, pin: '2580', light: true);
    await tapText(tester, '设置');
    await tester.tap(find.byKey(const Key('pin-2')));
    await tester.tap(find.byKey(const Key('pin-5')));
    await shot(tester, 'simple-lock-phone');
  });

  testWidgets('simple: the player keeps few buttons (desktop)', (tester) async {
    await start(tester, desktop, mode: UserMode.simple, watched: history);
    await tester.tap(find.byKey(const Key('simple-resume')));
    await pause(tester, const Duration(seconds: 1));
    await shot(tester, 'simple-player-desktop');
    await tester.pumpWidget(const SizedBox());
    await pause(tester);
  });

  testWidgets('developer: statistics and 链路 in the player, and 日志 (desktop)', (tester) async {
    DevLog.instance = DevLog();
    await start(tester, desktop, mode: UserMode.developer, lines: [line('线路一', ['第1集', '第2集']), line('线路二', ['第1集', '第2集'])]);
    await tapText(tester, '推荐片');
    await shot(tester, 'developer-detail-desktop');
    await tapText(tester, '播放');
    await pause(tester, const Duration(seconds: 1));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.tap(find.byKey(const Key('chain-button')));
    await pause(tester, const Duration(seconds: 2));
    await shot(tester, 'developer-player-desktop');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pause(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pause(tester);
    await tester.pageBack();
    await pause(tester);
    DevLog.instance
      ..warn('线路', '「线路一」无法播放：播放出错', detail: {'选集地址': 'https://line1.example.com/vod/e03.m3u8'})
      ..info('线路', '换到「线路二」，从 42:10 接着播');
    await tapText(tester, '日志');
    await tester.tap(find.textContaining('无法播放').first);
    await shot(tester, 'developer-log-desktop');
  });
}
