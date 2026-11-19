import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/drives.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/pages/drives_page.dart';

import 'fake_drive_engine.dart';
import 'fake_player.dart';

void main() {
  late FakePlayer player;

  /// Lets [time] go by, a frame every 100 ms.
  Future<void> pass(WidgetTester tester, Duration time) async {
    for (var t = Duration.zero; t < time; t += const Duration(milliseconds: 100)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> openDrives(WidgetTester tester, FakeDriveEngine engine) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    player = FakePlayer();
    await tester.pumpWidget(TvboxApp(state: AppState(clientFactory: (url) => EngineClient(url, httpClient: engine), playerBackend: () => (player = FakePlayer()).backend())));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('网盘')));
    await tester.pumpAndSettle();
  }

  /// The names of the entries the folder page shows, top to bottom.
  List<String> shown(WidgetTester tester) => [
    for (final tile in tester.widgetList<ListTile>(find.byWidgetPredicate((w) => w is ListTile && (w.key as ValueKey?)?.value.toString().startsWith('entry-') == true)))
      ((tile.title as Text).data!),
  ];

  testWidgets('drives are listed and added; a password goes to the engine and is never shown again', (tester) async {
    final engine = FakeDriveEngine();
    await openDrives(tester, engine);
    expect(find.text('家里的 AList'), findsOneWidget);
    expect(find.textContaining('AList / OpenList · http://192.168.1.2:5244'), findsOneWidget);

    await tester.tap(find.byKey(const Key('drive-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drive-kind-webdav')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('drive-token')), findsNothing, reason: 'tokens are AList only');
    await tester.enterText(find.byKey(const Key('drive-url')), 'https://dav.example.com/dav');
    await tester.enterText(find.byKey(const Key('drive-username')), 'u');
    await tester.enterText(find.byKey(const Key('drive-password')), 'secret');
    await tester.tap(find.byKey(const Key('drive-test')));
    await tester.pumpAndSettle();
    expect(find.text('连接成功，有 5 项'), findsOneWidget);
    await tester.tap(find.byKey(const Key('drive-save')));
    await tester.pumpAndSettle();

    expect(engine.posted.last, {'kind': 'webdav', 'name': '', 'url': 'https://dav.example.com/dav', 'username': 'u', 'password': 'secret', 'root': '/', 'proxy': false});
    expect(find.text('dav.example.com'), findsOneWidget, reason: 'the list is loaded again');

    // Editing: the password field starts empty and, left empty, is not sent (the engine keeps the one it has).
    await tester.tap(find.descendant(of: find.byKey(const Key('drive-d2')), matching: find.byType(PopupMenuButton<String>)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('drive-password'))).controller!.text, '');
    expect(find.text('已保存，不改就留空'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('drive-name')), '公司');
    await tester.tap(find.byKey(const Key('drive-save')));
    await tester.pumpAndSettle();
    expect(engine.posted.last.containsKey('password'), isFalse);
    expect(engine.posted.last['name'], '公司');
    expect(find.text('公司'), findsOneWidget);

    // Removing asks first.
    await tester.tap(find.descendant(of: find.byKey(const Key('drive-d2')), matching: find.byType(PopupMenuButton<String>)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drive-remove-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('公司'), findsNothing);
  });

  testWidgets('a drive is browsed by folders and breadcrumbs, sorted, and a locked folder asks for its password', (tester) async {
    final engine = FakeDriveEngine();
    await openDrives(tester, engine);
    await tester.tap(find.text('家里的 AList'));
    await tester.pumpAndSettle();
    expect(shown(tester), ['剧集', '私密', '大电影.mkv', '小短片.mp4', '说明.txt'], reason: 'folders first, then by name');
    expect(find.textContaining('2.8 GB'), findsOneWidget);
    expect(tester.widget<ListTile>(find.byKey(const Key('entry-/说明.txt'))).enabled, isFalse, reason: 'only videos open');

    await tester.tap(find.byKey(const Key('drive-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按大小'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(shown(tester), ['剧集', '私密', '说明.txt', '小短片.mp4', '大电影.mkv']);
    await tester.tap(find.byKey(const Key('drive-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按修改时间'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(shown(tester), ['私密', '剧集', '说明.txt', '大电影.mkv', '小短片.mp4']);

    await tester.tap(find.text('剧集'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drive-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按名称'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(shown(tester), ['第1集.mp4', '第1集.srt', '第2集.mp4', '第10集.mp4'], reason: 'numbers in names in order');
    expect(find.textContaining('有字幕'), findsOneWidget, reason: 'the episode with a subtitle beside it says so');

    await tester.tap(find.byKey(const Key('crumb-/')));
    await tester.pumpAndSettle();
    expect(shown(tester).first, '剧集');

    await tester.tap(find.text('私密'));
    await tester.pumpAndSettle();
    expect(find.text('这个文件夹设了密码'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('drive-folder-password')), 'guess');
    await tester.tap(find.byKey(const Key('drive-folder-unlock')));
    await tester.pumpAndSettle();
    expect(find.text('文件夹密码不对：/私密'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('drive-folder-password')), 'pw');
    await tester.tap(find.byKey(const Key('drive-folder-unlock')));
    await tester.pumpAndSettle();
    expect(shown(tester), ['秘密.mp4']);

    // Back goes up a folder before it leaves the drive.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(shown(tester).first, '剧集');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('drive-add')), findsOneWidget);
  });

  testWidgets('a video plays with its folder as the playlist, goes into the history, and resumes', (tester) async {
    final engine = FakeDriveEngine(
      history: [
        {'site': 'drive:d1', 'vodId': '/剧集', 'name': '剧集', 'line': '家里的 AList', 'episodeId': '/剧集/第2集.mp4', 'episodeName': '第2集', 'episodeIndex': 1, 'positionMs': 61000, 'durationMs': 1200000},
      ],
    );
    await openDrives(tester, engine);
    await tester.tap(find.text('家里的 AList'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('剧集'));
    await tester.pumpAndSettle();
    expect(find.text('上次看到：第2集 01:01'), findsOneWidget);
    expect(find.textContaining('看到 01:01'), findsOneWidget, reason: 'the file says how far it was watched');

    // Carrying on: the second episode, from where it was left.
    await tester.tap(find.text('继续播放'));
    await pass(tester, const Duration(seconds: 1));
    expect(engine.resolved, ['/剧集/第2集.mp4']);
    expect(player.opened.single, endsWith('/%E5%89%A7%E9%9B%86/%E7%AC%AC2%E9%9B%86.mp4'));
    expect(player.seeks, contains(const Duration(seconds: 61)));

    // The next episode is the next video of the folder, in name order.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await pass(tester, const Duration(seconds: 1));
    expect(engine.resolved.last, '/剧集/第10集.mp4');
    expect(engine.savedHistory.last['episodeId'], '/剧集/第10集.mp4');
    expect(engine.savedHistory.last['vodId'], '/剧集', reason: 'the folder is the video in the history');
    expect(engine.savedHistory.last['site'], 'drive:d1');

    await tester.binding.handlePopRoute();
    await pass(tester, const Duration(seconds: 1));
    expect(find.textContaining('上次看到：第10集'), findsOneWidget, reason: 'the folder page shows the new place');

    // Another file starts from its beginning.
    player.seeks.clear();
    await tester.tap(find.text('第1集.mp4'));
    await pass(tester, const Duration(seconds: 1));
    expect(engine.resolved.last, '/剧集/第1集.mp4');
    expect(player.seeks, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a drive folder in the history opens like a title and resumes there', (tester) async {
    final engine = FakeDriveEngine(
      history: [
        {'site': 'drive:d1', 'vodId': '/剧集', 'name': '剧集', 'line': '家里的 AList', 'episodeId': '/剧集/第2集.mp4', 'episodeName': '第2集', 'episodeIndex': 1, 'positionMs': 61000, 'durationMs': 1200000},
      ],
    );
    await openDrives(tester, engine);
    await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('我的')));
    await tester.pumpAndSettle();
    expect(find.text('网盘'), findsWidgets, reason: 'the card names where it is from');
    await tester.tap(find.text('剧集'));
    await tester.pumpAndSettle();
    expect(find.text('来源：网盘'), findsOneWidget);
    await tester.tap(find.textContaining('继续播放').first);
    await pass(tester, const Duration(seconds: 1));
    expect(engine.resolved, ['/剧集/第2集.mp4']);
    expect(player.seeks, contains(const Duration(seconds: 61)));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  test('entries sort with folders first and numbers in order', () {
    const entries = [
      DriveEntry(name: 'b10.mp4', path: '/b10.mp4', dir: false, size: 5, modified: 2),
      DriveEntry(name: 'B2.mp4', path: '/B2.mp4', dir: false, size: 9, modified: 1),
      DriveEntry(name: 'z', path: '/z', dir: true),
    ];
    expect(sortDriveEntries(entries, DriveSort.name).map((e) => e.name), ['z', 'B2.mp4', 'b10.mp4']);
    expect(sortDriveEntries(entries, DriveSort.size, descending: true).map((e) => e.name), ['z', 'B2.mp4', 'b10.mp4']);
    expect(sortDriveEntries(entries, DriveSort.date).map((e) => e.name), ['z', 'B2.mp4', 'b10.mp4']);
    expect(naturalCompare('第2集', '第10集'), lessThan(0));
    expect(naturalCompare('第02集', '第2集'), 0);
    expect(sizeLabel(0), '');
    expect(sizeLabel(1536), '1.5 KB');
    expect(positionLabel(3661000), '1:01:01');
  });
}
