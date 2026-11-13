import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/engine/local_engine.dart';
import 'package:tvbox_client/settings.dart';

import 'fake_engine.dart';

/// Refuses connections until [open] says otherwise, then forwards to [inner].
class _Gate extends http.BaseClient {
  _Gate(this.inner, this.open);

  final http.Client inner;
  final bool Function() open;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      open() ? inner.send(request) : Future.error(http.ClientException('refused'));
}

class _FakeLocalEngine implements LocalEngine {
  _FakeLocalEngine({this.output = const []});

  final List<String> output;
  int? startedOnPort;
  bool get started => startedOnPort != null && output.isEmpty;

  @override
  Future<bool> start(int port) async {
    startedOnPort = port;
    return true;
  }

  @override
  List<String> get recentOutput => output;

  @override
  void stop() {}
}

void main() {
  test('restores the saved engine and site, and remembers changes', () async {
    final settings = MemorySettings();
    await settings.setString('engineUrl', 'http://192.168.1.20:9978');
    await settings.setString('siteKey', 'cms');
    final urls = <Uri>[];
    final engine = fakeEngine(hasConfig: true);
    final state = AppState(
      clientFactory: (url) {
        urls.add(url);
        return EngineClient(url, httpClient: engine);
      },
      settings: settings,
    );

    await state.start();
    expect(urls.single.toString(), 'http://192.168.1.20:9978');
    expect(state.currentSiteKey, 'cms');

    await state.connect('http://10.0.0.5:9978');
    expect(settings.getString('engineUrl'), 'http://10.0.0.5:9978');
  });

  test('starts the bundled engine when nothing answers locally, then connects', () async {
    final local = _FakeLocalEngine();
    final engine = fakeEngine(hasConfig: true);
    // Unreachable until the fake engine is "started".
    final client = _Gate(engine, () => local.started);
    final state = AppState(
      clientFactory: (url) => EngineClient(url, httpClient: client),
      localEngine: local,
      waitStep: const Duration(milliseconds: 1),
    );
    await state.start();
    expect(local.startedOnPort, 9978);
    expect(state.connected, isTrue);
    expect(state.startingEngine, isFalse);
    expect(state.error, isNull);
  });

  test('does not start anything for a remote engine', () async {
    final local = _FakeLocalEngine();
    final state = AppState(
      clientFactory: (url) => EngineClient(url, httpClient: MockClient((_) => throw http.ClientException('refused'))),
      engineUrl: 'http://192.168.1.20:9978',
      localEngine: local,
      waitStep: const Duration(milliseconds: 1),
    );
    await state.start();
    expect(local.startedOnPort, isNull);
    expect(state.connected, isFalse);
  });

  test('reports the engine output when the bundled engine never answers', () async {
    final local = _FakeLocalEngine(output: ['Error: could not find java']);
    final state = AppState(
      clientFactory: (url) => EngineClient(url, httpClient: MockClient((_) => throw http.ClientException('refused'))),
      localEngine: local,
      waitStep: const Duration(milliseconds: 1),
    );
    await state.start();
    expect(state.connected, isFalse);
    expect(state.error, contains('could not find java'));
  });

  test('a saved site that no longer exists falls back to the first browsable one', () async {
    final settings = MemorySettings();
    await settings.setString('siteKey', 'gone');
    final engine = fakeEngine(hasConfig: true);
    final state = AppState(clientFactory: (url) => EngineClient(url, httpClient: engine), settings: settings);
    await state.start();
    expect(state.currentSiteKey, 'cms');
  });
}
