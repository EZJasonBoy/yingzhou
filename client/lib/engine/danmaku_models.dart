/// How a danmaku comment moves.
enum DanmakuMode { scroll, top, bottom }

/// One danmaku comment as the engine gives it.
class DanmakuComment {
  const DanmakuComment({required this.timeMs, this.mode = DanmakuMode.scroll, this.color = 0xFFFFFF, this.size = 25, required this.text});

  /// When it appears, in milliseconds of the video.
  final int timeMs;
  final DanmakuMode mode;

  /// 0xRRGGBB
  final int color;

  /// Bilibili's sizes: 25 normal, 18 small, 36 large.
  final int size;
  final String text;

  factory DanmakuComment.fromJson(Map<String, dynamic> j) => DanmakuComment(
    timeMs: (j['time'] as num?)?.toInt() ?? 0,
    mode: switch (j['mode']) {
      'top' => DanmakuMode.top,
      'bottom' => DanmakuMode.bottom,
      _ => DanmakuMode.scroll,
    },
    color: (j['color'] as num?)?.toInt() ?? 0xFFFFFF,
    size: (j['size'] as num?)?.toInt() ?? 25,
    text: j['text'] as String? ?? '',
  );
}

/// The danmaku of an episode, by time.
class DanmakuList {
  const DanmakuList({this.source = '', this.from = '', this.items = const []});

  /// `site`, `config`, `custom`, `file`; empty when there is no source for this episode.
  final String source;

  /// The address or service they came from.
  final String from;
  final List<DanmakuComment> items;

  static const empty = DanmakuList();

  String get sourceLabel => switch (source) {
    'site' => '站点',
    'config' => '订阅的弹幕接口',
    'custom' => '自定义弹幕接口',
    'file' => '本地文件',
    _ => '',
  };

  factory DanmakuList.fromJson(Map<String, dynamic> j) => DanmakuList(
    source: j['source'] as String? ?? '',
    from: j['from'] as String? ?? '',
    items: [for (final c in j['items'] as List<dynamic>? ?? const []) DanmakuComment.fromJson(c as Map<String, dynamic>)],
  );
}

/// Which danmaku services the engine asks besides the site: the config's API (the user switches it on) and the
/// user's own.
class DanmakuServices {
  const DanmakuServices({this.configApi = '', this.configApiEnabled = false, this.customApi = ''});

  /// The active config's `danmaku` field; empty when it has none.
  final String configApi;
  final bool configApiEnabled;
  final String customApi;

  factory DanmakuServices.fromJson(Map<String, dynamic> j) => DanmakuServices(
    configApi: j['configApi'] as String? ?? '',
    configApiEnabled: j['configApiEnabled'] as bool? ?? false,
    customApi: j['customApi'] as String? ?? '',
  );
}
