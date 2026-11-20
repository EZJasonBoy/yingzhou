import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/engine/models.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/ui/device_form.dart';

import 'fake_engine.dart';

void main() {
  List<Map<String, Object>> saved() => [
    {'id': 'a', 'name': 'http://a.test/tv.json', 'url': 'http://a.test/tv.json', 'usedAt': 5},
    {'id': 'b', 'name': '家里的', 'url': 'http://b.test/b.json', 'usedAt': 9},
    {'id': 'c', 'name': 'http://c.test/', 'url': 'http://c.test/'},
  ];

  Future<List<Map<String, Object>>> pumpSources(WidgetTester tester, {DeviceForm? form}) async {
    tester.view.physicalSize = form == DeviceForm.tv ? const Size(1920, 1080) : const Size(1400, 1000);
    tester.view.devicePixelRatio = form == DeviceForm.tv ? 2 : 1;
    addTearDown(tester.view.reset);
    final subs = saved();
    final app = TvboxApp(state: AppState(clientFactory: (url) => EngineClient(url, httpClient: fakeEngine(savedSubscriptions: subs))));
    await tester.pumpWidget(form == null ? app : DeviceFormScope.fixed(form, child: app));
    await tester.pumpAndSettle();
    await tester.tap(find.text('源').first);
    await tester.pumpAndSettle();
    return subs;
  }

  String label(WidgetTester tester, String id) {
    final row = find.byKey(Key('saved-sub-$id'));
    return tester.widgetList<Text>(find.descendant(of: row, matching: find.byType(Text))).first.data!;
  }

  double top(WidgetTester tester, String id) => tester.getTopLeft(find.byKey(Key('saved-sub-$id'))).dy;

  test('a subscription without a name is shown by its host and file', () {
    expect(const Subscription(id: 'x', name: 'http://a.test/x/tv.json', url: 'http://a.test/x/tv.json').label, 'a.test · tv.json');
    expect(const Subscription(id: 'x', name: 'http://a.test/', url: 'http://a.test/').label, 'a.test');
    expect(const Subscription(id: 'x', name: '饭太硬', url: 'http://a.test/').label, '饭太硬');
    expect(const Subscription(id: 'x', name: 'C:\\tv\\my.json', url: 'C:\\tv\\my.json').label, 'C:\\tv\\my.json');
  });

  testWidgets('saved subscriptions: latest first, one click switches, rename and delete from the menu', (tester) async {
    final subs = await pumpSources(tester);
    expect(find.text('已保存的订阅'), findsOneWidget);
    expect(label(tester, 'b'), '家里的');
    expect(label(tester, 'a'), 'a.test · tv.json');
    expect(label(tester, 'c'), 'c.test');
    expect(top(tester, 'b'), lessThan(top(tester, 'a')), reason: 'used most recently');
    expect(top(tester, 'a'), lessThan(top(tester, 'c')), reason: 'never used goes last');

    await tester.tap(find.byKey(const Key('saved-sub-a')));
    await tester.pumpAndSettle();
    expect(find.text('2 个站点 · 0 个解析 · 0 组直播'), findsOneWidget, reason: 'switched and loaded');
    expect(find.text('正在使用 · http://a.test/tv.json'), findsOneWidget);
    expect(top(tester, 'a'), lessThan(top(tester, 'b')), reason: 'now the latest');

    await tester.tap(find.byKey(const Key('saved-sub-menu-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('saved-sub-name')), '备用');
    await tester.tap(find.byKey(const Key('saved-sub-name-save')));
    await tester.pumpAndSettle();
    expect(label(tester, 'a'), '备用');
    expect(subs.firstWhere((s) => s['id'] == 'a')['name'], '备用');

    await tester.tap(find.byKey(const Key('saved-sub-menu-b')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(find.text('删除「家里的」？'), findsOneWidget);
    await tester.tap(find.byKey(const Key('saved-sub-remove-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('saved-sub-b')), findsNothing);
    expect(subs.map((s) => s['id']), ['a', 'c']);

    // A new address is saved and becomes the one in use; an address already saved is not added again.
    await tester.enterText(find.widgetWithText(TextField, '订阅地址'), 'http://d.test/new.json');
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    expect(find.text('正在使用 · http://d.test/new.json'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '订阅地址'), 'http://c.test/');
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    expect(subs, hasLength(3));
    expect(find.text('正在使用 · http://c.test/'), findsOneWidget);

    // Deleting the one in use empties the home page.
    await tester.tap(find.byKey(const Key('saved-sub-menu-c')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('这是正在用的订阅'), findsOneWidget);
    await tester.tap(find.byKey(const Key('saved-sub-remove-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('2 个站点 · 0 个解析 · 0 组直播'), findsNothing);
  });

  testWidgets('desktop and TV offer 手机输入 next to the subscription field; phones do not', (tester) async {
    await pumpSources(tester);
    expect(find.byKey(const Key('subscription-phone-input')), findsOneWidget);
    await pumpSources(tester, form: DeviceForm.phone);
    expect(find.byKey(const Key('subscription-phone-input')), findsNothing);
  });

  testWidgets('TV: OK on a saved subscription switches to it; the menu key opens rename / delete', (tester) async {
    await pumpSources(tester, form: DeviceForm.tv);
    expect(find.byKey(const Key('subscription-phone-input')), findsOneWidget);
    final row = find.byKey(const Key('saved-sub-b'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    Focus.of(tester.element(find.descendant(of: row, matching: find.byType(Container)).first)).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('saved-sub-rename')), findsOneWidget);
    expect(find.byKey(const Key('saved-sub-remove')), findsOneWidget);
    expect(find.text('复制地址'), findsNothing, reason: 'no clipboard worth having on a TV');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    Focus.of(tester.element(find.descendant(of: row, matching: find.byType(Container)).first)).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('正在使用 · http://b.test/b.json'), findsOneWidget);

    // Switching to an older one moves it to the top; the focus goes with it instead of jumping elsewhere.
    final older = find.byKey(const Key('saved-sub-a'));
    Focus.of(tester.element(find.descendant(of: older, matching: find.byType(Container)).first)).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('正在使用 · http://a.test/tv.json'), findsOneWidget);
    expect(tester.getTopLeft(older).dy, lessThan(tester.getTopLeft(row).dy), reason: 'a moved to the top');
    var focusInA = false;
    FocusManager.instance.primaryFocus!.context!.visitAncestorElements((e) {
      if (e.widget.key == const Key('saved-sub-a')) focusInA = true;
      return !focusInA;
    });
    expect(focusInA || FocusManager.instance.primaryFocus!.context!.widget.key == const Key('saved-sub-a'), isTrue);
  });
}
