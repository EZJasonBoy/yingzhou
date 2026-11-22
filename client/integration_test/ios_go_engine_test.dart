import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tvbox_client/engine/engine_client.dart';

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
    const channel = MethodChannel('yingzhou/go_engine');
    Future<EngineClient> start() async {
      final port = await channel.invokeMethod<int>('start', {'port': 0});
      expect(port, inInclusiveRange(1, 65535));
      return EngineClient(Uri.parse('http://127.0.0.1:$port'));
    }

    addTearDown(() => channel.invokeMethod<void>('stop'));
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
      if (request.uri.path == '/config.json') {
        response.headers.contentType = ContentType.json;
        response.write(config);
      } else if (request.uri.path == '/clip.wav') {
        response.headers.contentType = ContentType('audio', 'wav');
        response.contentLength = wave.length;
        response.add(wave);
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });

    final first = await start();
    addTearDown(first.close);
    final info = await first.info();
    expect(info.protocol, 1);
    expect(info.capabilities['jar'], isNot(true));
    final subscription = await first.addSubscription('$base/config.json');
    expect((await first.activate(subscription.id)).sites, 1);
    expect((await first.sites()).single.key, 'fixture');
    expect((await first.home('fixture')).list, isEmpty);
    final detail = await first.detail('fixture', '$base/clip.wav');
    final line = detail.lines.single;
    final playback = await first.resolvePlay('fixture', line.name, line.episodes.single.id);
    expect(playback.isDirect, isTrue);
    expect(playback.url, '$base/clip.wav');

    MediaKit.ensureInitialized();
    final player = Player();
    addTearDown(player.dispose);
    await player.open(Media(playback.url));
    await player.stream.position.firstWhere((position) => position.inMilliseconds >= 250).timeout(const Duration(seconds: 30));
    await player.stop();
    await channel.invokeMethod<void>('stop');
    final restored = await start();
    addTearDown(restored.close);
    expect((await restored.config()).subscriptionId, subscription.id);
    expect((await restored.sites()).single.key, 'fixture');
    await restored.removeSubscription(subscription.id);
  }, skip: !Platform.isIOS);
}
