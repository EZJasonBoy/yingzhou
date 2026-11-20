/// Takes out of a text what should not leave the device in a bug report: subscription addresses, tokens and
/// passwords, signed URL parameters (`tvsig`), the paths and queries of addresses on other hosts and the user's
/// home folder. Applied to everything the diagnostics page shows or copies (see `diagnostics_page.dart`), and to
/// crash records as they are written.
///
/// It errs on the side of hiding: an address on the internet keeps only its scheme and host
/// (`https://example.com/…`), because a subscription can hide behind any address. Addresses on this machine and on
/// the LAN keep their path, since that is where the engine's own routes show, with their sensitive parameters
/// masked. Running it again on its own output changes nothing.
class Redactor {
  Redactor({Iterable<String> homes = const [], Iterable<String> secrets = const []})
    : _homes = _variants(homes.where((h) => h.length >= 3)),
      _secrets = (secrets.map((s) => s.trim()).where((s) => s.length >= 8).toSet().toList()..sort((a, b) => b.length - a.length));

  /// What subscription addresses become.
  static const subscription = '<订阅地址>';

  /// What a masked value becomes.
  static const masked = '***';

  /// What the user's name in a home path becomes when the home folder itself is not known.
  static const user = '<用户>';

  final List<String> _homes;
  final List<String> _secrets;

  /// Query parameters of local addresses whose value is masked (compared in lower case).
  static const sensitiveKeys = {
    ...sensitiveTextKeys,
    'auth',
    'pass',
    'session',
    'sign',
    'sig',
    'x-amz-credential',
    'policy',
    'key-pair-id',
    'wssecret',
    'txsecret',
    'pk',
  };

  /// `key=value` and `"key": "value"` in running text whose value is masked (compared in lower case): only names that
  /// cannot mean anything else.
  static const sensitiveTextKeys = {
    'tvsig',
    'token',
    'access_token',
    'refresh_token',
    'id_token',
    'auth_key',
    'authorization',
    'password',
    'passwd',
    'pwd',
    'secret',
    'client_secret',
    'apikey',
    'api_key',
    'access_key',
    'cookie',
    'sessionid',
    'signature',
    'x-amz-signature',
    'x-amz-security-token',
  };

  String apply(String text) {
    if (text.isEmpty) return text;
    var out = text;
    for (final s in _secrets) {
      out = out.replaceAll(s, subscription);
      final encoded = Uri.encodeComponent(s);
      if (encoded != s) out = out.replaceAll(encoded, subscription);
    }
    // A subscription's key suffix (`<address>;pk;<key>`), wherever it is.
    out = out.replaceAllMapped(_pk, (m) => ';pk;$masked');
    out = out.replaceAllMapped(_url, (m) => _redactUrl(m[0]!));
    out = out.replaceAllMapped(_bearer, (m) => '${m[1]}$masked');
    out = out.replaceAllMapped(_pair, (m) {
      final value = m[3]!;
      if (value.isEmpty || value == masked || _harmless.contains(value.toLowerCase())) return m[0]!;
      return '${m[1]}${m[2]}$masked';
    });
    // The engine's pairing tokens: `<device id>.<32 random bytes, base64url>`.
    out = out.replaceAll(_engineToken, masked);
    for (final home in _homes) {
      out = out.replaceAll(RegExp(RegExp.escape(home), caseSensitive: false), '~');
    }
    out = out.replaceAllMapped(_windowsHome, (m) => '${m[1]}$user');
    out = out.replaceAllMapped(_unixHome, (m) => '${m[1]}$user');
    return out;
  }

  static final _pk = RegExp(r';pk;(?!\*\*\*)[^\s"&,;]+');
  static final _url = RegExp(r'''\b[a-zA-Z][a-zA-Z0-9+.\-]{1,15}://[^\s"'<>()\[\]{}`，。、；）]+''');
  static final _bearer = RegExp(r'\b((?:Bearer|Basic)\s+)(?!\*\*\*)[A-Za-z0-9._~+/=\-]{6,}', caseSensitive: false);
  static final _pair = RegExp(r'''(?<![A-Za-z0-9_\-])((?:"|')?(?:''' + _keyAlternatives() + r''')(?:"|')?)(\s*[=:]\s*"?)([^\s"&,;}]*)''', caseSensitive: false);
  static final _engineToken = RegExp(r'(?<![A-Za-z0-9_\-])[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]{43}(?![A-Za-z0-9_\-])');
  static final _windowsHome = RegExp(
    r'''([A-Za-z]:(?:\\\\|\\|/)(?:Users|Documents and Settings)(?:\\\\|\\|/))(?!<用户>|Public\b|Default\b|All Users\b)([^\\/\s"':*?<>|]+)''',
    caseSensitive: false,
  );
  static final _unixHome = RegExp(r'''((?<![A-Za-z0-9_.\-])/(?:home|Users)/)(?!<用户>|Shared\b)([^/\s"':]+)''');
  static const _harmless = {'true', 'false', 'null', 'bearer', 'basic', '***', '<订阅地址>'};

