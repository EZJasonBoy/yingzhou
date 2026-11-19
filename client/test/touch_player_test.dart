import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/pages/player_mobile.dart';
import 'package:tvbox_client/pages/player_page.dart';
import 'package:tvbox_client/pages/touch_gestures.dart';
import 'package:tvbox_client/ui/form_factor.dart';

import 'fake_engine.dart';
import 'fake_player.dart';

/// The players on phones and tablets: the layout upright and on its side, full screen and the turn to landscape,
/// the back gesture, the gestures on the picture, the lock, keeping the screen on and picture-in-picture. The
/// phone's side (`yingzhou/playback`, SystemChrome) is mocked and every call to it is noted.
void main() {
  late FakePlayer player;
  late List<MethodCall> playback;
  late List<MethodCall> system;
  const ratio = 2.625;
  const phone = Size(412, 915);
  const phoneLandscape = Size(915, 412);

  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const playbackChannel = MethodChannel('yingzhou/playback');

  setUp(() {
    playback = [];
    system = [];
    messenger.setMockMethodCallHandler(playbackChannel, (call) async {
      playback.add(call);
      return switch (call.method) {
        'getBrightness' => 0.5,
        'getVolume' => 0.4,
        'setVolume' => (call.arguments as Map)['value'],
        'setPip' || 'enterPip' => true,
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method.startsWith('SystemChrome.')) system.add(call);
      return null;
    });
  });

  tearDown(() {
    FormFactors.debugOverride = FormFactor.desktop;
    messenger.setMockMethodCallHandler(playbackChannel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  /// Lets [time] go by, a frame every 100 ms.
  Future<void> pass(WidgetTester tester, Duration time) async {
    for (var t = Duration.zero; t < time; t += const Duration(milliseconds: 100)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  void resize(WidgetTester tester, Size size) => tester.view.physicalSize = size * ratio;

  /// Opens 推荐片 (two lines of twelve episodes) and plays its first episode.
  Future<void> play(WidgetTester tester, {Size size = phone, FormFactor formFactor = FormFactor.phone}) async {
    FormFactors.debugOverride = formFactor;
    resize(tester, size);
    tester.view.devicePixelRatio = ratio;
    addTearDown(tester.view.reset);
    player = FakePlayer();
    final engine = fakeEngine(hasConfig: true, lines: [fakeLine('线路一', 'a', count: 12), fakeLine('线路二', 'b', count: 12)]);
    await tester.pumpWidget(
      TvboxApp(state: AppState(clientFactory: (url) => EngineClient(url, httpClient: engine), playerBackend: () => player.backend())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('推荐片'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '播放'));
    await pass(tester, const Duration(seconds: 1));
  }

  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  Iterable<MethodCall> calls(String method) => playback.where((c) => c.method == method);
  List<String>? lastOrientations() {
    final call = system.lastWhere((c) => c.method == 'SystemChrome.setPreferredOrientations', orElse: () => const MethodCall('none'));
    return call.method == 'none' ? null : (call.arguments as List).cast<String>();
  }

  String? lastUiMode() {
    final call = system.lastWhere((c) => c.method == 'SystemChrome.setEnabledSystemUIMode', orElse: () => const MethodCall('none'));
    return call.method == 'none' ? null : call.arguments as String;
  }

  /// Taps twice in quick succession at [at].
  Future<void> doubleTap(WidgetTester tester, Offset at) async {
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 400));
  }

  Rect picture(WidgetTester tester) => tester.getRect(find.byKey(const Key('touch-gestures')));

  double barsOpacity(WidgetTester tester) =>
      tester.widget<AnimatedOpacity>(find.ancestor(of: find.byType(TouchPlayerBars), matching: find.byType(AnimatedOpacity)).first).opacity;

  /// Brings the controls up with a tap on the picture, unless they are up already (a tap would hide them).
  Future<void> showControls(WidgetTester tester) async {
    if (barsOpacity(tester) == 0) {
      await tester.tapAt(picture(tester).center);
      await pass(tester, const Duration(milliseconds: 400));
    }
  }

  /// Taps a control, then lets the calls to the system it makes (one after the other) go through.
  Future<void> press(WidgetTester tester, Key key) async {
    await tester.tap(find.byKey(key));
    await pass(tester, const Duration(milliseconds: 200));
  }

  /// Turns the phone on its side the way the system would after the page asked for landscape.
  Future<void> turn(WidgetTester tester, Size size) async {
    resize(tester, size);
    await tester.pump();
    await pass(tester, const Duration(milliseconds: 300));
  }

  testWidgets('upright on a phone: the picture on top, the title, lines and episodes under it', (tester) async {
    await play(tester);
    expect(find.byType(PlayerPhoneInfo), findsOneWidget);
    final video = picture(tester);
    expect(video.width, phone.width);
    expect(video.height, closeTo(phone.width * 9 / 16, 1));
    // Upright the controls are the small set: no lock, no speed in the bar.
    await showControls(tester);
    expect(find.byKey(const Key('touch-fullscreen')), findsOneWidget);
    expect(find.byKey(const Key('danmaku-button')), findsNothing);
    expect(find.byKey(const Key('touch-lock')), findsNothing);

    final episode = find.byKey(const Key('phone-episode-3'));
    expect(tester.getSize(episode).height, greaterThanOrEqualTo(48));
    await tester.tap(episode);
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened.last, 'https://cdn.test/a/4.m3u8');

    await tester.tap(find.byKey(const Key('phone-line-1')));
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened.last, 'https://cdn.test/b/4.m3u8', reason: 'the same episode on the other line');

    // The subtitle panel opens under the picture, not over it.
    await tester.tap(find.byKey(const Key('phone-tracks')));
    await pass(tester, const Duration(milliseconds: 300));
    expect(find.text('字幕与音轨'), findsOneWidget);
    await tester.tap(find.byKey(const Key('phone-panel-close')));
    await pass(tester, const Duration(milliseconds: 300));
    expect(find.text('字幕与音轨'), findsNothing);
    await leave(tester);
  });

  testWidgets('full screen turns the phone to landscape; back leaves full screen before the page', (tester) async {
    await play(tester);
    await showControls(tester);
    await press(tester, const Key('touch-fullscreen'));
    expect(lastOrientations(), ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight']);
    expect(lastUiMode(), 'SystemUiMode.immersiveSticky');

    await turn(tester, phoneLandscape);
    expect(find.byType(PlayerPhoneInfo), findsNothing);
    expect(picture(tester).size, phoneLandscape);

    // The system's back: out of full screen, still on the page.
    await tester.binding.handlePopRoute();
    await pass(tester, const Duration(milliseconds: 200));
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(lastOrientations(), ['DeviceOrientation.portraitUp']);
    expect(lastUiMode(), 'SystemUiMode.edgeToEdge');
    await turn(tester, phone);
    expect(find.byType(PlayerPhoneInfo), findsOneWidget);

    // Back again leaves the page; every orientation is allowed again.
    await tester.binding.handlePopRoute();
    await pass(tester, const Duration(seconds: 1));
    expect(find.byType(PlayerPage), findsNothing);
    expect(lastOrientations(), isEmpty);
    await leave(tester);
  });

  testWidgets('a phone turned on its side goes full screen by itself, and back upright leaves it', (tester) async {
    await play(tester);
    await turn(tester, phoneLandscape);
    expect(lastUiMode(), 'SystemUiMode.immersiveSticky');
    expect(find.byKey(const Key('touch-lock')), findsOneWidget);
    await turn(tester, phone);
    expect(lastUiMode(), 'SystemUiMode.edgeToEdge');
    expect(find.byType(PlayerPhoneInfo), findsOneWidget);
    await leave(tester);
  });

  testWidgets('tap shows and hides the controls and never pauses; double taps seek and pause', (tester) async {
    await play(tester, size: phoneLandscape);
    final rect = picture(tester);
    // Let the controls hide on their own first.
    await pass(tester, const Duration(seconds: 4));
    expect(tester.widget<AnimatedOpacity>(find.ancestor(of: find.byType(TouchPlayerBars), matching: find.byType(AnimatedOpacity)).first).opacity, 0);
    await tester.tapAt(rect.center);
    await pass(tester, const Duration(milliseconds: 400));
    expect(tester.widget<AnimatedOpacity>(find.ancestor(of: find.byType(TouchPlayerBars), matching: find.byType(AnimatedOpacity)).first).opacity, 1);
    expect(player.state.playing, isTrue, reason: 'a tap on touch only shows the controls');
    await tester.tapAt(rect.center);
    await pass(tester, const Duration(milliseconds: 400));
    expect(tester.widget<AnimatedOpacity>(find.ancestor(of: find.byType(TouchPlayerBars), matching: find.byType(AnimatedOpacity)).first).opacity, 0);

    player.playTo(const Duration(minutes: 5));
    await doubleTap(tester, Offset(rect.left + rect.width * 0.85, rect.center.dy));
    expect(player.seeks.last, const Duration(minutes: 5, seconds: 10));
    await doubleTap(tester, Offset(rect.left + rect.width * 0.85, rect.center.dy));
    expect(player.seeks.last, const Duration(minutes: 5, seconds: 20), reason: 'steps add up');
    await pass(tester, const Duration(seconds: 1));
    player.playTo(const Duration(minutes: 5));
    await doubleTap(tester, Offset(rect.left + rect.width * 0.15, rect.center.dy));
    expect(player.seeks.last, const Duration(minutes: 4, seconds: 50));
    await doubleTap(tester, rect.center);
    expect(player.state.playing, isFalse);
    await doubleTap(tester, rect.center);
    expect(player.state.playing, isTrue);
    await leave(tester);
  });

  testWidgets('dragging sideways previews the time and seeks once it is let go', (tester) async {
    await play(tester, size: phoneLandscape);
    player.playTo(const Duration(minutes: 10));
    final rect = picture(tester);
    final seeks = player.seeks.length;
    final drag = await tester.startGesture(rect.center);
    for (var i = 0; i < 20; i++) {
      await drag.moveBy(Offset(rect.width / 40, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    // Half the picture's width: half of three minutes, less the few pixels it takes to tell a drag from a tap.
    expect(find.byKey(const Key('gesture-seek')), findsOneWidget);
    expect(find.textContaining(RegExp(r'^\+01:[23]\d$')), findsOneWidget);
    expect(player.seeks.length, seeks, reason: 'nothing is sought while the finger moves');
    await drag.up();
    await tester.pump();
    expect(player.seeks.length, seeks + 1);
    expect(player.seeks.last.inSeconds, closeTo(const Duration(minutes: 11, seconds: 30).inSeconds, 8));
    expect(find.byKey(const Key('gesture-seek')), findsNothing);
    await leave(tester);
  });

  testWidgets('dragging up and down: brightness on the left, the media volume on the right', (tester) async {
    await play(tester, size: phoneLandscape);
    final rect = picture(tester);

    Future<void> dragUp(Offset from) async {
      final drag = await tester.startGesture(from);
      // About 80% of the picture's height: from anywhere to full.
      for (var i = 0; i < 16; i++) {
        await drag.moveBy(Offset(0, -rect.height / 20));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await drag.up();
      await tester.pump();
    }

    await dragUp(Offset(rect.left + rect.width * 0.25, rect.center.dy + 80));
    final brightness = calls('setBrightness').map((c) => (c.arguments as Map)['value'] as double).toList();
    expect(brightness, isNotEmpty);
    expect(brightness.every((v) => v >= 0.5), isTrue, reason: 'up from the 50% the phone reported');
    expect(brightness.last, closeTo(1.0, 0.01));
    expect(calls('setVolume'), isEmpty);

    await dragUp(Offset(rect.left + rect.width * 0.75, rect.center.dy + 80));
    final volume = calls('setVolume').map((c) => (c.arguments as Map)['value'] as double).toList();
    expect(volume.last, closeTo(1.0, 0.01));
    expect(volume.every((v) => v >= 0.4), isTrue, reason: 'up from the 40% the phone reported');
    expect(player.state.volume, 100, reason: "the player's own volume is left alone when the system's can be set");

    // Leaving gives the brightness back to the system.
    await leave(tester);
    expect((calls('setBrightness').last.arguments as Map)['value'], isNull);
  });

  testWidgets('long press plays at twice the speed while held', (tester) async {
    await play(tester, size: phoneLandscape);
    final gesture = await tester.startGesture(picture(tester).center);
    await tester.pump(const Duration(milliseconds: 700));
    expect(player.state.rate, 2);
    expect(find.byKey(const Key('gesture-speed')), findsOneWidget);
    await gesture.up();
    await tester.pump();
    expect(player.state.rate, 1);
    expect(find.byKey(const Key('gesture-speed')), findsNothing);
    await leave(tester);
  });

  testWidgets('the lock: gestures and back do nothing until it is undone', (tester) async {
    await play(tester, size: phoneLandscape);
    final rect = picture(tester);
    await showControls(tester);
    await tester.tap(find.byKey(const Key('touch-lock')));
    await pass(tester, const Duration(milliseconds: 300));
    expect(find.text('屏幕已锁定'), findsOneWidget);
    // The bars are gone, the lock stays for a moment.
    expect(tester.widget<AnimatedOpacity>(find.ancestor(of: find.byType(TouchPlayerBars), matching: find.byType(AnimatedOpacity)).first).opacity, 0);

    player.playTo(const Duration(minutes: 5));
    final seeks = player.seeks.length;
    await doubleTap(tester, Offset(rect.left + rect.width * 0.85, rect.center.dy));
    await tester.dragFrom(rect.center, Offset(rect.width / 2, 0));
    await tester.pump();
    expect(player.seeks.length, seeks);
    expect(calls('setBrightness'), isEmpty);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(find.text('屏幕已锁定，点左侧的锁解锁'), findsOneWidget);

    await tester.tap(find.byKey(const Key('touch-lock')));
    await pass(tester, const Duration(milliseconds: 300));
    await doubleTap(tester, Offset(rect.left + rect.width * 0.85, rect.center.dy));
    expect(player.seeks.length, seeks + 1);
    await leave(tester);
  });

  testWidgets('the screen stays on while playing; picture-in-picture is armed and shows the picture alone', (tester) async {
    await play(tester, size: phoneLandscape);
    expect((calls('keepScreenOn').last.arguments as Map)['on'], isTrue);
    expect((calls('setPip').last.arguments as Map)['enabled'], isTrue);

    await doubleTap(tester, picture(tester).center);
    expect(player.state.playing, isFalse);
    expect((calls('keepScreenOn').last.arguments as Map)['on'], isFalse);
    expect((calls('setPip').last.arguments as Map)['enabled'], isFalse);
    await doubleTap(tester, picture(tester).center);

    // The system turns the window into picture-in-picture: no controls, no lock.
    await messenger.handlePlatformMessage(
      'yingzhou/playback',
      const StandardMethodCodec().encodeMethodCall(MethodCall('pip', {'inPip': true})),
      (_) {},
    );
    await tester.tapAt(picture(tester).center);
    await pass(tester, const Duration(milliseconds: 400));
    expect(find.byKey(const Key('touch-lock')), findsNothing);
    expect(tester.widget<AnimatedOpacity>(find.ancestor(of: find.byType(TouchPlayerBars), matching: find.byType(AnimatedOpacity)).first).opacity, 0);
    // The window's own button.
    await messenger.handlePlatformMessage(
      'yingzhou/playback',
      const StandardMethodCodec().encodeMethodCall(MethodCall('pipAction', {'action': 'toggle'})),
      (_) {},
    );
    await tester.pump();
    expect(player.state.playing, isFalse);
    await messenger.handlePlatformMessage(
      'yingzhou/playback',
      const StandardMethodCodec().encodeMethodCall(MethodCall('pip', {'inPip': false})),
      (_) {},
    );
    await tester.pump();
    await leave(tester);
    expect((calls('keepScreenOn').last.arguments as Map)['on'], isFalse);
    expect((calls('setPip').last.arguments as Map)['enabled'], isFalse);
  });

  testWidgets('leaving the app without picture-in-picture pauses', (tester) async {
    await play(tester, size: phoneLandscape);
    expect(player.state.playing, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(player.state.playing, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await leave(tester);
  });

  testWidgets('a tablet: episodes under the picture upright, the picture with its bars on its side', (tester) async {
    await play(tester, size: const Size(800, 1280), formFactor: FormFactor.tablet);
    expect(find.byType(PlayerPhoneInfo), findsOneWidget);
    await turn(tester, const Size(1280, 800));
    expect(find.byType(PlayerPhoneInfo), findsNothing);
    expect(lastUiMode(), isNot('SystemUiMode.immersiveSticky'), reason: 'turning a tablet does not hide the bars');
    await showControls(tester);
    await press(tester, const Key('touch-fullscreen'));
    expect(lastUiMode(), 'SystemUiMode.immersiveSticky');
    await tester.binding.handlePopRoute();
    await pass(tester, const Duration(milliseconds: 200));
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(lastUiMode(), 'SystemUiMode.edgeToEdge');
    expect(lastOrientations(), isEmpty, reason: 'a tablet turns freely again');
    await leave(tester);
  });

  testWidgets('desktops keep the mouse player', (tester) async {
    await play(tester, size: const Size(1400, 900), formFactor: FormFactor.desktop);
    expect(find.byType(TouchGestureLayer), findsNothing);
    expect(find.byType(TouchPlayerBars), findsNothing);
    expect(calls('keepScreenOn'), isEmpty);
    expect(system.where((c) => c.method == 'SystemChrome.setPreferredOrientations'), isEmpty);
    await leave(tester);
  });

  testWidgets('live TV on a phone: channels and guide under the picture, swipes change channel, full screen', (tester) async {
    FormFactors.debugOverride = FormFactor.phone;
    resize(tester, phone);
    tester.view.devicePixelRatio = ratio;
    addTearDown(tester.view.reset);
    player = FakePlayer();
    final engine = fakeEngine(hasConfig: true);
    await tester.pumpWidget(
      TvboxApp(state: AppState(clientFactory: (url) => EngineClient(url, httpClient: engine), playerBackend: () => player.backend())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('直播'));
    await pass(tester, const Duration(seconds: 1));
    expect(find.text('频道'), findsOneWidget);
    expect(find.text('节目单'), findsOneWidget);
    expect(player.opened.last, 'https://cdn.test/live/a.m3u8');

    final rect = picture(tester);
    expect(rect.width, phone.width);
    await tester.dragFrom(rect.center, Offset(-rect.width / 3, 0));
    await pass(tester, const Duration(milliseconds: 500));
    expect(player.opened.last, 'https://cdn.test/live/b.m3u8', reason: 'a swipe to the left is the next channel');
    await tester.dragFrom(rect.center, Offset(rect.width / 3, 0));
    await pass(tester, const Duration(milliseconds: 500));
    expect(player.opened.last, 'https://cdn.test/live/a.m3u8');

    await tester.tap(find.text('节目单'));
    await pass(tester, const Duration(milliseconds: 500));
    expect(find.textContaining('节目 1'), findsWidgets);

    await tester.tap(find.byKey(const Key('live-fullscreen')));
    await tester.pump();
    expect(lastOrientations(), ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight']);
    await turn(tester, phoneLandscape);
    expect(find.byType(NavigationBar), findsNothing, reason: 'full screen hides the navigation');
    expect(find.byType(NavigationRail), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(lastOrientations(), ['DeviceOrientation.portraitUp']);
    await turn(tester, phone);
    expect(find.byType(NavigationBar), findsOneWidget);
    await leave(tester);
  });
}
