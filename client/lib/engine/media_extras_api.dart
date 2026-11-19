import 'dart:convert';

import 'danmaku_models.dart';
import 'engine_client.dart';

/// A subtitle file as the engine handed it back: UTF-8 text in a format the player reads.
class ConvertedSubtitle {
  const ConvertedSubtitle({required this.format, required this.text});

  /// srt | ass | ssa | vtt
  final String format;
  final String text;

  factory ConvertedSubtitle.fromJson(Map<String, dynamic> j) => ConvertedSubtitle(format: j['format'] as String? ?? 'srt', text: j['text'] as String? ?? '');
}

/// Subtitles and danmaku: the parts of the engine's API that go with a video besides the picture.
extension MediaExtrasApi on EngineClient {
  /// Has the engine read a subtitle file from this device (any encoding; SRT, ASS, WebVTT, TTML, LRC, …).
  Future<ConvertedSubtitle> convertSubtitle(String name, List<int> bytes) async =>
      ConvertedSubtitle.fromJson(await send('POST', 'subtitle/convert', body: {'name': name, 'data': base64Encode(bytes)}) as Map<String, dynamic>);

  /// The danmaku of an episode: from the site, else the services the user switched on. [title] and [episode] are
  /// what those services are asked for.
  Future<DanmakuList> danmaku({
    required String site,
    required String line,
    required String episodeId,
    required String title,
    required String episode,
    bool refresh = false,
  }) async => DanmakuList.fromJson(
    await send(
      'GET',
      'danmaku',
      query: {'site': site, 'line': line, 'episodeId': episodeId, 'title': title, 'episode': episode, if (refresh) 'refresh': '1'},
    ) as Map<String, dynamic>,
  );

  /// Has the engine read a danmaku file from this device (Bilibili XML, JSON, ASS).
  Future<DanmakuList> parseDanmaku(String name, List<int> bytes) async =>
      DanmakuList.fromJson(await send('POST', 'danmaku/parse', body: {'name': name, 'data': base64Encode(bytes)}) as Map<String, dynamic>);

  Future<DanmakuServices> danmakuServices() async => DanmakuServices.fromJson(await send('GET', 'danmaku/services') as Map<String, dynamic>);
}
