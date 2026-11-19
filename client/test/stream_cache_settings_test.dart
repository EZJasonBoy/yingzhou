import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/pages/stream_cache_settings.dart';

import 'fake_engine.dart';

/// 播放缓存 on the 源 page: what the engine's stream cache holds, its switch, its size, and emptying it.
void main() {
  late List<Map<String, dynamic>> sent;

  /// The app on its 源 page. [cache] is what the engine's stream cache says of itself; null: an engine without one.
  Future<void> openSources(WidgetTester tester, {Map<String, Object>? cache}) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    sent = [];
    final engine = fakeEngine(hasConfig: true, streamCache: cache, settingsSent: sent);
    await tester.pumpWidget(TvboxApp(state: AppState(clientFactory: (url) => EngineClient(url, httpClient: engine))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('源'));
    await tester.pumpAndSettle();
  }

  Map<String, Object> holding({int mb = 1229, int streams = 3}) => {'available': true, 'bytes': mb * 1024 * 1024, 'files': 800, 'streams': streams, 'path': r'C:\data\cache\stream'};

  String usage(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('stream-cache-usage'))).data!;

  testWidgets('shows how much is cached and where', (tester) async {
    await openSources(tester, cache: holding());
    expect(find.text('播放缓存'), findsOneWidget);
    expect(usage(tester), '已用 1.2 GB / 2 GB · 3 个视频');
    expect(find.textContaining(r'C:\data\cache\stream'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('stream-cache-switch'))).value, isTrue);
  });

  testWidgets('the switch and the size change only their own setting', (tester) async {
    await openSources(tester, cache: holding());
    await tester.tap(find.byKey(const Key('stream-cache-switch')));
    await tester.pumpAndSettle();
    expect(sent, [
      {'streamCache': false},
    ]);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('stream-cache-switch'))).value, isFalse);
    expect(find.textContaining('已关闭：播放器直接向片源要分片'), findsOneWidget);

    await tester.tap(find.byKey(const Key('stream-cache-max')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('5 GB').last);
    await tester.pumpAndSettle();
    expect(sent.last, {'streamCacheMaxMB': 5120});
    expect(usage(tester), '已用 1.2 GB / 5 GB · 3 个视频');

    // Another setting saved afterwards leaves these two as they are: the engine lays what it is sent over the rest.
    await tester.tap(find.byKey(const Key('github-proxy-switch')));
    await tester.pumpAndSettle();
    expect(sent.last.keys, isNot(contains('streamCacheMaxMB')));
    expect(usage(tester), '已用 1.2 GB / 5 GB · 3 个视频');
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('stream-cache-switch'))).value, isFalse);
  });

  testWidgets('emptying the cache', (tester) async {
    await openSources(tester, cache: holding(mb: 300, streams: 1));
    expect(usage(tester), '已用 300 MB / 2 GB · 1 个视频');
    await tester.tap(find.byKey(const Key('stream-cache-clear')));
    await tester.pumpAndSettle();
    expect(usage(tester), '已用 0 MB / 2 GB');
    expect(tester.widget<OutlinedButton>(find.byKey(const Key('stream-cache-clear'))).onPressed, isNull, reason: 'nothing left to empty');
  });

  testWidgets('an engine that watches its disk (Android) says how much room is left; others say nothing of it', (tester) async {
    await openSources(tester, cache: holding());
    expect(find.byKey(const Key('stream-cache-free')), findsNothing);
    await tester.pumpWidget(const SizedBox());

    await openSources(tester, cache: {...holding(), 'freeBytes': 3 * 1024 * 1024 * 1024, 'reserveBytes': 500 * 1024 * 1024});
    expect(
      tester.widget<Text>(find.byKey(const Key('stream-cache-free'))).data,
      '设备剩余空间 3 GB。剩余空间不到 500 MB 时，缓存会先删掉自己的旧内容，再不够就不缓存、不预读。',
    );
  });

  testWidgets('an engine without a stream cache shows no such section', (tester) async {
    await openSources(tester);
    expect(find.text('播放缓存'), findsNothing);
    expect(find.byKey(const Key('github-proxy-switch')), findsOneWidget);
  });

  test('sizes read as people write them', () {
    String size(num mb) => StreamCacheSettings.size(mb * 1024 * 1024);
    expect([size(0), size(512), size(999), size(1024), size(1536), size(2048), size(10240), size(51200)], ['0 MB', '512 MB', '999 MB', '1 GB', '1.5 GB', '2 GB', '10 GB', '50 GB']);
  });
}
