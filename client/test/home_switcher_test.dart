import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/settings.dart';
import 'package:tvbox_client/ui/device_form.dart';

import 'fake_engine.dart';

/// The home page's switcher: subscription › entry of a multi-repository subscription › site, three chips when the
/// window is wide, one panel on a phone held upright. Two saved subscriptions; the first has three entries, one of
/// them a list with an entry of its own. Each config's home has a poster of its own.
void main() {
  const main = 'http://example.test/tv.json';
  const more = 'http://example.test/more.json';
  const child = 'http://example.test/sub.json';
  const friend = 'http://example.test/b.json';

  Map<String, Object> card(String id, String name) => {'site': 'cms', 'id': id, 'name': name, 'pic': '', 'remarks': ''};

  Future<AppState> pump(
    WidgetTester tester, {
    DeviceForm? form,
    Size size = const Size(1400, 900),
    bool twoSubscriptions = true,
    bool withRepos = true,
    Set<String> failRepos = const {},
    SettingsStore? settings,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final engine = fakeEngine(
      hasConfig: true,
      savedSubscriptions: [
        {'id': 's1', 'name': '家里的', 'url': main, 'usedAt': 2},
        if (twoSubscriptions) {'id': 'n2', 'name': '朋友的', 'url': friend, 'usedAt': 1},
      ],
      repos: withRepos
          ? [
              {'name': '主仓', 'url': main, 'group': false, 'depth': 0},
              {'name': '备用', 'url': more, 'group': true, 'depth': 0},
              {'name': '子仓', 'url': child, 'group': false, 'depth': 1, 'parent': more},
            ]
          : null,
      failRepos: failRepos,
      extraSites: [
        {'key': 'b', 'name': '采集站二', 'type': 1, 'searchable': true, 'quickSearch': true, 'filterable': true, 'runtime': 'cms'},
      ],
      homeByConfig: {
        main: [card('1', '甲片')],
        child: [card('2', '子仓片')],
        friend: [card('3', '乙片')],
      },
    );
    final state = AppState(clientFactory: (url) => EngineClient(url, httpClient: engine), settings: settings);
    final app = TvboxApp(state: state);
    await tester.pumpWidget(form == null ? app : DeviceFormScope.fixed(form, child: app));
    await tester.pumpAndSettle();
    return state;
  }

  testWidgets('wide: a chip per level that has a choice', (tester) async {
    await pump(tester, twoSubscriptions: false, withRepos: false);
    expect(find.byKey(const Key('home-sub-chip')), findsNothing, reason: 'one subscription: nothing to choose');
    expect(find.byKey(const Key('home-repo-chip')), findsNothing, reason: 'not a multi-repository subscription');
    expect(find.byKey(const Key('home-site-chip')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    await pump(tester);
    expect(find.descendant(of: find.byKey(const Key('home-sub-chip')), matching: find.text('家里的')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('home-repo-chip')), matching: find.text('主仓')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('home-site-chip')), matching: find.text('采集站')), findsOneWidget);
    expect(find.text('甲片'), findsOneWidget);
  });

  testWidgets('wide: another entry or subscription reloads the home, even with a site of the same key', (tester) async {
    final state = await pump(tester);
    await tester.tap(find.byKey(const Key('home-repo-chip')));
    await tester.pumpAndSettle();
    expect(find.text('备用（多仓）'), findsOneWidget);
    await tester.tap(find.text('子仓'));
    await tester.pumpAndSettle();
    expect(state.summary!.url, child);
    expect(find.text('子仓片'), findsOneWidget, reason: 'the same site key, another config: the home is loaded again');

    await tester.tap(find.byKey(const Key('home-sub-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('朋友的').last);
    await tester.pumpAndSettle();
    expect(state.summary!.subscriptionId, 'n2');
    expect(find.text('乙片'), findsOneWidget);
  });

  testWidgets('wide: a switch that fails is told, and the config that was there stays', (tester) async {
    final state = await pump(tester, failRepos: {child});
    await tester.tap(find.byKey(const Key('home-repo-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('子仓'));
    await tester.pumpAndSettle();
    expect(find.textContaining('没能切换'), findsOneWidget);
    expect(state.summary!.url, main);
    expect(find.text('甲片'), findsOneWidget);
  });

  testWidgets('each config keeps its site, and each subscription its entry', (tester) async {
    final settings = MemorySettings();
    final state = await pump(tester, settings: settings);
    await tester.tap(find.byKey(const Key('home-site-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('采集站二').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-repo-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('子仓'));
    await tester.pumpAndSettle();
    expect(state.currentSiteKey, 'b', reason: 'this config has the site too, and nothing was chosen here yet');
    await tester.tap(find.byKey(const Key('home-site-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('采集站').last);
    await tester.pumpAndSettle();

    // To the other subscription and back: its last entry, and that entry's site.
    await tester.tap(find.byKey(const Key('home-sub-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('朋友的').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-sub-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('家里的').last);
    await tester.pumpAndSettle();
    expect(state.summary!.url, child, reason: 'back to the entry used last in 家里的');
    expect(state.currentSiteKey, 'cms', reason: 'and the site chosen last in that entry');
  });

  testWidgets('phone held upright: one chip, a panel that steps up to entries and subscriptions', (tester) async {
    final state = await pump(tester, form: DeviceForm.phone, size: const Size(390, 844));
    expect(find.byKey(const Key('home-sub-chip')), findsNothing);
    expect(find.byKey(const Key('home-repo-chip')), findsNothing);
    await tester.tap(find.byKey(const Key('home-site-chip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sheet-site-cms')), findsOneWidget);
    expect(find.text('家里的 › 主仓'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sheet-context')));
    await tester.pumpAndSettle();
    expect(find.text('选择仓库'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sheet-back')));
    await tester.pumpAndSettle();
    expect(find.text('选择站点'), findsOneWidget, reason: '‹ goes down a level');

    await tester.tap(find.byKey(const Key('sheet-context')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sheet-to-subscriptions')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sheet-sub-n2')));
    await tester.pumpAndSettle();
    expect(state.summary!.subscriptionId, 'n2');
    expect(find.text('选择站点'), findsOneWidget, reason: 'back to the sites of what was loaded');
    await tester.tap(find.byKey(const Key('sheet-site-b')));
    await tester.pumpAndSettle();
    expect(find.text('选择站点'), findsNothing, reason: 'picking a site closes the panel');
    expect(state.currentSiteKey, 'b');
  });

  testWidgets('TV: the entry list is a dialog for the remote, entries of a list set in', (tester) async {
    final state = await pump(tester, form: DeviceForm.tv, size: const Size(1920, 1080));
    await tester.tap(find.byKey(const Key('home-repo-chip')));
    await tester.pumpAndSettle();
    expect(find.text('选择仓库'), findsOneWidget);
    final indent = tester.widget<Padding>(find.ancestor(of: find.byKey(const Key('tv-choice-2')), matching: find.byType(Padding)).first);
    expect((indent.padding as EdgeInsets).left, 20, reason: '子仓 is in 备用');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(state.summary!.url, child);
  });
}
