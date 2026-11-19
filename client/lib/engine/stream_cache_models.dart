// Wire types of the engine's stream cache (docs/protocol.md, "播放缓存").

/// What the engine keeps of the streams it served (`GET /api/v1/stream-cache`).
class StreamCacheInfo {
  const StreamCacheInfo({
    required this.available,
    this.enabled = false,
    this.bytes = 0,
    this.files = 0,
    this.streams = 0,
    this.maxBytes = 0,
    this.path = '',
    this.freeBytes = -1,
    this.reserveBytes = 0,
  });

  /// False when the engine has no stream cache (an older engine).
  final bool available;
  final bool enabled;
  final int bytes;
  final int files;

  /// Films (episodes) that have something in the cache.
  final int streams;
  final int maxBytes;

  /// Where it is on the engine's machine.
  final String path;

  /// Free space on that disk; -1 when the engine does not watch it (only the Android engine does).
  final int freeBytes;

  /// The cache gives way before the disk has less than this left; 0 when it only keeps to [maxBytes].
  final int reserveBytes;

  factory StreamCacheInfo.fromJson(Map<String, dynamic> j) => StreamCacheInfo(
    available: j['available'] as bool? ?? false,
    enabled: j['enabled'] as bool? ?? false,
    bytes: (j['bytes'] as num?)?.toInt() ?? 0,
    files: (j['files'] as num?)?.toInt() ?? 0,
    streams: (j['streams'] as num?)?.toInt() ?? 0,
    maxBytes: (j['maxBytes'] as num?)?.toInt() ?? 0,
    path: j['path'] as String? ?? '',
    freeBytes: (j['freeBytes'] as num?)?.toInt() ?? -1,
    reserveBytes: (j['reserveBytes'] as num?)?.toInt() ?? 0,
  );
}

/// The parts of a film that are in the engine's cache (`GET /api/v1/stream-cache/coverage`).
class StreamCoverage {
  const StreamCoverage({this.duration = Duration.zero, this.ranges = const []});

  final Duration duration;

  /// In order, not overlapping.
  final List<({Duration start, Duration end})> ranges;

  factory StreamCoverage.fromJson(Map<String, dynamic> j) => StreamCoverage(
    duration: Duration(milliseconds: (j['durationMs'] as num?)?.toInt() ?? 0),
    ranges: [
      for (final r in (j['ranges'] as List? ?? const []).cast<List<dynamic>>())
        if (r.length == 2) (start: Duration(milliseconds: (r[0] as num).toInt()), end: Duration(milliseconds: (r[1] as num).toInt())),
    ],
  );
}
