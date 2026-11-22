import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/engine/go_engine.dart';
import 'package:tvbox_client/engine/models.dart';
import 'package:tvbox_client/pages/sources_page.dart';
import 'package:tvbox_client/settings.dart';

class _NativeGo implements GoEngine {
  _NativeGo(this.port);

  final int port;
  int starts = 0;
  int stops = 0;
  bool fail = false;
  final started = Completer<void>();
  Completer<void>? gate;

  @override
  Future<int> start() async {
    starts++;
    if (!started.isCompleted) started.complete();
    if (gate != null) await gate!.future;
    if (fail) throw const EngineException('GO_START', '启动失败');
    return port;
  }

  @override
  Future<void> stop() async => stops++;
}

const _remote = 'http://192.168.1.20:9978';

EngineClient _client(Uri address, {Future<void> Function()? beforeInfo, List<String>? requests}) {
  final local = address.host == '127.0.0.1';
  return EngineClient(
    address,
    httpClient: MockClient((request) async {
      final path = request.url.path;
      requests?.add(path);
      Object body;
      switch (path) {
        case '/api/v1/info':
          await beforeInfo?.call();
          body = {
            'name': local ? 'yingzhou-go' : 'desktop',
            'protocol': 1,
            'version': 'test',
            'platform': local ? 'ios' : 'desktop',
            'capabilities': {'go': local},
          };
        case '/api/v1/settings':
          body = {};
        case '/api/v1/subscriptions':
          body = [];
        case '/api/v1/config':
          body = {'subscriptionId': 'sample', 'url': 'https://example.test/config.json', 'sites': 1, 'parses': 0, 'lives': 0};
        case '/api/v1/sites':
          body = [
            {'key': 'sample', 'name': 'Sample', 'type': 3, 'runtime': local ? 'go' : 'cms', 'searchable': true, 'quickSearch': true, 'filterable': false},
          ];
        default:
          return http.Response('{"error":{"code":"NOT_FOUND","message":"unavailable"}}', 404);
      }
      return http.Response(jsonEncode(body), 200);
    }),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('native channel asks for an assigned port and surfaces bad replies', () async {
    const channel = MethodChannel('yingzhou/go_engine');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    var reply = 43001;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'start' ? reply : null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    const engine = GoEngine();
    expect(await engine.start(), 43001);
    expect(calls.single.arguments, {'port': 0});
    await engine.stop();
    expect(calls.last.method, 'stop');
    expect(calls.last.arguments, isNull);
    reply = 0;
    await expectLater(engine.start(), throwsA(isA<EngineException>()));
  });

  test('first start uses built-in Go, saved selections restore with a new port', () async {
    final settings = MemorySettings();
    final requests = <String>[];
    final native = _NativeGo(43001);
    AppState make(_NativeGo engine) => AppState(
      settings: settings,
      goEngine: engine,
      clientFactory: (address) => _client(address, requests: requests),
    );
    final state = make(native);
    await state.start();
    expect(state.usingBuiltInGo, isTrue);
    expect(state.engineUrl, 'http://127.0.0.1:43001');
    expect(state.currentSite?.runtime, SiteRuntime.go);
    expect(requests, isNot(contains('/api/v1/settings')));
    expect(settings.getString('engineUrl'), isNull);
    await state.network.saveHttp('home:8080', updates: true);

    await state.connect(_remote);
    expect(state.info?.name, 'desktop');
    expect(native.stops, 1);
    expect(settings.getString('engineUrl'), _remote);
    expect(state.network.updateProxy, isEmpty);
    state.dispose();
    final next = _NativeGo(43002);
    final restored = make(next);
    await restored.start();
    expect(restored.usingBuiltInGo, isFalse);
    expect(next.starts, 0);
    await restored.useBuiltInGo();
    expect(restored.network.updateProxy, 'home:8080');
    expect(settings.getString('engineUrl'), _remote);
    restored.dispose();

    final again = make(_NativeGo(43003));
    await again.start();
    expect(again.engineUrl, 'http://127.0.0.1:43003');
    expect(again.remoteEngineUrl, _remote);
    again.dispose();
  });

  test('existing remote preference survives the upgrade and connection failures can be retried', () async {
    final settings = MemorySettings();
    await settings.setString('engineUrl', _remote);
    final native = _NativeGo(43001)..fail = true;
    final state = AppState(
      settings: settings,
      goEngine: native,
      clientFactory: (address) => _client(
        address,
        beforeInfo: () async {
          if (address.host != '127.0.0.1') throw http.ClientException('refused');
        },
      ),
    );
    await state.start();
    expect(native.starts, 0);
    expect(state.connected, isFalse);
    await state.useBuiltInGo();
    expect(state.error, '启动失败');
    expect(state.startingEngine, isFalse);
    native.fail = false;
    await state.connect();
    expect(state.connected, isTrue);
    expect(state.error, isNull);
    expect(settings.getString('engineUrl'), _remote);
    state.dispose();
  });

  test('a switch during native startup stops the superseded server, slow remote responses cannot replace Go', () async {
    final native = _NativeGo(43001)..gate = Completer<void>();
    final remoteInfo = Completer<void>();
    final releaseRemote = Completer<void>();
    final state = AppState(
      goEngine: native,
      clientFactory: (address) => _client(
        address,
        beforeInfo: () async {
          if (address.host != '127.0.0.1') {
            remoteInfo.complete();
            await releaseRemote.future;
          }
        },
      ),
    );
    final initial = state.start();
    await native.started.future;
    final remote = state.connect(_remote);
    native.gate!.complete();
    await remoteInfo.future;
    expect(native.stops, 1);
    await state.useBuiltInGo();
    releaseRemote.complete();
    await Future.wait([initial, remote]);
    expect(state.info?.name, 'yingzhou-go');
    expect(state.currentSite?.runtime, SiteRuntime.go);
    expect(state.busy, isFalse);
    state.dispose();
  });

  test('an address serving an ordinary webpage reports an error and offers the local engine again', () async {
    final state = AppState(
      goEngine: _NativeGo(43000),
      clientFactory: (address) =>
          address.host == '127.0.0.1' ? _client(address) : EngineClient(address, httpClient: MockClient((_) async => http.Response('<html></html>', 200))),
    );
    await state.start();
    await state.connect(_remote);
    expect(state.error, contains('引擎地址'));
    expect(state.connected, isFalse);
    await state.useBuiltInGo();
    expect(state.connected, isTrue);
    expect(state.error, isNull);
    state.dispose();
  });

  testWidgets('the source page switches between built-in and remote engines', (tester) async {
    final state = AppState(goEngine: _NativeGo(43001), clientFactory: _client);
    await state.start();
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: const MaterialApp(home: SourcesPage()),
      ),
    );
    await tester.tap(find.text('远程引擎'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '引擎地址'), _remote);
    await tester.tap(find.text('连接'));
    await tester.pumpAndSettle();
    expect(state.usingBuiltInGo, isFalse);
    expect(state.info?.name, 'desktop');
    await tester.tap(find.text('本机 Go'));
    await tester.pumpAndSettle();
    expect(state.info?.name, 'yingzhou-go');
    expect(find.widgetWithText(TextField, '引擎地址'), findsNothing);
  });
}
