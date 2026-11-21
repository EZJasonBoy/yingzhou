import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'poster_cache_stub.dart' if (dart.library.io) 'poster_cache_io.dart' as impl;

/// Posters and logos on disk, so lists paint at once on the second visit and without a network. Bounded: when
/// the folder grows past the limit, the files that were not used for the longest time go first.
abstract class PosterCache {
  /// The cache the app's images go through; null (tests, web) leaves images to Flutter's own in-memory cache.
  static PosterCache? instance;

  /// A cache in the app's cache folder; null where there is no file system.
  static Future<PosterCache?> open({int maxBytes = 300 * 1024 * 1024}) => impl.openPosterCache(maxBytes);

  /// A cache in [path], for tests.
  static PosterCache? at(String path, {int maxBytes = 300 * 1024 * 1024, Future<Uint8List> Function(Uri url, Map<String, String> headers)? fetch}) =>
      impl.posterCacheAt(path, maxBytes, fetch);

  /// The image's bytes: from disk when they are there, else downloaded and kept. Kept under [key] when given (the
  /// address as written, headers and all), else under [url].
  Future<Uint8List> load(String url, {Map<String, String>? headers, String? key});

  Future<int> size();

  Future<void> clear();
}

/// An image that comes through a [PosterCache].
@immutable
class CachedPoster extends ImageProvider<CachedPoster> {
  const CachedPoster(this.url, this.cache, {this.headers, this.key});

  final String url;
  final PosterCache cache;
  final Map<String, String>? headers;

  /// What the image is kept and recognised under, in memory and on disk; [url] when null.
  final String? key;

  String get _id => key ?? url;

  @override
  Future<CachedPoster> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(CachedPoster key, ImageDecoderCallback decode) => MultiFrameImageStreamCompleter(
    codec: _codec(decode),
    scale: 1,
    debugLabel: url,
    informationCollector: () => [DiagnosticsProperty<String>('poster', url)],
  );

  Future<ui.Codec> _codec(ImageDecoderCallback decode) async =>
      decode(await ui.ImmutableBuffer.fromUint8List(await cache.load(url, headers: headers, key: key)));

  @override
  bool operator ==(Object other) => other is CachedPoster && other._id == _id && identical(other.cache, cache);

  @override
  int get hashCode => _id.hashCode;
}
