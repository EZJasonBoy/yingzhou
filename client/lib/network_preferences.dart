import 'dart:convert';

import 'engine/models.dart';
import 'settings.dart';

class ClientNetworkPreferences {
  ClientNetworkPreferences(this._store, this._engineUrl);

  final SettingsStore _store;
  final String Function() _engineUrl;

  String get _profile {
    final url = Uri.tryParse(_engineUrl());
    return url != null && (url.scheme == 'http' || url.scheme == 'https') && url.host.isNotEmpty ? url.origin : _engineUrl();
  }

  Map<String, dynamic> _read(String key) {
    final text = _store.getString(key);
    if (text == null || text.isEmpty) return const {};
    try {
      final data = jsonDecode(text);
      if (data is Map<String, dynamic>) return data;
    } on FormatException {
      return const {};
    }
    return const {};
  }

  String get _githubKey => 'network.github|$_profile';
  String get _httpKey => 'network.http|$_profile';

  EngineSettings get githubSettings {
    final data = _read(_githubKey);
    return EngineSettings(githubProxy: data['enabled'] == true, githubProxyPrefix: data['prefix'] as String? ?? 'https://ghfast.top/');
  }

  String get updateMirror {
    final saved = githubSettings;
    return saved.githubProxy ? saved.githubProxyPrefix : '';
  }

  bool get githubPending => _read(_githubKey)['pending'] == true;

  Future<void> rememberGithub(EngineSettings settings, {bool pending = false}) =>
      _store.setString(_githubKey, jsonEncode({'enabled': settings.githubProxy, 'prefix': settings.githubProxyPrefix, 'pending': pending}));

  ({String address, bool updates}) get http {
    final data = _read(_httpKey);
    return (address: data['address'] as String? ?? '', updates: data['updates'] == true);
  }

  String get updateProxy {
    final saved = http;
    return saved.updates ? saved.address : '';
  }

  Future<void> saveHttp(String address, {required bool updates}) => _store.setString(_httpKey, jsonEncode({'address': address, 'updates': updates}));

  Future<void> migrateUpdateProxy() async {
    final old = _store.getString('update.proxy') ?? '';
    if (old.isEmpty) return;
    if (_store.getString(_httpKey) == null) {
      final address = normalizeProxy(old);
      if (address != null) await saveHttp(address, updates: address.isNotEmpty);
    }
    await _store.setString('update.proxy', '');
  }
}

String? normalizeProxy(String text) {
  final input = text.trim();
  if (input.isEmpty) return '';
  final address = input.replaceFirst(RegExp(r'^http://', caseSensitive: false), '').replaceFirst(RegExp(r'/$'), '');
  final match = RegExp(r'^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+):(\d{1,5})$').firstMatch(address);
  if (match == null) return null;
  final uri = Uri.tryParse('http://$address');
  final port = int.parse(match.group(2)!);
  return uri != null && uri.host.isNotEmpty && port > 0 && port < 65536 ? address : null;
}
