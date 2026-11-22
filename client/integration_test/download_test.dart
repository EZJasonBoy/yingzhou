// Downloading for offline viewing, in the real desktop app against the demo engine's slow source (《慢速源演示》):
//   engine: tvbox-engine --demo --dev-cors --port 19988
//   flutter test integration_test/download_test.dart -d windows --dart-define=ENGINE_URL=http://127.0.0.1:19988
//
// It downloads 「短片」 (two minutes of HLS) from the detail page, watching the episode's mark go from 排队中 through
// percentages to 已下载; then switches the slow source off (every segment and key answered with 503) and plays the
// download: it must start, seek to the end and back, and the source must see no request at all. Then it downloads
// 「短片加密」 with the source still off — that fails with the reason in 我的 → 下载 — switches the source on again and
// retries it from there. Every step prints "MARK:<step>"; SHOT_DIR saves screenshots.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/pages/seek_bar.dart';
import 'package:tvbox_client/player_backend.dart';
import 'package:tvbox_client/settings.dart';

const engineUrl = String.fromEnvironment('ENGINE_URL', defaultValue: 'http://127.0.0.1:19988');
const shotDir = String.fromEnvironment('SHOT_DIR');

/// Where 《慢速源演示》's episodes are in its one line.
const short = 5;
const shortAes = 6;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Player player;
  var playerMade = false;
  final clock = Stopwatch()..start();

  Future<T> real<T>(WidgetTester tester, Future<T> Function() action) async => (await tester.runAsync(action)) as T;

  Future<void> wait(WidgetTester tester, Duration d) async {
    final end = clock.elapsed + d;
    while (clock.elapsed < end) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
  }

  Future<void> until(WidgetTester tester, bool Function() done, String what, {Duration timeout = const Duration(seconds: 60)}) async {
    final end = clock.elapsed + timeout;
    while (!done()) {
      if (clock.elapsed > end) fail('timed out waiting for $what');
      await wait(tester, const Duration(milliseconds: 100));
    }
  }

  Future<String> http(String method, String path, [Object? body]) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, Uri.parse('$engineUrl$path'));
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      return await response.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }

  Future<List<Map<String, dynamic>>> downloads(WidgetTester tester) async =>
      ((jsonDecode(await real(tester, () => http('GET', '/api/v1/downloads'))) as Map<String, dynamic>)['items'] as List).cast<Map<String, dynamic>>();

  Future<List<Map<String, dynamic>>> sourceLog(WidgetTester tester) async =>
      ((jsonDecode(await real(tester, () => http('GET', '/demo/slow/log'))) as Map<String, dynamic>)['requests'] as List).cast<Map<String, dynamic>>();

  Future<void> shot(WidgetTester tester, String step) async {
    // ignore: avoid_print
    print('MARK:$step');
    if (shotDir.isEmpty) return;
    final element = find.byType(MaterialApp).evaluate().first;
    await tester.runAsync(() async {
      final image = await captureImage(element);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$shotDir/download-$step.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  /// The text of an episode's download mark on the detail page; null when it has none.
  String? mark(int episode) {
    final found = find.descendant(of: find.byKey(Key('download-mark-$episode')), matching: find.byType(Text)).evaluate();
    return found.isEmpty ? null : (found.first.widget as Text).data;
  }

  /// In the download sheet: picks only episode [only] (the sheet may begin with another one picked, or none).
  Future<void> pickOnly(WidgetTester tester, int only) async {
    for (var i = 0; find.byKey(Key('download-pick-$i')).evaluate().isNotEmpty; i++) {
      final chip = tester.widget<FilterChip>(find.byKey(Key('download-pick-$i')));
      if (chip.selected != (i == only)) {
        await tester.ensureVisible(find.byKey(Key('download-pick-$i')));
        await tester.tap(find.byKey(Key('download-pick-$i')));
        await wait(tester, const Duration(milliseconds: 200));
      }
    }
    expect(find.text('下载 1 集'), findsOneWidget);
  }

  testWidgets('download an episode, then play it with the source switched off', (tester) async {
    MediaKit.ensureInitialized();
    // A source quick enough for a test, and nothing left from an earlier run.
    await real(tester, () => http('GET', '/demo/slow/set?delayMs=100&connectMs=100&kBps=1500&totalKBps=0&cutAfter=0&refuse=0&reset=1'));
    for (final d in await downloads(tester)) {
      await real(tester, () => http('DELETE', '/api/v1/downloads/${d['id']}'));
    }
    // The detail page picks the episode watched last; a clean history makes that the first one.
    await real(tester, () => http('DELETE', '/api/v1/history'));
    addTearDown(() => http('GET', '/demo/slow/set?refuse=0&delayMs=400&connectMs=300&kBps=300'));

    final settings = MemorySettings();
    // These tests start from the site's recommendations, whatever an earlier one left in the history.
    await settings.setString('ui.startPage', 'home');
    await settings.setString('siteKey', 'demo');
    await tester.pumpWidget(
      TvboxApp(
        state: AppState(
          clientFactory: (url) => EngineClient(url),
          engineUrl: engineUrl,
          settings: settings,
          playerBackend: () {
            final backend = mediaKitBackend();
            player = backend.player;
            playerMade = true;
            return backend;
          },
        ),
      ),
    );
    await until(tester, () => find.text('星河往事 第二季').evaluate().isNotEmpty, 'the home page');
    final grid = find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('慢速源演示'), 300, scrollable: grid);
    await wait(tester, const Duration(milliseconds: 500));
    await tester.tap(find.text('慢速源演示').first);
    await until(tester, () => find.byKey(const Key('download-button')).evaluate().isNotEmpty, 'the detail page with its 下载 button');

    // 下载: the sheet starts with the first episode picked; 短片 instead.
    await tester.tap(find.byKey(const Key('download-button')));
    await wait(tester, const Duration(milliseconds: 600));
    expect(tester.widget<FilterChip>(find.byKey(const Key('download-pick-0'))).selected, isTrue);
    await pickOnly(tester, short);
    await shot(tester, 'sheet');
    await tester.tap(find.byKey(const Key('download-start')));
    await wait(tester, const Duration(milliseconds: 600));

    // The episode's mark: queued, then how far it is, then done.
    final seen = <String>{};
    await until(tester, () {
      final m = mark(short);
      if (m != null) seen.add(m);
      return m == '已下载';
    }, 'the download of 短片', timeout: const Duration(seconds: 120));
    // ignore: avoid_print
    print('MARKS:${jsonEncode(seen.toList())}');
    expect(seen.any((m) => m.endsWith('%')), isTrue, reason: 'progress shows while it downloads: $seen');
    final done = (await downloads(tester)).single;
    expect(done['state'], 'done');
    expect(done['parts'], 20);
    await shot(tester, 'downloaded');

    // The source goes away: every segment and key now gets 503.
    await real(tester, () => http('GET', '/demo/slow/set?refuse=503&reset=1'));
    await tester.ensureVisible(find.widgetWithText(OutlinedButton, '短片'));
    await tester.tap(find.widgetWithText(OutlinedButton, '短片'));
    await until(tester, () => playerMade && player.state.position > const Duration(seconds: 3), 'the download to play', timeout: const Duration(seconds: 30));
    expect(find.textContaining('离线播放（已下载）'), findsOneWidget);
    await shot(tester, 'playing-offline');

    // Anywhere in it: near the end, then back near the start.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(400, 300));
    Future<void> click(Duration position) async {
      final rect = tester.getRect(find.byKey(const Key('seek-bar')));
      final at = Offset(rect.left + SeekBar.inset + (rect.width - 2 * SeekBar.inset) * position.inMilliseconds / player.state.duration.inMilliseconds, rect.center.dy);
      await mouse.moveTo(const Offset(400, 300));
      await wait(tester, const Duration(milliseconds: 300));
      await mouse.moveTo(at);
      await wait(tester, const Duration(milliseconds: 300));
      await mouse.down(at);
      await tester.pump(const Duration(milliseconds: 60));
      await mouse.up();
      await tester.pump();
    }

    expect(player.state.duration, const Duration(minutes: 2));
    await click(const Duration(seconds: 105));
    await until(tester, () => player.state.position > const Duration(seconds: 106), 'playing near the end', timeout: const Duration(seconds: 15));
    await shot(tester, 'seeked-near-end');
    await click(const Duration(seconds: 20));
    await until(tester, () => player.state.position > const Duration(seconds: 21) && player.state.position < const Duration(seconds: 40), 'playing near the start', timeout: const Duration(seconds: 15));
    await mouse.removePointer();
    final asked = await sourceLog(tester);
    // ignore: avoid_print
    print('SOURCE-WHILE-OFFLINE:${jsonEncode(asked)}');
    expect(asked, isEmpty, reason: 'the download played without a single request to the source');

    // Back to the detail page; with the source still off, a second download fails, with the reason.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await wait(tester, const Duration(milliseconds: 500));
    if (find.byKey(const Key('download-button')).evaluate().isEmpty) {
      await tester.tap(find.byTooltip('返回 (Esc)'));
      await wait(tester, const Duration(milliseconds: 800));
    }
    await tester.tap(find.byKey(const Key('download-button')));
    await wait(tester, const Duration(milliseconds: 600));
    // 短片 was watched last: the sheet begins with it, but it is downloaded already, so nothing is picked.
    expect(tester.widget<FilterChip>(find.byKey(const Key('download-pick-$short'))).onSelected, isNull);
    await pickOnly(tester, shortAes);
    await tester.tap(find.byKey(const Key('download-start')));
    await until(tester, () => mark(shortAes) == '失败', 'the download to fail with the source off', timeout: const Duration(seconds: 90));
    final failed = (await downloads(tester)).firstWhere((d) => d['episodeName'] == '短片加密');
    expect(failed['error'] as String, contains('HTTP 503'));

    // 我的 → 下载: the failure and its reason; the source comes back, 重试 finishes it.
    await tester.pageBack();
    await wait(tester, const Duration(milliseconds: 800));
    await tester.tap(find.text('我的'));
    await wait(tester, const Duration(milliseconds: 800));
    await tester.tap(find.widgetWithText(Tab, '下载'));
    await wait(tester, const Duration(seconds: 1));
    expect(find.textContaining('失败：片源拒绝了'), findsOneWidget);
    await shot(tester, 'failed-in-list');
    await real(tester, () => http('GET', '/demo/slow/set?refuse=0&reset=1'));
    await tester.tap(find.byKey(Key('download-retry-${failed['id']}')));
    await until(tester, () => find.byKey(Key('download-play-${failed['id']}')).evaluate().isNotEmpty, 'the retried download', timeout: const Duration(seconds: 120));
    expect(find.textContaining('已下载 · '), findsNWidgets(2));
    await shot(tester, 'list-done');

    for (final d in await downloads(tester)) {
      await real(tester, () => http('DELETE', '/api/v1/downloads/${d['id']}'));
    }
  });
}
