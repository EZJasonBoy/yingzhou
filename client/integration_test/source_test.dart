// Recommendation sites, covers and source switching in the real desktop app, against the demo engine:
//   tvbox-engine --demo --port 19995 --data <scratch>
//   flutter test integration_test/source_test.dart -d windows --dart-define=ENGINE_URL=http://127.0.0.1:19995 [--dart-define=SHOT_DIR=<dir>]
//
// 演示豆瓣 is a recommendation site: its posters stand for titles (msearch: ids, one with no id) and its cover
// addresses carry a Douban Referer as a TVBox suffix; the demo answers 418 to a cover asked for without it and logs
// every hit. 演示失效站 has the demo's titles with every line dead. Nothing here needs a real subscription; the
// video is the demo's public HLS test stream.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/settings.dart';

const engineUrl = String.fromEnvironment('ENGINE_URL', defaultValue: 'http://127.0.0.1:19995');
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

  Future<void> mark(WidgetTester tester, String step) async {
    // ignore: avoid_print
    print('MARK:$step');
    await wait(tester, const Duration(seconds: 1));
    if (shotDir.isNotEmpty) {
      final element = find.byType(MaterialApp).evaluate().first;
      await tester.runAsync(() async {
        final image = await captureImage(element);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$shotDir/src-$step.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }
  }

  Duration? clock() {
    final texts = find.byType(Text).evaluate().map((e) => (e.widget as Text).data ?? '');
    final m = texts.map(RegExp(r'^(\d+):(\d\d) / \d+:\d\d').firstMatch).whereType<RegExpMatch>().firstOrNull;
    return m == null ? null : Duration(minutes: int.parse(m[1]!), seconds: int.parse(m[2]!));
  }

  Future<void> playing(WidgetTester tester) async {
    final end = DateTime.now().add(const Duration(seconds: 60));
    while ((clock() ?? Duration.zero) < const Duration(seconds: 2)) {
      if (DateTime.now().isAfter(end)) fail('playback did not start (clock: ${clock()})');
      await wait(tester, const Duration(milliseconds: 500));
    }
  }

  Future<Object?> engineJson(WidgetTester tester, String method, String path) => tester.runAsync<Object?>(() async {
        final client = HttpClient();
        try {
          final request = await client.openUrl(method, Uri.parse('$engineUrl$path'));
          final response = await request.close();
          final body = await response.transform(utf8.decoder).join();
          return body.isEmpty ? null : jsonDecode(body);
        } finally {
          client.close();
        }
      });

  final playButton = find.byWidgetPredicate((w) => w is Text && (w.data == '播放' || (w.data ?? '').startsWith('继续播放')));

  Future<void> start(WidgetTester tester, String site) async {
    MediaKit.ensureInitialized();
    final settings = MemorySettings();
    // These tests start from the site's recommendations, whatever an earlier one left in the history.
    await settings.setString('ui.startPage', 'home');
    await settings.setString('siteKey', site);
    await tester.pumpWidget(TvboxApp(state: AppState(clientFactory: (url) => EngineClient(url), engineUrl: engineUrl, settings: settings)));
  }

  testWidgets('a recommendation site: covers load with their Referer, and a poster opens a copy that plays', (tester) async {
    await engineJson(tester, 'DELETE', '/demo/douban/log');
    await start(tester, 'demo_douban');
    await until(tester, find.text('逆流长歌'));
    await wait(tester, const Duration(seconds: 5));
    final log = (await engineJson(tester, 'GET', '/demo/douban/log'))! as Map<String, dynamic>;
    // ignore: avoid_print
    print('POSTERS:${jsonEncode({'withReferer': log['withReferer'], 'withoutReferer': log['withoutReferer']})}');
    expect(log['withoutReferer'], 0, reason: 'every cover is asked for with the Referer its address carries');
    expect(log['withReferer'] as int, greaterThanOrEqualTo(8), reason: 'the covers on screen, the @Headers= one included');
    final statuses = {for (final h in log['hits'] as List<dynamic>) (h as Map<String, dynamic>)['status']};
    expect(statuses, {200}, reason: 'no cover was refused (418)');
    await mark(tester, 'douban-home');

    // 归途边境 is on 演示站 next to 「归途边境 第二季」: only the same title counts.
    await tester.tap(find.text('归途边境').first);
    await until(tester, playButton);
    expect(find.textContaining('来自 演示'), findsOneWidget, reason: 'opened on a site that has the title, not the recommendation site');
    expect(find.text('归途边境 第二季'), findsNothing);
    await mark(tester, 'douban-detail');

    await tester.tap(playButton.first);
    await playing(tester);
    // ignore: avoid_print
    print('SWITCHED:${find.textContaining('已换到').evaluate().isNotEmpty}');
    await mark(tester, 'douban-playing');
  });

  testWidgets('folder cards open the list inside them, level by level, down to a room that plays', (tester) async {
    await start(tester, 'demo_folder');
    await until(tester, find.text('平台甲'));
    expect(find.byKey(const Key('poster-folder')), findsWidgets, reason: 'the platforms are folders');
    await mark(tester, 'folder-home');

    await tester.tap(find.text('平台甲').first);
    await until(tester, find.text('分区一'));
    expect(find.byKey(const Key('folder-title')), findsOneWidget);
    await mark(tester, 'folder-platform');

    await tester.tap(find.text('分区一').first);
    await until(tester, find.text('一号房间'));
    await mark(tester, 'folder-area');

    await tester.tap(find.text('一号房间').first);
    await until(tester, playButton);
    await tester.tap(playButton.first);
    await playing(tester);
    await mark(tester, 'folder-playing');
  });

  testWidgets('a site whose lines are all dead: the player moves to another site and plays on', (tester) async {
    await start(tester, 'demo_dead');
    await until(tester, find.text('白昼迷踪 第二季'));
    await tester.tap(find.text('白昼迷踪 第二季').first);
    await until(tester, playButton);
    expect(find.text('来自 演示失效站'), findsOneWidget, reason: 'it has lines, so the detail stays on its site');
    await tester.tap(playButton.first);
    await until(tester, find.textContaining('已换到「'), timeout: const Duration(seconds: 60));
    await mark(tester, 'dead-switched');
    await playing(tester);
    await mark(tester, 'dead-playing');
  });
}
