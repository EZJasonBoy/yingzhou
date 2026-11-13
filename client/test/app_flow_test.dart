import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';

import 'fake_engine.dart';

void main() {
  Future<void> pumpApp(
    WidgetTester tester, {
    bool hasConfig = false,
    Size size = const Size(1400, 900),
    List<Map<String, Object>> history = const [],
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final engine = fakeEngine(hasConfig: hasConfig, history: history);
    await tester.pumpWidget(TvboxApp(state: AppState(clientFactory: (url) => EngineClient(url, httpClient: engine))));
    await tester.pumpAndSettle();
  }

  testWidgets('import a subscription, browse the home page, open a detail', (tester) async {
    await pumpApp(tester);
    expect(find.text('还没有导入订阅'), findsOneWidget);

    await tester.tap(find.text('源'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已连接：tvbox-engine 0.1.0'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '订阅地址'), 'http://example.test/tv.json');
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    expect(find.text('2 个站点 · 0 个解析 · 0 组直播'), findsOneWidget);
    expect(find.text('js1 · 这台引擎还不支持这类站点'), findsOneWidget);

    await tester.tap(find.text('首页'));
    await tester.pumpAndSettle();
    expect(find.text('推荐'), findsOneWidget);
    expect(find.text('电影'), findsOneWidget);
    expect(find.text('推荐片'), findsOneWidget);

    await tester.tap(find.text('电影'));
    await tester.pumpAndSettle();
    expect(find.text('分类片'), findsOneWidget);
    expect(find.text('筛选'), findsOneWidget);

    await tester.tap(find.text('分类片'));
    await tester.pumpAndSettle();
    expect(find.text('片名'), findsOneWidget);
    expect(find.text('简介'), findsOneWidget, reason: 'HTML in the description is stripped');
    expect(find.text('第2集'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '播放'), findsOneWidget);
  });

  testWidgets('search streams results from the engine', (tester) async {
    await pumpApp(tester, hasConfig: true);
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '推荐');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('推荐片'), findsWidgets);
    expect(find.textContaining('搜索完成 · 1/1 个站点 · 找到 1 条'), findsOneWidget);
  });

  testWidgets('detail offers resume from history, favorites show up under 我的', (tester) async {
    await pumpApp(tester, hasConfig: true, history: [
      {
        'site': 'cms',
        'vodId': '7',
        'name': '推荐片',
        'line': '线路一',
        'episodeId': 'https://cdn.test/2.m3u8',
        'episodeName': '第2集',
        'episodeIndex': 1,
        'positionMs': 61000,
        'durationMs': 122000,
        'updatedAt': 1,
      },
    ]);

    await tester.tap(find.text('推荐片'));
    await tester.pumpAndSettle();
    expect(find.text('继续播放 第2集  01:01'), findsOneWidget);
    expect(find.text('从头播放'), findsOneWidget);

    await tester.tap(find.byTooltip('收藏'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('取消收藏'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(find.text('推荐片'), findsWidgets, reason: 'history entry');
    expect(find.text('第2集'), findsOneWidget, reason: 'episode shown on the history card');

    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    expect(find.text('片名'), findsOneWidget, reason: 'favorite saved from the detail page');
  });

  testWidgets('resume picks the recorded episode even when episodes share a url', (tester) async {
    await pumpApp(tester, hasConfig: true, history: [
      {
        'site': 'cms',
        'vodId': '7',
        'name': '推荐片',
        'line': '线路一',
        'episodeId': 'https://cdn.test/2.m3u8',
        'episodeName': '第3集',
        'episodeIndex': 2,
        'positionMs': 5000,
        'durationMs': 100000,
        'updatedAt': 1,
      },
    ]);
    await tester.tap(find.text('推荐片'));
    await tester.pumpAndSettle();
    expect(find.text('继续播放 第3集  00:05'), findsOneWidget);
  });

  testWidgets('phone layout uses a bottom navigation bar', (tester) async {
    await pumpApp(tester, hasConfig: true, size: const Size(400, 800));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.text('推荐片'), findsOneWidget);
  });
}
