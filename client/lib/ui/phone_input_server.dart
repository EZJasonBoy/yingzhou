import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Which keyboard the phone should bring up for the box.
enum PhoneKeyboard { text, url, search }

/// What the phone page asks for: the label over the box, an example in it, and the keyboard that suits it.
class PhoneInputRequest {
  const PhoneInputRequest({required this.title, this.hint = '', this.keyboard = PhoneKeyboard.text});

  /// What to type, e.g. "订阅地址" or "搜索词".
  final String title;
  final String hint;
  final PhoneKeyboard keyboard;
}

/// A web page for typing on a phone, served by this app on its LAN address while the "手机输入" window is open
/// (TVBox's "推送"): the TV shows a QR code of the page's address, the phone opens it, and what is sent there fills
/// a field here. Typing a long subscription address with a remote control is the reason it exists.
///
/// The app serves it, not the engine: it works the same with the built-in engine and with one on another device,
/// and the engine's access rules stay as they are. What keeps it to the person in front of the screen:
/// - the address carries a random token ([token], about 60 bits) that is only shown on this screen;
/// - one text and it closes; unused, it closes after [ttl] (10 minutes) or when the window is closed;
/// - it only answers its own address (everything else is 404), takes at most [maxBytes], sets no cookies and runs
///   no script; the page cannot be framed or send its form anywhere but here.
class PhoneInputServer {
  PhoneInputServer._(this._server, this.token, this.request, Duration ttl)
      : expiresAt = DateTime.now().add(ttl),
        port = _server.port {
    _timer = Timer(ttl, () => unawaited(_finish(null)));
    _server.listen(_handle, onError: (Object _) {});
  }

  /// Starts listening on a free port of every IPv4 address ([address] for tests).
  static Future<PhoneInputServer> start(PhoneInputRequest request, {Duration ttl = const Duration(minutes: 10), Object? address}) async {
    final server = await HttpServer.bind(address ?? InternetAddress.anyIPv4, 0);
    server.idleTimeout = const Duration(seconds: 30);
    return PhoneInputServer._(server, newToken(), request, ttl);
  }

  static const maxBytes = 16 * 1024;

  final HttpServer _server;
  final String token;
  final PhoneInputRequest request;
  final DateTime expiresAt;
  late final Timer _timer;
  final _done = Completer<String?>();

  /// The text sent from the phone; null once it expired or was closed without one.
  Future<String?> get result => _done.future;
  bool get finished => _done.isCompleted;
  final int port;

  /// The page's address on [host] (an address of this device the phone can reach).
  Uri urlFor(String host) => Uri(scheme: 'http', host: host, port: port, path: '/$token');

  Future<void> close() => _finish(null);

  Future<void> _finish(String? text) async {
    if (!_done.isCompleted) _done.complete(text);
    _timer.cancel();
    await _server.close(force: true);
  }

  /// Letters and digits that cannot be mistaken for one another, should someone type the address.
  static const _alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';

  static String newToken([Random? random]) {
    final r = random ?? Random.secure();
    return String.fromCharCodes(List.generate(12, (_) => _alphabet.codeUnitAt(r.nextInt(_alphabet.length))));
  }

  static const _csp = "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'";

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set('Referrer-Policy', 'no-referrer')
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('Content-Security-Policy', _csp);
    String? received;
    try {
      if (req.uri.path != '/$token' || _done.isCompleted) {
        res.statusCode = HttpStatus.notFound;
        res.headers.contentType = ContentType.text;
        res.write('Not found');
        return;
      }
      if (req.method == 'GET' || req.method == 'HEAD') {
        _html(res, _formPage());
        return;
      }
      if (req.method != 'POST') {
        res.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      final body = await _readBody(req);
      if (body == null) {
        res.statusCode = HttpStatus.requestEntityTooLarge;
        _html(res, _formPage(error: '内容太长了'));
        return;
      }
      final text = _textOf(body, req.headers.contentType?.mimeType)?.trim();
      if (text == null || text.isEmpty) {
        res.statusCode = HttpStatus.badRequest;
        _html(res, _formPage(error: '没有填内容'));
        return;
      }
      _html(res, _sentPage());
      received = text;
    } catch (_) {
      try {
        res.statusCode = HttpStatus.badRequest;
      } catch (_) {
        // Headers already sent.
      }
    } finally {
      try {
        await res.close();
      } catch (_) {
        // The phone went away.
      }
      // After the answer has gone out: closing the server cuts open connections.
      if (received != null) unawaited(_finish(received));
    }
  }

  static String? _textOf(String body, String? mimeType) {
    if (mimeType == 'application/json') {
      final json = jsonDecode(body);
      return json is Map && json['text'] is String ? json['text'] as String : null;
    }
    return Uri.splitQueryString(body, encoding: utf8)['text'];
  }

