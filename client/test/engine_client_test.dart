import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/engine/models.dart';

import 'fake_engine.dart';

void main() {
  final base = Uri.parse('http://127.0.0.1:9978');

  test('parses engine info', () async {
    final info = await EngineClient(base, httpClient: fakeEngine()).info();
    expect(info.name, 'tvbox-engine');
    expect(info.protocol, 1);
    expect(info.capabilities['jar'], isFalse);
  });

  test('maps engine error bodies to EngineException', () async {
    final client = EngineClient(base, httpClient: fakeEngine());
    await expectLater(
      client.sites(),
      throwsA(isA<EngineException>().having((e) => e.code, 'code', 'NO_CONFIG').having((e) => e.statusCode, 'status', 409)),
    );
  });

  test('subscribe, activate, list sites with utf-8 names', () async {
    final client = EngineClient(base, httpClient: fakeEngine());
    final sub = await client.addSubscription('http://example.test/tv.json');
    final summary = await client.activate(sub.id);
    expect(summary.sites, 2);
    final sites = await client.sites();
    expect(sites.map((s) => s.name), ['采集站', '脚本站']);
    expect(sites.map((s) => s.runtime), [SiteRuntime.cms, SiteRuntime.js]);
  });

  test('unreachable engine is reported as UNREACHABLE', () async {
    final client = EngineClient(base, httpClient: MockClient((_) => throw http.ClientException('refused')));
    await expectLater(client.info(), throwsA(isA<EngineException>().having((e) => e.code, 'code', 'UNREACHABLE')));
  });
}
