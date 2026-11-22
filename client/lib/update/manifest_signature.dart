import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';

import 'release_info.dart';

Future<SimplePublicKey> _bundledKey() async {
  final hex = (await rootBundle.loadString('assets/update-ed25519.hex')).trim();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) throw StateError('Invalid bundled update key');
  return SimplePublicKey([
    for (var index = 0; index < hex.length; index += 2) int.parse(hex.substring(index, index + 2), radix: 16),
  ], type: KeyPairType.ed25519);
}

class UpdateIntegrityException implements Exception {
  const UpdateIntegrityException(this.message);
  final String message;
}

Future<ReleaseInfo> verifyUpdateManifest(String text, {SimplePublicKey? verificationKey}) async {
  final envelope = jsonDecode(text);
  if (envelope is! Map<String, dynamic> || envelope['version'] == null) throw const FormatException('invalid manifest');
  if (envelope['signed'] is! String || envelope['signature'] is! String) throw const UpdateIntegrityException('更新清单缺少发布签名');
  final payload = base64Decode(envelope['signed'] as String);
  final signature = base64Decode(envelope['signature'] as String);
  final key = verificationKey ?? await _bundledKey();
  if (signature.length != 64 || !await Ed25519().verify(payload, signature: Signature(signature, publicKey: key))) {
    throw const UpdateIntegrityException('更新清单的发布签名无效');
  }
  final release = ReleaseInfo.fromJson(jsonDecode(utf8.decode(payload)));
  if (release.assets.values.any((asset) => !RegExp(r'^[0-9a-f]{64}$').hasMatch(asset.sha256))) {
    throw const UpdateIntegrityException('更新清单缺少安装包的 SHA-256 摘要');
  }
  return release;
}
