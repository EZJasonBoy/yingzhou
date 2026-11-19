import 'dart:convert';

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
}
