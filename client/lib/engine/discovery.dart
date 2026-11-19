import 'discovery_stub.dart' if (dart.library.io) 'discovery_io.dart' as impl;

/// An engine announced on the LAN (mDNS `_tvbox-engine._tcp`).
class DiscoveredEngine {
  const DiscoveredEngine({required this.name, required this.url, this.protocol = 1});

  final String name;

  /// e.g. `http://192.168.1.5:9978`
  final String url;
  final int protocol;
}

/// Looks for engines on the LAN while started.
abstract class EngineDiscovery {
  /// Starts looking; [onChange] gets the full list each time an engine appears or goes away.
  Future<void> start(void Function(List<DiscoveredEngine> engines) onChange);

  Future<void> stop();
}

/// The mDNS service type engines announce themselves with.
const engineServiceType = '_tvbox-engine._tcp';

/// Null where the platform has no discovery (web).
EngineDiscovery? createEngineDiscovery() => impl.createEngineDiscovery();

/// What this device calls itself when it pairs (the computer's name).
String deviceName() => impl.deviceName();
