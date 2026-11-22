// Seeking in a slow stream, measured in the real desktop app against the demo engine's slow source
// (《慢速源演示》, served under /demo/slow with a delay per request and a bandwidth cap):
//   engine: tvbox-engine --demo --dev-cors --port 19978
//   flutter test integration_test/seek_test.dart -d windows --dart-define=ENGINE_URL=http://127.0.0.1:19978
//
// The first test plays the first minute of the HLS episode, then clicks on the seek bar: forward into what was read
// ahead, back into what was played, to two places nothing was fetched from, back to the first of them, and to the
// very beginning; in between it drags the bar. For each seek it prints a line "SEEK:{json}" with the time from the
// click until the first picture and until playback runs again, and the requests the slow source saw meanwhile. It
// also prints the memory of the app and of the engine ("MEMORY:{json}"). The second test plays the same film as one
// file (a direct link, which the engine does not cache) and seeks inside what the player itself has kept.
//
// --dart-define=SEEK_STRICT=false only reports (used to measure a build without the stream cache);
// SLOW_DELAY_MS / SLOW_CONNECT_MS / SLOW_KBPS / SLOW_TOTAL_KBPS change how poor the source is; SHOT_DIR saves
// screenshots and the results (seek-results.json).
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

const engineUrl = String.fromEnvironment('ENGINE_URL', defaultValue: 'http://127.0.0.1:19978');
const shotDir = String.fromEnvironment('SHOT_DIR');
const strict = bool.fromEnvironment('SEEK_STRICT', defaultValue: true);
const delayMs = int.fromEnvironment('SLOW_DELAY_MS', defaultValue: 400);
const connectMs = int.fromEnvironment('SLOW_CONNECT_MS', defaultValue: 300);
const kBps = int.fromEnvironment('SLOW_KBPS', defaultValue: 500);
const totalKBps = int.fromEnvironment('SLOW_TOTAL_KBPS', defaultValue: 0);

/// SEEK_CACHE=false switches the engine's stream cache off for the run (and on again after it), to see what it is worth.
const streamCache = bool.fromEnvironment('SEEK_CACHE', defaultValue: true);

