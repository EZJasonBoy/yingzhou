import 'dart:convert';

import 'package:cryptography/cryptography.dart';

final _testUpdateKey = Ed25519().newKeyPair();
Future<SimplePublicKey> get testUpdatePublicKey async => (await _testUpdateKey).extractPublicKey();

Future<String> signUpdateFixture(String json) async {
  final payload = utf8.encode(json);
  final signature = await Ed25519().sign(payload, keyPair: await _testUpdateKey);
  return jsonEncode({...jsonDecode(json) as Map<String, dynamic>, 'signed': base64Encode(payload), 'signature': base64Encode(signature.bytes)});
}
