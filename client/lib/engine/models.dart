// Wire types of engine protocol v1 (docs/protocol.md).

class EngineInfo {
  const EngineInfo({
    required this.name,
    required this.version,
    required this.protocol,
    required this.platform,
    required this.capabilities,
  });

  final String name;
  final String version;
  final int protocol;
  final String platform;

  /// jar / js / py / sniff -> supported
  final Map<String, bool> capabilities;

  factory EngineInfo.fromJson(Map<String, dynamic> json) => EngineInfo(
        name: json['name'] as String,
        version: json['version'] as String,
        protocol: json['protocol'] as int,
        platform: json['platform'] as String,
        capabilities: (json['capabilities'] as Map<String, dynamic>? ?? const {})
            .map((k, v) => MapEntry(k, v == true)),
      );
}

class Subscription {
  const Subscription({required this.id, required this.name, required this.url, this.usedAt = 0});

  final String id;

  /// The name it was given; the engine uses the address itself until it is renamed.
  final String name;
  final String url;

  /// When it last loaded as the active subscription (epoch ms); 0 when it never has, or the engine is older.
  final int usedAt;

  /// True when the user gave it a name of its own.
  bool get named => name.isNotEmpty && name != url;

  /// What a list shows: its name, or a short form of the address (host and file) when it has none.
  String get label {
    if (named) return name;
    final u = Uri.tryParse(url);
    if (u == null || u.host.isEmpty) return url;
    final file = u.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
    return file == null ? u.host : '${u.host} · $file';
  }

  factory Subscription.fromJson(Map<String, dynamic> json) => Subscription(
        id: json['id'] as String,
        name: json['name'] as String,
        url: json['url'] as String,
        usedAt: (json['usedAt'] as num?)?.toInt() ?? 0,
      );
}

/// An entry of a multi-repository subscription. An entry can be such a list itself: once the engine has opened
/// it, it is a [group] and its entries follow it with a larger [depth].
class RepoInfo {
  const RepoInfo({required this.name, required this.url, this.group = false, this.depth = 0, this.parent = ''});

  final String name;
  final String url;
  final bool group;
  final int depth;

  /// The url of the list this entry is in; '' for the subscription's own entries.
  final String parent;

  factory RepoInfo.fromJson(Map<String, dynamic> json) => RepoInfo(
    name: json['name'] as String,
    url: json['url'] as String,
    group: json['group'] as bool? ?? false,
    depth: (json['depth'] as num?)?.toInt() ?? 0,
    parent: json['parent'] as String? ?? '',
  );
}

/// Engine-wide settings (`/api/v1/settings`).
class EngineSettings {
  const EngineSettings({
    this.githubProxy = false, this.githubProxyPrefix = '', this.doh = '', this.streamCache = true, this.streamCacheMaxMB = 2048,
    this.httpProxy = '', this.proxyScopes = const {}, this.supportsProxyScopes = false,
  });

  /// Off: files on GitHub come from GitHub, and a proxy a subscription put in front of them is taken off.
  /// On: they are fetched through [githubProxyPrefix].
  final bool githubProxy;
  final String githubProxyPrefix;
  final String httpProxy;
  final Set<String> proxyScopes;
  final bool supportsProxyScopes;

  /// The url of the DNS-over-HTTPS server names are looked up with; empty (default) for the system's DNS.
  final String doh;
  /// The engine's stream cache: whether HLS is kept on its disk, and how many MB it may take. Not part of [toJson]:
  /// they are changed on their own (`EngineClient.patchSettings`), so saving the others never resets them.
  final bool streamCache;
  final int streamCacheMaxMB;

  factory EngineSettings.fromJson(Map<String, dynamic> json) => EngineSettings(
    githubProxy: json['githubProxy'] as bool? ?? false,
    githubProxyPrefix: json['githubProxyPrefix'] as String? ?? '',
    httpProxy: json['httpProxy'] as String? ?? '',
    proxyScopes: (json['proxyScopes'] as List?)?.whereType<String>().toSet() ?? const {},
    supportsProxyScopes: json.containsKey('proxyScopes'),
    doh: json['doh'] as String? ?? '',
    streamCache: json['streamCache'] as bool? ?? true,
    streamCacheMaxMB: (json['streamCacheMaxMB'] as num?)?.toInt() ?? 2048,
  );

  Map<String, dynamic> toJson() => {'githubProxy': githubProxy, 'githubProxyPrefix': githubProxyPrefix, 'doh': doh};