/// Seconds per segment of the slow source.
const segmentSeconds = 6;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Player player;
  var playerMade = false;
  final clock = Stopwatch()..start();

  /// When libmpv said it was seeking (true) or showing pictures again (false), on [clock].
  final seekingEvents = <(int, bool)>[];
  final results = <Map<String, Object?>>[];

  Future<T> real<T>(WidgetTester tester, Future<T> Function() action) async => (await tester.runAsync(action)) as T;

  Future<void> wait(WidgetTester tester, Duration d) async {
    final end = clock.elapsed + d;
    while (clock.elapsed < end) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
  }

  Future<void> until(WidgetTester tester, bool Function() done, String what, {Duration timeout = const Duration(seconds: 40)}) async {
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

  /// The requests the slow source has seen.
  Future<List<Map<String, dynamic>>> origin(WidgetTester tester) async =>
      ((jsonDecode(await real(tester, () => http('GET', '/demo/slow/log'))) as Map<String, dynamic>)['requests'] as List).cast<Map<String, dynamic>>();

  /// A property of libmpv; empty before the player page has made its player.
  Future<String> mpv(WidgetTester tester, String property) async =>
      playerMade ? await real(tester, () => (player.platform as NativePlayer).getProperty(property)) : '';

  Future<Map<String, dynamic>> cacheState(WidgetTester tester) async {
    try {
      return jsonDecode(await mpv(tester, 'demuxer-cache-state')) as Map<String, dynamic>;
    } catch (_) {
      return const {};
    }
  }

  /// What libmpv holds, in seconds of the film: "0.0-95.2 1200.0-1230.5".
  Future<String> cached(WidgetTester tester) async {
    final ranges = (await cacheState(tester))['seekable-ranges'] as List? ?? const [];
    return [for (final r in ranges.cast<Map<String, dynamic>>()) '${(r['start'] as num).toStringAsFixed(1)}-${(r['end'] as num).toStringAsFixed(1)}'].join(' ');
  }

  /// Working set and private bytes, in MB, of this app and of the engine it talks to, and what libmpv holds.
  Future<Map<String, Object?>> memory(WidgetTester tester, String step) async {
    final port = Uri.parse(engineUrl).port;
    final script =
        '\$e=(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1).OwningProcess;'
        'foreach(\$i in @($pid,\$e)){ \$p=Get-Process -Id \$i -ErrorAction SilentlyContinue; if(\$p){ "{0} {1} {2}" -f \$i,[int](\$p.WorkingSet64/1MB),[int](\$p.PrivateMemorySize64/1MB) } }';
    final out = await real(tester, () => Process.run('powershell', ['-NoProfile', '-Command', script]));
    final lines = (out.stdout as String).trim().split(RegExp(r'\s*\n\s*')).map((l) => l.split(' ')).where((l) => l.length == 3).toList();
    final state = await cacheState(tester);
    String? mb(Object? bytes) => bytes == null ? null : ((bytes as num) / (1024 * 1024)).toStringAsFixed(1);
    final sample = <String, Object?>{
      'step': step,
      'atS': clock.elapsed.inSeconds,
      if (lines.isNotEmpty) 'appWorkingSetMB': int.parse(lines[0][1]),
      if (lines.isNotEmpty) 'appPrivateMB': int.parse(lines[0][2]),
      if (lines.length > 1) 'engineWorkingSetMB': int.parse(lines[1][1]),
      if (lines.length > 1) 'enginePrivateMB': int.parse(lines[1][2]),
      'mpvCache': await cached(tester),
      'mpvCacheMB': mb(state['total-bytes']),
      'mpvCacheFileMB': mb(state['file-cache-bytes']),
    };
    // ignore: avoid_print
    print('MEMORY:${jsonEncode(sample)}');
    results.add({'kind': 'memory', ...sample});
    return sample;
  }

  Future<void> shot(WidgetTester tester, String step) async {
    // ignore: avoid_print
    print('MARK:$step');
    if (shotDir.isEmpty) return;
    final element = find.byType(MaterialApp).evaluate().first;
    await tester.runAsync(() async {
      final image = await captureImage(element);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$shotDir/seek-$step.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  /// The point on the seek bar that stands for [position].
  Offset onBar(WidgetTester tester, Duration position) {
    final rect = tester.getRect(find.byKey(const Key('seek-bar')));
    final fraction = position.inMilliseconds / player.state.duration.inMilliseconds;
    return Offset(rect.left + SeekBar.inset + (rect.width - 2 * SeekBar.inset) * fraction, rect.center.dy);
  }

  /// Does [act] — a click or a drag on the seek bar that ends in a seek to about [expected] — and watches the player
  /// until it plays again. [act] answers the moment to count from: the click, or the end of the drag.
  Future<Map<String, Object?>> measure(WidgetTester tester, String name, Duration expected, Future<int> Function() act) async {
    final cacheBefore = await cached(tester);
    final seenBefore = (await origin(tester)).fold<int>(0, (m, r) => r['id'] as int > m ? r['id'] as int : m);
    final from = player.state.position;
    final started = clock.elapsedMicroseconds;
    final acted = await act();

    // libmpv reports the place it is going to as soon as it starts to seek; playback runs again once the position
    // has moved on from there.
    Duration? target;
    int? resumedAt;
    final deadline = clock.elapsed + const Duration(seconds: 90);
    while (resumedAt == null && clock.elapsed < deadline) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 4)));
      final p = player.state.position;
      if (target == null && (p - expected).abs() < const Duration(seconds: 4)) target = p;
      if (target != null && p >= target + const Duration(seconds: 1)) resumedAt = clock.elapsedMicroseconds;
    }
    await tester.pump();
    final during = seekingEvents.where((e) => e.$1 >= started && (resumedAt == null || e.$1 <= resumedAt)).toList();
    // The first picture: the last time libmpv stopped "seeking" before playback ran again.
    final shown = during.where((e) => !e.$2).map((e) => e.$1).toList();
    final requests = (await origin(tester)).where((r) => (r['id'] as int) > seenBefore && r['what'] == 'segment').toList();
    final segment = target == null ? -1 : target.inSeconds ~/ segmentSeconds;
    final result = <String, Object?>{
      'kind': 'seek',
      'name': name,
      'fromS': from.inMilliseconds / 1000,
      'targetS': target == null ? null : target.inMilliseconds / 1000,
      'intoSegmentS': target == null ? null : (target.inMilliseconds % (segmentSeconds * 1000)) / 1000,
      'mpvCachedBefore': cacheBefore,
      'firstPictureMs': shown.isEmpty ? null : (shown.last - acted) ~/ 1000,
      // One second of film later, less that second: includes a stall right after the first picture.
      'playingMs': resumedAt == null ? null : (resumedAt - acted) ~/ 1000 - 1000,
      // How often the player was told to seek.
      'playerSeeks': during.where((e) => e.$2).length,
      'originRequests': requests.length,
      'originAborted': requests.where((r) => r['aborted'] == true).length,
      'originNewConnections': requests.where((r) => r['newConnection'] == true).length,
      // Requests for the segment the seek landed in: what a seek into cached video must not need.
      'originForTarget': requests.where((r) => r['index'] == segment).length,
      'originSegments': requests.map((r) => r['index']).toList(),
    };
    // ignore: avoid_print
    print('SEEK:${jsonEncode(result)}');
    results.add(result);
    return result;
  }

  /// Starts the app, opens 慢速源演示 and plays [episode] from its beginning, with a source as poor as the knobs say.
  /// Answers how long the first picture took.
  Future<int> openEpisode(WidgetTester tester, String episode) async {
    MediaKit.ensureInitialized();
    playerMade = false;
    await real(tester, () => http('GET', '/demo/slow/set?delayMs=$delayMs&connectMs=$connectMs&kBps=$kBps&totalKBps=$totalKBps&reset=1'));
    // Start with nothing cached: the numbers are those of a first viewing.
    await real(tester, () => http('DELETE', '/api/v1/stream-cache'));
    await real(tester, () => http('PUT', '/api/v1/settings', {'streamCache': streamCache}));
    addTearDown(() => http('PUT', '/api/v1/settings', {'streamCache': true}));
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
            (player.platform as NativePlayer).observeProperty('seeking', (value) async => seekingEvents.add((clock.elapsedMicroseconds, value == 'yes')));
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
    // The episode by name starts from its beginning, whatever the history says.
    final button = find.widgetWithText(OutlinedButton, episode);
    await until(tester, () => button.evaluate().isNotEmpty, 'the detail page');
    await memory(tester, 'before playing');
    await tester.ensureVisible(button);
    await wait(tester, const Duration(milliseconds: 500));
    final opened = clock.elapsedMilliseconds;
    await tester.tap(button);
    await until(tester, () => playerMade && player.state.position > const Duration(seconds: 1), 'the first picture', timeout: const Duration(seconds: 60));
    return clock.elapsedMilliseconds - opened - 1000;
  }

  /// A mouse for the seek bar. Hovering over the bar keeps the controls up, as it does for a user aiming at it.
  Future<({TestGesture mouse, Future<void> Function(Offset) aim, Future<int> Function(Duration) click})> pointer(WidgetTester tester) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(400, 300));
    Future<void> aim(Offset at) async {
      await mouse.moveTo(const Offset(400, 300));
      await wait(tester, const Duration(milliseconds: 300));
      await mouse.moveTo(at);
      await wait(tester, const Duration(milliseconds: 300));
    }

    // A click on the bar; counted from the moment the button goes down.
    Future<int> click(Duration position) async {
      final at = onBar(tester, position);
      await aim(at);
      final pressed = clock.elapsedMicroseconds;
      await mouse.down(at);
      await tester.pump(const Duration(milliseconds: 60));
      await mouse.up();
      await tester.pump();
      return pressed;
    }

    return (mouse: mouse, aim: aim, click: click);
  }

  Duration s(double seconds) => Duration(milliseconds: (seconds * 1000).round());

  void save(String name) {
    if (shotDir.isEmpty) return;
    File('$shotDir/$name.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'source': {'delayMs': delayMs, 'connectMs': connectMs, 'kBps': kBps, 'totalKBps': totalKBps},
        'streamCache': streamCache,
        'results': results,
      }),
    );
  }

  testWidgets('seeking in a slow stream', (tester) async {
    results.clear();
    results.add({'kind': 'start', 'playingMs': await openEpisode(tester, '普通')});
    // ignore: avoid_print
    print('START:${jsonEncode(results.last)}');
    await until(tester, () => player.state.position >= const Duration(seconds: 60), 'a minute of playback', timeout: const Duration(seconds: 150));
    await shot(tester, 'played-a-minute');
    await memory(tester, 'after one minute');
    final (:mouse, :aim, :click) = await pointer(tester);

    // Forward, into what should have been read ahead while the first minute played.
    final forward = await measure(tester, 'forward into read-ahead', s(85), () => click(s(85)));
    await wait(tester, const Duration(seconds: 4));
    // Back, into what was played.
    final back = await measure(tester, 'back into played', s(20), () => click(s(20)));
    await wait(tester, const Duration(seconds: 4));
    await shot(tester, 'back');
    // Somewhere nothing was fetched from, most of a segment in.
    final cold = await measure(tester, 'cold', s(1204.5), () => click(s(1204.5)));
    await wait(tester, const Duration(seconds: 12));
    await shot(tester, 'cold');
    final cold2 = await measure(tester, 'cold again', s(724.5), () => click(s(724.5)));
    await wait(tester, const Duration(seconds: 12));
    // Back to where the first cold seek played for a while.
    final revisit = await measure(tester, 'back to the earlier place', s(1210), () => click(s(1210)));
    await wait(tester, const Duration(seconds: 4));
    await memory(tester, 'after the seeks');

    // A drag along the bar: two seconds from 22:00 to 30:03 in twenty moves, then let go.
    final labelsWhileDragging = <String>{};
    final drag = await measure(tester, 'drag', s(1803), () async {
      final start = onBar(tester, s(1320));
      final end = onBar(tester, s(1803));
      await aim(start);
      await mouse.down(start);
      for (var i = 1; i <= 20; i++) {
        await mouse.moveTo(Offset.lerp(start, end, i / 20)!);
        await wait(tester, const Duration(milliseconds: 100));
        final label = find.byKey(const Key('seek-target')).evaluate();
        if (label.isNotEmpty) labelsWhileDragging.add((label.first.widget as Text).data ?? '');
      }
      final released = clock.elapsedMicroseconds;
      await mouse.up();
      await tester.pump();
      return released;
    });
    // Requests for places the pointer only passed over (25:36 to 30:00; before that lies the read-ahead of the
    // place the drag started from).
    final passedOver = (drag['originSegments'] as List).where((i) => (i as int) >= 256 && i < 300).toList();
    drag['originForPassedOver'] = passedOver.length;
    // ignore: avoid_print
    print('DRAG:${jsonEncode({'targetTimesShown': labelsWhileDragging.toList(), 'originForPassedOver': passedOver})}');
    await wait(tester, const Duration(seconds: 4));
    await shot(tester, 'dragged');

    // All the way back: the beginning was played two minutes and several seeks ago.
    final beginning = await measure(tester, 'back to the beginning', s(4), () => click(s(4)));
    await wait(tester, const Duration(seconds: 3));
    await memory(tester, 'at the end');
    save('seek-results');
    await mouse.removePointer();

    for (final r in [forward, back, cold, cold2, revisit, drag, beginning]) {
      expect(r['playingMs'], isNotNull, reason: '${r['name']}: playback did not run again');
    }
    if (strict) {
      // What was fetched before is there at once and costs the source nothing.
      for (final r in [forward, back, revisit, beginning]) {
        expect(r['playingMs'] as int, lessThan(1000), reason: '${r['name']}: $r');
        expect(r['originForTarget'], 0, reason: '${r['name']} went back to the source: $r');
      }
      // A drag is one seek, made when the button is let go; meanwhile the bar says where it would land.
      expect(drag['playerSeeks'], 1, reason: 'the drag: $drag');
      expect(passedOver, isEmpty, reason: 'the drag fetched from places it only passed over: $drag');
      expect(labelsWhileDragging.length, greaterThan(5), reason: 'the target time follows the pointer');
    }
    // Back to the detail page, so the next test starts from a clean player.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await wait(tester, const Duration(seconds: 1));
  });

  // The same film as one file: not HLS, so the engine's stream cache has no part in it and the player's own cache
  // is all there is. On desktop that cache is a file: what was played stays there until the video is closed.
  testWidgets('a direct link: seeking inside what the player has kept', (tester) async {
    results.clear();
    results.add({'kind': 'start', 'playingMs': await openEpisode(tester, '直链')});
    // ignore: avoid_print
    print('START:${jsonEncode(results.last)}');
    await until(tester, () => player.state.position >= const Duration(seconds: 40), 'forty seconds of playback', timeout: const Duration(seconds: 150));
    final playing = await memory(tester, 'direct link, after forty seconds');
    final (:mouse, aim: _, :click) = await pointer(tester);

    final back = await measure(tester, 'direct link: back into played', s(6), () => click(s(6)));
    await wait(tester, const Duration(seconds: 3));
    final forward = await measure(tester, 'direct link: forward again', s(34), () => click(s(34)));
    await wait(tester, const Duration(seconds: 3));
    await memory(tester, 'direct link, at the end');
    save('seek-results-direct');
    await mouse.removePointer();

    if (strict) {
      for (final r in [back, forward]) {
        expect(r['playingMs'], isNotNull, reason: '${r['name']}: playback did not run again');
        expect(r['playingMs'] as int, lessThan(1000), reason: '${r['name']}: $r');
        expect(r['originForTarget'], 0, reason: '${r['name']} went back to the source: $r');
      }
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        expect(playing['mpvCacheFileMB'], isNotNull, reason: 'the player keeps its cache in a file: $playing');
      }
    }
    // Closing the video deletes the cache file.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await wait(tester, const Duration(seconds: 2));
    final left = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}yingzhou-player-cache');
    final files = left.existsSync() ? left.listSync().map((f) => f.path).toList() : <String>[];
    // ignore: avoid_print
    print('CACHEFILES:${jsonEncode(files)}');
    if (strict) expect(files, isEmpty, reason: 'cache files left behind');
  });
}
