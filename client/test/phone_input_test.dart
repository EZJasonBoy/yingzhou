import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/ui/phone_input.dart';
import 'package:tvbox_client/ui/phone_input_server.dart';

/// The base class makes real clients; flutter_test's global override answers every request with 400.
class _RealHttp extends HttpOverrides {}

/// A request the way a phone's browser makes it.
Future<(int, String, HttpHeaders)> send(Uri url, {String method = 'GET', String? body, String type = 'application/x-www-form-urlencoded'}) async {
  final client = HttpOverrides.runWithHttpOverrides(HttpClient.new, _RealHttp());
  try {
    final req = await client.openUrl(method, url);
    if (body != null) {
      req.headers.contentType = ContentType.parse(type);
      req.add(utf8.encode(body));
    }
    final res = await req.close();
    return (res.statusCode, await utf8.decodeStream(res), res.headers);
  } finally {
    client.close(force: true);
  }
}

void main() {
  const request = PhoneInputRequest(title: '订阅地址', hint: 'http(s)://…', keyboard: PhoneKeyboard.url);

  test('serves the form on its own address only, takes one text, then stops answering', () async {
    final server = await PhoneInputServer.start(request, address: InternetAddress.loopbackIPv4);
    final url = server.urlFor('127.0.0.1');

    final (status, page, headers) = await send(url);
    expect(status, 200);
    expect(page, contains('<form method="post" action="/${server.token}"'));
    expect(page, contains('订阅地址'));
    expect(page, contains('inputmode="url"'));
    expect(page, isNot(contains('<script')), reason: 'no script on the page');
    expect(headers.value('content-security-policy'), contains("default-src 'none'"));
    expect(headers.value('cache-control'), 'no-store');

    expect((await send(url.replace(path: '/'))).$1, 404);
    expect((await send(url.replace(path: '/${server.token}x'))).$1, 404);
    expect((await send(url.replace(path: '/wrongtoken12'), method: 'POST', body: 'text=x')).$1, 404);
    expect((await send(url, method: 'POST', body: 'text=+')).$1, 400, reason: 'blank');
    expect((await send(url, method: 'POST', body: 'text=${'a' * PhoneInputServer.maxBytes}')).$1, 413);
    expect(server.finished, isFalse, reason: 'bad tries do not use it up');

    final sent = await send(url, method: 'POST', body: 'text=${Uri.encodeQueryComponent('  http://example.test/tv.json;pk;密钥 ')}');
    expect(sent.$1, 200);
    expect(sent.$2, contains('已发送'));
    expect(await server.result, 'http://example.test/tv.json;pk;密钥', reason: 'trimmed, Chinese intact');

    try {
      expect((await send(url)).$1, 404);
    } on IOException {
      // Already closed: fine too.
    }
  });

  test('takes JSON too', () async {
    final server = await PhoneInputServer.start(const PhoneInputRequest(title: '搜索词', keyboard: PhoneKeyboard.search), address: InternetAddress.loopbackIPv4);
    final page = await send(server.urlFor('127.0.0.1'));
    expect(page.$2, contains('inputmode="search"'));
    await send(server.urlFor('127.0.0.1'), method: 'POST', body: jsonEncode({'text': '流浪地球'}), type: 'application/json');
    expect(await server.result, '流浪地球');
  });

  test('closes unused after its time, and when closed', () async {
    final expiring = await PhoneInputServer.start(request, ttl: const Duration(milliseconds: 100), address: InternetAddress.loopbackIPv4);
    expect(await expiring.result, isNull);
    final closed = await PhoneInputServer.start(request, address: InternetAddress.loopbackIPv4);
    await closed.close();
    expect(await closed.result, isNull);
    await expectLater(send(closed.urlFor('127.0.0.1')), throwsA(isA<IOException>()));
  });

  test('tokens are random, short enough to type and without look-alike characters', () {
    final tokens = {for (var i = 0; i < 50; i++) PhoneInputServer.newToken()};
    expect(tokens, hasLength(50));
    for (final t in tokens) {
      expect(t, matches(RegExp(r'^[a-hj-km-np-z2-9]{12}$')));
    }
  });

  test('home network addresses come first; loopback and link-local are left out', () {
    expect(PhoneInputServer.rankAddress([192, 168, 1, 5]), 0);
    expect(PhoneInputServer.rankAddress([10, 0, 0, 2]), 1);
    expect(PhoneInputServer.rankAddress([172, 20, 1, 1]), 2);
    expect(PhoneInputServer.rankAddress([172, 32, 1, 1]), 3);
    expect(PhoneInputServer.rankAddress([100, 100, 1, 1]), 5, reason: 'Tailscale / carrier NAT');
    expect(PhoneInputServer.rankAddress([169, 254, 3, 4]), isNull);
    expect(PhoneInputServer.rankAddress([127, 0, 0, 1]), isNull);
  });

  testWidgets('the dialog shows the QR code, can switch address, and hands back what the phone sent', (tester) async {
    final server = (await tester.runAsync(() => PhoneInputServer.start(request, address: InternetAddress.loopbackIPv4)))!;
    String? got = 'not yet';
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  got = await showDialog<String>(
                    context: context,
                    builder: (_) => PhoneInputDialog(
                      request: request,
                      findAddresses: () async => ['127.0.0.1', '192.168.9.9'],
                      startServer: (_) async => server,
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump();
    expect(find.text('用手机输入订阅地址'), findsOneWidget);
    expect(find.byKey(const Key('phone-input-qr')), findsOneWidget);
    String shown() => tester.widget<SelectableText>(find.byKey(const Key('phone-input-url'))).data!;
    expect(shown(), 'http://127.0.0.1:${server.port}/${server.token}');
    expect(find.textContaining('后失效，只能用一次'), findsOneWidget);

    await tester.tap(find.text('192.168.9.9'));
    await tester.pump();
    expect(shown(), startsWith('http://192.168.9.9:'));

    // The server answers and finishes on the real event loop; the dialog hears of it on the next frame.
    await tester.runAsync(() async {
      await send(server.urlFor('127.0.0.1'), method: 'POST', body: 'text=hello');
      await server.result;
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(got, 'hello');
    expect(find.text('用手机输入订阅地址'), findsNothing, reason: 'closed by itself');
  });

  testWidgets('without a network the dialog says so', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PhoneInputDialog(request: request, findAddresses: () async => const [])),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('phone-input-error')), findsOneWidget);
    expect(find.textContaining('没有连上局域网'), findsOneWidget);
  });
}
