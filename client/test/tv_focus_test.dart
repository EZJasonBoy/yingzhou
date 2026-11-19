import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/ui/device_form.dart';
import 'package:tvbox_client/ui/tv/tv_focus.dart';
import 'package:tvbox_client/ui/tv/tv_shell.dart';

import 'fake_engine.dart';
import 'fake_player.dart';

/// The app on a TV, driven with the arrow keys, Enter and Escape / BACK the way a remote drives it, checking where
/// the focus is after each step.
void main() {
  /// A 1080p TV at xhdpi: 960 x 540 logical pixels.
  Future<FakePlayer> pumpTv(WidgetTester tester, {bool hasConfig = true, List<Map<String, Object>> history = const []}) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final player = FakePlayer();
    final engine = fakeEngine(hasConfig: hasConfig, history: history);
    await tester.pumpWidget(
      DeviceFormScope.fixed(
        DeviceForm.tv,
        child: TvboxApp(
          state: AppState(
            clientFactory: (url) => EngineClient(url, httpClient: engine),
            playerBackend: () => player.backend(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return player;
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k, {int times = 1}) async {
    for (var i = 0; i < times; i++) {
      await tester.sendKeyEvent(k);
      await tester.pumpAndSettle();
    }
  }

  /// The widget that has the focus: the nearest [TvFocusable] or button around the primary focus, as a finder
  /// would see it.
  FocusNode focused() => FocusManager.instance.primaryFocus!;

  bool focusIsIn(Finder finder) {
    final node = focused();
    final element = finder.evaluate().single;
    var inside = false;
    node.context!.visitAncestorElements((e) {
      if (e == element) inside = true;
      return !inside;
    });
    return inside || node.context == element;
  }

  bool focusOnText(String text) => focusIsIn(find.ancestor(of: find.text(text), matching: find.byType(TvFocusable)).first);

  testWidgets('the rail: starts on 首页, ↑/↓ move, OK opens a page and goes into it, ← comes back', (tester) async {
    await pumpTv(tester);
    expect(find.byType(TvShell), findsOneWidget);
    // The phone and desktop navigation are not there.
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
    expect(focusIsIn(find.byKey(const Key('tv-rail-0'))), isTrue, reason: 'starts on 首页');

    await key(tester, LogicalKeyboardKey.arrowDown, times: 2);
    expect(focusIsIn(find.byKey(const Key('tv-rail-2'))), isTrue, reason: '↓↓ reaches 搜索');
    // The rail shows its labels while it has the focus.
    expect(find.text('搜索'), findsOneWidget);

    await key(tester, LogicalKeyboardKey.select);
    expect(focusOnText('A'), isTrue, reason: 'OK opens 搜索 and puts the focus on the keyboard');
    // Only icons while the page has the focus.
    expect(find.descendant(of: find.byKey(const Key('tv-rail-2')), matching: find.text('搜索')), findsNothing);

    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusIsIn(find.byKey(const Key('tv-rail-2'))), isTrue, reason: '← from the left edge of the page goes to its entry');
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(focusOnText('A'), isTrue, reason: '→ goes back to where the focus was in the page');
  });

  testWidgets('home: → into the posters, ↑ to the tabs, OK opens the detail with the focus on 播放, BACK comes back to the poster', (tester) async {
    await pumpTv(tester);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(focusOnText('推荐片'), isTrue, reason: 'the first poster of 首页');

    // ↑ goes to the tab right above the poster (电影; 推荐 is to its left), which opens when it keeps the focus.
    await key(tester, LogicalKeyboardKey.arrowUp);
    expect(focused().context!.findAncestorWidgetOfExactType<TabBar>(), isNotNull, reason: '↑ from the posters reaches the tabs');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('分类片'), findsOneWidget, reason: 'the category under the focused tab shows');
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(focused().context!.findAncestorWidgetOfExactType<TextButton>(), isNotNull, reason: '↓ from the tabs: 筛选');
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(focusOnText('分类片'), isTrue, reason: '↓ past 筛选 to the category poster');

    await key(tester, LogicalKeyboardKey.select);
    expect(find.text('片名'), findsOneWidget, reason: 'the detail page');
    expect(focusIsIn(find.byKey(const Key('detail-play'))), isTrue, reason: 'the main action has the focus');
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(focused().context!.findAncestorWidgetOfExactType<ChoiceChip>(), isNotNull, reason: '↓ reaches the lines, not what is under the button');
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(find.ancestor(of: find.text('第1集'), matching: find.byType(OutlinedButton)), findsOneWidget);
    expect(
      focusIsIn(find.ancestor(of: find.text('第1集'), matching: find.byType(OutlinedButton))),
      isTrue,
      reason: '↓ again reaches the episodes',
    );

    // BACK leaves the page, and the poster that opened it has the focus again.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('片名'), findsNothing);
    expect(focusOnText('分类片'), isTrue);
  });

  testWidgets('BACK on the main screen: page → its entry → 首页 → asks before quitting', (tester) async {
    await pumpTv(tester);
    await key(tester, LogicalKeyboardKey.arrowDown, times: 3);
    await key(tester, LogicalKeyboardKey.select);
    expect(find.text('观看历史'), findsOneWidget, reason: '我的 is open');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(focusIsIn(find.byKey(const Key('tv-rail-3'))), isTrue, reason: 'out of the page, onto its entry');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(focusIsIn(find.byKey(const Key('tv-rail-0'))), isTrue, reason: 'then to 首页');
    expect(find.text('推荐'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('退出映舟？'), findsOneWidget);
    expect(focusIsIn(find.widgetWithText(TextButton, '取消')), isTrue, reason: 'the safe answer has the focus');
    await key(tester, LogicalKeyboardKey.select);
    expect(find.text('退出映舟？'), findsNothing);
  });

  testWidgets('search: type with the on-screen keyboard, 搜索 shows the results, recent searches come back', (tester) async {
    await pumpTv(tester);
    await key(tester, LogicalKeyboardKey.arrowDown, times: 2);
    await key(tester, LogicalKeyboardKey.select);
    expect(focusOnText('A'), isTrue);
    // A → B → C; then OK types C, ← ← OK types A.
    await key(tester, LogicalKeyboardKey.arrowRight, times: 2);
    await key(tester, LogicalKeyboardKey.select);
    await key(tester, LogicalKeyboardKey.arrowLeft, times: 2);
    await key(tester, LogicalKeyboardKey.select);
    final field = tester.widget<TextField>(find.byKey(const Key('tv-search-field')));
    expect(field.controller!.text, 'CA');
    // 删除 then the letters of the title the fake engine knows nothing about do not matter: it answers every query.
    await key(tester, LogicalKeyboardKey.arrowDown, times: 6);
    expect(focusIsIn(find.byKey(const Key('tv-key-delete'))), isTrue);
    await key(tester, LogicalKeyboardKey.select);
    expect(field.controller!.text, 'C');
    await key(tester, LogicalKeyboardKey.arrowRight, times: 2);
    expect(focusIsIn(find.byKey(const Key('tv-key-search'))), isTrue);
    await key(tester, LogicalKeyboardKey.select);
    expect(find.text('推荐片'), findsOneWidget);
    expect(find.textContaining('「C」搜索完成'), findsOneWidget);

    // → from the keyboard reaches the results.
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(focusOnText('推荐片'), isTrue);
  });

  testWidgets('a text field does not open the system keyboard when the focus passes; OK does', (tester) async {
    await pumpTv(tester);
    await key(tester, LogicalKeyboardKey.arrowDown, times: 2);
    await key(tester, LogicalKeyboardKey.select);
    // Up from the keyboard to the field.
    await key(tester, LogicalKeyboardKey.arrowUp);
    expect(focused().context!.findAncestorStateOfType<EditableTextState>(), isNotNull, reason: 'the search field has the focus');
    // The field is connected, but tells the system it wants no keyboard (Android then shows none).
    String inputType() => ((tester.testTextInput.setClientArgs!['inputType'] as Map)['name'] as String);
    expect(inputType(), 'TextInputType.none', reason: 'no system keyboard just for passing by');
    await key(tester, LogicalKeyboardKey.select);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(focused().context!.findAncestorStateOfType<EditableTextState>(), isNotNull, reason: 'the field keeps the focus');
    expect(inputType(), isNot('TextInputType.none'), reason: 'OK connects it again asking for the real keyboard');
    expect(tester.testTextInput.isVisible, isTrue, reason: 'OK opens it');
    // Leaving the field closes the gate again: the next field connects without a keyboard.
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(focusOnText('A'), isTrue);
    await key(tester, LogicalKeyboardKey.arrowUp);
    expect(inputType(), 'TextInputType.none');
  });

  testWidgets('desktop: no TV frame, no rail of big entries, mouse habits unchanged', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final engine = fakeEngine(hasConfig: true);
    await tester.pumpWidget(
      DeviceFormScope.fixed(
        DeviceForm.desktop,
        child: TvboxApp(
          state: AppState(clientFactory: (url) => EngineClient(url, httpClient: engine)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TvShell), findsNothing);
    expect(find.byType(NavigationRail), findsOneWidget);
    // No overscan padding: the rail starts at the window's edge.
    expect(tester.getTopLeft(find.byType(NavigationRail)), Offset.zero);
    await tester.tap(find.text('推荐片'));
    await tester.pumpAndSettle();
    expect(find.text('片名'), findsOneWidget);
  });
}
