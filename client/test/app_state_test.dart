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
  Future<http.StreamedResponse> send(http.BaseRequest request) => open() ? inner.send(request) : Future.error(http.ClientException('refused'));
}

/// Sends each request to the client [pick] chooses for it.
class _Route extends http.BaseClient {
  _Route(this.pick);

  final http.Client Function(http.BaseRequest request) pick;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => pick(request).send(request);
}

class _FakeLocalEngine implements LocalEngine {
  _FakeLocalEngine({this.output = const []});

  final List<String> output;
  int? startedOnPort;
  bool? startedWithAndroidJni;
  bool get started => startedOnPort != null && output.isEmpty;

  @override
  Future<bool> start(int port, {bool androidJni = false}) async {
    startedOnPort = port;
    startedWithAndroidJni = androidJni;
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
    expect(local.startedWithAndroidJni, isFalse);
    expect(state.connected, isTrue);
    expect(state.startingEngine, isFalse);
    expect(state.error, isNull);
  });

  test('applies the local JNI preference to the next bundled engine launch', () async {
    final settings = MemorySettings();
    final engine = fakeEngine(hasConfig: true);
    AppState createState(_FakeLocalEngine? local) => AppState(
      settings: settings,
      localEngine: local,
      clientFactory: (url) => EngineClient(url, httpClient: _Gate(engine, () => local?.started == true)),
      waitStep: const Duration(milliseconds: 1),
    );

    final running = _FakeLocalEngine();
    final state = createState(running);
    expect(state.canConfigureLocalJni, isTrue);
    expect(createState(null).canConfigureLocalJni, isFalse);
    await state.start();
    await state.setLocalAndroidJni(true);
    expect(running.startedWithAndroidJni, isFalse);

    final next = _FakeLocalEngine();
    final restarted = createState(next);
    await restarted.start();
    expect(restarted.localAndroidJni, isTrue);
    expect(next.startedWithAndroidJni, isTrue);
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
    expect(state.canConfigureLocalJni, isFalse);
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

  test('a subscription that fails to load keeps the engine connected, says why, and retries', () async {
    final engine = fakeEngine(hasConfig: true);
    var failConfig = true;
    final failing = MockClient(
      (_) async => http.Response(
        '{"error":{"code":"CONFIG_LOAD_FAILED","message":"http://example.test/tv.json: timeout"}}',
        502,
        headers: {'content-type': 'application/json'},
      ),
    );
    final client = _Route((request) => failConfig && request.url.path == '/api/v1/config' ? failing : engine);
    final state = AppState(clientFactory: (url) => EngineClient(url, httpClient: client));
    await state.start();
    expect(state.connected, isTrue);
    expect(state.hasConfig, isFalse);
    expect(state.loadingConfig, isFalse);
    expect(state.configError, contains('timeout'));

    failConfig = false;
    await state.reloadConfig();
    expect(state.hasConfig, isTrue);
    expect(state.configError, isNull);
    expect(state.currentSiteKey, 'cms');
  });

  test('a saved site that no longer exists falls back to the first browsable one', () async {
    final settings = MemorySettings();
    await settings.setString('siteKey', 'gone');
    final engine = fakeEngine(hasConfig: true);
    final state = AppState(
      clientFactory: (url) => EngineClient(url, httpClient: engine),
      settings: settings,
    );
    await state.start();
    expect(state.currentSiteKey, 'cms');
  });
}
