import 'package:material_ui/material_ui.dart';

import '../app_state.dart';

/// Headers for loading an image from the engine (posters, channel logos the engine serves): the pairing token when
/// the image comes from the paired engine on another device. Null for any other address, so the token never goes
/// to third-party image hosts.
Map<String, String>? engineImageHeaders(BuildContext context, String url) {
  final state = context.getInheritedWidgetOfExactType<AppScope>()?.notifier;
  final token = state?.engineToken;
  if (state == null || token == null || token.isEmpty) return null;
  return sameOrigin(url, state.engineUrl) ? {'Authorization': 'Bearer $token'} : null;
}

/// Scheme, host and port are the same.
bool sameOrigin(String a, String b) {
  final x = Uri.tryParse(a);
  final y = Uri.tryParse(b);
  if (x == null || y == null || !x.hasScheme || !y.hasScheme) return false;
  return x.scheme == y.scheme && x.host.toLowerCase() == y.host.toLowerCase() && x.port == y.port;
}
