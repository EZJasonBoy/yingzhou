// LAN sharing and pairing (docs/protocol.md, "鉴权" and "局域网共享").

import 'engine_client.dart';

/// A device paired with the engine.
class LanDevice {
  const LanDevice({required this.id, required this.name, this.createdAt = 0, this.lastSeenAt = 0, this.lastAddress = ''});

  final String id;
  final String name;
  final int createdAt;
  final int lastSeenAt;
  final String lastAddress;

  factory LanDevice.fromJson(Map<String, dynamic> j) => LanDevice(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
    lastSeenAt: (j['lastSeenAt'] as num?)?.toInt() ?? 0,
    lastAddress: j['lastAddress'] as String? ?? '',
  );
}

/// `GET /api/v1/lan`: only the engine on this machine answers it.
class LanStatus {
  const LanStatus({
    required this.supported,
    required this.enabled,
    this.forced = false,
    this.listening = false,
    this.name = '',
    this.port = 0,
    this.addresses = const [],
    this.discoverable = false,
    this.error = '',
    this.code = '',
    this.codeExpiresAt = 0,
    this.lockedUntil = 0,
    this.devices = const [],
  });

  final bool supported;
  final bool enabled;
  final bool forced;
  final bool listening;
  final String name;
  final int port;
  final List<String> addresses;
  final bool discoverable;
  final String error;
  final String code;
  final int codeExpiresAt;
  final int lockedUntil;
  final List<LanDevice> devices;

  factory LanStatus.fromJson(Map<String, dynamic> j) => LanStatus(
    supported: j['supported'] as bool? ?? false,
    enabled: j['enabled'] as bool? ?? false,
    forced: j['forced'] as bool? ?? false,
    listening: j['listening'] as bool? ?? false,
    name: j['name'] as String? ?? '',
    port: (j['port'] as num?)?.toInt() ?? 0,
    addresses: [for (final a in j['addresses'] as List? ?? const []) a as String],
    discoverable: j['discoverable'] as bool? ?? false,
    error: j['error'] as String? ?? '',
    code: j['code'] as String? ?? '',
    codeExpiresAt: (j['codeExpiresAt'] as num?)?.toInt() ?? 0,
    lockedUntil: (j['lockedUntil'] as num?)?.toInt() ?? 0,
    devices: [for (final d in j['devices'] as List? ?? const []) LanDevice.fromJson(d as Map<String, dynamic>)],
  );
}

extension LanApi on EngineClient {
  Future<LanStatus> lanStatus() async => LanStatus.fromJson(await send('GET', 'lan') as Map<String, dynamic>);

  Future<LanStatus> setLanSharing(bool enabled) async => LanStatus.fromJson(await send('PUT', 'lan', body: {'enabled': enabled}) as Map<String, dynamic>);

  Future<LanStatus> newPairingCode() async => LanStatus.fromJson(await send('POST', 'lan/code') as Map<String, dynamic>);

  Future<void> revokeDevice(String id) => send('DELETE', 'lan/devices/${Uri.encodeComponent(id)}');

  /// Trades the code the engine shows for a token. An empty [code] only asks the engine to show one
  /// (it answers `PAIR_CODE_REQUIRED`).
  Future<String> pair(String code, String name) async {
    final res = await send('POST', 'pair', body: {'code': code, 'name': name}) as Map<String, dynamic>;
    return res['token'] as String;
  }
}
