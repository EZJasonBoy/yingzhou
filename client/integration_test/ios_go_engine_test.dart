import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/engine/go_engine.dart';
import 'package:tvbox_client/engine/models.dart';
import 'package:tvbox_client/player_backend.dart';
import 'package:tvbox_client/settings.dart';

import 'ios_http_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('iOS embeds Go, plays through a subscription and restores it after restart', (tester) async {
    final events = ReceivePort();
    addTearDown(events.close);
    final port = Completer<int>();
    final requests = <String>[];
    events.listen((event) {
      if (event is int) port.complete(event);
      if (event is String) {
        requests.add(event);
        debugPrint('fixture $event');
      }
    });
    final fixture = await Isolate.spawn(serveIosFixture, events.sendPort);
    addTearDown(() => fixture.kill(priority: Isolate.immediate));
    final base = 'http://127.0.0.1:${await port.future.timeout(const Duration(seconds: 15))}';

    final state = AppState(clientFactory: (url) => EngineClient(url), settings: MemorySettings(), goEngine: createGoEngine());
    addTearDown(state.dispose);
    await state.start();
    expect(state.usingBuiltInGo, isTrue);
    expect(state.info?.capabilities['go'], isTrue, reason: state.error);
    expect(state.info?.capabilities['jar'], isNot(true));
    final localUrl = Uri.parse(state.engineUrl);
    await state.importSubscription('$base/config.json');
    final subscription = state.subscriptions.singleWhere((entry) => entry.url == '$base/config.json');
    expect(state.summary?.subscriptionId, subscription.id, reason: state.error);
    expect(state.browsableSites.single.key, 'fixture');
    expect((await state.client.home('fixture')).list, isEmpty);
    final detail = await state.client.detail('fixture', '$base/clip.mp4');
    final line = detail.lines.single;
    final playback = await state.client.resolvePlay('fixture', line.name, line.episodes.single.id);
    expect(playback.isDirect, isTrue);
    expect(playback.url, '$base/clip.mp4');

    MediaKit.ensureInitialized();
    final backend = mediaKitBackend();
    final player = backend.player;
    addTearDown(player.dispose);
    final errors = <String>[];
    final errorEvents = player.stream.error.listen((message) {
      errors.add(message);
      debugPrint('player error $message');
    });
    final logEvents = player.stream.log.listen((message) => debugPrint('mpv $message'));
    var furthest = Duration.zero;
    final positions = player.stream.position.listen((position) {
      if (position > furthest) furthest = position;
    });
    addTearDown(errorEvents.cancel);
    addTearDown(logEvents.cancel);
    addTearDown(positions.cancel);
    await tester.pumpWidget(MaterialApp(home: backend.view));
    await player.open(Media(playback.url, httpHeaders: playback.headers)).timeout(const Duration(seconds: 30));
    final elapsed = Stopwatch()..start();
    while (elapsed.elapsed < const Duration(seconds: 30)) {
      if (furthest.inMilliseconds >= 250 && player.state.videoParams.w == 64 && player.state.videoParams.h == 48) break;
      await tester.pump(const Duration(milliseconds: 100));
    }
    final diagnostics = 'requests=$requests errors=$errors furthest=$furthest state=${player.state}';
    expect(requests.any((entry) => entry.startsWith('GET /clip.mp4 ')), isTrue, reason: diagnostics);
    expect(player.state.videoParams.w, 64, reason: diagnostics);
    expect(player.state.videoParams.h, 48, reason: diagnostics);
    expect(furthest.inMilliseconds, greaterThanOrEqualTo(250), reason: diagnostics);
    debugPrint('decoded ${player.state.videoParams.w}×${player.state.videoParams.h} video, played $furthest');
    await player.stop();
    await tester.pumpWidget(const SizedBox.shrink());
    await state.connect(base);
    expect(state.info?.name, 'remote-fixture', reason: state.error);
    expect(state.usingBuiltInGo, isFalse);
    expect(state.subscriptions, isEmpty);
    final stopped = EngineClient(localUrl);
    addTearDown(stopped.close);
    await expectLater(stopped.info(), throwsA(isA<EngineException>()));
    await state.useBuiltInGo();
    expect(state.info?.capabilities['go'], isTrue, reason: state.error);
    expect(state.summary?.subscriptionId, subscription.id);
    expect(state.browsableSites.single.key, 'fixture');
    await state.removeSubscription(subscription.id);
  }, skip: !Platform.isIOS);
}
