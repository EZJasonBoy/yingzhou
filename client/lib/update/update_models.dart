import 'release_info.dart';

// What an update check found, and the user's addresses for it, independent of how requests are made.

/// How a check reached `latest.json`.
enum UpdateRoute { direct, mirror }

/// What a check found, or why it found nothing.
class UpdateCheckResult {
  const UpdateCheckResult({
    required this.current,
    required this.at,
    this.release,
    this.route,
    this.mirror = '',
    this.proxy = '',
    this.failures = const [],
  });

  /// The running version.
  final String current;
  final DateTime at;

  /// The newest release; null when the check failed.
  final ReleaseInfo? release;

  /// Which way it was fetched; null when the check failed.
  final UpdateRoute? route;

  /// The GitHub accelerating prefix the check could fall back to ('' when none was set).
  final String mirror;

  /// The HTTP proxy (`host:port`) everything went through ('' when none).
  final String proxy;

  /// Why each route that was tried failed, in the order tried, for the user.
  final List<String> failures;

  bool get ok => release != null;

  /// Positive when the release is newer than the running version, 0 when the same, negative when older (a build
  /// from the repository, ahead of the last release).
  int get comparison => release == null ? 0 : compareVersions(release!.version, current);

  bool get newer => comparison > 0;

  /// [url] the way this check got through: behind the prefix when that is how `latest.json` came.
  String routed(String url) => route == UpdateRoute.mirror && mirror.isNotEmpty ? '$mirror$url' : url;

  /// The way it came, for the user: `直连 GitHub`, `经加速前缀 ghfast.top`, with the proxy when there is one.
  String get routeLabel {
    final way = switch (route) {
      UpdateRoute.direct => '直连 GitHub',
      UpdateRoute.mirror => '经加速前缀 ${mirrorHost(mirror)}',
      null => '',
    };
    return proxy.isEmpty ? way : '$way（经代理 $proxy）';
  }
}

/// `ghfast.top` of `https://ghfast.top/`.
String mirrorHost(String prefix) {
  final host = Uri.tryParse(prefix)?.host ?? '';
  return host.isEmpty ? prefix : host;
}

/// `host:port` of an HTTP proxy as the user typed it (`http://` and a trailing slash are dropped); '' for none,
/// null when it is not one.
String? normalizeProxy(String text) {
  var t = text.trim();
  if (t.isEmpty) return '';
  t = t.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '').replaceFirst(RegExp(r'/+$'), '');
  final m = RegExp(r'^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+):(\d{1,5})$').firstMatch(t);
  if (m == null) return null;
  final port = int.parse(m.group(2)!);
  return port > 0 && port < 65536 ? t : null;
}

/// A GitHub accelerating prefix as the engine keeps it: ends with one slash; '' for none.
String normalizeMirror(String prefix) {
  final p = prefix.trim();
  if (p.isEmpty) return '';
  final withScheme = p.startsWith('http://') || p.startsWith('https://') ? p : 'https://$p';
  return '${withScheme.replaceFirst(RegExp(r'/+$'), '')}/';
}
