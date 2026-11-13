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
  const Subscription({required this.id, required this.name, required this.url});

  final String id;
  final String name;
  final String url;

  factory Subscription.fromJson(Map<String, dynamic> json) => Subscription(
        id: json['id'] as String,
        name: json['name'] as String,
        url: json['url'] as String,
      );
}

/// An entry of a multi-repository subscription. An entry can be such a list itself: once the engine has opened
/// it, it is a [group] and its entries follow it with a larger [depth].
class RepoInfo {
  const RepoInfo({required this.name, required this.url, this.group = false, this.depth = 0});

  final String name;
  final String url;
  final bool group;
  final int depth;

  factory RepoInfo.fromJson(Map<String, dynamic> json) => RepoInfo(
    name: json['name'] as String,
    url: json['url'] as String,
    group: json['group'] as bool? ?? false,
    depth: (json['depth'] as num?)?.toInt() ?? 0,
  );
}

class ConfigSummary {
  const ConfigSummary({
    required this.subscriptionId,
    required this.url,
    required this.repos,
    required this.sites,
    required this.parses,
    required this.lives,
    required this.spider,
    required this.wallpaper,
  });

  final String subscriptionId;

  /// The config actually loaded (for a repository, the chosen entry).
  final String url;
  final List<RepoInfo> repos;
  final int sites;
  final int parses;
  final int lives;
  final String spider;
  final String wallpaper;

  factory ConfigSummary.fromJson(Map<String, dynamic> json) => ConfigSummary(
        subscriptionId: json['subscriptionId'] as String,
        url: json['url'] as String,
        repos: [
          for (final r in json['repos'] as List<dynamic>? ?? const [])
            RepoInfo.fromJson(r as Map<String, dynamic>),
        ],
        sites: json['sites'] as int,
        parses: json['parses'] as int,
        lives: json['lives'] as int,
        spider: json['spider'] as String? ?? '',
        wallpaper: json['wallpaper'] as String? ?? '',
      );
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
  });

  final String key;
  final String name;
  final int type;
  final bool searchable;
  final bool quickSearch;
  final bool filterable;
  final SiteRuntime runtime;

  factory SiteInfo.fromJson(Map<String, dynamic> json) => SiteInfo(
        key: json['key'] as String,
        name: json['name'] as String,
        type: json['type'] as int,
        searchable: json['searchable'] as bool,
        quickSearch: json['quickSearch'] as bool,
        filterable: json['filterable'] as bool,
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
