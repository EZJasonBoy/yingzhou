import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/remote/remote_host.dart';
import 'package:tvbox_client/pages/line_probe_settings.dart';
import 'package:tvbox_client/pages/player_dial.dart';
import 'package:tvbox_client/pages/player_page.dart';
import 'package:tvbox_client/settings.dart';
import 'package:tvbox_client/ui/device_form.dart';
import 'package:tvbox_client/ui/line_probe_view.dart';
import 'package:tvbox_client/ui/user_mode.dart';

import 'fake_engine.dart';
import 'fake_player.dart';

/// The player with the line probe (线路体检): lines found dead are skipped, the wait for a picture follows what was
/// found, and the 「正在换线路」 card (player_switching.dart) on a desktop and with a remote. 推荐片 has three
/// lines; the engine is the fake one, the player [FakePlayer].
void main() {
  late FakePlayer player;
  late List<String> resolved;

  const a = 'https://cdn.test/a';
  const b = 'https://cdn.test/b';
  const c = 'https://cdn.test/c';
  final threeLines = [fakeLine('线路一', 'a'), fakeLine('线路二', 'b'), fakeLine('线路三', 'c')];

  /// Watched to 01:01 of 第2集 on 线路一.
  const watched = <String, Object>{
    'site': 'cms',
    'vodId': '7',
    'name': '推荐片',
    'line': '线路一',
    'episodeId': '$a/2.m3u8',
    'episodeName': '第2集',
    'episodeIndex': 1,
    'positionMs': 61000,
    'durationMs': 2400000,
  };

  /// 线路一 measured fine (it fails when played), 线路二 a fast 1080p, 线路三 a 4K too slow for it.
  final measured = <String, Map<String, Object>>{
    '线路一': {'state': 'ok', 'width': 1920, 'height': 1080, 'bytesPerSecond': 2097152},
    '线路二': {'state': 'ok', 'width': 1920, 'height': 1080, 'bytesPerSecond': 3355443},
    '线路三': {'state': 'slow', 'width': 3840, 'height': 2160, 'bytesPerSecond': 1153434},
  };

  Future<void> pass(WidgetTester tester, Duration time) async {
    for (var t = Duration.zero; t < time; t += const Duration(milliseconds: 100)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  Future<SettingsStore> store(UserMode mode) async {
    final s = MemorySettings();
    await s.setString(UserModeController.key, mode.name);
    // The site's recommendations first, also when something was watched: 推荐片 is opened from there.
    await s.setString(UserModeController.startKey, 'home');
    return s;
  }

  /// Opens 推荐片's detail page. [dead] lines do not resolve; [silent] addresses resolve but show nothing.
  Future<void> openDetail(
    WidgetTester tester, {
    UserMode mode = UserMode.standard,
    SettingsStore? settings,
    Map<String, Map<String, Object>>? probe,
    Future<void>? gate,
    Set<String> dead = const {},
    Set<String> silent = const {},
    List<Map<String, Object>> history = const [],
    DeviceForm form = DeviceForm.desktop,
  }) async {
    final tv = form == DeviceForm.tv;
    tester.view.physicalSize = tv ? const Size(1920, 1080) : const Size(1400, 900);
    tester.view.devicePixelRatio = tv ? 2 : 1;
    addTearDown(tester.view.reset);
    player = FakePlayer()..silent.addAll(silent);
    resolved = [];
    final engine = fakeEngine(hasConfig: true, lines: threeLines, history: history, deadLines: dead, resolved: resolved, probe: probe, probeGate: gate);
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
    if (tv) {
      await pass(tester, const Duration(seconds: 1));
      return;
    }
    await tester.pumpAndSettle();
    await tester.tap(find.text('推荐片'));
    await tester.pumpAndSettle();
  }

  Future<void> play(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('detail-play')));
    await pass(tester, const Duration(milliseconds: 500));
  }

  final card = find.byKey(const Key('switching-card'));
  Finder inCard(Finder f) => find.descendant(of: card, matching: f);
  Finder row(int line, Finder f) => find.descendant(of: find.byKey(Key('switching-row-$line')), matching: f);

  group('changing line', () {
    testWidgets('a line the probe found dead is skipped; one it found alive gets the full 15 seconds', (tester) async {
      await openDetail(
        tester,
        probe: {
          ...measured,
          '线路二': {'state': 'dead', 'reason': '404'},
        },
        silent: {'$a/1.m3u8'},
      );
      await play(tester);
      expect(player.opened, ['$a/1.m3u8'], reason: 'the best of what plays');
      await pass(tester, const Duration(seconds: 14));
      expect(resolved, ['线路一'], reason: 'still within its 15 seconds');
      await pass(tester, const Duration(seconds: 2));
      expect(resolved, ['线路一', '线路三'], reason: '线路二 was found dead: not tried');
      expect(player.opened, ['$a/1.m3u8', '$c/1.m3u8']);
      await leave(tester);
    });

    testWidgets('a line the probe did not measure gets 8 seconds', (tester) async {
      await openDetail(tester, probe: {'线路二': measured['线路二']!, '线路三': measured['线路三']!}, silent: {'$a/1.m3u8'});
      // Picked by hand on the detail page: 线路一 plays although it was not measured.
      await tester.tap(find.byKey(const Key('detail-line-0')));
      await tester.pumpAndSettle();
      await play(tester);
      expect(player.opened, ['$a/1.m3u8']);
      await pass(tester, const Duration(seconds: 7));
      expect(resolved, ['线路一']);
      await pass(tester, const Duration(seconds: 1, milliseconds: 500));
      expect(resolved, ['线路一', '线路二'], reason: 'given up after 8 seconds, not 15');
      expect(find.textContaining('等了 8 秒还没有画面'), findsNothing, reason: 'a change of line, not an error');
      await leave(tester);
    });

    testWidgets('an answer that comes while a line loads moves on from a dead one at once', (tester) async {
      final settings = await store(UserMode.standard);
      await settings.setString(LineProbeSettings.settingKey, 'false');
      final gate = Completer<void>();
      await openDetail(
        tester,
        settings: settings,
        probe: {
          '线路一': {'state': 'dead', 'reason': '超时'},
          '线路二': measured['线路二']!,
        },
        gate: gate.future,
        silent: {'$a/1.m3u8'},
      );
      await play(tester);
      expect(player.opened, ['$a/1.m3u8'], reason: 'no answer yet: the line on screen');
      gate.complete();
      await pass(tester, const Duration(milliseconds: 500));
      expect(resolved, ['线路一', '线路二'], reason: 'not after 15 seconds');
      expect(player.opened.last, '$b/1.m3u8');
      await leave(tester);
    });
  });

  group('the 正在换线路 card', () {
    testWidgets('no picture two seconds after opening: the card instead of the spinner; it goes with the picture', (tester) async {
      await openDetail(tester, silent: {'$a/1.m3u8'});
      await play(tester);
      await pass(tester, const Duration(seconds: 1));
      expect(card, findsNothing);
      expect(find.text('正在缓冲…'), findsOneWidget);
      await pass(tester, const Duration(seconds: 1));
      expect(card, findsOneWidget);
      expect(find.text('正在缓冲…'), findsNothing, reason: 'the card replaces the spinner');
      expect(inCard(find.text('正在等画面')), findsOneWidget);
      expect(find.byKey(const Key('switching-sentence')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('switching-sentence'))).data, '正在试「线路一」，还没有画面。打不开会自动换下一条，也可以自己选一条。');
      expect(row(0, find.text('正在试')), findsOneWidget);
      expect(row(0, find.byType(ProbeWave)), findsOneWidget);

      player.playTo(const Duration(seconds: 3));
      await pass(tester, const Duration(milliseconds: 300));
      expect(card, findsNothing, reason: 'the picture came');
      await leave(tester);
    });

    testWidgets('after a change of line: what happened, a row per line, and where it carries on from', (tester) async {
      await openDetail(tester, probe: measured, dead: {'线路一'}, silent: {'$b/2.m3u8'}, history: [watched]);
      await play(tester);
      expect(resolved, ['线路一', '线路二'], reason: 'the line watched last time first, it was measured fine');
      expect(card, findsOneWidget, reason: 'at once after a change of line');
      expect(inCard(find.text('正在换线路')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('switching-sentence'))).data, '「线路一」解析失败。正在试「线路二」，接上以后从 01:01 接着播。');
      expect(row(0, find.text('打不开 · 解析失败')), findsOneWidget);
      expect(row(1, find.text('正在试 · 1080p · 3.2 MB/s')), findsOneWidget);
      expect(row(2, find.text('能播 · 4K · 1.1 MB/s')), findsOneWidget);
      expect(row(2, find.byType(SlowMark)), findsOneWidget);
      expect(find.textContaining('已切到'), findsNothing, reason: 'the card says it; no notice on top');

      player.playTo(const Duration(seconds: 62));
      await pass(tester, const Duration(milliseconds: 300));
      expect(card, findsNothing);
      expect(find.text('「线路一」解析失败，已切到「线路二」'), findsOneWidget, reason: 'a sentence stays once the picture is there');
      await leave(tester);
    });

    testWidgets('simple mode: numbered lines and plain words', (tester) async {
      await openDetail(tester, mode: UserMode.simple, probe: measured, dead: {'线路一'}, silent: {'$b/2.m3u8'}, history: [watched]);
      await play(tester);
      expect(tester.widget<Text>(find.byKey(const Key('switching-sentence'))).data, '线路 1 打不开。正在试线路 2，接上以后从 01:01 接着播。');
      expect(row(0, find.text('打不开')), findsOneWidget);
      expect(row(1, find.text('正在试')), findsOneWidget);
      expect(row(2, find.text('能播')), findsOneWidget);
      expect(row(2, find.byType(SlowMark)), findsOneWidget);
      expect(inCard(find.textContaining('MB/s')), findsNothing);
      expect(inCard(find.textContaining('解析失败')), findsNothing);
      await leave(tester);
    });

    testWidgets('选一条 opens the lines; 停在这里 stays on the line and changes no more', (tester) async {
      await openDetail(tester, dead: {'线路一'}, silent: {'$b/1.m3u8'});
      await play(tester);
      expect(card, findsOneWidget);
      await tester.tap(find.byKey(const Key('switching-pick')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(card, findsNothing);
      expect(find.byKey(const Key('player-line-0')), findsOneWidget, reason: 'the episodes panel, the lines on top');
      await leave(tester);

      await openDetail(tester, dead: {'线路一'}, silent: {'$b/1.m3u8'});
      await play(tester);
      await tester.tap(find.byKey(const Key('switching-stay')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(card, findsNothing);
      expect(find.text('正在缓冲…'), findsOneWidget, reason: 'waiting on this line, as asked');
      await pass(tester, const Duration(seconds: 16));
      expect(resolved, ['线路一', '线路二'], reason: '线路三 is not tried behind the user\'s back');
      expect(find.textContaining('已停在「线路二」，不会自动换线路'), findsOneWidget);
      expect(card, findsNothing);
      await leave(tester);
    });

    testWidgets('播放信息 lists what the probe found of each line', (tester) async {
      await openDetail(
        tester,
        probe: {
          ...measured,
          '线路一': {'state': 'dead', 'reason': '超时'},
        },
      );
      await play(tester);
      expect(player.opened, ['$b/1.m3u8']);
      await tester.tap(find.byKey(const Key('info-button')));
      await pass(tester, const Duration(milliseconds: 300));
      final info = find.byKey(const Key('play-info'));
      expect(find.descendant(of: info, matching: find.text('各条线路刚测过的结果')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('play-info-probe-0')), matching: find.text('打不开 · 超时')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('play-info-probe-1')), matching: find.text('线路二 · 正在播')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('play-info-probe-1')), matching: find.text('1080p · 3.2 MB/s')), findsOneWidget);
      await leave(tester);
    });
  });

  group('with a remote', () {
    Future<void> key(WidgetTester tester, LogicalKeyboardKey k, {int times = 1}) async {
      for (var i = 0; i < times; i++) {
        await tester.sendKeyEvent(k, platform: 'android', physicalKey: k == LogicalKeyboardKey.goBack ? PhysicalKeyboardKey.escape : null);
        await pass(tester, const Duration(milliseconds: 300));
      }
    }

    bool focusIsIn(Finder finder) {
      final element = finder.evaluate().single;
      final focused = FocusManager.instance.primaryFocus!;
      var inside = focused.context == element;
      focused.context!.visitAncestorElements((e) {
        if (e == element) inside = true;
        return !inside;
      });
      return inside;
    }

    /// 首页 → 推荐片 → 播放, all with the remote; 线路一 does not resolve and 线路二 shows nothing.
    Future<void> openOnTv(WidgetTester tester) async {
      await openDetail(tester, form: DeviceForm.tv, dead: {'线路一'}, silent: {'$b/1.m3u8'});
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.select);
      await pass(tester, const Duration(seconds: 1));
      await key(tester, LogicalKeyboardKey.select);
      await pass(tester, const Duration(milliseconds: 500));
      expect(resolved, ['线路一', '线路二']);
      expect(card, findsOneWidget);
    }

    testWidgets('the focus goes to 选一条 and stays in the card at every edge; BACK closes the card, not the player', (tester) async {
      await openOnTv(tester);
      expect(focusIsIn(find.byKey(const Key('switching-pick'))), isTrue);
      for (final k in [LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowDown]) {
        await key(tester, k, times: 3);
        expect(focusIsIn(card), isTrue, reason: '$k');
      }
      await key(tester, LogicalKeyboardKey.arrowRight, times: 3);
      expect(focusIsIn(find.byKey(const Key('switching-stay'))), isTrue);
      await key(tester, LogicalKeyboardKey.arrowUp);
      expect(focusIsIn(find.byKey(const Key('switching-stay'))), isTrue);
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(focusIsIn(find.byKey(const Key('switching-pick'))), isTrue);
      expect(player.seeks, isEmpty, reason: 'no key reached the picture');
      expect(find.byKey(const Key('tv-episode-0')), findsNothing, reason: 'nor opened a panel');

      // Even if the focus is taken away, the next key puts it back and does nothing else.
      FocusManager.instance.primaryFocus!.unfocus();
      await pass(tester, const Duration(milliseconds: 100));
      await key(tester, LogicalKeyboardKey.arrowUp);
      expect(focusIsIn(card), isTrue);
      expect(find.byKey(const Key('tv-episode-0')), findsNothing);

      await key(tester, LogicalKeyboardKey.goBack);
      expect(card, findsNothing);
      expect(find.byType(PlayerPage), findsOneWidget, reason: 'still playing');
      await leave(tester);
    });

    testWidgets('OK on 选一条 opens the lines; → then OK is 停在这里', (tester) async {
      await openOnTv(tester);
      await key(tester, LogicalKeyboardKey.select);
      expect(card, findsNothing);
      expect(find.byKey(const Key('tv-lines')), findsOneWidget, reason: "the dial's 线路 panel");
      expect(focusIsIn(find.byKey(const Key('tv-lines'))), isTrue, reason: 'with the focus in it');
      expect(tester.widget<Text>(find.byKey(const Key('tv-panel-line-0-status'))).data, '刚才打不开');
      await key(tester, LogicalKeyboardKey.goBack);
      expect(find.byKey(const Key('tv-lines')), findsNothing, reason: 'BACK goes back to the dial');
      expect(card, findsNothing, reason: 'the card does not come back over the dial');
      await leave(tester);

      await openOnTv(tester);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.select);
      expect(card, findsNothing);
      await pass(tester, const Duration(seconds: 16));
      expect(resolved, ['线路一', '线路二']);
      expect(find.textContaining('已停在「线路二」'), findsOneWidget);
      await leave(tester);
    });

    testWidgets("the dial's 线路 panel shows what the probe found, and so does the remote's state", (tester) async {
      await openDetail(tester, form: DeviceForm.tv, probe: measured);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.select);
      await pass(tester, const Duration(seconds: 1));
      await key(tester, LogicalKeyboardKey.select);
      await pass(tester, const Duration(milliseconds: 500));
      expect(player.opened, ['$b/1.m3u8'], reason: 'the fastest of the lines whose speed is enough for their picture');
      player.playTo(const Duration(minutes: 1));
      await pass(tester, const Duration(milliseconds: 300));

      // ↑ opens the dial on 选集 (nothing was used yet in this app); ↓ to 线路; OK opens its panel next to the dial.
      TvDialMemory.reset();
      await key(tester, LogicalKeyboardKey.arrowUp);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.select);
      String? status(int line) => tester.widget<Text>(find.byKey(Key('tv-panel-line-$line-status'))).data;
      expect(status(0), '1080p · 2.0 MB/s');
      expect(status(1), '正在播 · 1080p', reason: 'the line playing says so');
      expect(status(2), '4K · 1.1 MB/s · 慢');

      final state = RemoteHost.instance.player!.remoteState();
      expect(state['lineStates'], [
        {'state': 'ok', 'label': '1080p · 2.0 MB/s'},
        {'state': 'ok', 'label': '1080p · 3.2 MB/s'},
        {'state': 'slow', 'label': '4K · 1.1 MB/s'},
      ]);
      await leave(tester);
    });
  });
}
