// Flow storyboards: a user task walked through the real app, one screenshot per action, every key press and tap
// counted. tools/design/storyboard.mjs turns the result into a page with a Mermaid diagram and a film strip.
//
//   tvbox-engine --demo --port 19978          (.claude/launch.json "demo-engine")
//   flutter test integration_test/flows_test.dart -d windows --dart-define=FLOW_DIR=<dir>
//   node tools/design/storyboard.mjs <dir>
//
// A flow is written as the user would do it: `press` a key, `tap` something, `type` text; `waitFor` is the app's
// time, not the user's, and is shown but not counted. Each action names the screen it leads to, which becomes a node
// in the diagram. Add a flow by copying one of the tests below; keep them short (one task each).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/settings.dart';
import 'package:tvbox_client/ui/device_form.dart';
import 'package:tvbox_client/ui/poster.dart';

const engineUrl = String.fromEnvironment('ENGINE_URL', defaultValue: 'http://127.0.0.1:19978');
const flowDir = String.fromEnvironment('FLOW_DIR');
const siteKey = String.fromEnvironment('SITE_KEY', defaultValue: 'demo');

/// Records one flow: the actions, the screens they lead to, how long the app took, and a screenshot of each.
class FlowRecorder {
  FlowRecorder(this.tester, {required this.id, required this.title, required this.form, required this.size, this.pixelRatio = 2});

  final WidgetTester tester;
  final String id;
  final String title;
  final DeviceForm form;
  final Size size;
  final double pixelRatio;
  final _steps = <Map<String, Object?>>[];
  final _clock = Stopwatch();

  Future<void> pause(Duration d) async {
    final end = DateTime.now().add(d);
    while (DateTime.now().isBefore(end)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump();
    }
  }

  /// Lays the app out as this flow's device and starts it on the demo site.
  Future<void> start({Map<String, String> prefs = const {}, required Finder ready, required String screen}) async {
    MediaKit.ensureInitialized();
    tester.view.devicePixelRatio = pixelRatio;
    tester.view.physicalSize = size * pixelRatio;
    addTearDown(tester.view.reset);
    final settings = MemorySettings();
    // These tests start from the site's recommendations, whatever an earlier one left in the history.
    await settings.setString('ui.startPage', 'home');
    await settings.setString('siteKey', siteKey);
    for (final e in prefs.entries) {
      await settings.setString(e.key, e.value);
    }
    final state = AppState(clientFactory: (url) => EngineClient(url), engineUrl: engineUrl, settings: settings);
    await tester.pumpWidget(DeviceFormScope.fixed(form, child: TvboxApp(state: state)));
    _clock.start();
    await waitFor(ready, label: '启动', screen: screen);
  }

  Future<void> press(LogicalKeyboardKey key, {required String screen, String? label}) async {
    await tester.sendKeyEvent(key);
    await _record('key', label ?? _keyName(key), screen, settle: const Duration(milliseconds: 450));
  }

  Future<void> tap(Finder target, {required String label, required String screen}) async {
    await tester.tap(target.first);
    await _record('tap', label, screen, settle: const Duration(milliseconds: 600));
  }

  Future<void> type(String text, {required String screen, bool submit = true}) async {
    await tester.enterText(find.byType(EditableText).first, text);
    if (submit) await tester.testTextInput.receiveAction(TextInputAction.search);
    await _record('type', '输入「$text」${submit ? '并确认' : ''}', screen, settle: const Duration(milliseconds: 600));
  }

