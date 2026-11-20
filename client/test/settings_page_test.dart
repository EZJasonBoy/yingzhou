import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/pages/settings_page.dart';
import 'package:tvbox_client/settings.dart';
import 'package:tvbox_client/ui/device_form.dart';
import 'package:tvbox_client/ui/theme.dart';

import 'fake_engine.dart';
import 'fake_player.dart';

/// 设置 as a page of its own, apart from 源, and the choice of light or dark in it.
void main() {
  Future<SettingsStore> pumpApp(WidgetTester tester, {Size size = const Size(1200, 800), DeviceForm? form, SettingsStore? settings}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = settings ?? MemorySettings();
    final player = FakePlayer();
    final app = TvboxApp(
      // A new key each time: pumping the app again starts it again, as closing and opening it does.
      key: UniqueKey(),
      state: AppState(
        clientFactory: (url) => EngineClient(url, httpClient: fakeEngine(hasConfig: true)),
        settings: store,
        playerBackend: () => player.backend(),
      ),
    );
    await tester.pumpWidget(form == null ? app : DeviceFormScope.fixed(form, child: app));
    await tester.pumpAndSettle();
    return store;
  }

  Brightness brightness(WidgetTester tester) => Theme.of(tester.element(find.byType(Scaffold).first)).brightness;

  testWidgets('设置 is its own page: what was on 源 besides the engine, the subscriptions and the sites is there', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('源'));
    await tester.pumpAndSettle();
    expect(find.text('订阅地址'), findsWidgets, reason: '源 keeps the subscriptions');
    expect(find.text('引擎地址'), findsOneWidget, reason: 'and the engine it talks to');
    expect(find.byKey(const Key('github-proxy-switch')), findsNothing, reason: 'the network settings moved');
    expect(find.byKey(const Key('theme-mode')), findsNothing);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    final list = find.byKey(const Key('settings-list'));
    for (final heading in ['外观', '播放', '网络', '局域网', '下载与数据', '关于']) {
      expect(find.descendant(of: list, matching: find.text(heading, skipOffstage: false)), findsOneWidget, reason: 'the $heading group');
    }
    await tester.dragUntilVisible(find.byKey(const Key('about-engine')), list, const Offset(0, -300));
    expect(find.byKey(const Key('about-engine')), findsOneWidget);
    expect(find.textContaining('不内置、不提供任何影视内容'), findsOneWidget);
  });

  testWidgets('light or dark: a desktop starts dark, the choice applies at once and is kept', (tester) async {
    final store = await pumpApp(tester, form: DeviceForm.desktop);
    expect(brightness(tester), Brightness.dark, reason: 'desktops are dark until the user chooses');
    expect(store.getString(ThemeChoice.key), isNull);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(tester.widget<SegmentedButton<ThemeMode>>(find.byKey(const Key('theme-mode'))).selected, {ThemeMode.dark});
    await tester.tap(find.text('浅色'));
    await tester.pumpAndSettle();
    expect(brightness(tester), Brightness.light);
    expect(store.getString(ThemeChoice.key), 'light');

    // The next start remembers it.
    await pumpApp(tester, form: DeviceForm.desktop, settings: store);
    expect(brightness(tester), Brightness.light);
  });

  testWidgets('in the light theme, what is drawn over the picture stays dark', (tester) async {
    final store = MemorySettings();
    await store.setString(ThemeChoice.key, 'light');
    await pumpApp(tester, form: DeviceForm.desktop, settings: store);
    expect(brightness(tester), Brightness.light);
    await tester.tap(find.text('推荐片'));
    await tester.pumpAndSettle();
    final play = find.byKey(const Key('detail-play'));
    expect(Theme.of(tester.element(play)).brightness, Brightness.light, reason: 'the detail page follows the theme');

    await tester.tap(play);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    final episodes = find.text('选集');
    expect(episodes, findsWidgets, reason: 'the player and its bar');
    expect(Theme.of(tester.element(episodes.first)).brightness, Brightness.dark, reason: 'the bar sits on video');
    await tester.tap(episodes.first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(Theme.of(tester.element(find.byType(ChoiceChip).first)).brightness, Brightness.dark, reason: 'and so does the panel of lines and episodes');
  });

  testWidgets('light or dark: a phone follows the system until told otherwise', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await pumpApp(tester, size: const Size(400, 800), form: DeviceForm.phone);
    expect(brightness(tester), Brightness.light);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(brightness(tester), Brightness.dark, reason: 'follows the system');

    // A phone held upright has six tabs and no room for a seventh: 设置 is in 我的.
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.descendant(of: find.byType(NavigationBar), matching: find.text('设置')), findsNothing);
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsWidgets);
    expect(find.widgetWithText(AppBar, '设置'), findsOneWidget, reason: 'opened as a page with a way back');

    await tester.tap(find.text('浅色'));
    await tester.pumpAndSettle();
    expect(brightness(tester), Brightness.light, reason: 'the choice wins over the system');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, '设置'), findsNothing);
  });

  testWidgets('a phone on its side has 设置 in the rail, and a desktop window at its smallest still fits it', (tester) async {
    await pumpApp(tester, size: const Size(800, 400), form: DeviceForm.phone);
    expect(find.byType(NavigationRail), findsOneWidget);
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('theme-mode')), findsOneWidget);
    expect(find.byKey(const Key('open-settings'), skipOffstage: false), findsNothing, reason: 'no second entry in 我的 when the rail has it');

    // 800 x 520 is the smallest the desktop window goes: seven entries must not overflow it.
    await pumpApp(tester, size: const Size(800, 520), form: DeviceForm.desktop);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
  });

  testWidgets('TV: 设置 is the last entry of the rail, and the remote gets into it', (tester) async {
    await pumpApp(tester, size: const Size(960, 540), form: DeviceForm.tv);
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('theme-mode')), findsOneWidget, reason: 'OK on the seventh entry opens 设置');
    final focus = FocusManager.instance.primaryFocus!;
    var inside = false;
    focus.context!.visitAncestorElements((e) {
      if (e.widget is SettingsPage) inside = true;
      return !inside;
    });
    expect(inside, isTrue, reason: 'the focus went into the page');
    expect(brightness(tester), Brightness.dark, reason: 'a TV is dark until the user chooses');
  });
}
