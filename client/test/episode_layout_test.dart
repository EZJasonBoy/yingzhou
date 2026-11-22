import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/ui/device_form.dart';

import 'fake_engine.dart';
import 'fake_player.dart';

Map<String, Object> _line(String name, List<String> episodes) => {
  'name': name,
  'episodes': [
    for (var i = 0; i < episodes.length; i++) {'id': 'https://cdn.test/$name/$i.m3u8', 'name': episodes[i]},
  ],
};

/// 选集 on the detail page follows how the site names its episodes.
void main() {
  Future<void> openDetail(WidgetTester tester, {List<Map<String, Object>>? lines, Map<String, Map<String, Object>> details = const {}, Size size = const Size(1400, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final engine = fakeEngine(hasConfig: true, lines: lines, details: details);
    final player = FakePlayer();
    await tester.pumpWidget(
      DeviceFormScope.fixed(
        DeviceForm.desktop,
        child: TvboxApp(state: AppState(clientFactory: (url) => EngineClient(url, httpClient: engine), playerBackend: () => player.backend())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('推荐片'));
    await tester.pumpAndSettle();
  }

  testWidgets('long titles are rows: the whole title shows, numbered, several columns on a wide window', (tester) async {
    const titles = ['第1期：先导片 六位朋友再次出发', '第2期：雪山脚下的第一夜', '20261120加更版：没播出的那些事'];
    await openDetail(tester, lines: [_line('线路一', titles)]);
    for (final t in titles) {
      expect(find.text(t), findsOneWidget);
    }
    final first = tester.getRect(find.widgetWithText(OutlinedButton, titles[0]));
    final second = tester.getRect(find.widgetWithText(OutlinedButton, titles[1]));
    expect(first.width, greaterThan(250), reason: 'room for the title');
    expect(second.top, first.top, reason: 'rows sit side by side while they fit');
    expect(find.descendant(of: find.widgetWithText(OutlinedButton, titles[2]), matching: find.text('3')), findsOneWidget, reason: 'its place in the list');

    await tester.tap(find.text(titles[1]));
    await tester.pumpAndSettle();
    expect(find.textContaining('第2期：雪山脚下的第一夜'), findsWidgets, reason: 'the row plays its episode');
  });

  testWidgets('a narrow window lists long titles one under the other', (tester) async {
    const titles = ['第1期：先导片 六位朋友再次出发', '第2期：雪山脚下的第一夜'];
    await openDetail(tester, lines: [_line('线路一', titles)], size: const Size(400, 800));
    await tester.scrollUntilVisible(find.text(titles[1]), 200, scrollable: find.byType(Scrollable).last);
    final first = tester.getRect(find.widgetWithText(OutlinedButton, titles[0]));
    final second = tester.getRect(find.widgetWithText(OutlinedButton, titles[1]));
    expect(second.top, greaterThan(first.top));
    expect(second.left, first.left);
  });

  testWidgets('file names are shown by what tells them apart', (tester) async {
    await openDetail(tester, lines: [_line('线路一', ['片名.2026.EP01.4K.WEB-DL.H265.mp4', '片名.2026.EP02.4K.WEB-DL.H265.mp4'])]);
    expect(find.widgetWithText(OutlinedButton, 'EP01'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'EP02'), findsOneWidget);
    expect(tester.getSize(find.widgetWithText(OutlinedButton, 'EP01')).width, 112, reason: 'short again: the grid');
  });

  testWidgets('a site that only numbers the episodes of a dated show says so, and offers other sources', (tester) async {
    await openDetail(
      tester,
      details: {
        'cms/7': {
          'site': 'cms',
          'id': '7',
          'name': '片名',
          'remarks': '更新至20261120加更版',
          'lines': [
            _line('线路一', ['1', '2', '3']),
            _line('线路二', ['1', '2', '3']),
          ],
        },
      },
    );
    expect(find.byKey(const Key('detail-episodes-numbers')), findsOneWidget);
    expect(find.text('共 3 集 · 更新至20261120加更版'), findsOneWidget, reason: 'what the site says about the latest one, next to 选集');
    await tester.tap(find.text('看看别的来源'));
    await tester.pumpAndSettle();
    expect(find.text('换一个来源'), findsOneWidget);
  });

  testWidgets('numbers borrow the titles another line of the same length has', (tester) async {
    await openDetail(
      tester,
      lines: [
        _line('超清', ['1', '2', '3']),
        _line('蓝光', ['20261106期', '20261113抢鲜版', '20261120加更版']),
      ],
    );
    expect(find.byKey(const Key('detail-episodes-borrowed')), findsOneWidget);
    expect(find.textContaining('取自线路「蓝光」'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '20261113抢鲜版'), findsOneWidget);
    expect(find.byKey(const Key('detail-episodes-numbers')), findsNothing);
  });

  testWidgets('an ordinary series keeps its small buttons and gets no note', (tester) async {
    await openDetail(tester);
    expect(tester.getSize(find.widgetWithText(OutlinedButton, '第1集')).width, 112);
    expect(find.byKey(const Key('detail-episodes-numbers')), findsNothing);
    expect(find.byKey(const Key('detail-episodes-borrowed')), findsNothing);
  });
}
