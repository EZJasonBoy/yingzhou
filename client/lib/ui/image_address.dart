import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// A cover or logo address as TVBox configs and spiders write it, turned into what to fetch.
///
/// Besides plain http(s) URLs, images come as:
/// - `url@Referer=…@User-Agent=…@Cookie=…@Headers={json}`: request headers after the address, each value running
///   to the next `@` (TVBox, FongMi's TV);
/// - `//host/path`: protocol-relative, fetched over https;
/// - `proxy://do=…&…`: the engine's `/proxy`;
/// - `http://127.0.0.1:<engine port>/…`: the engine as a spider on the engine's own machine sees it, which from
///   another device means the engine's address;
/// - `data:image/png;base64,…`: the image itself.
///
/// Douban's image hosts refuse requests without a Douban Referer (and answer 418 to unknown clients); those get a
/// Referer and a browser User-Agent unless the address gives its own.
@immutable
class ImageAddress {
  const ImageAddress._({this.url, this.headers = const {}, required this.cacheKey, this.dataUri});

  /// The http(s) URL to fetch; null for a `data:` image.
  final String? url;

  /// The request headers the address asks for; empty for most.
  final Map<String, String> headers;

  /// What the image is kept under: the address as written, trimmed. The same cover with other headers is another
  /// image, and a plain URL keeps the key it always had.
  final String cacheKey;

  /// The image itself, for a `data:` address.
  final String? dataUri;

  /// A common desktop browser, for hosts that turn other clients away.
  static const browserUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  static const doubanReferer = 'https://movie.douban.com/';

  static const _markers = ['@Headers=', '@Cookie=', '@Referer=', '@User-Agent='];

  /// What to fetch for [raw], or null when there is nothing this client can load: a blank address, or another
  /// scheme (`assets://`, `file://`, …). [engineUrl] is the engine in use, for `proxy://` and the engine's
  /// loopback address.
  static ImageAddress? parse(String raw, {String? engineUrl}) {
    final address = raw.trim();
    if (address.isEmpty) return null;
    if (address.length > 5 && address.substring(0, 5).toLowerCase() == 'data:') return ImageAddress._(cacheKey: address, dataUri: address);

    var url = address;
    final headers = <String, String>{};
    // Only a marker cuts: `https://x/@2x.png` is an address with an @ in it, not one with headers.
    final cut = _markers.map(address.indexOf).where((i) => i >= 0).fold<int?>(null, (a, b) => a == null || b < a ? b : a);
    if (cut != null) {
      url = address.substring(0, cut).trim();
      // The JSON first, then the single headers over it, in the order FongMi's TV applies them.
      final json = _value(address, '@Headers=');
      if (json != null) headers.addAll(_jsonHeaders(json));
      for (final (marker, name) in const [('@Cookie=', 'Cookie'), ('@Referer=', 'Referer'), ('@User-Agent=', 'User-Agent')]) {
        final value = _value(address, marker);
        if (value != null && value.isNotEmpty) headers[name] = value;
      }
    }

    if (url.startsWith('//')) url = 'https:$url';
    final engine = _engine(engineUrl);
    if (url.length >= 8 && url.substring(0, 8).toLowerCase() == 'proxy://') {
      if (engine == null) return null;
      final rest = url.substring(8);
      url = '${engine.origin}/proxy?${rest.startsWith('?') ? rest.substring(1) : rest}';
    }

    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) return null;
    // The engine's port on this machine's loopback: a spider on the engine's machine pointing at the engine.
    if (engine != null && !engine.local && _isLoopback(uri.host) && uri.port == engine.port) {
      final rest = url.substring(url.indexOf('://') + 3);
      final path = rest.indexOf(RegExp('[/?#]'));
      url = '${engine.origin}${path < 0 ? '' : rest.substring(path)}';
    }

    if (_isDouban(uri.host)) {
      headers.putIfAbsent('Referer', () => doubanReferer);
      headers.putIfAbsent('User-Agent', () => browserUserAgent);
    }
    return ImageAddress._(url: url, headers: Map.unmodifiable(headers), cacheKey: address);
  }

  /// The value after [marker], up to the next `@`.
  static String? _value(String address, String marker) {
    final at = address.indexOf(marker);
    if (at < 0) return null;
    final start = at + marker.length;
    final end = address.indexOf('@', start);
    return address.substring(start, end < 0 ? address.length : end).trim();
  }

  /// `@Headers=` as a JSON object, URL-encoded or not; nothing when it is not one.
  static Map<String, String> _jsonHeaders(String text) {
    String? decoded;
    try {
      decoded = Uri.decodeComponent(text);
    } on ArgumentError {
      // A stray % in raw JSON.
    } on FormatException {
      // Escapes that are not UTF-8.
    }
    for (final candidate in [?decoded, text]) {
      final Object? json;
      try {
        json = jsonDecode(candidate);
      } on FormatException {
        continue;
      }
      if (json is! Map) continue;
      final headers = <String, String>{};
      for (final MapEntry(:key, :value) in json.entries) {
        if (value is! String && value is! num && value is! bool) continue;
        final name = '$key'.trim();
        final v = '$value'.trim();
        if (name.isEmpty || v.isEmpty || _broken(name) || _broken(v)) continue;
        headers[_headerName(name)] = v;
      }
      return headers;
    }
    return const {};
  }

  /// A line break would end the header early, or let a value add headers of its own.
  static bool _broken(String s) => s.contains('\r') || s.contains('\n');

  static String _headerName(String key) => switch (key.toLowerCase()) {
    'ua' || 'user-agent' => 'User-Agent',
    'referer' || 'referrer' => 'Referer',
    'cookie' => 'Cookie',
    _ => key,
  };

  static bool _isLoopback(String host) => const {'127.0.0.1', 'localhost', '::1'}.contains(host.toLowerCase());

  static bool _isDouban(String host) {
    final h = host.toLowerCase();
    return const ['doubanio.com', 'douban.com'].any((d) => h == d || h.endsWith('.$d'));
  }

  static ({String origin, int port, bool local})? _engine(String? engineUrl) {
    final uri = engineUrl == null ? null : Uri.tryParse(engineUrl.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) return null;
    return (origin: uri.origin, port: uri.port, local: _isLoopback(uri.host));
  }
}

/// An image carried in a `data:` address, decoded in place: no network, no disk cache.
@immutable
class DataUriImage extends ImageProvider<DataUriImage> {
  const DataUriImage(this.uri);

  final String uri;

  @override
  Future<DataUriImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(DataUriImage key, ImageDecoderCallback decode) => MultiFrameImageStreamCompleter(
    codec: _codec(decode),
    scale: 1,
    debugLabel: 'data: image',
    informationCollector: () => [DiagnosticsProperty<int>('data: image, characters', uri.length)],
  );

  Future<ui.Codec> _codec(ImageDecoderCallback decode) async {
    var text = uri;
    // Base64 wrapped over lines (as some configs write it) does not decode with the breaks in.
    final comma = text.indexOf(',');
    if (comma > 0 && text.substring(0, comma).toLowerCase().endsWith(';base64')) text = text.replaceAll(RegExp(r'\s'), '');
    return decode(await ui.ImmutableBuffer.fromUint8List(UriData.parse(text).contentAsBytes()));
  }

  @override
  bool operator ==(Object other) => other is DataUriImage && other.uri == uri;

  @override
  int get hashCode => uri.hashCode;
}
