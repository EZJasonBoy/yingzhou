import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/engine/line_probe.dart';
import 'package:tvbox_client/engine/models.dart';
import 'package:tvbox_client/engine/vod_models.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/pages/line_probe_settings.dart';
import 'package:tvbox_client/settings.dart';
import 'package:tvbox_client/ui/device_form.dart';
import 'package:tvbox_client/ui/line_probe_view.dart';
import 'package:tvbox_client/ui/user_mode.dart';

import 'fake_engine.dart';
import 'fake_player.dart';

/// The line probe (线路体检, docs/design/line-probe.md) on the client: the model and its words, the rule 播放 picks a
/// line by, the engine's stream, and the detail page's line buttons. The player's side is line_switching_test.dart.
void main() {
  const mb = 1048576;
  final threeLines = [fakeLine('线路一', 'a'), fakeLine('线路二', 'b'), fakeLine('线路三', 'c')];

  /// 线路一 does not open, 线路二 is a fast 1080p, 线路三 a 4K too slow for it.
  final mixed = <String, Map<String, Object>>{
    '线路一': {'state': 'dead', 'reason': '超时', 'resolveMs': 6000},
    '线路二': {'state': 'ok', 'kind': 'hls', 'width': 1920, 'height': 1080, 'resolveMs': 180, 'firstByteMs': 420, 'bytesPerSecond': 3355443},
    '线路三': {'state': 'slow', 'kind': 'hls', 'width': 3840, 'height': 2160, 'bytesPerSecond': 1153434},
  };

  group('the model', () {
    LineProbe p(Map<String, dynamic> j) => LineProbe.fromJson({'index': 0, 'line': 'x', ...j});

    test('reads an answer; what was not measured stays null', () {
      final ok = p({'state': 'ok', 'kind': 'hls', 'width': 1920, 'height': 1080, 'resolveMs': 180, 'firstByteMs': 420, 'bytesPerSecond': 3355443});
      expect(ok.state, LineProbeState.ok);
      expect(ok.quality, '1080p');
      expect(ok.speed, '3.2 MB/s');
      final bare = p({'state': 'dead', 'reason': '404'});
      expect(bare.width, isNull);
      expect(bare.bytesPerSecond, isNull);
      expect(bare.quality, isNull);
      expect(p({'state': 'something-new'}).state, LineProbeState.skipped, reason: 'an answer this client does not know says nothing');
    });

    test('simple mode has four plain words; standard the picture and speed; developer the milliseconds', () {
      final ok = p(mixed['线路二']!);
      final slow = p(mixed['线路三']!);
      final dead = p(mixed['线路一']!);
      final sniff = p({'state': 'sniff'});
      final skipped = p({'state': 'skipped'});

      expect([ok, slow, dead, sniff].map((x) => x.text(ProbeWording.simple)), ['快', '慢', '打不开', '要试了才知道']);
      expect(skipped.label(ProbeWording.simple), '', reason: 'not measured: nothing said');

      expect(ok.label(ProbeWording.standard), '1080p · 3.2 MB/s');
      expect(slow.label(ProbeWording.standard), '4K · 1.1 MB/s');
      expect(slow.slowMark, isTrue);
      expect(slow.text(ProbeWording.standard), '4K · 1.1 MB/s · 慢');
      expect(dead.label(ProbeWording.standard), '打不开 · 超时');
      expect(p({'state': 'ok'}).label(ProbeWording.standard), '能播', reason: 'alive, nothing measured');

      expect(ok.label(ProbeWording.developer), '1080p · 3.2 MB/s · 解析 180 ms · 首字节 420 ms');
      expect(dead.label(ProbeWording.developer), '打不开 · 超时 · 解析 6000 ms');
      expect(const LineProbe.testing(0).text(ProbeWording.standard), '测速中');
    });

    test('a throttled line (the demo engine\'s 限速线路): small, slow, its reason left to 慢', () {
      final slow = p({'state': 'slow', 'width': 320, 'height': 180, 'bytesPerSecond': 102400, 'reason': '网速不够'});
      expect(slow.text(ProbeWording.standard), '180p · 100 KB/s · 慢');
      expect(slow.text(ProbeWording.simple), '慢');
      expect(p({'state': 'dead', 'reason': '不是视频'}).label(ProbeWording.standard), '打不开 · 不是视频', reason: 'a reason is shown as it comes');
    });

    test('a film cropped to 1920×800 is still a 1080p picture, and needs the speed of one', () {
      final cropped = p({'state': 'ok', 'width': 1920, 'height': 800, 'bytesPerSecond': 0.7 * mb});
      expect(cropped.quality, '1080p');
      expect(cropped.resolution, 1080);
      expect(cropped.fastEnough, isTrue);
      expect(p({'state': 'ok', 'width': 3840, 'height': 2160, 'bytesPerSecond': 2.0 * mb}).fastEnough, isFalse, reason: '4K wants about 2.5 MB/s');
    });
  });

  group('the line 播放 starts on', () {
    LineProbe r(int i, LineProbeState state, {int? height, double? speed}) => LineProbe(
      index: i,
      line: '$i',
      state: state,
      width: height == null ? null : height * 16 ~/ 9,
      height: height,
      bytesPerSecond: speed == null ? null : speed * mb,
    );

    test('nothing known yet: the line it would have started on', () {
      expect(choosePlayLine(const {}, fallback: 2, lastWatched: 1), 2);
    });

    test('the line watched last time, when it plays', () {
      final results = {0: r(0, LineProbeState.ok, height: 2160, speed: 9), 1: r(1, LineProbeState.ok, height: 720, speed: 0.4)};
      expect(choosePlayLine(results, lastWatched: 1, fallback: 0), 1, reason: 'habits are not upset for a better picture');
      expect(choosePlayLine({...results, 1: r(1, LineProbeState.dead)}, lastWatched: 1, fallback: 1), 0, reason: 'unless it does not open');
    });

    test('else the best picture the line is fast enough for; the faster of two alike', () {
      final results = {
        0: r(0, LineProbeState.ok, height: 2160, speed: 1.1), // 4K, too slow for it
        1: r(1, LineProbeState.ok, height: 1080, speed: 0.8),
        2: r(2, LineProbeState.ok, height: 1080, speed: 3.2),
        3: r(3, LineProbeState.ok, height: 720, speed: 9),
      };
      expect(choosePlayLine(results, fallback: 0), 2);
      expect(choosePlayLine({...results, 0: r(0, LineProbeState.ok, height: 2160, speed: 2.6)}, fallback: 3), 0, reason: 'a 4K that keeps up');
    });

    test('none fast enough: the fastest; no line alive at all: the next one not found dead', () {
      expect(choosePlayLine({0: r(0, LineProbeState.ok, height: 2160, speed: 1.0), 1: r(1, LineProbeState.ok, height: 2160, speed: 2.0)}, fallback: 0), 1);
      expect(
        choosePlayLine({0: r(0, LineProbeState.dead), 1: r(1, LineProbeState.slow, speed: 0.1), 2: r(2, LineProbeState.slow, speed: 0.2)}, fallback: 0),
        2,
      );
      expect(
        choosePlayLine({0: r(0, LineProbeState.dead), 1: r(1, LineProbeState.dead), 2: r(2, LineProbeState.sniff)}, fallback: 0, candidates: [0, 1, 2]),
        2,
      );
      expect(choosePlayLine({0: r(0, LineProbeState.dead), 1: r(1, LineProbeState.testing)}, fallback: 0, candidates: [0, 1]), 1);
    });
  });

  group('the engine', () {
    final base = Uri.parse('http://127.0.0.1:9978');

    test('streams each line as it finishes, with its place in the request, then ends', () async {
      final asked = <Map<String, dynamic>>[];
      final client = EngineClient(
        base,
        httpClient: fakeEngine(hasConfig: true, probe: {'线路二': mixed['线路二']!, '线路一': mixed['线路一']!}, probeAsked: asked),
      );
      final answers = await client.probeLines('cms', [
        (line: '线路一', episodeId: 'a1'),
        (line: '线路二', episodeId: 'b1'),
        (line: '线路三', episodeId: 'c1'),
      ], direct: true).toList();
      expect(answers.map((a) => (a.index, a.line, a.state)), [
        (1, '线路二', LineProbeState.ok),
        (0, '线路一', LineProbeState.dead),
        (2, '线路三', LineProbeState.skipped),
      ]);
      expect(asked.single, {
        'site': 'cms',
        'lines': [
          {'line': '线路一', 'episodeId': 'a1'},
          {'line': '线路二', 'episodeId': 'b1'},
          {'line': '线路三', 'episodeId': 'c1'},
        ],
        'direct': true,
      });
    });

    test('an engine from before the probe answers 404', () async {
      final client = EngineClient(base, httpClient: fakeEngine(hasConfig: true));
      await expectLater(
        client.probeLines('cms', [(line: '线路一', episodeId: 'a1')]).toList(),
        throwsA(isA<EngineException>().having((e) => e.statusCode, 'status', 404)),
      );
    });

    test('a probe asks only the lines that have the episode, each with its own id of it, and files the answers by line', () async {
      final asked = <Map<String, dynamic>>[];
      final client = EngineClient(
        base,
        httpClient: fakeEngine(hasConfig: true, probe: mixed, probeAsked: asked),
      );
      final detail = VodDetail.fromJson({
        'site': 'cms',
        'id': '7',
        'name': '片名',
        'lines': [
          fakeLine('线路一', 'a'),
          // A trailer first: the episodes sit one place further on.
          {
            'name': '线路二',
            'episodes': [
              {'id': 'https://cdn.test/b/trailer.m3u8', 'name': '预告'},
              for (var i = 1; i <= 3; i++) {'id': 'https://cdn.test/b/$i.m3u8', 'name': '第$i集'},
            ],
          },
          fakeLine('线路三', 'c', count: 1),
        ],
      });
      final probes = LineProbes();
      final run = probes.probe(client, detail, line: 0, episode: 1)!;
      expect(run.of(0)?.state, LineProbeState.testing);
      await Future<void>.delayed(Duration.zero);
      while (run.running) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect((asked.single['lines'] as List).map((l) => (l as Map)['episodeId']), [
        'https://cdn.test/a/2.m3u8',
        'https://cdn.test/b/2.m3u8',
      ], reason: '线路三 has no 第2集');
      expect(run.of(0)?.state, LineProbeState.dead);
      expect(run.of(1)?.state, LineProbeState.ok);
      expect(run.of(2), isNull);
      expect(identical(probes.find(client, detail, 1, 2), run), isTrue, reason: 'the same episode, found from another line');
      expect(probes.find(EngineClient(base, httpClient: fakeEngine()), detail, 0, 1), isNull, reason: 'another engine knows nothing of it');
      expect(identical(probes.probe(client, detail, line: 0, episode: 1), run), isTrue, reason: 'fresh: not asked again');
      expect(asked, hasLength(1));
      expect(probes.probe(client, detail.copyWithLines(const []), line: 0, episode: 0), isNull);
    });
  });

  group('the detail page', () {
    late FakePlayer player;
    late List<Map<String, dynamic>> probeAsked;

    Future<SettingsStore> store(UserMode mode) async {
      final s = MemorySettings();
      await s.setString(UserModeController.key, mode.name);
      // The site's recommendations first, also when something was watched: the tests open 推荐片 from there.
      await s.setString(UserModeController.startKey, 'home');
      return s;
    }

    Future<void> openDetail(
      WidgetTester tester, {
      UserMode mode = UserMode.standard,
      SettingsStore? settings,
      Map<String, Map<String, Object>>? probe,
      Future<void>? gate,
      List<Map<String, Object>> history = const [],
      DeviceForm form = DeviceForm.desktop,
      Size size = const Size(1400, 900),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      player = FakePlayer();
      probeAsked = [];
      final engine = fakeEngine(hasConfig: true, lines: threeLines, history: history, probe: probe, probeAsked: probeAsked, probeGate: gate);
      await tester.pumpWidget(
        DeviceFormScope.fixed(
          form,
          child: TvboxApp(
            key: UniqueKey(),
            state: AppState(
              clientFactory: (url) => EngineClient(url, httpClient: engine),
              settings: settings ?? await store(mode),
              playerBackend: () => player.backend(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('推荐片'));
      await tester.pumpAndSettle();
    }

    Future<void> pass(WidgetTester tester, Duration time) async {
      for (var t = Duration.zero; t < time; t += const Duration(milliseconds: 100)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> leave(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    }

    Finder onChip(int i, Finder f) => find.descendant(of: find.byKey(Key('detail-line-$i')), matching: f);

    testWidgets('the lines are measured as the page opens: a wave on each button, then what was found', (tester) async {
      final gate = Completer<void>();
      await openDetail(tester, probe: mixed, gate: gate.future);
      expect(probeAsked, hasLength(1), reason: 'asked once the detail and its history are in');
      expect((probeAsked.single['lines'] as List).map((l) => (l as Map)['line']), ['线路一', '线路二', '线路三']);
      for (var i = 0; i < 3; i++) {
        expect(onChip(i, find.byType(ProbeWave)), findsOneWidget, reason: 'line $i is being measured');
      }
      expect(tester.widget<TextButton>(find.byKey(const Key('detail-probe-again'))).onPressed, isNull, reason: 'not again while it runs');
      expect(find.text('正在测…'), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(ProbeWave), findsNothing);
      expect(onChip(0, find.text('打不开 · 超时')), findsOneWidget);
      expect(onChip(1, find.text('1080p · 3.2 MB/s')), findsOneWidget);
      expect(onChip(2, find.text('4K · 1.1 MB/s')), findsOneWidget);
      expect(onChip(2, find.byType(SlowMark)), findsOneWidget);

      await tester.tap(find.byKey(const Key('detail-probe-again')));
      await tester.pumpAndSettle();
      expect(find.text('重新测一遍'), findsOneWidget);
      expect(probeAsked, hasLength(2), reason: '重新测一遍 asks again');
    });

    testWidgets('simple mode: 快, 慢, 打不开 by the numbered lines, and no numbers', (tester) async {
      await openDetail(tester, mode: UserMode.simple, probe: mixed);
      expect(onChip(0, find.text('线路 1')), findsOneWidget);
      expect(onChip(0, find.text('打不开')), findsOneWidget);
      expect(onChip(1, find.text('快')), findsOneWidget);
      expect(onChip(2, find.byType(SlowMark)), findsOneWidget);
      expect(find.textContaining('MB/s'), findsNothing);
      expect(find.textContaining('1080p'), findsNothing);
      expect(find.textContaining('超时'), findsNothing, reason: 'the reason is for the other modes');
    });

    testWidgets('an engine from before the probe: the buttons stay as they were, nothing to probe again', (tester) async {
      await openDetail(tester);
      expect(find.byType(ProbeWave), findsNothing);
      expect(find.byKey(const Key('detail-probe-again')), findsNothing);
      await tester.tap(find.text('播放'));
      await pass(tester, const Duration(seconds: 1));
      expect(player.opened, ['https://cdn.test/a/1.m3u8'], reason: 'the first line, as before');
      await leave(tester);
    });

    testWidgets('播放 starts on the best line the probe found, not the first', (tester) async {
      await openDetail(tester, probe: mixed);
      await tester.tap(find.text('播放'));
      await pass(tester, const Duration(seconds: 1));
      expect(player.opened, ['https://cdn.test/b/1.m3u8'], reason: '线路一 does not open, 线路三 is too slow for its 4K');
      expect(probeAsked, hasLength(1), reason: 'the answers of the detail page are used, not asked again');
      await leave(tester);
    });

    testWidgets('the line watched last time is kept when it plays, slow 4K or not; a line picked by hand is played as it is', (tester) async {
      final history = <String, Object>{
        'site': 'cms',
        'vodId': '7',
        'name': '推荐片',
        'line': '线路三',
        'episodeId': 'https://cdn.test/c/2.m3u8',
        'episodeName': '第2集',
        'episodeIndex': 1,
        'positionMs': 61000,
        'durationMs': 2400000,
      };
      await openDetail(
        tester,
        probe: {
          ...mixed,
          '线路三': {...mixed['线路三']!, 'state': 'ok'},
        },
        history: [history],
      );
      expect(
        (probeAsked.single['lines'] as List).map((l) => (l as Map)['episodeId']),
        contains('https://cdn.test/c/2.m3u8'),
        reason: 'the episode to be played',
      );
      await tester.tap(find.byKey(const Key('detail-play')));
      await pass(tester, const Duration(seconds: 1));
      expect(player.opened, ['https://cdn.test/c/2.m3u8']);
      await leave(tester);

      await openDetail(tester, probe: mixed);
      await tester.tap(find.byKey(const Key('detail-line-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('播放'));
      await pass(tester, const Duration(seconds: 1));
      expect(player.opened, ['https://cdn.test/a/1.m3u8'], reason: 'the user chose 线路一');
      await leave(tester);
    });

    testWidgets('a phone waits for 播放 (or 测一遍线路) before it probes; 设置 can change that', (tester) async {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const playback = MethodChannel('yingzhou/playback');
      messenger.setMockMethodCallHandler(
        playback,
        (call) async => switch (call.method) {
          'getBrightness' => 0.5,
          'getVolume' => 0.4,
          _ => null,
        },
      );
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(playback, null);
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });

      final settings = await store(UserMode.standard);
      await openDetail(tester, settings: settings, probe: mixed, form: DeviceForm.phone, size: const Size(412, 915));
      expect(probeAsked, isEmpty, reason: 'nothing fetched just for opening the page on a phone');
      await tester.ensureVisible(find.byKey(const Key('detail-probe-again')));
      expect(find.text('测一遍线路'), findsOneWidget);
      await tester.tap(find.byKey(const Key('detail-probe-again')));
      await tester.pumpAndSettle();
      expect(probeAsked, hasLength(1));
      expect(onChip(1, find.text('1080p · 3.2 MB/s')), findsOneWidget);

      await settings.setString(LineProbeSettings.settingKey, 'true');
      await openDetail(tester, settings: settings, probe: mixed, form: DeviceForm.phone, size: const Size(412, 915));
      expect(probeAsked, hasLength(1), reason: 'turned on in 设置: the phone probes as the page opens');
      await leave(tester);
    });

    testWidgets('a phone without probing on the detail page probes when 播放 is pressed', (tester) async {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const playback = MethodChannel('yingzhou/playback');
      messenger.setMockMethodCallHandler(
        playback,
        (call) async => switch (call.method) {
          'getBrightness' => 0.5,
          'getVolume' => 0.4,
          _ => null,
        },
      );
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(playback, null);
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });
      await openDetail(tester, probe: mixed, form: DeviceForm.phone, size: const Size(412, 915));
      expect(probeAsked, isEmpty);
      await tester.tap(find.byKey(const Key('detail-play')));
      await pass(tester, const Duration(seconds: 1));
      expect(probeAsked, hasLength(1), reason: 'the episode that plays is probed now');
      expect(player.opened.first, 'https://cdn.test/a/1.m3u8', reason: 'no answer yet when it started: the line on screen');
      await leave(tester);
    });

    testWidgets('设置 → 播放: 打开详情时先测线路, on by default off phones', (tester) async {
      final settings = await store(UserMode.standard);
      await openDetail(tester, settings: settings);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      final toggle = find.byKey(const Key('probe-on-detail'));
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(settings.getString(LineProbeSettings.settingKey), 'false', reason: 'kept as the web console reads it');
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      expect(LineProbeSettings.resolve(MemorySettings(), phone: true), isFalse);
      expect(LineProbeSettings.resolve(MemorySettings(), phone: false), isTrue);
    });
  });
}

extension on VodDetail {
  VodDetail copyWithLines(List<PlayLine> lines) => VodDetail(site: site, id: id, name: name, lines: lines);
}
