import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';

import 'fake_engine.dart';

/// The fake engine plus `/github-proxy`: three presets, and a probe in which GitHub itself and `fast.test` answer,
/// `slow.test` answers late and `dead.test` times out (a fake mirror for each case). What the app saves and asks
/// to probe is kept.
class _ProxyEngine extends http.BaseClient {
  _ProxyEngine({this.presets = true});

  final bool presets;
  final http.Client _inner = fakeEngine(hasConfig: true);
  final _settings = <String, dynamic>{'githubProxy': false, 'githubProxyPrefix': 'https://fast.test/', 'doh': ''};
  final saved = <Map<String, dynamic>>[];
  final probed = <List<String>>[];

  http.StreamedResponse _json(Object body, [int status = 200]) =>
      http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(body))), status, headers: {'content-type': 'application/json; charset=utf-8'});

  static const _list = [
    {'name': 'fast.test', 'prefix': 'https://fast.test/'},
    {'name': 'slow.test', 'prefix': 'https://slow.test/'},
    {'name': 'dead.test', 'prefix': 'https://dead.test/'},
  ];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    switch ((request.method, request.url.path)) {
      case ('GET', '/api/v1/settings'):
        return _json(_settings);
      case ('PUT', '/api/v1/settings'):
        final body = jsonDecode((request as http.Request).body) as Map<String, dynamic>;
        saved.add(body);
        _settings.addAll(body);
        return _json(_settings);
      case ('GET', '/api/v1/github-proxy') when presets:
        return _json({'presets': _list, 'probeUrl': 'https://raw.githubusercontent.com/x/y/abc/.gitattributes'});
      case ('POST', '/api/v1/github-proxy/probe') when presets:
        final asked = [for (final p in (jsonDecode((request as http.Request).body) as Map<String, dynamic>)['prefixes'] as List<dynamic>) '$p'];
        probed.add(asked);
        return _json({
          'url': 'https://raw.githubusercontent.com/x/y/abc/.gitattributes',
          'results': [
            {'prefix': '', 'ok': true, 'ms': 35},
            for (final p in asked)
              switch (p) {
                'https://fast.test/' => {'prefix': p, 'ok': true, 'ms': 120},
                'https://slow.test/' => {'prefix': p, 'ok': true, 'ms': 2400},
                _ => {'prefix': p, 'ok': false, 'ms': 8000, 'error': 'timeout talking to ${Uri.parse(p).host}'},
              },
          ],
        });
    }
    return _inner.send(request);
  }
}

void main() {
  Future<void> openSettings(WidgetTester tester, http.Client engine) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(TvboxApp(state: AppState(clientFactory: (url) => EngineClient(url, httpClient: engine))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
  }

  final choice = find.byKey(const Key('github-proxy-choice'));

  testWidgets('presets to pick from, measured with 测速, and an address of the user\'s own', (tester) async {
    final engine = _ProxyEngine();
    await openSettings(tester, engine);

    // Off by default: no list, nothing measured.
    expect(choice, findsNothing);
    expect(find.byKey(const Key('github-proxy-probe')), findsNothing);
    await tester.tap(find.byKey(const Key('github-proxy-switch')));
    await tester.pumpAndSettle();
    expect(engine.saved.last, containsPair('githubProxy', true));
    expect(engine.saved.last, containsPair('githubProxyPrefix', 'https://fast.test/'));
    expect(tester.widget<DropdownButton<String>>(choice).value, 'https://fast.test/');
    expect(find.text('dead.test').hitTestable(), findsNothing);
    expect(find.byKey(const Key('github-proxy-custom')), findsNothing);
    expect(engine.probed, isEmpty, reason: 'nothing is measured until asked');

    await tester.tap(find.byKey(const Key('github-proxy-probe')));
    await tester.pumpAndSettle();
    expect(engine.probed.single, ['https://fast.test/', 'https://slow.test/', 'https://dead.test/']);
    expect(find.text('直连 GitHub：35 ms'), findsOneWidget);
    await tester.tap(choice);
    await tester.pumpAndSettle();
    expect(find.text('fast.test · 120 ms').hitTestable(), findsOneWidget);
    expect(find.text('dead.test · 超时').hitTestable(), findsOneWidget);

    // Another preset.
    await tester.tap(find.text('slow.test · 2400 ms').last);
    await tester.pumpAndSettle();
    expect(engine.saved.last, containsPair('githubProxyPrefix', 'https://slow.test/'));
    expect(tester.widget<DropdownButton<String>>(choice).value, 'https://slow.test/');

    // One of the user's own: 自定义 is picked, and the next 测速 measures it too.
    await tester.tap(choice);
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义地址…').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('github-proxy-custom')), 'https://mine.test/');
    await tester.tap(find.byKey(const Key('github-proxy-apply')));
    await tester.pumpAndSettle();
    expect(engine.saved.last, containsPair('githubProxyPrefix', 'https://mine.test/'));
    expect(tester.widget<DropdownButton<String>>(choice).value, '');
    await tester.tap(find.byKey(const Key('github-proxy-probe')));
    await tester.pumpAndSettle();
    expect(engine.probed.last, contains('https://mine.test/'));
    expect(find.text('自定义地址 · 超时').hitTestable(), findsOneWidget);
  });

  testWidgets('an engine from before presets: the switch and the address field, as before', (tester) async {
    final engine = _ProxyEngine(presets: false);
    await openSettings(tester, engine);
    await tester.tap(find.byKey(const Key('github-proxy-switch')));
    await tester.pumpAndSettle();
    expect(choice, findsNothing);
    expect(tester.widget<TextField>(find.widgetWithText(TextField, '代理地址')).controller!.text, 'https://fast.test/');
    expect(find.byKey(const Key('github-proxy-probe')), findsNothing, reason: 'it cannot measure either');
    await tester.enterText(find.widgetWithText(TextField, '代理地址'), 'https://mine.test/');
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(engine.saved.last, containsPair('githubProxyPrefix', 'https://mine.test/'));
  });
}