  static String _keyAlternatives() => (sensitiveTextKeys.toList()..sort((a, b) => b.length - a.length)).map(RegExp.escape).join('|');

  /// The home folder as written in files and in JSON (`\\`), with either slash.
  static List<String> _variants(Iterable<String> homes) {
    final out = <String>{};
    for (final h in homes) {
      final trimmed = h.endsWith('\\') || h.endsWith('/') ? h.substring(0, h.length - 1) : h;
      out
        ..add(trimmed)
        ..add(trimmed.replaceAll('\\', '/'))
        ..add(trimmed.replaceAll('\\', r'\\'));
    }
    return out.toList()..sort((a, b) => b.length - a.length);
  }

  String _redactUrl(String raw) {
    // Punctuation that ended a sentence rather than the address.
    var url = raw;
    var tail = '';
    while (url.isNotEmpty && '.,:;!?'.contains(url[url.length - 1])) {
      tail = url[url.length - 1] + tail;
      url = url.substring(0, url.length - 1);
    }
    final schemeEnd = url.indexOf('://');
    final scheme = url.substring(0, schemeEnd).toLowerCase();
    var rest = url.substring(schemeEnd + 3);
    if (scheme == 'clan' || scheme == 'content') return '$scheme://…$tail';
    if (scheme == 'file') return url + tail;

    // Authority: up to the first `/`, `?` or `#`.
    final authorityEnd = rest.indexOf(RegExp(r'[/?#]'));
    var authority = authorityEnd < 0 ? rest : rest.substring(0, authorityEnd);
    rest = authorityEnd < 0 ? '' : rest.substring(authorityEnd);
    final at = authority.lastIndexOf('@');
    final userInfo = at >= 0;
    if (userInfo) authority = authority.substring(at + 1);
    final host = _hostOf(authority);
    final prefix = '$scheme://${userInfo ? '$masked@' : ''}$authority';
    if (rest.isEmpty || rest == '/') return '$prefix$rest$tail';
    if (!isLocalHost(host)) return '$prefix/…$tail';

    // This machine or the LAN: keep the path, mask what must not be seen in the query.
    final hash = rest.indexOf('#');
    if (hash >= 0) rest = '${rest.substring(0, hash)}${hash == rest.length - 1 ? '#' : '#…'}';
    final q = rest.indexOf('?');
    if (q < 0) return '$prefix$rest$tail';
    final path = rest.substring(0, q);
    var query = rest.substring(q + 1);
    var fragment = '';
    final hashInQuery = query.indexOf('#');
    if (hashInQuery >= 0) {
      fragment = query.substring(hashInQuery);
      query = query.substring(0, hashInQuery);
    }
    final pairs = [
      for (final part in query.split('&'))
        if (part.isNotEmpty) _redactParameter(part),
    ];
    return '$prefix$path?${pairs.join('&')}$fragment$tail';
  }

  String _redactParameter(String part) {
    final eq = part.indexOf('=');
    if (eq < 0) return part;
    final name = part.substring(0, eq);
    final value = part.substring(eq + 1);
    final decodedName = _decode(name).toLowerCase();
    if (sensitiveKeys.contains(decodedName)) return value == masked ? part : '$name=$masked';
    final decoded = _decode(value);
    if (decoded.contains('://')) return '$name=${decoded.replaceAllMapped(_url, (m) => _redactUrl(m[0]!))}';
    return part;
  }

  static String _decode(String s) {
    try {
      return Uri.decodeQueryComponent(s);
    } on FormatException {
      return s;
    } on ArgumentError {
      return s;
    }
  }

  static String _hostOf(String authority) {
    if (authority.startsWith('[')) {
      final end = authority.indexOf(']');
      return end < 0 ? authority : authority.substring(1, end);
    }
    final colon = authority.lastIndexOf(':');
    return (colon < 0 ? authority : authority.substring(0, colon)).toLowerCase();
  }

  /// Loopback, private (RFC 1918), link-local and `.local` / `.lan` names: this machine and the LAN.
  static bool isLocalHost(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h == '::1' || h == '0.0.0.0' || h.endsWith('.localhost') || h.endsWith('.local') || h.endsWith('.lan')) return true;
    if (h.startsWith('fe80:') || h.startsWith('fc') || h.startsWith('fd')) return h.contains(':');
    final parts = h.split('.');
    if (parts.length != 4) return false;
    final n = parts.map(int.tryParse).toList();
    if (n.any((x) => x == null || x < 0 || x > 255)) return false;
    final a = n[0]!, b = n[1]!;
    return a == 127 || a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31) || (a == 169 && b == 254);
  }
}
