import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/settings.dart';
import 'package:tvbox_client/ui/device_form.dart';
import 'package:tvbox_client/update/update_models.dart';
import 'package:tvbox_client/update/update_service.dart';

import 'fake_engine.dart';
import 'update_test.dart' show FakeUpdateBackend, newerRelease;

void main() {
  /// The app with [backend] standing in for the network; on the 源 page unless [tv].
  Future<(AppState, UpdateService)> pumpApp(
    WidgetTester tester,
    FakeUpdateBackend backend, {
    bool tv = false,
    SettingsStore? settings,
    DateTime Function()? clock,
  }) async {
    if (tv) {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 2;
    } else {
      tester.view.physicalSize = const Size(1400, 3000);
      tester.view.devicePixelRatio = 1;
    }
    addTearDown(tester.view.reset);
    final engine = fakeEngine(hasConfig: true);
    final state = AppState(clientFactory: (url) => EngineClient(url, httpClient: engine), settings: settings);
    final service = UpdateService(settings: state.settings, network: state.network, backend: backend, clock: clock);
    UpdateService.debugUse(state, service);
    final app = TvboxApp(state: state);
    await tester.pumpWidget(tv ? DeviceFormScope.fixed(DeviceForm.tv, child: app) : app);
    await tester.pumpAndSettle();
    if (!tv) {
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('update-check')));
      await tester.pumpAndSettle();
    }
    return (state, service);
  }

  String text(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(Key(key))).data!;

  /// Whether the focus is on the widget with [key] or inside it.
  bool focusedWithin(Key key) {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    if (context.widget.key == key) return true;
    var found = false;
    context.visitAncestorElements((e) {
      found = e.widget.key == key;
      return !found;
    });
    return found;
  }

  testWidgets('check now: a newer version shows what changed, and the desktop saves the package', (tester) async {
    final backend = FakeUpdateBackend(result: newerRelease());
    final (_, service) = await pumpApp(tester, backend);
    expect(text(tester, 'update-version'), '映舟 0.4.1421356');
    expect(text(tester, 'update-status'), '还没有检查过');
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('update-auto'))).value, isFalse, reason: 'off by default');
    expect(backend.checks, isEmpty, reason: 'nothing is asked on its own');

    await tester.tap(find.byKey(const Key('update-check')));
    await tester.pumpAndSettle();
    expect(backend.checks.single, ('', ''), reason: 'the GitHub proxy is off: no prefix to fall back to');
    expect(find.byKey(const Key('update-dialog')), findsOneWidget);
    expect(find.text('发现新版本 0.4.0'), findsOneWidget);
    expect(find.textContaining('当前 0.3.14 · 发布于 2026-11-21'), findsOneWidget);
    expect(text(tester, 'update-route'), '更新信息：直连 GitHub');
    // The notes, Markdown taken off.
    expect(find.text('新功能'), findsOneWidget);
    expect(find.text('自动更新：检查新版本'), findsOneWidget);
    expect(find.text('修复了 bug'), findsOneWidget);

    await tester.tap(find.byKey(const Key('update-download')));
    await tester.pumpAndSettle();
    expect(backend.downloads.single, ('https://github.com/Sa1koro/yingzhou/releases/download/v0.4.0/yingzhou-windows-x64-setup.exe', 'yingzhou-windows-x64-setup.exe', ''));
    expect(backend.expectedSizes.single, 1234, reason: 'the size the manifest gives');
    expect(text(tester, 'update-downloaded'), '已下载到 C:/Users/me/Downloads/yingzhou-windows-x64-setup.exe');
    await tester.tap(find.byKey(const Key('update-reveal')));
    await tester.pumpAndSettle();
    expect(backend.revealed.single, 'C:/Users/me/Downloads/yingzhou-windows-x64-setup.exe');

    await tester.tap(find.text('以后再说'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('update-dialog')), findsNothing);
    expect(text(tester, 'update-status'), startsWith('发现新版本 0.4.0（2026-11-21）'));
    expect(text(tester, 'update-status-route'), '获取途径：直连 GitHub');
    expect(text(tester, 'update-download-status'), contains('已下载到'));
    expect(service.last!.newer, isTrue);
    // And again from the card.
    await tester.tap(find.byKey(const Key('update-show')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('update-reveal')), findsOneWidget, reason: 'the download is remembered');
  });

  testWidgets('update settings reflect the HTTP proxy selected in network settings', (tester) async {
    final backend = FakeUpdateBackend();
    final (_, service) = await pumpApp(tester, backend);
    await tester.tap(find.byKey(const Key('update-check')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('update-dialog')), findsNothing);
    expect(text(tester, 'update-status'), startsWith('已是最新版本'));

    backend.result = UpdateCheckResult(current: '0.3.14', at: DateTime.now(), failures: const ['直连 GitHub：连不上']);
    await tester.tap(find.byKey(const Key('update-check')));
    await tester.pumpAndSettle();
    expect(text(tester, 'update-status'), '检查失败：直连 GitHub：连不上');
    expect(text(tester, 'update-route-explain'), contains('设置 → 网络'));
    expect(find.byKey(const Key('update-proxy')), findsNothing);
    await tester.ensureVisible(find.text('网络代理（HTTP）'));
    await tester.tap(find.text('网络代理（HTTP）'));
    await tester.pumpAndSettle();
    final address = find.byKey(const Key('network-proxy-address'));
    final save = find.byKey(const Key('network-proxy-save'));
    await tester.enterText(address, '127.0.0.1');
    await tester.tap(find.byKey(const Key('network-proxy-updates')));
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('请输入 HTTP 代理地址，例如 127.0.0.1:7890'), findsOneWidget);
    expect(service.network.updateProxy, '');
    await tester.enterText(address, 'http://127.0.0.1:7890/');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(service.network.updateProxy, '127.0.0.1:7890');
    expect(tester.widget<TextField>(address).controller!.text, '127.0.0.1:7890');
    await tester.ensureVisible(find.byKey(const Key('update-check')));
    await tester.tap(find.byKey(const Key('update-check')));
    await tester.pumpAndSettle();
    expect(backend.checks.last, ('', '127.0.0.1:7890'));
    expect(text(tester, 'update-status'), '检查失败：直连 GitHub：连不上（经代理 127.0.0.1:7890）');

    await tester.tap(find.byKey(const Key('update-auto')));
    await tester.pumpAndSettle();
    expect(service.autoCheck, isTrue);
    expect(find.textContaining('每天最多检查一次'), findsOneWidget);
  });

  testWidgets('Android downloads the package through current network settings before opening the installer', (tester) async {
    final backend = FakeUpdateBackend(
      keys: const ['android-arm64-v8a'],
      result: newerRelease(route: UpdateRoute.mirror, mirror: 'https://ghfast.top/'),
    );
    final (state, _) = await pumpApp(tester, backend);
    await state.setGithubProxy(enabled: true, prefix: 'https://ghfast.top/');
    await state.setNetworkProxy('proxy.lan:8080', updates: true, scopes: {});
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('update-check')));
    await tester.pumpAndSettle();
    expect(text(tester, 'update-route'), '更新信息：经加速前缀 ghfast.top（经代理 proxy.lan:8080）');

    await tester.tap(find.byKey(const Key('update-download')));
    await tester.pumpAndSettle();
    expect(backend.downloads.single, ('https://github.com/Sa1koro/yingzhou/releases/download/v0.4.0/yingzhou-android-arm64-v8a.apk', 'yingzhou-android-arm64-v8a.apk', 'proxy.lan:8080'));
    expect(backend.downloadMirrors.single, 'https://ghfast.top/');
    expect(backend.opened, isEmpty);
    await tester.tap(find.byKey(const Key('update-reveal')));
    await tester.pumpAndSettle();
    expect(backend.revealed.single, endsWith('.apk'));

    // A box without a browser: the address, to take elsewhere.
    backend.canOpen = false;
    await tester.tap(find.byKey(const Key('update-page')));
    await tester.pumpAndSettle();
    expect(backend.opened.last, 'https://github.com/Sa1koro/yingzhou/releases/tag/v0.4.0');
    expect(find.byKey(const Key('update-address')), findsOneWidget);

    await tester.tap(find.text('以后再说'));
    await tester.pumpAndSettle();
    expect(text(tester, 'update-status-route'), '获取途径：经加速前缀 ghfast.top（经代理 proxy.lan:8080）');
  });

  testWidgets('automatic check: off does nothing; on, a newer version is shown once; on a TV with the D-pad', (tester) async {
    var now = DateTime(2026, 11, 20, 12);
    final settings = MemorySettings();
    final backend = FakeUpdateBackend(result: newerRelease(notes: List.generate(60, (i) => '- 第 ${i + 1} 条改动').join('\n')));
    final (_, service) = await pumpApp(tester, backend, tv: true, settings: settings, clock: () => now);

    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(backend.checks, isEmpty, reason: 'off by default');

    await service.setAutoCheck(true);
    await tester.pump(const Duration(hours: 3));
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(backend.checks, hasLength(1));
    expect(find.byKey(const Key('update-dialog')), findsOneWidget);
    expect(service.notifiedVersion, '0.4.0');

    // The remote: the focus is on 下载; ↑ goes to the notes, which ↓ scrolls; BACK closes.
    expect(focusedWithin(const Key('update-download')), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(focusedWithin(const Key('update-notes')), isTrue);
    final scroll = tester.state<ScrollableState>(find.descendant(of: find.byKey(const Key('update-notes')), matching: find.byType(Scrollable)));
    expect(scroll.position.pixels, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, greaterThan(0));
    expect(focusedWithin(const Key('update-notes')), isTrue, reason: 'scrolling, not leaving');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('update-dialog')), findsNothing);

    // A day later the same version again: asked, not shown again.
    now = now.add(const Duration(days: 1, minutes: 1));
    await tester.pump(const Duration(hours: 3));
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(backend.checks, hasLength(2));
    expect(find.byKey(const Key('update-dialog')), findsNothing);
  });
}
