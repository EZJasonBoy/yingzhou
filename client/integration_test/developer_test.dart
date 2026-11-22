// Developer mode in the real desktop app, on a real video from the demo engine: the statistics over the picture are
// libmpv's own, 链路 names the address the player was given, 播放信息 says the same in plain words, and the log has
// the steps.
//   engine: tvbox-engine --demo --port 19978
//   flutter test integration_test/developer_test.dart -d windows [--dart-define=SHOT_DIR=<dir>]
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/diagnostics/dev_log.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/settings.dart';
import 'package:tvbox_client/ui/user_mode.dart';

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

  Future<void> until(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 40)}) async {
    final end = DateTime.now().add(timeout);
    while (finder.evaluate().isEmpty) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting for $finder');
      await wait(tester, const Duration(milliseconds: 200));
    }
  }

  Future<void> shot(WidgetTester tester, String name) async {
    if (shotDir.isEmpty) return;
    RenderObject ro = find.byType(MaterialApp).evaluate().first.renderObject!;
    while (!ro.isRepaintBoundary) {
      ro = ro.parent!;
    }
    // ignore: invalid_use_of_protected_member
    final layer = ro.debugLayer! as OffsetLayer;
    await tester.runAsync(() async {
      final image = await layer.toImage(ro.paintBounds, pixelRatio: 1);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory(shotDir).createSync(recursive: true);
      File('$shotDir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  List<String> textsIn(Finder scope) => [
    for (final e in find.descendant(of: scope, matching: find.byType(Text)).evaluate()) (e.widget as Text).data ?? '',
  ];

  Duration? clock() {
    final texts = find.byType(Text).evaluate().map((e) => (e.widget as Text).data ?? '');
    final m = texts.map(RegExp(r'^(\d+):(\d\d) / \d+:\d\d').firstMatch).whereType<RegExpMatch>().firstOrNull;
    return m == null ? null : Duration(minutes: int.parse(m[1]!), seconds: int.parse(m[2]!));
  }

  testWidgets('developer mode on a real video: statistics from libmpv, 链路, and the log', (tester) async {
    MediaKit.ensureInitialized();
    DevLog.instance = DevLog();
    final settings = MemorySettings();
    // These tests start from the site's recommendations, whatever an earlier one left in the history.
    await settings.setString('ui.startPage', 'home');
    await settings.setString('siteKey', 'demo');
    await settings.setString(UserModeController.key, UserMode.developer.name);
    await tester.pumpWidget(TvboxApp(state: AppState(clientFactory: (url) => EngineClient(url), engineUrl: engineUrl, settings: settings)));
    await until(tester, find.text('星河往事 第二季'));
    await tester.tap(find.text('星河往事 第二季').first);
    // "播放", or "继续播放 …" when an earlier run left history in the engine.
    final playButton = find.byWidgetPredicate((w) => w is Text && (w.data == '播放' || (w.data ?? '').startsWith('继续播放')));
    await until(tester, playButton);
    expect(find.byKey(const Key('detail-dev-info')), findsOneWidget);
    await tester.tap(playButton.first);
    final end = DateTime.now().add(const Duration(seconds: 40));
    while ((clock() ?? Duration.zero) < const Duration(seconds: 2)) {
      if (DateTime.now().isAfter(end)) fail('playback did not start (clock: ${clock()})');
      await wait(tester, const Duration(milliseconds: 500));
    }

    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await wait(tester, const Duration(seconds: 3));
    final stats = find.byKey(const Key('player-stats'));
    expect(stats, findsOneWidget);
    final rows = textsIn(stats);
    // ignore: avoid_print
    print('STATS:${rows.join(' | ')}');
    expect(rows, contains('视频'), reason: 'libmpv answered');
    expect(rows, contains('解码'));
    expect(rows.any((t) => t.contains('×') && t.contains('fps')), isTrue, reason: 'resolution and frame rate: $rows');
    expect(rows, isNot(contains('这个播放器不提供解码和输出的统计')));
    await shot(tester, 'developer-stats-real');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp); // any key brings the controls back
    await wait(tester, const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('chain-button')));
    await wait(tester, const Duration(seconds: 1));
    final chain = find.byKey(const Key('player-chain'));
    expect(chain, findsOneWidget);
    final url = tester.widget<SelectableText>(find.byKey(const Key('chain-url'))).data ?? '';
    // ignore: avoid_print
    print('CHAIN:${textsIn(chain).join(' | ')} | url=$url');
    expect(url, startsWith('http'));
    expect(find.descendant(of: chain, matching: find.text('首帧')), findsOneWidget, reason: 'the first picture was timed');
    await shot(tester, 'developer-chain-real');

    final lines = [for (final e in DevLog.instance.entries) e.line];
    // ignore: avoid_print
    print('LOG:\n${lines.join('\n')}');
    expect(lines.any((l) => l.contains(' 解析 ')), isTrue);
    expect(lines.any((l) => l.contains('出画面')), isTrue);

    // 播放信息, the plain-words panel every mode has: on a real video its picture, speed and decoder are libmpv's.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape); // closes 链路
    await wait(tester, const Duration(milliseconds: 300));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp); // the controls again
    await wait(tester, const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('info-button')));
    await wait(tester, const Duration(seconds: 3));
    final info = find.byKey(const Key('play-info'));
    expect(info, findsOneWidget);
    expect(chain, findsNothing, reason: 'one panel at a time');
    final said = textsIn(info);
    // ignore: avoid_print
    print('INFO:${said.join(' | ')}');
    expect(said.any((t) => RegExp(r'^(4K|2K|\d+p)（\d+×\d+）').hasMatch(t)), isTrue, reason: 'the picture in words, from libmpv: $said');
    expect(said, contains('解码'));
    expect(said.any((t) => t.startsWith('已缓冲 ')), isTrue);
    expect(said.any((t) => t.contains('http')), isFalse, reason: 'no addresses in 播放信息');
    await shot(tester, 'play-info-real');

    // Esc closes the panel, then leaves the player: back on the detail page.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await wait(tester, const Duration(milliseconds: 300));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await until(tester, find.byKey(const Key('detail-dev-info')));
  });
}
