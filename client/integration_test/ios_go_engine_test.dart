import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/engine/go_engine.dart';
import 'package:tvbox_client/engine/models.dart';
import 'package:tvbox_client/settings.dart';

Uint8List audioFixture() {
  const sampleRate = 8000;
  const samples = sampleRate * 3;
  final wave = Uint8List(44 + samples * 2);
  final data = ByteData.sublistView(wave);
  wave.setRange(0, 4, ascii.encode('RIFF'));
  data.setUint32(4, wave.length - 8, Endian.little);
  wave.setRange(8, 16, ascii.encode('WAVEfmt '));
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  wave.setRange(36, 40, ascii.encode('data'));
  data.setUint32(40, samples * 2, Endian.little);
  return wave;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('iOS embeds Go, plays through a subscription and restores it after restart', (tester) async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => origin.close(force: true));
    final base = 'http://127.0.0.1:${origin.port}';
    final wave = audioFixture();
    final config = jsonEncode({
      'sites': [
        {'key': 'fixture', 'name': '本机推送', 'type': 3, 'api': 'csp_Push'},
      ],
    });
    origin.listen((request) async {
      final response = request.response;
      response.headers.contentType = ContentType.json;
      if (request.uri.path == '/config.json') {
        response.write(config);
      } else if (request.uri.path == '/clip.wav') {
        response.headers.contentType = ContentType('audio', 'wav');
        response.contentLength = wave.length;
        response.add(wave);
      } else if (request.uri.path == '/api/v1/info') {
        response.write(jsonEncode({'name': 'remote-fixture', 'version': '1', 'platform': 'remote', 'protocol': 1}));
      } else if (request.uri.path == '/api/v1/subscriptions') {
        response.write('[]');
      } else if (request.uri.path == '/api/v1/settings') {
        response.write('{}');
      } else if (request.uri.path == '/api/v1/config') {
        response.statusCode = HttpStatus.notFound;
        response.write(
          jsonEncode({
            'error': {'code': 'NO_CONFIG', 'message': 'No active subscription'},
          }),
        );
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });

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
    final detail = await state.client.detail('fixture', '$base/clip.wav');
    final line = detail.lines.single;
    final playback = await state.client.resolvePlay('fixture', line.name, line.episodes.single.id);
    expect(playback.isDirect, isTrue);
    expect(playback.url, '$base/clip.wav');

    MediaKit.ensureInitialized();
    final player = Player();
    addTearDown(player.dispose);
    await player.open(Media(playback.url));
    await player.stream.position.firstWhere((position) => position.inMilliseconds >= 250).timeout(const Duration(seconds: 30));
    await player.stop();
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
