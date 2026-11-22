import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/ui/device_form.dart';
import 'package:tvbox_client/ui/sectioned_page.dart';

import 'fake_engine.dart';

/// 设置 and 源 on a wide window, a phone and a TV: the list of groups, the two columns, and jumping to a group
/// (ui/sectioned_page.dart).
void main() {
  Future<void> pumpApp(WidgetTester tester, {required Size size, required DeviceForm form, List<Map<String, Object>> extraSites = const []}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final engine = fakeEngine(hasConfig: true, extraSites: extraSites);
    await tester.pumpWidget(DeviceFormScope.fixed(form, child: TvboxApp(state: AppState(clientFactory: (url) => EngineClient(url, httpClient: engine)))));
    await tester.pumpAndSettle();
  }

  bool onScreen(WidgetTester tester, Finder finder) {
    final rect = tester.getRect(finder);
    final view = tester.view.physicalSize;
    return rect.top >= 0 && rect.bottom <= view.height;
  }

  testWidgets('a wide window: the groups are listed on the left, cards stand in two columns, an entry jumps to its group', (tester) async {
    // Not tall: at 1440 × 900 the whole page is in sight with two columns.
    await pumpApp(tester, size: const Size(1440, 480), form: DeviceForm.desktop);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    for (final id in ['look', 'network', 'about']) {
      expect(find.byKey(Key('section-index-$id')), findsOneWidget, reason: id);
    }
    // This engine has no stream cache and no danmaku services: 播放 has no card, so it has no entry and no heading.
    expect(find.byKey(const Key('section-index-play')), findsNothing);
    expect(find.descendant(of: find.byKey(const Key('settings-list')), matching: find.text('播放')), findsNothing);
    expect(find.byKey(const Key('section-chips')), findsNothing);

    final mode = tester.getRect(find.byKey(const Key('user-mode')));
    final start = tester.getRect(find.byKey(const Key('start-page')));
    expect(start.left, greaterThan(mode.right), reason: 'the first two cards of 外观 side by side');
    expect((start.top - mode.top).abs(), lessThan(1));

    expect(onScreen(tester, find.byKey(const Key('about-engine'))), isFalse, reason: '关于 is further down');
    await tester.tap(find.byKey(const Key('section-index-about')));
    await tester.pumpAndSettle();
    expect(onScreen(tester, find.byKey(const Key('about-engine'))), isTrue);
  });

  testWidgets('a phone: one column, with the groups as chips above it', (tester) async {
    await pumpApp(tester, size: const Size(400, 800), form: DeviceForm.phone);
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('section-chips')), findsOneWidget);
    expect(find.byKey(const Key('section-index-look')), findsNothing);
    final mode = tester.getRect(find.byKey(const Key('user-mode')));
    final theme = tester.getRect(find.byKey(const Key('theme-mode')));
    expect(theme.top, greaterThan(mode.bottom), reason: 'one under the other');

    await tester.dragUntilVisible(find.byKey(const Key('section-chip-about')), find.byKey(const Key('section-chips')), const Offset(-200, 0));
    await tester.tap(find.byKey(const Key('section-chip-about')));
    await tester.pumpAndSettle();
    expect(onScreen(tester, find.byKey(const Key('about-engine'))), isTrue);
  });

  testWidgets('a TV: the page follows the focus along the list of groups, → goes into the group', (tester) async {
    await pumpApp(tester, size: const Size(960, 540), form: DeviceForm.tv);
    // 设置 is the last entry of the rail.
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('section-index-look')), findsOneWidget);
    // Down the list to 关于: the page scrolls along.
    // The focus starts on the first group, 外观; 网络 and 关于 are below it (the groups with nothing in them on
    // this engine are left out).
    for (var i = 0; i < 2; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    expect(onScreen(tester, find.byKey(const Key('about-engine'))), isTrue);
    final entry = Focus.of(tester.element(find.descendant(of: find.byKey(const Key('section-index-about')), matching: find.text('关于'))));
    expect(entry.hasFocus, isTrue, reason: 'the focus is on the entry');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(entry.hasFocus, isFalse, reason: 'and → took it into the group');
  });

  testWidgets('源 on a wide window: the sites stand beside the subscriptions; many sites can be narrowed down', (tester) async {
    await pumpApp(
      tester,
      size: const Size(1440, 900),
      form: DeviceForm.desktop,
      extraSites: [
        for (var i = 0; i < 14; i++) {'key': 'x$i', 'name': i == 3 ? '纸船影视' : '站点 $i', 'type': 1, 'searchable': true, 'quickSearch': true, 'filterable': true, 'runtime': 'cms'},
      ],
    );
    await tester.tap(find.text('源'));
    await tester.pumpAndSettle();
    Finder heading(String text) => find.descendant(of: find.byKey(const Key('sources-list')), matching: find.text(text));
    final sites = tester.getRect(heading('站点'));
    final subscriptions = tester.getRect(heading('订阅'));
    expect(sites.left, greaterThan(subscriptions.left + 300), reason: 'a column of its own');
    expect(onScreen(tester, heading('站点')), isTrue, reason: 'in sight without scrolling');

    expect(find.byKey(const Key('site-filter')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('site-filter')), '纸船');
    await tester.pumpAndSettle();
    expect(find.text('纸船影视'), findsOneWidget);
    expect(find.text('站点 5'), findsNothing);
  });

  testWidgets('ColumnsFlow puts each child in the shorter column, and one without height takes no place', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 416,
            child: ColumnsFlow(
              columns: 2,
              gap: 16,
              children: [
                SizedBox(key: Key('a'), height: 100),
                SizedBox.shrink(key: Key('none')),
                SizedBox(key: Key('b'), height: 40),
                SizedBox(key: Key('c'), height: 30),
              ],
            ),
          ),
        ),
      ),
    );
    expect(tester.getRect(find.byKey(const Key('a'))), const Rect.fromLTWH(0, 0, 200, 100));
    expect(tester.getRect(find.byKey(const Key('b'))), const Rect.fromLTWH(216, 0, 200, 40));
    expect(tester.getRect(find.byKey(const Key('c'))), const Rect.fromLTWH(216, 40, 200, 30), reason: 'under b, the shorter column');
    expect(tester.getSize(find.byType(ColumnsFlow)), const Size(416, 100));
  });
}
