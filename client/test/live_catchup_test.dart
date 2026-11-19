import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/engine/live_models.dart';
import 'package:tvbox_client/main.dart';

import 'fake_engine.dart';
import 'fake_player.dart';

/// Catch-up on the live page: the fake engine's 回看台 has two days of it, 普通台 none.
void main() {
  late FakePlayer player;

  Future<void> pass(WidgetTester tester, Duration time) async {
    for (var t = Duration.zero; t < time; t += const Duration(milliseconds: 100)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> openLive(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    player = FakePlayer();
    final engine = fakeEngine(hasConfig: true);
    await tester.pumpWidget(
      TvboxApp(
        state: AppState(clientFactory: (url) => EngineClient(url, httpClient: engine), playerBackend: () => player.backend()),
      ),
    );
    await pass(tester, const Duration(seconds: 1));
    await tester.tap(find.text('直播').first);
    await pass(tester, const Duration(seconds: 1));
  }

  String yesterday() => chinaDate(DateTime.now(), daysAgo: 1).substring(5);

  testWidgets('a past programme of a channel with catch-up plays back with a seek bar; one click goes back to live', (tester) async {
    await openLive(tester);
    expect(player.opened, ['https://cdn.test/live/a.m3u8'], reason: 'the first channel plays live');
    expect(find.byKey(const Key('back-to-live')), findsNothing);

    // Today back to the two days the channel allows.
    expect(find.widgetWithText(ChoiceChip, '今天'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '昨天'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '前天'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNWidgets(3), reason: 'no further back than the channel allows');

    await tester.tap(find.widgetWithText(ChoiceChip, '昨天'));
    await pass(tester, const Duration(milliseconds: 500));
    expect(find.text('${yesterday()} 节目 1'), findsOneWidget, reason: 'yesterday\'s guide');
    expect(find.text('回看'), findsWidgets, reason: 'every programme of yesterday can be played back');

    await tester.tap(find.text('${yesterday()} 节目 2'));
    await pass(tester, const Duration(seconds: 1));
    final start = DateTime.parse('${chinaDate(DateTime.now(), daysAgo: 1)}T02:00:00+08:00');
    final end = start.add(const Duration(hours: 2));
    expect(player.opened.last, 'https://cdn.test/catchup/a.m3u8?start=${start.millisecondsSinceEpoch}&end=${end.millisecondsSinceEpoch}');
    expect(find.byKey(const Key('back-to-live')), findsOneWidget);
    expect(find.text('回看中'), findsOneWidget, reason: 'the programme being played back is marked in the guide');
    expect(find.byKey(const Key('catchup-seek')), findsOneWidget);

    // The seek bar moves the playback.
    final slider = tester.widget<Slider>(find.byKey(const Key('catchup-seek')));
    slider.onChanged!(slider.max / 2);
    expect(player.seeks.last, const Duration(minutes: 20), reason: 'half of the 40 minutes the fake media lasts');

    await tester.tap(find.byKey(const Key('back-to-live')));
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened.last, 'https://cdn.test/live/a.m3u8');
    expect(find.byKey(const Key('back-to-live')), findsNothing);
    expect(find.byKey(const Key('catchup-seek')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('changing channel goes back to live, and a channel without catch-up has no days or marks', (tester) async {
    await openLive(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, '昨天'));
    await pass(tester, const Duration(milliseconds: 500));
    await tester.tap(find.text('${yesterday()} 节目 3'));
    await pass(tester, const Duration(seconds: 1));
    expect(find.byKey(const Key('back-to-live')), findsOneWidget);

    await tester.tap(find.text('普通台').first);
    await pass(tester, const Duration(seconds: 1));
    expect(player.opened.last, 'https://cdn.test/live/b.m3u8');
    expect(find.byKey(const Key('back-to-live')), findsNothing);
    expect(find.widgetWithText(ChoiceChip, '昨天'), findsNothing, reason: 'no days to choose from');
    expect(find.text('回看'), findsNothing, reason: 'nothing is marked for playing back');
    expect(find.text('直播中'), findsOneWidget, reason: 'today\'s guide, as before');

    // Clicking a programme that has ended does nothing on such a channel.
    // The programme before the one on air (in view: the guide scrolls to the current one). Before 02:00 in China
    // there is none, and this is skipped.
    final current = DateTime.now().toUtc().add(const Duration(hours: 8)).hour ~/ 2;
    final ended = find.text('${chinaDate(DateTime.now()).substring(5)} 节目 $current');
    if (current >= 1) {
      await tester.tap(ended.first);
      await pass(tester, const Duration(milliseconds: 500));
      expect(player.opened.last, 'https://cdn.test/live/b.m3u8');
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
