import 'dart:convert';

import 'package:media_kit/media_kit.dart';

import 'pages/seek_bar.dart' show BufferedRange;
import 'player_cache_stub.dart' if (dart.library.io) 'player_cache_io.dart' as impl;

/// What libmpv holds of the media it plays.
class PlayerCacheState {
  const PlayerCacheState({this.ranges = const [], this.diskBytes = 0});

  /// The stretches it can seek in without reading anything.
  final List<BufferedRange> ranges;

  /// The size of its cache file; 0 when it keeps the cache in memory.
  final int diskBytes;
}

/// How the player keeps what it has read, so that seeking back and forth does not go back to the network.
///
/// libmpv keeps the packets it has read ("demuxer cache") and seeks inside them at once. Where they are kept depends
/// on where the video comes from:
///
/// - **through the engine's stream cache** (`PlayInfo.cache`): the engine has everything that was played or read
///   ahead on its disk and hands it back in milliseconds, so the player keeps only a little, in memory;
/// - **anything else on the network** (a direct mp4 / flv / mkv link, HLS the engine does not cache): the player is
///   all there is, so on desktop its cache goes to a file — everything read stays seekable for as long as the
///   video is open, and memory holds only the index of it. The file is deleted when the video is closed.
///
/// Players that are not libmpv (the fake one of the widget tests) are left alone.
class PlayerCache {
  /// Read-ahead and look-back the player keeps in memory when the engine caches the stream.
  static const engineForward = '24MiB';
  static const engineBack = '8MiB';

  /// With a cache file these bound the index libmpv keeps in memory (about 1 MB per minute of video); without one
  /// (the file could not be made, or not a desktop) they bound the packets themselves, as media_kit does by default.
  static const ownForward = '32MiB';
  static const ownBack = '32MiB';

  /// How far ahead the player reads into its cache file, in seconds.
  static const ownReadAheadSeconds = 300;

  /// A cache file never shrinks while its video is open; past this size the page opens the video again where it is.
  static const diskLimit = 4 * 1024 * 1024 * 1024;

  /// Before the player opens a media: sets libmpv's cache up for where the video comes from.
  static Future<void> prepare(Player player, {required bool engineCached}) async {
    final native = player.platform;
    if (native is! NativePlayer) return;
    final dir = engineCached ? null : impl.playerCacheDir();
    final options = <String, String>{
      'cache': 'yes',
      'demuxer-seekable-cache': 'yes',
      'cache-on-disk': dir == null ? 'no' : 'yes',
      'demuxer-cache-dir': ?dir,
      'demuxer-max-bytes': engineCached ? engineForward : ownForward,
      'demuxer-max-back-bytes': engineCached ? engineBack : ownBack,
      // With a file, read-ahead is bounded in time (the index would allow half an hour); otherwise by the bytes above.
      'cache-secs': dir == null ? '3600' : '$ownReadAheadSeconds',
      // The engine answers at once and deals with a slow source itself: giving up on it after media_kit's five
      // seconds would only start the same download again.
      'network-timeout': engineCached ? '30' : '5',
    };
    for (final option in options.entries) {
      await native.setProperty(option.key, option.value);
    }
  }

  /// What libmpv holds right now. Empty for a player that is not libmpv, except for its read-ahead.
  static Future<PlayerCacheState> read(Player player) async {
    final native = player.platform;
    if (native is! NativePlayer) {
      final position = player.state.position;
      final buffer = player.state.buffer;
      return PlayerCacheState(ranges: [if (buffer > position) (start: position, end: buffer)]);
    }
    try {
      final state = jsonDecode(await native.getProperty('demuxer-cache-state')) as Map<String, dynamic>;
      Duration seconds(Object? v) => Duration(microseconds: ((v as num) * 1e6).round());
      return PlayerCacheState(
        ranges: [
          for (final r in (state['seekable-ranges'] as List? ?? const []).cast<Map<String, dynamic>>()) (start: seconds(r['start']), end: seconds(r['end'])),
        ],
        diskBytes: (state['file-cache-bytes'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      // Nothing is open, or this libmpv words it differently: no ranges to show.
      return const PlayerCacheState();
    }
  }

  /// Several lists of ranges as one, in order, with what overlaps or touches joined.
  static List<BufferedRange> merge(Iterable<BufferedRange> ranges) {
    final sorted = ranges.where((r) => r.end > r.start).toList()..sort((a, b) => a.start.compareTo(b.start));
    final out = <BufferedRange>[];
    for (final r in sorted) {
      if (out.isNotEmpty && r.start <= out.last.end + const Duration(milliseconds: 500)) {
        if (r.end > out.last.end) out[out.length - 1] = (start: out.last.start, end: r.end);
      } else {
        out.add(r);
      }
    }
    return out;
  }
}
