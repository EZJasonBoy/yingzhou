import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/pages/player_tracks.dart';
import 'package:tvbox_client/settings.dart';

import 'fake_engine.dart';
import 'fake_player.dart';

/// The 字幕 / 音轨 panel and keys of the player. 推荐片's episodes come with two subtitles from the site; the fake
/// player says which tracks the stream has and notes what the page chose.
void main() {
  late FakePlayer player;
  late MemorySettings settings;
  late Map<String, Map<String, dynamic>> saved;

  const siteSubs = [
    {'name': '简体中文', 'lang': 'zh', 'format': 'srt', 'url': 'http://127.0.0.1:9978/subtitle?url=a'},
    {'name': 'English', 'lang': 'en', 'format': 'ass', 'url': 'http://127.0.0.1:9978/subtitle?url=b'},
  ];

  Future<void> pass(WidgetTester tester, Duration time) async {
    for (var t = Duration.zero; t < time; t += const Duration(milliseconds: 100)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> play(
    WidgetTester tester, {
    List<Map<String, Object>> subtitles = siteSubs,
    List<Map<String, Object>> history = const [],
    List<AudioTrack>? audio,
    List<SubtitleTrack> inStream = const [],
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    player = FakePlayer()..subtitleTracksInStream = inStream;
    if (audio != null) player.audioTracks = audio;
    settings = MemorySettings();
    saved = {};
    final engine = fakeEngine(hasConfig: true, history: history, savedHistory: saved, subtitles: {'*': subtitles});
    await tester.pumpWidget(
      TvboxApp(
        state: AppState(clientFactory: (url) => EngineClient(url, httpClient: engine), playerBackend: () => player.backend(), settings: settings),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('推荐片'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('播放').first);
    await pass(tester, const Duration(seconds: 1));
  }

  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> showControls(WidgetTester tester) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(600, 300));
    await mouse.moveTo(const Offset(620, 320));
    await tester.pump();
    await mouse.removePointer();
  }

  Future<void> openPanel(WidgetTester tester) async {
    await showControls(tester);
    await tester.tap(find.byKey(const Key('tracks-button')));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k) async {
    await tester.sendKeyEvent(k);
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('a stream without subtitles of its own shows the site\'s first one', (tester) async {
    await play(tester);
    expect(player.subtitleChoices, hasLength(1));
    final chosen = player.subtitleChoices.single;
    expect(chosen.uri, isTrue);
    expect(chosen.id, 'http://127.0.0.1:9978/subtitle?url=a');
    expect(chosen.title, '简体中文');
    expect(chosen.language, 'zh');
    await leave(tester);
  });

  testWidgets('the stream\'s own subtitles come first: the site\'s are listed but not switched on', (tester) async {
    await play(tester, inStream: [const SubtitleTrack('1', '内封中字', 'chi')]);
    expect(player.subtitleChoices, isEmpty, reason: 'libmpv shows the stream\'s default itself');
    await openPanel(tester);
    expect(find.text('内封中字（中文）'), findsOneWidget);
    expect(find.text('简体中文'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    await leave(tester);
  });

  testWidgets('the panel switches between subtitles, turns them off, and shows the audio tracks', (tester) async {
    await play(tester, audio: [const AudioTrack('1', null, 'zh', channelscount: 1), const AudioTrack('2', 'Director', 'en', channelscount: 2)]);
    await openPanel(tester);
    expect(find.text('简体中文'), findsOneWidget);
    expect(find.text('音轨 1 · 中文 · 单声道'), findsOneWidget);
    expect(find.text('音轨 2 · Director · 英语 · 立体声'), findsOneWidget);

    await tester.tap(find.text('English'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(player.subtitleChoices.last.id, 'http://127.0.0.1:9978/subtitle?url=b');
    expect(find.text('字幕：English'), findsOneWidget, reason: 'a notice on the picture');

    // Back to the first: it is a track of the player by now, chosen by its id, not added a second time.
    await tester.tap(find.text('简体中文'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(player.subtitleChoices.last.uri, isFalse);
    expect(player.subtitleChoices.last.title, '简体中文');
    expect(player.subtitleChoices.where((t) => t.uri).length, 2);

    await tester.tap(find.text('关闭'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(player.subtitleChoices.last.id, 'no');

    await tester.tap(find.text('音轨 2 · Director · 英语 · 立体声'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(player.audioChoices.last.id, '2');

    // Esc closes the panel before it leaves the player.
    await key(tester, LogicalKeyboardKey.escape);
    expect(find.byType(TracksPanel), findsNothing);
    expect(find.byType(Scaffold), findsWidgets);
    await leave(tester);
  });

  testWidgets('Z and X shift the timing by half a second and say so, C turns subtitles off and on again', (tester) async {
    await play(tester);
    await key(tester, LogicalKeyboardKey.keyX);
    expect(player.mpv['sub-delay'], '0.50');
    expect(find.text('字幕延后 0.5 秒'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.keyZ);
    await key(tester, LogicalKeyboardKey.keyZ);
    expect(player.mpv['sub-delay'], '-0.50');
    expect(find.text('字幕提前 0.5 秒'), findsOneWidget);
    await openPanel(tester);
    expect(find.text('提前 0.5 秒'), findsOneWidget, reason: 'the panel shows the offset');
    await tester.tap(find.text('归零'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(player.mpv['sub-delay'], '0.00');
    await key(tester, LogicalKeyboardKey.escape);

    await key(tester, LogicalKeyboardKey.keyC);
    expect(player.subtitleChoices.last.id, 'no');
    expect(find.text('字幕已关闭'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.keyC);
    expect(player.subtitleChoices.last.title, '简体中文', reason: 'back to the one shown before');
    await key(tester, LogicalKeyboardKey.keyJ);
    expect(player.subtitleChoices.last.title, 'English', reason: 'J: the next one');
    await leave(tester);
  });

  testWidgets('size and position are libmpv settings remembered on this device', (tester) async {
    await play(tester);
    await openPanel(tester);
    await tester.tap(find.byTooltip('大一点'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byTooltip('往上'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('110%'), findsOneWidget);
    expect(find.text('上移 5%'), findsOneWidget);
    expect(player.mpv['sub-scale'], '1.10');
    expect(player.mpv['sub-pos'], '95');
    expect(settings.getString('player.subtitle.scale'), '1.1');
    expect(settings.getString('player.subtitle.raise'), '5');
    await leave(tester);

    // The next video starts with them.
    final again = FakePlayer();
    final tracks = PlayerTracks(player: Player(platformPlayer: again), client: EngineClient(Uri.parse('http://127.0.0.1:9978')), settings: settings);
    await tester.pump();
    expect(tracks.scale, 1.1);
    expect(again.mpv['sub-pos'], '95');
    tracks.dispose();
  });

  testWidgets('the choice goes into the history, and the next visit chooses the same language again', (tester) async {
    await play(tester, audio: [const AudioTrack('1', null, 'zh'), const AudioTrack('2', null, 'en')]);
    await openPanel(tester);
    await tester.tap(find.text('English'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('音轨 2 · 英语'));
    await tester.pump(const Duration(milliseconds: 200));
    await leave(tester);
    expect(saved['7']?['subtitle'], 'lang:en');
    expect(saved['7']?['audio'], 'lang:en');

    await play(tester, audio: [const AudioTrack('1', null, 'zh'), const AudioTrack('2', null, 'en')], history: [
      {'site': 'cms', 'vodId': '7', 'name': '推荐片', 'line': '线路一', 'episodeId': 'https://cdn.test/1.m3u8', 'episodeIndex': 0, 'positionMs': 0, 'durationMs': 0, 'subtitle': 'lang:en', 'audio': 'lang:en'},
    ]);
    expect(player.subtitleChoices.single.title, 'English');
    expect(player.audioChoices.single.id, '2');
    await leave(tester);

    await play(tester, history: [
      {'site': 'cms', 'vodId': '7', 'name': '推荐片', 'line': '线路一', 'episodeId': 'https://cdn.test/1.m3u8', 'episodeIndex': 0, 'positionMs': 0, 'durationMs': 0, 'subtitle': 'off'},
    ]);
    expect(player.subtitleChoices.single.id, 'no', reason: 'turned off last time: stays off');
    await leave(tester);
  });

  testWidgets('a subtitle file from disk is read by the engine and shown', (tester) async {
    await play(tester, subtitles: const []);
    await openPanel(tester);
    expect(find.text('这个视频没有字幕，可以从本地加载。'), findsOneWidget);
    filePicker = (label, extensions) async {
      expect(extensions, contains('srt'));
      return (name: '本地.srt', bytes: Uint8List.fromList([1, 2, 3]));
    };
    addTearDown(() => filePicker = pickWithDialog);
    await tester.tap(find.text('从本地文件加载…'));
    await pass(tester, const Duration(milliseconds: 300));
    final chosen = player.subtitleChoices.last;
    expect(chosen.data, isTrue);
    expect(chosen.id, contains('本地.srt'), reason: 'the text the engine handed back');
    expect(find.widgetWithText(ChoiceChip, '本地.srt'), findsOneWidget);
    await leave(tester);
  });
}
