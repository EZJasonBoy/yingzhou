// What the active config and the DNS setting do to the engine's requests (`/api/v1/network`).

/// A DNS-over-HTTPS server the user can choose; `EngineSettings.doh` holds the [url] of the chosen one.
class DohOption {
  const DohOption({required this.name, required this.url, this.ips = const [], this.source = 'builtin'});

  final String name;
  final String url;
  final List<String> ips;

  /// `builtin`: offered by the engine; `config`: listed by the active config; `saved`: chosen earlier, no longer offered.
  final String source;

  factory DohOption.fromJson(Map<String, dynamic> json) => DohOption(
    name: json['name'] as String? ?? '',
    url: json['url'] as String? ?? '',
    ips: [for (final ip in json['ips'] as List<dynamic>? ?? const []) '$ip'],
    source: json['source'] as String? ?? 'builtin',
  );
}

class NetworkInfo {
  const NetworkInfo({
    this.doh = '',
    this.dohOptions = const [],
    this.dohStatus = '',
    this.hosts = const {},
    this.headerHosts = const [],
    this.ads = const [],
  });

  /// The chosen DoH server's url; empty when the system's DNS is used.
  final String doh;
  final List<DohOption> dohOptions;

  /// Empty until a name was looked up through the chosen server; then `ok` or `failed: <reason>`.
  final String dohStatus;

  /// The active config's `hosts`: name -> the name or address it is resolved as.
  final Map<String, String> hosts;

  /// The hosts the active config's `headers` add request headers for.
  final List<String> headerHosts;

  /// The active config's `ads`: hosts blocked while sniffing.
  final List<String> ads;

  factory NetworkInfo.fromJson(Map<String, dynamic> json) => NetworkInfo(
    doh: json['doh'] as String? ?? '',
    dohOptions: [for (final o in json['dohOptions'] as List<dynamic>? ?? const []) DohOption.fromJson(o as Map<String, dynamic>)],
    dohStatus: json['dohStatus'] as String? ?? '',
    hosts: (json['hosts'] as Map<String, dynamic>? ?? const {}).map((k, v) => MapEntry(k, '$v')),
    headerHosts: [for (final h in json['headerHosts'] as List<dynamic>? ?? const []) '$h'],
    ads: [for (final a in json['ads'] as List<dynamic>? ?? const []) '$a'],
  );
}
