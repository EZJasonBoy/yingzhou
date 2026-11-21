import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import 'image_address.dart';
import 'poster_cache.dart';

final _githubHost = RegExp(r'^(?:[a-z0-9-]+\.githubusercontent\.com|(?:(?:api|gist|codeload)\.)?github\.com)$', caseSensitive: false);

String? _githubImage(String url, String mirror) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.userInfo.isNotEmpty) return null;
  if (_githubHost.hasMatch(uri.host)) return url;
  final nested = mirror.isNotEmpty && url.startsWith(mirror) ? url.substring(mirror.length) : url.substring(uri.origin.length).replaceFirst(RegExp('^/'), '');
  final unwrapped = nested.startsWith('http://') || nested.startsWith('https://') ? nested : 'https://$nested';
  final target = Uri.tryParse(unwrapped);
  return target != null && target.userInfo.isEmpty && _githubHost.hasMatch(target.host) ? unwrapped : null;
}

/// Headers for loading an image from the engine (posters, channel logos the engine serves): the pairing token when
/// the image comes from the paired engine on another device. Null for any other address, so the token never goes
/// to third-party image hosts.
Map<String, String>? engineImageHeaders(BuildContext context, String url) {
  final state = context.getInheritedWidgetOfExactType<AppScope>()?.notifier;
  final token = state?.engineToken;
  if (state == null || token == null || token.isEmpty) return null;
  return sameOrigin(url, state.engineUrl) ? {'Authorization': 'Bearer $token'} : null;
}

/// The image for a cover or logo address as configs write it ([ImageAddress]): with the headers the address asks
/// for, the pairing token when it ends up at the engine's own origin (a `proxy://` address included), then
/// [headers] over both. Through the disk cache when the app has one. Null when there is nothing to load.
ImageProvider? netImageProvider(BuildContext context, String raw, {Map<String, String>? headers}) {
  final state = context.getInheritedWidgetOfExactType<AppScope>()?.notifier;
  final address = ImageAddress.parse(raw, engineUrl: state?.engineUrl);
  if (address == null) return null;
  final data = address.dataUri;
  if (data != null) return DataUriImage(data);
  final original = address.url!;
  final sent = {...address.headers, ...?engineImageHeaders(context, original), ...?headers};
  final network = state?.engineSettings ?? state?.network.githubSettings;
  final prefix = network?.githubProxyPrefix ?? '';
  final direct = sent.isEmpty ? _githubImage(original, prefix) : null;
  final mirror = network?.githubProxy == true && direct != null && prefix.isNotEmpty && !Uri.parse(direct).hasQuery;
  final url = direct ?? original;
  // Browsers refuse to let pages set these; asking only makes the request fail.
  if (kIsWeb) sent.removeWhere((name, _) => const {'referer', 'cookie', 'user-agent'}.contains(name.toLowerCase()));
  final cache = PosterCache.instance;
  final sending = sent.isEmpty ? null : sent;
  if (mirror) return CachedPoster('$prefix$url', cache, fallback: url, key: address.cacheKey);
  return cache != null ? CachedPoster(url, cache, headers: sending, key: address.cacheKey) : NetworkImage(url, headers: sending);
}

/// Scheme, host and port are the same.
bool sameOrigin(String a, String b) {
  final x = Uri.tryParse(a);
  final y = Uri.tryParse(b);
  if (x == null || y == null || !x.hasScheme || !y.hasScheme) return false;
  return x.scheme == y.scheme && x.host.toLowerCase() == y.host.toLowerCase() && x.port == y.port;
}
