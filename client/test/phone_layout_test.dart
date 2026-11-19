import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/pages/detail_page.dart';
import 'package:tvbox_client/ui/device_form.dart';
import 'package:tvbox_client/ui/poster.dart';

import 'fake_engine.dart';
import 'fake_player.dart';

/// The app on phones and tablets: which navigation each size gets, every tab laid out without overflowing (an
/// overflow fails the test), touch-sized episodes on the detail page, and the system back going to 首页 first.
void main() {
  Future<FakePlayer> pumpApp(WidgetTester tester, Size size, {DeviceForm? form, double ratio = 2.625}) async {
    tester.view.physicalSize = size * ratio;
    tester.view.devicePixelRatio = ratio;
    addTearDown(tester.view.reset);
    final player = FakePlayer();
    final engine = fakeEngine(hasConfig: true, lines: [fakeLine('线路一', 'a', count: 40), fakeLine('线路二', 'b', count: 40)]);
    final app = TvboxApp(
      state: AppState(clientFactory: (url) => EngineClient(url, httpClient: engine), playerBackend: () => player.backend()),
    );
    // Unset: an Android device that is not a TV, phone or tablet by the window's size, as on a real one.
    await tester.pumpWidget(
      form != null
          ? DeviceFormScope.fixed(form, child: app)
          : DeviceFormScope(controller: DeviceFormController(platform: TargetPlatform.android), child: app),
    );
    await tester.pumpAndSettle();
    return player;
  }

  const phone = Size(360, 740);
  const bigPhone = Size(412, 915);
  const phoneLandscape = Size(915, 412);
  const tablet = Size(800, 1280);
  const tabletLandscape = Size(1280, 800);

  Future<void> visitEveryTab(WidgetTester tester) async {
    for (final tab in ['直播', '搜索', '我的', '源', '网盘', '首页']) {
      await tester.tap(find.text(tab).last);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }
  }

  testWidgets('a phone held upright has the bottom bar, and every tab fits', (tester) async {
    for (final size in [phone, bigPhone]) {
      await pumpApp(tester, size);
      expect(DeviceFormScope.of(tester.element(find.byType(Scaffold).first)), DeviceForm.phone);
      expect(find.byType(NavigationBar), findsOneWidget, reason: '$size');
      expect(find.byType(NavigationRail), findsNothing);
      await visitEveryTab(tester);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('a phone on its side and a tablet have the rail, and every tab fits', (tester) async {
    for (final size in [phoneLandscape, tablet, tabletLandscape]) {
      await pumpApp(tester, size);
      expect(find.byType(NavigationRail), findsOneWidget, reason: '$size');
      expect(find.byType(NavigationBar), findsNothing);
      await visitEveryTab(tester);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('the poster wall has three columns on a phone', (tester) async {
    await pumpApp(tester, phone);
    await tester.tap(find.text('电影'));
    await tester.pumpAndSettle();
    // Three posters, two gaps of 10 dp, 20 dp of padding at each side: (360 - 40 - 20) / 3.
    expect(tester.getSize(find.byType(PosterCard).first).width, moreOrLessEquals(100, epsilon: 0.5));
  });

  testWidgets('the detail page on a phone: touch-sized lines and episodes, nothing cut off', (tester) async {
    for (final size in [phone, phoneLandscape, tablet]) {
      await pumpApp(tester, size);
      await tester.tap(find.text('推荐片'));
      await tester.pumpAndSettle();
      expect(find.text('片名'), findsOneWidget);
      final page = find.descendant(of: find.byType(DetailPage), matching: find.byType(Scrollable)).first;
      await tester.scrollUntilVisible(find.widgetWithText(OutlinedButton, '第1集'), 200, scrollable: page);
      final episode = tester.getSize(find.widgetWithText(OutlinedButton, '第1集'));
      expect(episode.height, greaterThanOrEqualTo(48), reason: '$size');
      final line = tester.getSize(find.byType(ChoiceChip).first);
      expect(line.height, greaterThanOrEqualTo(48), reason: 'chips keep a 48 dp target ($size)');
      if (size.width < 600) {
        // Upright on a phone the episodes fill the row: at least three to a row.
        final first = tester.getRect(find.widgetWithText(OutlinedButton, '第1集'));
        final third = tester.getRect(find.widgetWithText(OutlinedButton, '第3集'));
        expect(third.top, first.top, reason: 'three episodes in the first row ($size)');
      }
      await tester.scrollUntilVisible(find.text('第40集'), 300, scrollable: page);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('back on another tab goes to 首页 before it leaves the app', (tester) async {
    await pumpApp(tester, phone);
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    final shown = find.byType(IndexedStack);
    expect(tester.widget<IndexedStack>(shown).index, 3);
    final left = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(left, isTrue, reason: 'the shell took the back press');
    expect(tester.widget<IndexedStack>(shown).index, 0);
  });

  testWidgets('desktops keep their layout at the same sizes', (tester) async {
    await pumpApp(tester, const Size(1000, 700), form: DeviceForm.desktop, ratio: 1);
    expect(find.byType(NavigationRail), findsOneWidget);
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    // No back-to-首页 on desktops: the mouse's back button is for pages, not tabs.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 3);
  });
}
