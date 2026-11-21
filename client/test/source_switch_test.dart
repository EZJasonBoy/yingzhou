import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';

import 'fake_engine.dart';
import 'fake_player.dart';

/// A recommendation that stands for a title, a detail with nothing to play, and every line failing: each is looked
/// for on the other sites, as TVBox and FongMi do. Sites: 采集站 (cms), 采集站二 (b), 采集站三 (c, not changeable).
void main() {
  late List<String> searchAsked;
  late List<String> detailAsked;
  late List<String> resolvedAt;
  late FakePlayer player;

  Map<String, Object> site(String key, String name, {bool changeable = true}) =>
      {'key': key, 'name': name, 'type': 1, 'searchable': true, 'quickSearch': true, 'filterable': true, 'runtime': 'cms', 'changeable': changeable};
  Map<String, Object> card(String site, String id, String name) => {'site': site, 'id': id, 'name': name, 'pic': '', 'remarks': ''};
  Map<String, Object> detail(String site, String id, String name, List<Map<String, Object>> lines) =>
      {'site': site, 'id': id, 'name': name, 'lines': lines};

  Future<void> pass(WidgetTester tester, Duration time) async {
    for (var t = Duration.zero; t < time; t += const Duration(milliseconds: 100)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The app on 采集站's home, with [home] as its cards, and the poster [open] tapped.
  Future<void> openCard(
    WidgetTester tester, {
    required List<Map<String, Object>> home,
    required String open,
    Map<String, Map<String, Object>> details = const {},
    Map<String, List<Map<String, Object>>> hits = const {},
    Map<String, Object> cmsSite = const {},
    Set<String> dead = const {},
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    searchAsked = [];
    detailAsked = [];
    resolvedAt = [];
    player = FakePlayer();
    final engine = fakeEngine(
      hasConfig: true,
      homeList: home,
      details: details,
      searchHits: hits,
      cmsSite: cmsSite,
      extraSites: [site('b', '采集站二'), site('c', '采集站三', changeable: false)],
      searchAsked: searchAsked,
      detailAsked: detailAsked,
      resolvedAt: resolvedAt,
      deadLines: dead,
    );
    await tester.pumpWidget(TvboxApp(state: AppState(clientFactory: (url) => EngineClient(url, httpClient: engine), playerBackend: () => player.backend())));
    await tester.pumpAndSettle();
    await tester.tap(find.text(open));
    await tester.pumpAndSettle();
  }

  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('a recommendation that stands for a title opens the same title on another site', (tester) async {
    await openCard(
      tester,
      home: [card('cms', 'msearch:星河往事', '星河往事'), card('cms', '', '长夜')],
      open: '星河往事',
      hits: {
        'b': [card('b', '21', '星河往事')],
        'c': [card('c', '31', '星河往事')],
      },
      details: {'b/21': detail('b', '21', '星河往事', [fakeLine('线路一', 'x')])},
    );
    expect(detailAsked.where((d) => d.startsWith('cms/')), isEmpty, reason: 'the recommendation site is never asked for a detail');
    expect(searchAsked.single, '星河往事|b,c', reason: 'searchable sites this engine runs, without the recommendation site');
    expect(find.text('来自 采集站二'), findsOneWidget);
    expect(find.text('播放'), findsOneWidget);
    expect(find.text('换一个（1）'), findsOneWidget, reason: 'c is listed though it is never picked on its own');
  });

  testWidgets('换一个 lists every copy, and the one picked is loaded as it is', (tester) async {
    await openCard(
      tester,
      home: [card('cms', 'msearch:星河往事', '星河往事')],
      open: '星河往事',
      hits: {
        'b': [card('b', '21', '星河往事')],
        'c': [card('c', '31', '星河往事'), card('c', '32', '星河往事 第二季')],
      },
      details: {
        'b/21': detail('b', '21', '星河往事', [fakeLine('线路一', 'x')]),
        'c/31': detail('c', '31', '星河往事', [fakeLine('线路一', 'y')]),
      },
    );
    await tester.tap(find.byKey(const Key('detail-change-source')));
    await tester.pumpAndSettle();
    expect(find.text('同名'), findsOneWidget);
    expect(find.text('名字相近'), findsOneWidget);
    expect(find.byKey(const Key('source-c-32')), findsOneWidget);
    await tester.tap(find.byKey(const Key('source-c-31')));
    await tester.pumpAndSettle();
    expect(find.text('来自 采集站三'), findsOneWidget);
    expect(detailAsked.last, 'c/31');
  });

  testWidgets('a detail with nothing to play goes to another site, unless its site is not changeable', (tester) async {
    await openCard(
      tester,
      home: [card('cms', '7', '推荐片')],
      open: '推荐片',
      details: {
        'cms/7': detail('cms', '7', '推荐片', const []),
        'b/22': detail('b', '22', '推荐片', [fakeLine('线路一', 'x')]),
      },
      hits: {
        'b': [card('b', '22', '推荐片')],
      },
    );
    expect(find.text('来自 采集站二'), findsOneWidget);
    expect(find.text('「采集站」上没有可播放的线路，已换到这里'), findsOneWidget);
    await leave(tester);

    await openCard(
      tester,
      home: [card('cms', '7', '推荐片')],
      open: '推荐片',
      cmsSite: {'changeable': false},
      details: {'cms/7': detail('cms', '7', '推荐片', const [])},
      hits: {
        'b': [card('b', '22', '推荐片')],
      },
    );
    expect(find.text('暂无播放线路'), findsOneWidget);
    expect(searchAsked, isEmpty, reason: 'a site that is not changeable is not left on its own');
  });

  testWidgets('nothing found for a recommendation: says so, with how many sites were asked', (tester) async {
    await openCard(
      tester,
      home: [card('cms', 'msearch:星河往事', '星河往事')],
      open: '星河往事',
      hits: {'b': const [], 'c': const []},
    );
    expect(find.byKey(const Key('detail-not-found')), findsOneWidget);
    expect(find.textContaining('没在其他站点找到《星河往事》'), findsOneWidget);
    expect(find.textContaining('搜了 2 个站点'), findsOneWidget);
  });

  testWidgets('every line failing in the player moves on to another site, same episode, and the detail follows', (tester) async {
    await openCard(
      tester,
      home: [card('cms', '7', '推荐片')],
      open: '推荐片',
      dead: {'线路一'},
      details: {
        'cms/7': detail('cms', '7', '推荐片', [fakeLine('线路一', 'a')]),
        'b/22': detail('b', '22', '推荐片', [fakeLine('二号线', 'b')]),
      },
      hits: {
        'b': [card('b', '22', '推荐片')],
      },
    );
    await tester.tap(find.text('播放'));
    await pass(tester, const Duration(seconds: 2));
    expect(resolvedAt, ['cms:线路一', 'b:二号线'], reason: 'the dead line, then the same episode on 采集站二');
    expect(find.textContaining('已换到「采集站二」'), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await pass(tester, const Duration(seconds: 1));
    expect(find.text('来自 采集站二'), findsOneWidget);
    expect(find.text('「采集站」的线路都不能播放，已换到这里'), findsOneWidget);
    await leave(tester);
  });

  testWidgets('with no other copy, the player says every line failed and no other site helped', (tester) async {
    await openCard(
      tester,
      home: [card('cms', '7', '推荐片')],
      open: '推荐片',
      dead: {'线路一'},
      details: {'cms/7': detail('cms', '7', '推荐片', [fakeLine('线路一', 'a')])},
      hits: {'b': const []},
    );
    await tester.tap(find.text('播放'));
    await pass(tester, const Duration(seconds: 2));
    expect(resolvedAt, ['cms:线路一']);
    expect(find.textContaining('别的站点也没有找到能播放的《推荐片》'), findsOneWidget);
    await leave(tester);
  });
}