  /// The settings are saved as a whole: change one through this, so the others go back as they were.
  EngineSettings copyWith({bool? githubProxy, String? githubProxyPrefix, String? doh}) => EngineSettings(
    githubProxy: githubProxy ?? this.githubProxy,
    githubProxyPrefix: githubProxyPrefix ?? this.githubProxyPrefix,
    httpProxy: httpProxy,
    proxyScopes: proxyScopes,
    supportsProxyScopes: supportsProxyScopes,
    doh: doh ?? this.doh,
    streamCache: streamCache,
    streamCacheMaxMB: streamCacheMaxMB,
  );
}

class ConfigSummary {
  const ConfigSummary({
    required this.subscriptionId,
    required this.url,
    this.fetchedUrl = '',
    required this.repos,
    required this.sites,
    required this.parses,
    required this.lives,
    required this.spider,
    required this.wallpaper,
    this.fetchedAt = 0,
    this.stored = false,
    this.refreshing = false,
    this.refreshError = '',
  });

  /// When the config in use was downloaded (epoch milliseconds); 0 when unknown.
  final int fetchedAt;

  /// The engine started from the copy it kept of the last download; the network has not confirmed it (yet).
  final bool stored;

  /// That copy is being checked against the network right now.
  final bool refreshing;

  /// Why the last download failed while the config in use was kept; empty when it did not.
  final String refreshError;

  final String subscriptionId;

  /// The config actually loaded (for a repository, the chosen entry), as the subscription wrote it.
  final String url;

  /// Where it is really fetched from when the GitHub proxy setting changes that; empty or equal to [url] otherwise.
  final String fetchedUrl;
  final List<RepoInfo> repos;
  final int sites;
  final int parses;
  final int lives;
  final String spider;
  final String wallpaper;

  factory ConfigSummary.fromJson(Map<String, dynamic> json) => ConfigSummary(
        subscriptionId: json['subscriptionId'] as String,
        url: json['url'] as String,
        fetchedUrl: json['fetchedUrl'] as String? ?? '',
        repos: [
          for (final r in json['repos'] as List<dynamic>? ?? const [])
            RepoInfo.fromJson(r as Map<String, dynamic>),
        ],
        sites: json['sites'] as int,
        parses: json['parses'] as int,
        lives: json['lives'] as int,
        spider: json['spider'] as String? ?? '',
        wallpaper: json['wallpaper'] as String? ?? '',
        fetchedAt: (json['fetchedAt'] as num?)?.toInt() ?? 0,
        stored: json['stored'] as bool? ?? false,
        refreshing: json['refreshing'] as bool? ?? false,
        refreshError: json['refreshError'] as String? ?? '',
      );
}

/// Sizes of the engine's data cache (`/api/v1/cache`).
class CacheInfo {
  const CacheInfo({this.bytes = 0, this.entries = 0});

  final int bytes;
  final int entries;

  factory CacheInfo.fromJson(Map<String, dynamic> json) =>
      CacheInfo(bytes: (json['bytes'] as num?)?.toInt() ?? 0, entries: (json['entries'] as num?)?.toInt() ?? 0);
}

enum SiteRuntime { cms, js, jar, py, remote, unknown }

class SiteInfo {
  const SiteInfo({
    required this.key,
    required this.name,
    required this.type,
    required this.searchable,
    required this.quickSearch,
    required this.filterable,
    required this.runtime,
    this.changeable = true,
  });

  final String key;
  final String name;
  final int type;
  final bool searchable;
  final bool quickSearch;
  final bool filterable;
  final SiteRuntime runtime;

  /// The config's `changeable`: whether playback may switch to this site, or away from it, on its own when a title
  /// cannot be played where it is. True when the engine does not say (engines before v0.4.1421).
  final bool changeable;

  factory SiteInfo.fromJson(Map<String, dynamic> json) => SiteInfo(
        key: json['key'] as String,
        name: json['name'] as String,
        type: json['type'] as int,
        searchable: json['searchable'] as bool,
        quickSearch: json['quickSearch'] as bool,
        filterable: json['filterable'] as bool,
        changeable: json['changeable'] as bool? ?? true,
        runtime: SiteRuntime.values.firstWhere(
          (r) => r.name == json['runtime'],
          orElse: () => SiteRuntime.unknown,
        ),
      );
}

/// An error reported by the engine (`{"error": {"code", "message"}}`) or a transport failure.
class EngineException implements Exception {
  const EngineException(this.code, this.message, {this.statusCode});

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() => '$code: $message';
}