  /// Moves the mouse to [at] (desktop): some controls only show once the pointer moves.
  Future<void> hover(Offset at, {required String label, required String screen}) async {
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: at - const Offset(20, 20));
    await mouse.moveTo(at);
    await tester.pump();
    await _record('move', label, screen, settle: const Duration(milliseconds: 300));
    await mouse.removePointer();
  }

  /// The app's turn: waits until [finder] shows, records how long it took. With [optional] a timeout is written into
  /// the step instead of failing the flow.
  Future<void> waitFor(Finder finder, {required String label, required String screen, Duration timeout = const Duration(seconds: 40), bool optional = false}) async {
    final started = _clock.elapsedMilliseconds;
    final end = DateTime.now().add(timeout);
    var seen = true;
    while (finder.evaluate().isEmpty) {
      if (DateTime.now().isAfter(end)) {
        if (!optional) fail('$id: timed out waiting for $finder ($label)');
        seen = false;
        break;
      }
      await pause(const Duration(milliseconds: 150));
    }
    await _record('wait', seen ? label : '$label（${timeout.inSeconds} 秒内没等到）', screen, settle: const Duration(milliseconds: 900), waited: _clock.elapsedMilliseconds - started);
  }

  Future<void> _record(String kind, String label, String screen, {required Duration settle, int? waited}) async {
    await pause(settle);
    final n = _steps.length;
    final image = '${n.toString().padLeft(2, '0')}.png';
    // ignore: avoid_print
    print('FLOW:$id:$n:$kind:$label');
    if (flowDir.isNotEmpty) await _shot(image);
    _steps.add({'n': n, 'kind': kind, 'label': label, 'screen': screen, 'image': flowDir.isEmpty ? null : image, 'waitedMs': ?waited});
  }

  Future<void> _shot(String name) async {
    RenderObject ro = find.byType(MaterialApp).evaluate().first.renderObject!;
    while (!ro.isRepaintBoundary) {
      ro = ro.parent!;
    }
    // ignore: invalid_use_of_protected_member
    final layer = ro.debugLayer! as OffsetLayer;
    await tester.runAsync(() async {
      final image = await layer.toImage(ro.paintBounds, pixelRatio: ro is RenderView ? 1 : pixelRatio);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = Directory('$flowDir/$id')..createSync(recursive: true);
      File('${dir.path}/$name').writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  /// Writes flow.json next to the screenshots.
  void finish({String? note}) {
    final counts = <String, int>{};
    for (final s in _steps) {
      counts.update(s['kind']! as String, (v) => v + 1, ifAbsent: () => 1);
    }
    final waited = _steps.fold<int>(0, (sum, s) => sum + ((s['waitedMs'] as int?) ?? 0));
    final json = {
      'id': id,
      'title': title,
      'form': form.name,
      'size': [size.width, size.height],
      'note': ?note,
      'actions': (counts['key'] ?? 0) + (counts['tap'] ?? 0) + (counts['type'] ?? 0) + (counts['move'] ?? 0),
      'counts': counts,
      'waitedMs': waited,
      'steps': _steps,
    };
    // ignore: avoid_print
    print('FLOW_DONE:$id:${json['actions']} actions');
    if (flowDir.isEmpty) return;
    final dir = Directory('$flowDir/$id')..createSync(recursive: true);
    File('${dir.path}/flow.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
  }

  static String _keyName(LogicalKeyboardKey key) => switch (key) {
    LogicalKeyboardKey.arrowLeft => '←',
    LogicalKeyboardKey.arrowRight => '→',
    LogicalKeyboardKey.arrowUp => '↑',
    LogicalKeyboardKey.arrowDown => '↓',
    LogicalKeyboardKey.enter => 'OK',
    LogicalKeyboardKey.escape => '返回',
    _ => key.keyLabel,
  };
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const title = '星河往事 第二季';
  final playButton = find.byWidgetPredicate((w) => w is Text && (w.data == '播放' || (w.data ?? '').startsWith('继续播放')));
  final clock = find.byWidgetPredicate((w) => w is Text && RegExp(r'^0?0:0[2-9] / ').hasMatch(w.data ?? ''));

  testWidgets('电视：从首页打开一部片并播放', (tester) async {
    final f = FlowRecorder(tester, id: 'tv-play', title: '电视：从首页打开一部片并播放', form: DeviceForm.tv, size: const Size(960, 540));
    await f.start(ready: find.text(title), screen: '首页');
    await f.press(LogicalKeyboardKey.arrowRight, screen: '首页 · 焦点进入内容区');
    await f.press(LogicalKeyboardKey.arrowDown, screen: '首页 · 焦点下移');
    await f.press(LogicalKeyboardKey.arrowRight, screen: '首页 · 选中一张海报');
    await f.press(LogicalKeyboardKey.enter, screen: '详情');
    await f.waitFor(playButton, label: '详情加载', screen: '详情');
    await f.press(LogicalKeyboardKey.enter, screen: '播放');
    // The TV player hides its clock with the controls; a short wait stands in when it never shows.
    await f.waitFor(clock, label: '开始出画面', screen: '播放', timeout: const Duration(seconds: 12), optional: true);
    f.finish(note: '遥控器上的每一下都算一步；等待是应用的时间，不算步数。');
  });

  testWidgets('手机：搜索并播放', (tester) async {
    final f = FlowRecorder(tester, id: 'phone-search', title: '手机：搜索一部片并播放', form: DeviceForm.phone, size: const Size(393, 852), pixelRatio: 3);
    await f.start(ready: find.text(title), screen: '首页');
    await f.tap(find.text('搜索'), label: '点底栏「搜索」', screen: '搜索');
    await f.type('星河往事', screen: '搜索结果');
    // hitTestable: the home page underneath has the same titles.
    final result = find.byType(PosterCard).hitTestable();
    await f.waitFor(find.textContaining('搜索完成'), label: '各站点结果到齐', screen: '搜索结果');
    // The first row comes from 演示失效站, whose lines are dead: a user who knows filters to a working site first.
    await f.tap(find.textContaining('演示站 '), label: '筛到「演示站」（前排结果来自失效站）', screen: '搜索结果 · 演示站');
    await f.tap(result, label: '点第一张海报', screen: '详情');
    await f.waitFor(playButton, label: '详情加载', screen: '详情');
    await f.tap(playButton, label: '点「播放」', screen: '播放');
    await f.waitFor(clock, label: '开始出画面', screen: '播放');
    f.finish();
  });

  testWidgets('桌面：播放中换一条线路', (tester) async {
    final f = FlowRecorder(tester, id: 'desktop-line', title: '桌面：播放中换一条线路', form: DeviceForm.desktop, size: const Size(1440, 900));
    await f.start(ready: find.text(title), screen: '首页');
    await f.tap(find.text(title), label: '点海报', screen: '详情');
    await f.waitFor(playButton, label: '详情加载', screen: '详情');
    await f.tap(playButton, label: '点「播放」', screen: '播放');
    await f.waitFor(clock, label: '开始出画面', screen: '播放');
    await f.hover(const Offset(720, 480), label: '移动鼠标（唤出控制条）', screen: '播放 · 控制条');
    await f.tap(find.text('选集'), label: '点「选集」', screen: '播放 · 选集面板');
    await f.tap(find.text('需解析线路'), label: '点「需解析线路」', screen: '播放 · 换线中');
    await f.waitFor(clock, label: '新线路出画面', screen: '播放');
    f.finish();
  });
}
