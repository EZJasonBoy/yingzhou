import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/discovery.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/engine/models.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/pages/lan_section.dart';
import 'package:tvbox_client/settings.dart';
import 'package:tvbox_client/ui/engine_image.dart';

import 'fake_engine.dart';
import 'fake_lan_engine.dart';

const remote = 'http://192.168.1.5:9978';

class _FakeDiscovery implements EngineDiscovery {
  _FakeDiscovery(this.engines);

  final List<DiscoveredEngine> engines;
  bool started = false;

  @override
  Future<void> start(void Function(List<DiscoveredEngine> engines) onChange) async {
    started = true;
    onChange(engines);
  }

  @override
  Future<void> stop() async => started = false;
}

void main() {
  AppState remoteState(FakeLanEngine engine, {SettingsStore? settings}) => AppState(
    clientFactory: (url) => EngineClient(url, httpClient: engine),
    engineUrl: remote,
    settings: settings,
    waitStep: const Duration(milliseconds: 1),
  );

  test('a remote engine asks for pairing; a wrong code says why, the right one connects and is remembered', () async {
    final engine = FakeLanEngine(fakeEngine(hasConfig: true));
    final settings = MemorySettings();
    final state = remoteState(engine, settings: settings);
    await state.start();
    expect(state.connected, isFalse);
    expect(state.needsPairing, isTrue);
    expect(state.error, contains('配对'));

    await state.requestPairingCode();
    expect(engine.codeRequests, 1, reason: 'opening the dialog makes the engine show a code');

    expect(await state.pair('000000'), isFalse);
    expect(state.pairingError, contains('配对码不对'));
    expect(state.needsPairing, isTrue);

    expect(await state.pair('123456'), isTrue);
    expect(state.connected, isTrue);
    expect(state.hasConfig, isTrue);
    expect(state.needsPairing, isFalse);
    expect(engine.pairedNames.single, isNotEmpty, reason: 'the device names itself');
    expect(settings.getString('engineToken|http://192.168.1.5:9978'), 'dev1.secret');

    // Next start: the kept token is used straight away.
    final again = remoteState(engine, settings: settings);
    await again.start();
    expect(again.connected, isTrue);
    expect(again.needsPairing, isFalse);
  });

  test('the token goes with every request, streamed search included, and never to another engine', () async {
    final engine = FakeLanEngine(fakeEngine(hasConfig: true));
    engine.tokens.add('dev9.secret');
    final settings = MemorySettings();
    await settings.setString('engineToken|http://192.168.1.5:9978', 'dev9.secret');
    final state = remoteState(engine, settings: settings);
    await state.start();
    expect(state.connected, isTrue);
    await state.client.home('cms');
    await state.client.searchAll('推荐').toList();
    await state.client.resolvePlay('cms', '线路一', 'https://cdn.test/1.m3u8');
    final seen = engine.authorizations.where((a) => a.$1 != '/api/v1/info').toList();
    expect(seen.map((a) => a.$1), containsAll(['/api/v1/settings', '/api/v1/config', '/api/v1/sites', '/api/v1/sites/cms/home', '/api/v1/search/stream', '/api/v1/play/resolve']));
    expect(seen.every((a) => a.$2 == 'Bearer dev9.secret'), isTrue, reason: '$seen');

    // Another engine gets its own token (none here), not this one.
    engine.authorizations.clear();
    await state.connect('http://192.168.1.6:9978');
    expect(engine.authorizations.every((a) => a.$2 == null), isTrue);
  });

  test('a revoked token leads back to pairing', () async {
    final engine = FakeLanEngine(fakeEngine(hasConfig: true));
    final state = remoteState(engine);
    await state.start();
    await state.pair('123456');
    expect(state.connected, isTrue);

    engine.revoke('dev1.secret');
    await expectLater(state.client.home('cms'), throwsA(isA<EngineException>().having((e) => e.statusCode, 'status', 401)));
    expect(state.needsPairing, isTrue);
    expect(state.connected, isFalse);
    expect(state.error, contains('重新配对'));

    expect(await state.pair('123456'), isTrue);
    expect(state.connected, isTrue);
  });

  testWidgets('images from the paired engine carry the token; images from elsewhere do not', (tester) async {
    final engine = FakeLanEngine(fakeEngine(hasConfig: true));
    final state = remoteState(engine);
    await state.start();
    await state.pair('123456');
    late BuildContext ctx;
    await tester.pumpWidget(AppScope(state: state, child: Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    })));
    expect(engineImageHeaders(ctx, '$remote/demo/poster/1.png'), {'Authorization': 'Bearer dev1.secret'});
    expect(engineImageHeaders(ctx, 'http://192.168.1.5:9979/x.png'), isNull);
    expect(engineImageHeaders(ctx, 'https://img.example/x.png'), isNull);
  });

  testWidgets('the pairing dialog comes up by itself and connects with the code', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final engine = FakeLanEngine(fakeEngine(hasConfig: true));
    await tester.pumpWidget(TvboxApp(state: remoteState(engine)));
    await tester.pumpAndSettle();
    expect(find.text('与引擎配对'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('pairing-code')), '111111');
    await tester.tap(find.widgetWithText(FilledButton, '配对'));
    await tester.pumpAndSettle();
    expect(find.textContaining('配对码不对'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('pairing-code')), '123456');
    await tester.tap(find.widgetWithText(FilledButton, '配对'));
    await tester.pumpAndSettle();
    expect(find.text('与引擎配对'), findsNothing);
    expect(find.text('推荐片'), findsOneWidget, reason: 'the home page loads from the paired engine');
  });

  testWidgets('cancelling leaves a way back to pairing on the Sources page', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final engine = FakeLanEngine(fakeEngine(hasConfig: true));
    await tester.pumpWidget(TvboxApp(state: remoteState(engine)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('与引擎配对'), findsNothing);
    await tester.tap(find.text('源'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('lan-pair')));
    await tester.pumpAndSettle();
    expect(find.text('与引擎配对'), findsOneWidget);
  });

  testWidgets('LAN sharing switch on the engine of this machine: code, devices, revoke', (tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final engine = FakeLanEngine(fakeEngine(hasConfig: true), local: true, code: '654321');
    engine.devices = [
      {'id': 'd1', 'name': '客厅电视', 'createdAt': 1, 'lastSeenAt': 2, 'lastAddress': '192.168.1.9'},
    ];
    final state = AppState(clientFactory: (url) => EngineClient(url, httpClient: engine));
    await tester.pumpWidget(TvboxApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('局域网共享'), findsOneWidget);
    expect(find.text('654321'), findsNothing);

    await tester.tap(find.byKey(const Key('lan-sharing-switch')));
    await tester.pumpAndSettle();
    expect(engine.sharing, isTrue);
    expect(find.text('654321'), findsOneWidget);
    expect(find.textContaining('http://192.168.1.5:9978'), findsOneWidget);
    expect(find.text('客厅电视'), findsOneWidget);

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(engine.devices, isEmpty);
    expect(find.text('客厅电视'), findsNothing);

    await tester.tap(find.byKey(const Key('lan-sharing-switch')));
    await tester.pumpAndSettle();
    expect(engine.sharing, isFalse);
    // Leave no poll timer behind.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('engines found on the LAN can be picked, then paired', (tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final lan = FakeLanEngine(fakeEngine(hasConfig: true));
    final discovery = _FakeDiscovery([const DiscoveredEngine(name: '书房电脑', url: 'http://192.168.1.7:9978')]);
    final state = AppState(clientFactory: (url) => EngineClient(url, httpClient: lan), engineUrl: remote);
    await tester.pumpWidget(AppScope(state: state, child: MaterialApp(home: Scaffold(body: SingleChildScrollView(child: LanSection(discovery: discovery))))));
    // (A spinner turns while searching, so the frames are pumped one by one.)
    await tester.tap(find.byKey(const Key('lan-search')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(discovery.started, isTrue);
    expect(find.text('书房电脑'), findsOneWidget);
    await tester.tap(find.text('书房电脑'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(state.engineUrl, 'http://192.168.1.7:9978');
    expect(state.needsPairing, isTrue);
    await tester.tap(find.byKey(const Key('lan-search')));
    await tester.pump();
    expect(discovery.started, isFalse);
  });
}