  /// The body as text, or null when it is longer than [maxBytes]. A body a little too long is still read to the end
  /// (and dropped), so the phone gets the answer instead of a broken connection; past 1 MB the connection is cut.
  static Future<String?> _readBody(HttpRequest req) async {
    if (req.contentLength > 1024 * 1024) throw const HttpException('too large');
    final bytes = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in req) {
      total += chunk.length;
      if (total > 1024 * 1024) throw const HttpException('too large');
      if (total <= maxBytes) bytes.add(chunk);
    }
    return total > maxBytes ? null : utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }

  static void _html(HttpResponse res, String page) {
    res.headers.contentType = ContentType.html;
    res.add(utf8.encode(page));
  }

  static const _style = '''
:root{color-scheme:light dark;--bg:#f6f5f2;--card:#fff;--text:#1d1b19;--muted:#6b6660;--line:#d9d4cc;--accent:#e8664a}
@media (prefers-color-scheme:dark){:root{--bg:#161412;--card:#221f1c;--text:#f2efe9;--muted:#a8a199;--line:#3a352f}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:16px/1.5 system-ui,-apple-system,"PingFang SC","Microsoft YaHei",sans-serif}
main{max-width:560px;margin:0 auto;padding:24px 16px}h1{font-size:20px;margin:0 0 4px}p{margin:8px 0;color:var(--muted)}
form{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px;margin-top:16px}
label{display:block;font-weight:600;margin-bottom:8px}
textarea,input{width:100%;font:inherit;color:inherit;background:transparent;border:1px solid var(--line);border-radius:10px;padding:12px}
textarea{min-height:120px;resize:vertical}
button{margin-top:12px;width:100%;font:inherit;font-weight:600;color:#fff;background:var(--accent);border:0;border-radius:10px;padding:12px}
.error{color:#d93a2b;font-weight:600}.ok{font-size:40px;margin:24px 0 0}
''';

  String _formPage({String? error}) {
    final e = const HtmlEscape();
    final title = e.convert(request.title);
    final hint = e.convert(request.hint);
    final field = request.keyboard == PhoneKeyboard.url
        ? '<textarea id="t" name="text" required maxlength="8000" placeholder="$hint" autocapitalize="off" autocomplete="off" '
              'autocorrect="off" spellcheck="false" inputmode="url"></textarea>'
        : '<input id="t" name="text" required maxlength="2000" placeholder="$hint" autocomplete="off" enterkeyhint="send" '
              'inputmode="${request.keyboard == PhoneKeyboard.search ? 'search' : 'text'}">';
    return '''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><title>映舟 · 手机输入</title><style>$_style</style></head>
<body><main>
<h1>映舟 · 手机输入</h1>
<p>在下面填好$title，点「发送」，它就会出现在映舟里。这个网页只能用一次，10 分钟内有效。</p>
${error == null ? '' : '<p class="error">${e.convert(error)}</p>'}
<form method="post" action="/$token" accept-charset="utf-8">
<label for="t">$title</label>
$field
<button type="submit">发送</button>
</form>
</main></body></html>''';
  }

  String _sentPage() => '''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>映舟 · 已发送</title><style>$_style</style></head>
<body><main><p class="ok">✓</p><h1>已发送</h1><p>看一下映舟那边。这个网页可以关掉了。</p></main></body></html>''';

  /// This device's IPv4 addresses a phone on the same network can probably reach, the likeliest first: home
  /// network ranges before others, virtual adapters (WSL, Docker, VPNs such as Tailscale) last; link-local and
  /// loopback addresses are left out.
  static Future<List<String>> lanAddresses() async {
    final List<NetworkInterface> interfaces;
    try {
      interfaces = await NetworkInterface.list(includeLoopback: false, type: InternetAddressType.IPv4);
    } on SocketException {
      return const [];
    }
    final ranked = <(int, int, String)>[];
    var order = 0;
    for (final i in interfaces) {
      final name = i.name.toLowerCase();
      final virtual = const ['vethernet', 'virtual', 'vmware', 'vbox', 'docker', 'veth', 'br-', 'wsl', 'tailscale', 'zerotier', 'utun', 'tun', 'tap', 'hyper-v']
          .any(name.contains);
      for (final a in i.addresses) {
        final rank = rankAddress(a.rawAddress);
        if (rank == null) continue;
        ranked.add((rank + (virtual ? 10 : 0), order++, a.address));
      }
    }
    ranked.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    return [for (final r in ranked) r.$3];
  }

  /// Lower is likelier to be the home network; null for addresses a phone cannot use (loopback, link-local).
  static int? rankAddress(List<int> b) {
    if (b.length != 4 || b[0] == 127 || b[0] == 0) return null;
    if (b[0] == 169 && b[1] == 254) return null;
    if (b[0] == 192 && b[1] == 168) return 0;
    if (b[0] == 10) return 1;
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return 2;
    // 100.64.0.0/10: carrier NAT and Tailscale; a phone at home is rarely on it.
    if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return 5;
    return 3;
  }
}
