import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_client/diagnostics/redact.dart';

void main() {
  final r = Redactor(homes: [r'C:\Users\Alice', '/home/alice'], secrets: ['https://sub.example.com/private/tv.json']);

  void expectGone(String out, List<String> secrets) {
    for (final s in secrets) {
      expect(out, isNot(contains(s)), reason: '"$s" is still in: $out');
    }
  }

  group('addresses', () {
    test('an address on the internet keeps only its scheme and host', () {
      final out = r.apply('failed: https://cdn.example.com/live/abc.m3u8?token=s3cr3t&e=1700000000 (HTTP 403)');
      expect(out, 'failed: https://cdn.example.com/… (HTTP 403)');
    });

    test('subscription addresses the app knows go entirely, also percent-encoded', () {
      final out = r.apply('loaded https://sub.example.com/private/tv.json: 40 sites; '
          'GET http://127.0.0.1:9978/api/v1/config?url=https%3A%2F%2Fsub.example.com%2Fprivate%2Ftv.json');
      expect(out, contains('loaded <订阅地址>: 40 sites'));
      expect(out, contains('http://127.0.0.1:9978/api/v1/config?url=<订阅地址>'));
      expectGone(out, ['sub.example.com', 'private']);
    });

    test('the ;pk; key of a subscription is masked even when the address is not known', () {
      final out = r.apply('导入 clan://localhost/tv/a.json;pk;abcdef123 失败，再试 http://other.example.org/x.json;pk;Zm9vYmFy');
      expectGone(out, ['abcdef123', 'Zm9vYmFy', 'localhost/tv']);
      expect(out, contains('clan://…'));
      expect(out, contains('http://other.example.org/…'));
    });

    test('user and password in an address go', () {
      final out = r.apply('webdav: http://bob:hunter2@nas.example.net:5005/dav/movies failed');
      expect(out, 'webdav: http://***@nas.example.net:5005/… failed');
    });

    test('local and LAN addresses keep their path, the tvsig and token parameters are masked', () {
      final out = r.apply('play http://127.0.0.1:9978/hls/k1/index.m3u8?tvsig=l2x9k0.local.AbC_dEf-123456&t=1 and '
          'http://192.168.1.20:9978/proxy?siteKey=csp_A&url=https%3A%2F%2Fvideo.example.com%2Fa.mp4%3Fsign%3Dxyz&token=dev1.aaaa');
      expect(out, contains('http://127.0.0.1:9978/hls/k1/index.m3u8?tvsig=***&t=1'));
      expect(out, contains('http://192.168.1.20:9978/proxy?siteKey=csp_A&url=https://video.example.com/…&token=***'));
      expectGone(out, ['AbC_dEf', 'xyz', 'dev1.aaaa', 'a.mp4']);
    });

    test('an address at the end of a sentence keeps the full stop outside', () {
      expect(r.apply('see https://example.com/path/to/x.'), 'see https://example.com/….');
      expect(r.apply('host only https://example.com/'), 'host only https://example.com/');
    });
  });

  group('tokens', () {
    test('Bearer tokens, JSON and key=value secrets, and bare engine tokens', () {
      // `<device id>.<base64url of 32 random bytes>`, as the engine hands out (43 characters after the dot).
      const token = 'd7f3a9c2.Q2hhbmdlTWVQbGVhc2VUaGlzSXNOb3RBUmVhbFRva2V';
      final out = r.apply('Authorization: Bearer $token\n'
          '{"token":"$token","hasToken":true,"password": "hunter2","name":"客厅"}\n'
          'password=hunter2&user=bob\n'
          'paired with $token');
      expectGone(out, [token, 'hunter2', 'Q2hhbmdl']);
      expect(out, contains('"hasToken":true'));
      expect(out, contains('"name":"客厅"'));
      expect(out, contains('user=bob'));
    });

    test('words that only contain a key name are left alone', () {
      const text = 'tokens: 5, mytoken=1, has_password: false, passwordless login';
      expect(r.apply(text), text);
    });
  });

  group('home folders', () {
    test('the known home folder becomes ~, with either slash and JSON escapes', () {
      final out = r.apply(r'data in C:\Users\Alice\.tvbox-next\engine; c:/users/alice/AppData; {"dir":"C:\\Users\\Alice\\Videos"}');
      expect(out, r'data in ~\.tvbox-next\engine; ~/AppData; {"dir":"~\\Videos"}');
    });

    test('other users folders lose the name', () {
      final out = Redactor().apply(r'at C:\Users\Bob\app\lib\x.dart and /home/carol/.cache and /Users/dave/Library, but C:\Users\Public stays');
      expect(out, r'at C:\Users\<用户>\app\lib\x.dart and /home/<用户>/.cache and /Users/<用户>/Library, but C:\Users\Public stays');
    });

    test('a file address keeps its path, without the home folder', () {
      expect(r.apply('file:///C:/Users/Alice/Videos/a.mkv'), 'file:///~/Videos/a.mkv');
    });
  });

  test('running it again changes nothing', () {
    const text = r'''
https://cdn.example.com/a?token=1 http://127.0.0.1:9978/m3u8?url=https%3A%2F%2Fx.y%2Fz&tvsig=abc
Authorization: Bearer abcdefghijk  "password":"p"  C:\Users\Alice\x  /home/bob/y  https://sub.example.com/private/tv.json;pk;k
''';
    final once = r.apply(text);
    expect(r.apply(once), once);
  });

  test('local hosts', () {
    for (final h in ['127.0.0.1', 'localhost', '::1', '10.0.0.2', '192.168.31.5', '172.20.1.1', '169.254.3.4', 'nas.local', 'box.lan']) {
      expect(Redactor.isLocalHost(h), isTrue, reason: h);
    }
    for (final h in ['8.8.8.8', '172.32.0.1', 'example.com', 'github.com', '192.169.0.1']) {
      expect(Redactor.isLocalHost(h), isFalse, reason: h);
    }
  });
}
