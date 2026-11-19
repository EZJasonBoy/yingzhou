import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';

import 'fake_engine.dart';

/// The fake engine with the settings and `/api/v1/network` of an engine that knows `hosts` / `headers` / `doh`:
/// two built-in DoH servers and one the config offers. Every settings object the app saves is kept in [saved].
class _NetworkEngine extends http.BaseClient {
  _NetworkEngine({String doh = '', this.dohStatus = '', this.rules = false}) {
    _settings['doh'] = doh;
  }

  final String dohStatus;

  /// Whether the active config has hosts, headers and ads.
  final bool rules;
  final http.Client _inner = fakeEngine(hasConfig: true);
  final _settings = <String, dynamic>{'githubProxy': false, 'githubProxyPrefix': 'https://ghfast.top/', 'doh': ''};
  final saved = <Map<String, dynamic>>[];

  http.StreamedResponse _json(Object body) =>
      http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(body))), 200, headers: {'content-type': 'application/json; charset=utf-8'});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    switch ((request.method, request.url.path)) {
      case ('GET', '/api/v1/settings'):
        return _json(_settings);
      case ('PUT', '/api/v1/settings'):
        final body = jsonDecode((request as http.Request).body) as Map<String, dynamic>;
        saved.add(body);
        _settings
          ..clear()
          ..addAll(body);
        return _json(_settings);
      case ('GET', '/api/v1/network'):
        return _json({
          'doh': _settings['doh'],
          'dohStatus': dohStatus,
          'dohOptions': [
            {'name': '腾讯', 'url': 'https://doh.pub/dns-query', 'ips': <String>[], 'source': 'builtin'},
            {'name': '阿里', 'url': 'https://dns.alidns.com/dns-query', 'ips': <String>[], 'source': 'builtin'},
            {
              'name': '演示',
              'url': 'https://doh.config.test/dns-query',
              'ips': ['192.0.2.1'],
              'source': 'config',
            },
          ],
          'hosts': rules ? {'a.test': '192.0.2.7', 'cache.*.cdn.test': 'edge.cdn.test'} : <String, String>{},
          'headerHosts': rules ? ['media.test'] : <String>[],
          'ads': rules ? ['ads.test'] : <String>[],
        });
    }
    return _inner.send(request);
  }
}

void main() {
  Future<void> openSources(WidgetTester tester, http.Client engine) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(TvboxApp(state: AppState(clientFactory: (url) => EngineClient(url, httpClient: engine))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('源'));
    await tester.pumpAndSettle();
  }

  String chosen(WidgetTester tester) => tester.widget<DropdownButton<String>>(find.byKey(const Key('doh-choice'))).value!;

  testWidgets('DoH is off until the user picks a server, and the other settings stay as they were', (tester) async {
    final engine = _NetworkEngine();
    await openSources(tester, engine);

    expect(chosen(tester), '', reason: 'off by default');
    expect(find.textContaining('已关闭：用系统的 DNS 查域名'), findsOneWidget);
    expect(find.byKey(const Key('config-network-rules')), findsNothing, reason: 'this config brings no rules');

    await tester.tap(find.byKey(const Key('doh-choice')));
    await tester.pumpAndSettle();
    expect(find.text('腾讯（doh.pub）'), findsOneWidget);
    expect(find.text('演示（doh.config.test，订阅提供）'), findsOneWidget, reason: 'what the active config offers is listed, not switched on');
    await tester.tap(find.text('阿里（dns.alidns.com）'));
    await tester.pumpAndSettle();

    expect(engine.saved.single, {'githubProxy': false, 'githubProxyPrefix': 'https://ghfast.top/', 'doh': 'https://dns.alidns.com/dns-query'});
    expect(chosen(tester), 'https://dns.alidns.com/dns-query');
    expect(find.textContaining('交给所选的服务商查'), findsOneWidget);

    // Another setting changes: the DNS choice goes back to the engine unchanged.
    await tester.tap(find.byKey(const Key('github-proxy-switch')));
    await tester.pumpAndSettle();
    expect(engine.saved.last, {'githubProxy': true, 'githubProxyPrefix': 'https://ghfast.top/', 'doh': 'https://dns.alidns.com/dns-query'});
    expect(chosen(tester), 'https://dns.alidns.com/dns-query');

    // And off again.
    await tester.tap(find.byKey(const Key('doh-choice')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭（系统 DNS）').last);
    await tester.pumpAndSettle();
    expect(engine.saved.last['doh'], '');
    expect(engine.saved.last['githubProxy'], true);
  });

  testWidgets('a server that does not answer is reported, and the config\'s network rules can be looked at', (tester) async {
    final engine = _NetworkEngine(doh: 'https://resolver.elsewhere.test/dns-query', dohStatus: 'failed: timeout', rules: true);
    await openSources(tester, engine);

    expect(chosen(tester), 'https://resolver.elsewhere.test/dns-query', reason: 'a choice the engine no longer lists is still shown');
    expect(find.text('所选的服务商刚才没有应答（timeout），这段时间用的是系统的 DNS'), findsOneWidget);

    expect(find.text('当前订阅自带的网络规则：2 条域名重定向 · 1 条请求头 · 1 个嗅探屏蔽域名'), findsOneWidget);
    expect(find.text('a.test → 192.0.2.7'), findsNothing);
    await tester.tap(find.text('查看'));
    await tester.pumpAndSettle();
    expect(find.text('a.test → 192.0.2.7'), findsOneWidget);
    expect(find.text('cache.*.cdn.test → edge.cdn.test'), findsOneWidget);
    expect(find.text('media.test'), findsOneWidget);
    expect(find.text('ads.test'), findsOneWidget);
  });

  testWidgets('an engine without the network endpoint shows nothing extra', (tester) async {
    await openSources(tester, fakeEngine(hasConfig: true));
    expect(find.byKey(const Key('github-proxy-switch')), findsOneWidget);
    expect(find.byKey(const Key('doh-choice')), findsNothing);
  });
}
