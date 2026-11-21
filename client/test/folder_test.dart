import 'package:flutter/services.dart';
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

/// Folder cards (`vod_tag: folder`), as live-game and drive sites list platform → area → room: TVBox opens one by
/// asking for the category whose id is the card's, not for a detail.
void main() {
  Map<String, Object> folder(String id, String name) => {'site': 'cms', 'id': id, 'name': name, 'pic': '', 'remarks': '', 'tag': 'folder'};
  Map<String, Object> room(String id, String name) => {'site': 'cms', 'id': id, 'name': name, 'pic': '', 'remarks': '直播中'};

  late List<String> categoryAsked;
  late List<String> detailAsked;

  Future<void> start(WidgetTester tester, {bool tv = false}) async {
    tester.view.physicalSize = tv ? const Size(1920, 1080) : const Size(1400, 900);
    tester.view.devicePixelRatio = tv ? 2 : 1;
    addTearDown(tester.view.reset);
    categoryAsked = [];
    detailAsked = [];
    final engine = fakeEngine(
      hasConfig: true,
      homeList: [folder('p1', '平台甲'), room('r9', '推荐房间')],
      categories: {
        'p1': [folder('a1', '分区一'), folder('a2', '分区二')],
        'a1': [room('r1', '一号房间'), room('r2', '二号房间')],
      },
      categoryAsked: categoryAsked,
      detailAsked: detailAsked,
    );
    final player = FakePlayer();
    Widget app = TvboxApp(state: AppState(clientFactory: (url) => EngineClient(url, httpClient: engine), playerBackend: () => player.backend()));
    if (tv) app = DeviceFormScope.fixed(DeviceForm.tv, child: app);
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
  }

  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  String title() => (find.byKey(const Key('folder-title')).evaluate().single.widget as Text).data!;

  /// The poster that has the focus, by name.
  String? focusedPoster() {
    String? name;
    FocusManager.instance.primaryFocus?.context?.visitAncestorElements((e) {
      if (e.widget is PosterCard) {
        name = (e.widget as PosterCard).vod.name;
        return false;
      }
      return true;
    });
    return name;
  }

  testWidgets('a folder opens what is inside it, level by level, and back goes up again', (tester) async {
    await start(tester);
    expect(find.byKey(const Key('poster-folder')), findsOneWidget, reason: 'only 平台甲 is a folder');

    await tester.tap(find.text('平台甲'));
    await tester.pumpAndSettle();
    expect(title(), '平台甲');
    expect(categoryAsked, contains('p1'), reason: 'the category whose id is the folder\'s');
    expect(detailAsked, isEmpty, reason: 'a folder has no detail to ask for');
    expect(find.text('分区一'), findsOneWidget);
    expect(find.byKey(const Key('poster-folder')), findsNWidgets(2));

    await tester.tap(find.text('分区一'));
    await tester.pumpAndSettle();
    expect(title(), '分区一');
    expect(categoryAsked, contains('a1'));
    expect(find.byKey(const Key('poster-folder')), findsNothing, reason: 'rooms are videos');

    await tester.tap(find.text('一号房间'));
    await tester.pumpAndSettle();
    expect(find.byType(DetailPage), findsOneWidget);
    expect(detailAsked, ['cms/r1']);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(title(), '分区一');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(title(), '平台甲');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('folder-title')), findsNothing, reason: 'back on the home page');

    // A card that is not a folder opens its detail as before.
    await tester.tap(find.text('推荐房间'));
    await tester.pumpAndSettle();
    expect(find.byType(DetailPage), findsOneWidget);
    expect(detailAsked, ['cms/r1', 'cms/r9']);
    await leave(tester);
  });

  testWidgets('on a TV the first poster of a folder takes the focus, and OK goes one level deeper', (tester) async {
    await start(tester, tv: true);
    // The home's rows sit partly under the header on a 540-high screen; open it the way OK on the poster does.
    tester.widget<PosterCard>(find.widgetWithText(PosterCard, '平台甲')).onTap();
    await tester.pumpAndSettle();
    expect(title(), '平台甲');
    expect(focusedPoster(), '分区一');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(focusedPoster(), '分区二');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(title(), '分区一');
    expect(focusedPoster(), '一号房间');
    await leave(tester);
  });
}
