import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';

import 'discovery.dart';

EngineDiscovery? createEngineDiscovery() => _BonsoirDiscovery();

String deviceName() {
  final host = Platform.localHostname;
  final os = Platform.isWindows
      ? 'Windows'
      : Platform.isMacOS
      ? 'Mac'
      : Platform.isAndroid
      ? 'Android'
      : Platform.isIOS
      ? 'iOS'
      : 'Linux';
  return host.isEmpty ? '映舟 · $os' : '$host（$os）';
}

/// mDNS through the operating system's own service (Bonjour on macOS, DNS-SD on Windows, NSD on Android) via
/// the bonsoir plugin.
class _BonsoirDiscovery implements EngineDiscovery {
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _sub;
  final _found = <String, DiscoveredEngine>{};

  @override
  Future<void> start(void Function(List<DiscoveredEngine> engines) onChange) async {
    await stop();
    final discovery = BonsoirDiscovery(type: engineServiceType, printLogs: false);
    _discovery = discovery;
    await discovery.initialize();
    _sub = discovery.eventStream?.listen((event) {
      final service = event.service;
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent():
          if (service != null) unawaited(service.resolve(discovery.serviceResolver).catchError((Object _) {}));
        case BonsoirDiscoveryServiceResolvedEvent() || BonsoirDiscoveryServiceUpdatedEvent():
          if (service == null) return;
          final engine = _engine(service);
          if (engine == null) return;
          _found[service.name] = engine;
          onChange(_found.values.toList());
        case BonsoirDiscoveryServiceLostEvent():
          if (service != null && _found.remove(service.name) != null) onChange(_found.values.toList());
        default:
          break;
      }
    });
    await discovery.start();
  }

  /// An IPv4 address first: link-local IPv6 addresses need a zone the URL cannot carry everywhere.
  DiscoveredEngine? _engine(BonsoirService service) {
    final addresses = service.hostAddresses;
    final v4 = addresses.where((a) => !a.contains(':')).toList();
    final host = v4.isNotEmpty ? v4.first : (addresses.isNotEmpty ? '[${addresses.first}]' : service.hostname);
    if (host == null || host.isEmpty) return null;
    final name = service.attributes['name']?.trim();
    return DiscoveredEngine(
      name: name == null || name.isEmpty ? service.name : name,
      url: 'http://$host:${service.port}',
      protocol: int.tryParse(service.attributes['protocol'] ?? '') ?? 1,
    );
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    final d = _discovery;
    _discovery = null;
    _found.clear();
    if (d != null && !d.isStopped) {
      try {
        await d.stop();
      } catch (_) {
        // Already stopped by the platform.
      }
    }
  }
}
