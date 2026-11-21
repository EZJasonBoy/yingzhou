import 'engine_client.dart';

// The GitHub proxies the engine offers and measuring them (`/api/v1/github-proxy`).

/// A GitHub proxy ("gh-proxy") to pick from: [prefix] goes in front of the GitHub address.
class GithubProxyPreset {
  const GithubProxyPreset({required this.name, required this.prefix});

  final String name;
  final String prefix;

  factory GithubProxyPreset.fromJson(Map<String, dynamic> json) =>
      GithubProxyPreset(name: json['name'] as String? ?? '', prefix: json['prefix'] as String? ?? '');
}

/// How one prefix answered: the empty prefix is GitHub itself.
class GithubProxyProbeResult {
  const GithubProxyProbeResult({required this.prefix, required this.ok, required this.ms, this.error = ''});

  final String prefix;

  /// It answered with the file.
  final bool ok;
  final int ms;

  /// Why not, when not [ok] (the engine's words: `HTTP 503 from <host>`, `timeout talking to <host>`...).
  final String error;

  factory GithubProxyProbeResult.fromJson(Map<String, dynamic> json) => GithubProxyProbeResult(
    prefix: json['prefix'] as String? ?? '',
    ok: json['ok'] as bool? ?? false,
    ms: (json['ms'] as num?)?.toInt() ?? 0,
    error: json['error'] as String? ?? '',
  );
}

extension GithubProxyApi on EngineClient {
  /// The proxies the engine offers; an engine from before presets answers 404 ([EngineException]).
  Future<List<GithubProxyPreset>> githubProxyPresets() async {
    final json = await send('GET', 'github-proxy') as Map<String, dynamic>;
    return [for (final p in json['presets'] as List<dynamic>? ?? const []) GithubProxyPreset.fromJson(p as Map<String, dynamic>)];
  }

  /// One small GitHub file straight from GitHub (first) and through each of [prefixes] (the presets when empty).
  Future<List<GithubProxyProbeResult>> probeGithubProxies(List<String> prefixes) async {
    final json = await send('POST', 'github-proxy/probe', body: {'prefixes': prefixes}) as Map<String, dynamic>;
    return [for (final r in json['results'] as List<dynamic>? ?? const []) GithubProxyProbeResult.fromJson(r as Map<String, dynamic>)];
  }
}
