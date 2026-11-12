import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/engine/models.dart';
import 'package:tvbox_client/engine/vod_models.dart';

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
      client.config(),
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

  test('home, detail and streamed search', () async {
    final client = EngineClient(base, httpClient: fakeEngine(hasConfig: true));
    final home = await client.home('cms');
    expect(home.classes.single.name, '电影');
    expect(home.filters['1']!.single.values.length, 2);

    final detail = await client.detail('cms', '7');
    expect(detail.lines.single.episodes.map((e) => e.name), ['第1集', '第2集']);

    final events = await client.searchAll('推荐').toList();
    expect(events.whereType<SearchResults>().single.items.single.name, '推荐片');
    expect(events.last, isA<SearchEnd>());
  });

  test('unreachable engine is reported as UNREACHABLE', () async {
    final client = EngineClient(base, httpClient: MockClient((_) => throw http.ClientException('refused')));
    await expectLater(client.info(), throwsA(isA<EngineException>().having((e) => e.code, 'code', 'UNREACHABLE')));
  });
}
