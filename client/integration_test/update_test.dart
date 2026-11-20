// The 网络 and 更新 cards in the real desktop app:
//   engine: tvbox-engine --demo --port <port>
//   flutter test integration_test/update_test.dart -d windows --dart-define=ENGINE_URL=http://127.0.0.1:<port> --dart-define=SHOT_DIR=<dir>
// 测速 has the demo engine fetch a ~100-byte file of this repository through every preset (real network); the
// update check reads a latest.json served by the test itself, then the real address once (nothing is downloaded).
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/pages/sources_page.dart';
import 'package:tvbox_client/settings.dart';
import 'package:tvbox_client/update/update_backend.dart';
import 'package:tvbox_client/update/update_backend_io.dart';
import 'package:tvbox_client/update/update_client.dart';
import 'package:tvbox_client/update/update_service.dart';

const engineUrl = String.fromEnvironment('ENGINE_URL', defaultValue: 'http://127.0.0.1:19978');
const shotDir = String.fromEnvironment('SHOT_DIR');

/// The 网络 and 更新 cards in the real desktop app, against a demo engine: GitHub acceleration's presets and 测速
/// (the engine really fetches the small probe file through each preset), then 检查更新 against a local
/// latest.json announcing a newer version (nothing is downloaded), then once against the real address.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> wait(WidgetTester tester, Duration d) async {
    final end = DateTime.now().add(d);
    while (DateTime.now().isBefore(end)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
  }

  Future<void> until(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 30)}) async {
    final end = DateTime.now().add(timeout);
    while (finder.evaluate().isEmpty) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting for $finder');
      await wait(tester, const Duration(milliseconds: 200));
    }
  }

  Future<void> mark(WidgetTester tester, String step) async {
    print('MARK:$step');
    await wait(tester, const Duration(milliseconds: 600));
    if (shotDir.isNotEmpty) {
      final element = find.byType(MaterialApp).evaluate().first;
      await tester.runAsync(() async {
        final image = await captureImage(element);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$shotDir/update-$step.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }
  }

  String text(Key key) => (find.byKey(key).evaluate().single.widget as Text).data!;

  testWidgets('GitHub acceleration presets with 测速, and checking for an update', (tester) async {
    MediaKit.ensureInitialized();
    // latest.json as the release job writes it, served here.
    final server = (await tester.runAsync(() => HttpServer.bind(InternetAddress.loopbackIPv4, 0)))!;
    server.listen((request) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'version': '9.9.9',
          'tag': 'v9.9.9',
          'date': '2026-12-01',
          'notes': '### 2026-12-01（演示）\n\n- **检查更新**：有新版本时提示，并下载这台设备的安装包。\n- GitHub 加速代理可以从列表里选，并能「测速」。\n',
          'assets': {
            'windows-x64': {'name': 'yingzhou-windows-x64-setup.exe', 'size': 123456789},
          },
        }),
      );
      request.response.close();
    });
    addTearDown(() => server.close(force: true));

    final settings = MemorySettings();
    final state = AppState(clientFactory: (url) => EngineClient(url), engineUrl: engineUrl, settings: settings);
    UpdateService.debugUse(
      state,
      UpdateService(settings: settings, backend: IoUpdateBackend(UpdateClient(latestUrl: 'http://127.0.0.1:${server.port}/latest.json'))),
    );
    await tester.pumpWidget(TvboxApp(state: state));
    await until(tester, find.text('源'));
    final connecting = DateTime.now().add(const Duration(seconds: 60));
    while (state.engineSettings == null) {
      if (DateTime.now().isAfter(connecting)) fail('the demo engine at $engineUrl did not answer');
      await wait(tester, const Duration(milliseconds: 200));
    }
    await tester.tap(find.text('源'));
    await wait(tester, const Duration(seconds: 1));

    // 网络: on, then measured.
    final toggle = find.byKey(const Key('github-proxy-switch'));
    await tester.ensureVisible(toggle);
    // The engine may still have it on from an earlier run.
    if (!tester.widget<SwitchListTile>(toggle).value) await tester.tap(toggle);
    final probe = find.byKey(const Key('github-proxy-probe'));
    final ready = DateTime.now().add(const Duration(seconds: 30));
    while (probe.evaluate().isEmpty || tester.widget<FilledButton>(probe).onPressed == null) {
      if (DateTime.now().isAfter(ready)) fail('测速 did not become available');
      await wait(tester, const Duration(milliseconds: 200));
    }
    await tester.tap(probe);
    await until(tester, find.textContaining('直连 GitHub：'), timeout: const Duration(seconds: 20));
    print('PROBE:${text(const Key('github-proxy-probe-status'))}');
    for (final e in find.byWidgetPredicate((w) => w is ListTile && (w.key as ValueKey?)?.value.toString().startsWith('github-proxy-preset-') == true).evaluate()) {
      final tile = e.widget as ListTile;
      final trailing = tile.trailing is Tooltip ? ((tile.trailing as Tooltip).child as Text).data : '-';
      print('PROBE:${(tile.title as Text).data} $trailing');
    }
    await tester.ensureVisible(find.byKey(const Key('github-proxy-probe')));
    await mark(tester, 'probe');

    // 更新: a newer version from the local latest.json.
    // At the bottom of the page, after the demo config's sites: built once scrolled to.
    await tester.scrollUntilVisible(
      find.byKey(const Key('update-check')),
      400,
      scrollable: find.descendant(of: find.byType(SourcesPage), matching: find.byType(Scrollable)).first,
    );
    await wait(tester, const Duration(milliseconds: 500));
    await mark(tester, 'card');
    await tester.tap(find.byKey(const Key('update-check')));
    await until(tester, find.byKey(const Key('update-dialog')));
    expect(find.text('发现新版本 9.9.9'), findsOneWidget);
    expect(find.text('检查更新：有新版本时提示，并下载这台设备的安装包。'), findsOneWidget);
    expect(find.byKey(const Key('update-download')), findsOneWidget, reason: 'a Windows package is listed');
    print('ROUTE:${text(const Key('update-route'))}');
    await mark(tester, 'dialog');
    await tester.tap(find.text('以后再说'));
    await wait(tester, const Duration(milliseconds: 500));
    print('STATUS:${text(const Key('update-status'))} | ${text(const Key('update-status-route'))}');
    await mark(tester, 'found');

    // The real address, before any release published it: says why it found nothing.
    final real = await tester.runAsync(() => UpdateBackend().check());
    print('REAL:${real!.ok ? 'found ${real.release!.version} via ${real.routeLabel}' : real.failures.join('; ')}');
  });
}
