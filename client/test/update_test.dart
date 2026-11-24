import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart' show SimplePublicKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_client/engine/models.dart' show EngineSettings;
import 'package:tvbox_client/network_preferences.dart' show ClientNetworkPreferences;
import 'package:tvbox_client/settings.dart';
import 'package:tvbox_client/update/release_info.dart';
import 'package:tvbox_client/update/update_backend.dart';
import 'package:tvbox_client/update/update_client.dart';
import 'package:tvbox_client/update/update_models.dart';
import 'package:tvbox_client/update/update_service.dart';

import 'support/update_signer.dart';

/// Real sockets, whatever the test binding does to `HttpClient`.
class _RealHttp extends HttpOverrides {}

HttpClient _realClient() => HttpOverrides.runWithHttpOverrides(HttpClient.new, _RealHttp());

String _manifest(String version, {String notes = '- 新功能'}) => jsonEncode({
  'version': version,
  'tag': 'v$version',
  'date': '2026-11-21',
  'notes': notes,
  'page': 'https://github.com/Sa1koro/yingzhou/releases/tag/v$version',
  'download': 'https://github.com/Sa1koro/yingzhou/releases/download/v$version/',
  'assets': {
    'windows-x64': {'name': 'yingzhou-windows-x64-setup.exe', 'size': 1234, 'sha256': 'a' * 64},
    'windows-x64-zip': {'name': 'yingzhou-windows-x64.zip', 'size': 2345, 'sha256': 'b' * 64},
    'macos-arm64': {'name': 'yingzhou-macos-arm64.dmg', 'size': 3456, 'sha256': 'c' * 64},
    for (final abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']) 'android-$abi': {'name': 'yingzhou-android-$abi.apk', 'sha256': 'd' * 64},
  },
});

/// A local server standing in for GitHub, a GitHub accelerating mirror (`/mirror/<address>`) and an HTTP proxy
/// (a request whose target is an absolute address of another host), all at once. Records what it was asked.
class _FakeNet {
  _FakeNet._(this._server);

  final HttpServer _server;
  final asked = <String>[];

  /// What GitHub answers for latest.json: a body, or an HTTP status when it starts with a digit and is short.
  String latest = _manifest('0.4.0');
  int latestStatus = 200;
  bool mirrorWorks = true;
  bool signLatest = true;

  /// A package to download, by path.
  final files = <String, List<int>>{};

  static Future<_FakeNet> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final net = _FakeNet._(server);
    server.listen(net._serve);
    return net;
  }

  String get base => 'http://127.0.0.1:${_server.port}';

  Future<void> _serve(HttpRequest request) async {
    final uri = request.uri;
    final through = uri.hasAuthority && uri.host != '127.0.0.1' ? 'proxy' : (uri.path.startsWith('/mirror/') ? 'mirror' : 'direct');
    asked.add('$through ${uri.hasAuthority ? uri : uri.path}');
    final res = request.response;
    if (through == 'mirror' && !mirrorWorks) {
      res.statusCode = 502;
      await res.close();
      return;
    }
    final file = files[uri.path.split('/').last];
    if (file != null) {
      res.contentLength = file.length;
      res.add(file);
    } else if (uri.path.endsWith('latest.json')) {
      res.statusCode = latestStatus;
      res.headers.contentType = ContentType.json;
      var text = latest;
      if (signLatest && latestStatus == 200) {
        try {
          text = await signUpdateFixture(latest);
        } on FormatException {
          text = latest;
        }
      }
      res.write(text);
    } else {
      res.statusCode = 404;
    }
    await res.close();
  }

  Future<void> close() => _server.close(force: true);
}

/// A port nothing listens on.
Future<int> _deadPort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

void main() {
  test('the version in the app is the version in pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(r'^version:\s*([^\s+]+)', multiLine: true).firstMatch(pubspec)!.group(1);
    expect(appVersion, version, reason: 'update lib/update/release_info.dart with pubspec.yaml');
  });

  group('versions', () {
    test('the digits of a constant: from the third number on, a decimal; the build number does not count; a pre-release comes first', () {
      expect(compareVersions('0.4.0', '0.3.14'), 1);
      expect(compareVersions('0.10.0', '0.9.0'), 1, reason: 'the first two are whole numbers');
      // Every version released so far, in order.
      const released = ['0.3.0', '0.3.14', '0.4.0', '0.4.14', '0.4.1421', '0.4.14213', '0.4.1421356', '0.4.1468', '0.4.1468250'];
      for (var i = 1; i < released.length; i++) {
        expect(compareVersions(released[i], released[i - 1]), 1, reason: '${released[i]} after ${released[i - 1]}');
      }
      expect(compareVersions('0.4.1468', '0.4.1421356'), 1, reason: '0.41468 is more than 0.41421356');
      expect(compareVersions('0.4.146825', '0.4.1468'), 1);
      expect(compareVersions('0.4.14', '0.4.140'), 0);
      expect(compareVersions('0.3.2', '0.3.14'), 1, reason: '0.32 is more than 0.314');
      expect(compareVersions('0.3.14+4', '0.3.14'), 0);
      expect(compareVersions('v0.3.14', '0.3.14'), 0);
      expect(compareVersions('0.4', '0.4.0'), 0);
      expect(compareVersions('0.4.0-beta.1', '0.4.0'), -1);
      expect(compareVersions('0.4.0-beta.2', '0.4.0-beta.1'), 1);
      expect(compareVersions('nonsense', '0.0.1'), -1);
    });

    test('the package for this machine', () {
      final release = ReleaseInfo.fromJson(jsonDecode(_manifest('0.4.0')));
      String? pick(String os, String abi, {bool installed = true}) => assetFor(release, assetKeysFor(os: os, abi: abi, installed: installed))?.name;
      expect(pick('windows', 'windows_x64'), 'yingzhou-windows-x64-setup.exe');
      expect(pick('windows', 'windows_x64', installed: false), 'yingzhou-windows-x64.zip', reason: 'unzipped: the zip again');
      expect(pick('macos', 'macos_arm64'), 'yingzhou-macos-arm64.dmg');
      expect(pick('macos', 'macos_x64'), isNull, reason: 'an Intel Mac cannot run an ARM-only build');
      expect(pick('android', 'android_arm64'), 'yingzhou-android-arm64-v8a.apk');
      expect(pick('android', 'android_arm'), 'yingzhou-android-armeabi-v7a.apk', reason: 'a 32-bit install stays 32-bit');
      expect(pick('android', 'android_x64'), 'yingzhou-android-x86_64.apk');
      expect(pick('linux', 'linux_x64'), isNull);
      expect(pick('ios', 'ios_arm64'), isNull);
      expect(release.urlOf(release.assets['windows-x64']!), 'https://github.com/Sa1koro/yingzhou/releases/download/v0.4.0/yingzhou-windows-x64-setup.exe');
      expect(release.assets['windows-x64']!.size, 1234);
    });

    test('a manifest without a version is refused; missing fields are filled in', () {
      expect(() => ReleaseInfo.fromJson({'notes': 'x'}), throwsFormatException);
      expect(() => ReleaseInfo.fromJson(['0.4.0']), throwsFormatException);
      final bare = ReleaseInfo.fromJson({'version': 'v0.5.1'});
      expect(bare.version, '0.5.1');
      expect(bare.page, 'https://github.com/Sa1koro/yingzhou/releases/tag/v0.5.1');
      expect(bare.download, 'https://github.com/Sa1koro/yingzhou/releases/download/v0.5.1/');
      expect(bare.assets, isEmpty);

      // A manifest passed on by an accelerating proxy cannot send the user elsewhere.
      final elsewhere = ReleaseInfo.fromJson({
        'version': '0.5.1',
        'page': 'https://evil.test/release',
        'download': 'https://evil.test/files/',
        'assets': {'windows-x64': 'app.exe'},
      });
      expect(elsewhere.page, 'https://github.com/Sa1koro/yingzhou/releases/tag/v0.5.1');
      expect(elsewhere.urlOf(elsewhere.assets['windows-x64']!), 'https://github.com/Sa1koro/yingzhou/releases/download/v0.5.1/app.exe');
    });

    test('proxy and mirror addresses', () {
      expect(normalizeProxy(''), '');
      expect(normalizeProxy(' 127.0.0.1:7890 '), '127.0.0.1:7890');
      expect(normalizeProxy('http://proxy.lan:8080/'), 'proxy.lan:8080');
      expect(normalizeProxy('[::1]:1080'), '[::1]:1080');
      expect(normalizeProxy('127.0.0.1'), isNull);
      expect(normalizeProxy('127.0.0.1:99999'), isNull);
      expect(normalizeProxy('a b:80'), isNull);
      expect(normalizeMirror('ghfast.top'), 'https://ghfast.top/');
      expect(normalizeMirror('https://ghfast.top//'), 'https://ghfast.top/');
      expect(normalizeMirror(' '), '');
    });
  });

  group('checking', () {
    late _FakeNet net;
    late SimplePublicKey key;
    setUp(() async {
      net = await _FakeNet.start();
      key = await testUpdatePublicKey;
    });
    tearDown(() => net.close());

    UpdateClient client({String? latestUrl, String current = '0.3.14'}) => UpdateClient(
      latestUrl: latestUrl ?? '${net.base}/releases/download/channel/latest.json',
      currentVersion: current,
      verificationKey: key,
      timeout: const Duration(seconds: 5),
      httpClient: _realClient,
    );

    test('a newer, the same and an older version', () async {
      final newer = await client().check();
      expect(newer.ok, isTrue);
      expect(newer.newer, isTrue);
      expect(newer.release!.version, '0.4.0');
      expect(newer.release!.notes, '- 新功能');
      expect(newer.route, UpdateRoute.direct);
      expect(newer.routeLabel, '直连 GitHub');
      expect(newer.failures, isEmpty);

      net.latest = _manifest('0.3.14');
      final same = await client().check();
      expect((same.ok, same.newer, same.comparison), (true, false, 0));

      net.latest = _manifest('0.3.0');
      final older = await client().check();
      expect((older.ok, older.newer, older.comparison), (true, false, -1));
      expect(net.asked, everyElement(startsWith('direct /releases/download/channel/latest.json')));
    });

    test('unreachable, with no mirror to fall back to', () async {
      final r = await client(latestUrl: 'http://127.0.0.1:${await _deadPort()}/latest.json').check();
      expect(r.ok, isFalse);
      expect(r.route, isNull);
      expect(r.failures, ['直连 GitHub：连不上']);
    });

    test('malformed JSON, and JSON that is not a manifest', () async {
      net.latest = '{"version": "0.4.0", ';
      final broken = await client().check();
      expect(broken.ok, isFalse);
      expect(broken.failures.single, contains('格式不对'));

      net.latest = '{"hello": "world"}';
      expect((await client().check()).failures.single, contains('格式不对'));

      net.latest = 'Not Found';
      net.latestStatus = 404;
      expect((await client().check()).failures.single, contains('HTTP 404'));
    });

    test('the selected mirror is preferred and GitHub is the fallback', () async {
      final dead = 'http://127.0.0.1:${await _deadPort()}/releases/download/channel/latest.json';
      final r = await client(latestUrl: dead).check(mirror: '${net.base}/mirror');
      expect(r.ok, isTrue);
      expect(r.route, UpdateRoute.mirror);
      expect(r.mirror, '${net.base}/mirror/');
      expect(r.failures, isEmpty);
      expect(r.routeLabel, '经加速前缀 127.0.0.1');
      expect(net.asked, ['mirror /mirror/$dead']);
      // Downloads then take the same way.
      expect(r.routed('https://github.com/x/y.exe'), '${net.base}/mirror/https://github.com/x/y.exe');

      net.asked.clear();
      net.latestStatus = 503;
      final both = await client().check(mirror: '${net.base}/mirror/');
      expect(both.failures, ['经加速前缀 127.0.0.1：HTTP 503', '直连 GitHub：HTTP 503']);
      net.latestStatus = 200;
      net.mirrorWorks = false;
      final direct = await client().check(mirror: '${net.base}/mirror/');
      expect(direct.route, UpdateRoute.direct);

      net.mirrorWorks = false;
      final none = await client(latestUrl: dead).check(mirror: '${net.base}/mirror/');
      expect(none.ok, isFalse);
      expect(none.failures, ['经加速前缀 127.0.0.1：HTTP 502', '直连 GitHub：连不上']);
    });

    test('unsigned or modified release manifests cannot authorize an update', () async {
      net.signLatest = false;
      expect((await client().check()).failures.single, contains('缺少发布签名'));
      final envelope = jsonDecode(await signUpdateFixture(net.latest)) as Map<String, dynamic>;
      envelope['version'] = '9.9.9';
      net.latest = jsonEncode(envelope);
      expect((await client().check()).release!.version, '0.4.0');
      envelope['signed'] = base64Encode(utf8.encode(_manifest('9.9.9')));
      net.latest = jsonEncode(envelope);
      expect((await client().check()).failures.single, contains('签名无效'));
    });

    test('through the HTTP proxy: a host that does not resolve is still reached', () async {
      final viaProxy = UpdateClient(
        latestUrl: 'http://update.invalid/releases/download/channel/latest.json',
        currentVersion: '0.3.14',
        verificationKey: key,
        httpClient: _realClient,
      );
      final r = await viaProxy.check(proxy: '127.0.0.1:${net._server.port}');
      expect(r.ok, isTrue);
      expect(r.proxy, '127.0.0.1:${net._server.port}');
      expect(r.routeLabel, '直连 GitHub（经代理 127.0.0.1:${net._server.port}）');
      expect(net.asked, ['proxy http://update.invalid/releases/download/channel/latest.json']);

      // A proxy that is not there.
      final dead = await viaProxy.check(proxy: '127.0.0.1:${await _deadPort()}');
      expect(dead.ok, isFalse);
      expect(dead.failures.single, '直连 GitHub：连不上');
    });

    test('downloads through the proxy into a file, never leaving half a file under the real name', () async {
      final dir = await Directory.systemTemp.createTemp('yingzhou-update-test');
      addTearDown(() => dir.delete(recursive: true));
      net.files['app.exe'] = List.generate(300 * 1024, (i) => i % 251);
      final digest = sha256.convert(net.files['app.exe']!).toString();
      final seen = <int>[];
      final file = await client().download(
        'http://downloads.invalid/v0.4.0/app.exe',
        File('${dir.path}/app.exe'),
        expectedSha256: digest,
        proxy: '127.0.0.1:${net._server.port}',
        progress: (received, total) {
          expect(total, 300 * 1024);
          seen.add(received);
        },
      );
      expect(await file.readAsBytes(), net.files['app.exe']);
      expect(seen.last, 300 * 1024);
      expect(net.asked, ['proxy http://downloads.invalid/v0.4.0/app.exe']);

      // Cancelled half-way: neither the file nor the part is left.
      await file.delete();
      await expectLater(
        client().download('${net.base}/v0.4.0/app.exe', File('${dir.path}/app.exe'), expectedSha256: digest, cancelled: () => true),
        throwsA(isA<UpdateCancelled>()),
      );
      expect(dir.listSync(), isEmpty);
      // Not there at all.
      await expectLater(client().download('${net.base}/v0.4.0/missing.exe', File('${dir.path}/m.exe'), expectedSha256: digest), throwsA(isA<HttpException>()));
      expect(dir.listSync(), isEmpty);
      // Not the size the manifest says (a proxy's page answered with 200): refused.
      Object? wrong;
      try {
        await client().download('${net.base}/v0.4.0/app.exe', File('${dir.path}/app.exe'), expectedSha256: digest, expectedSize: 123);
      } on HttpException catch (e) {
        wrong = e;
      }
      expect(describeFailure(wrong!), contains('大小不对'));
      expect(dir.listSync(), isEmpty);
      await file.writeAsString('existing verified package');
      await expectLater(
        client().download('${net.base}/v0.4.0/app.exe', file, expectedSha256: 'a' * 64, expectedSize: net.files['app.exe']!.length),
        throwsA(predicate((error) => describeFailure(error!).contains('SHA-256'))),
      );
      expect(await file.readAsString(), 'existing verified package');
      net.asked.clear();
      net.mirrorWorks = false;
      await client().download('${net.base}/v0.4.0/app.exe', file, expectedSha256: digest, mirror: '${net.base}/mirror');
      expect(net.asked.map((address) => address.split(' ').first), ['mirror', 'direct']);
    });
  });

  group('the service', () {
    test('the automatic check is off until turned on, then asks once a day', () async {
      var now = DateTime(2026, 11, 20, 12);
      final backend = FakeUpdateBackend();
      final settings = MemorySettings();
      final network = ClientNetworkPreferences(settings, () => 'http://localhost:9978');
      final service = UpdateService(settings: settings, network: network, backend: backend, clock: () => now);
      expect(service.autoCheck, isFalse);
      expect(service.due, isFalse);

      await service.setAutoCheck(true);
      expect(service.due, isTrue);
      await network.rememberGithub(const EngineSettings(githubProxy: true, githubProxyPrefix: 'https://ghfast.top/'));
      await service.check();
      expect(backend.checks, [('https://ghfast.top/', '')]);
      expect(service.due, isFalse);
      now = now.add(const Duration(hours: 23));
      expect(service.due, isFalse);
      now = now.add(const Duration(hours: 1));
      expect(service.due, isTrue);

      // Offline: still due, so the next chance tries again.
      backend.result = UpdateCheckResult(current: '0.3.14', at: now, failures: const ['直连 GitHub：连不上']);
      await service.check();
      expect(service.due, isTrue);
      backend.result = null;

      await network.saveHttp('127.0.0.1:7890', updates: false);
      expect(network.updateProxy, '');
      await network.saveHttp('127.0.0.1:7890', updates: true);
      await network.rememberGithub(const EngineSettings());
      await service.check();
      expect(backend.checks.last, ('', '127.0.0.1:7890'));
    });

    test('remember routes for each engine and migrate the existing update proxy exactly once', () async {
      final settings = MemorySettings();
      await settings.setString('update.proxy', '127.0.0.1:7890');
      var origin = 'http://localhost:9978';
      final network = ClientNetworkPreferences(settings, () => origin);
      await network.migrateUpdateProxy();
      await network.rememberGithub(const EngineSettings(githubProxy: true, githubProxyPrefix: 'https://fast.test/'));
      final backend = FakeUpdateBackend();
      final service = UpdateService(settings: settings, network: network, backend: backend);
      await service.check();
      expect(backend.checks.last, ('https://fast.test/', '127.0.0.1:7890'));
      origin = 'http://nas.lan:9978';
      await network.migrateUpdateProxy();
      await service.check();
      expect(backend.checks.last, ('', ''));
      origin = 'http://localhost:9978';
      await service.check();
      expect(backend.checks.last, ('https://fast.test/', '127.0.0.1:7890'));
    });
  });
}

/// An [UpdateBackend] answering what the test sets, recording what it was asked.
class FakeUpdateBackend implements UpdateBackend {
  FakeUpdateBackend({this.result, this.keys = const ['windows-x64']});

  UpdateCheckResult? result;
  final List<String> keys;
  final checks = <(String, String)>[];
  final downloads = <(String, String, String)>[];
  final expectedSizes = <int>[];
  final downloadMirrors = <String>[];
  final opened = <String>[];
  final revealed = <String>[];
  bool canOpen = true;
  Object? downloadError;
  Object? revealError;
  Future<void>? downloadGate;

  @override
  bool get supported => true;

  @override
  bool get opensPackageInstaller => keys.any((key) => key.startsWith('android-'));

  @override
  Future<UpdateCheckResult> check({String mirror = '', String proxy = ''}) async {
    checks.add((mirror, proxy));
    final r =
        result ??
        UpdateCheckResult(current: '0.3.14', at: DateTime.now(), release: ReleaseInfo.fromJson(jsonDecode(_manifest('0.3.14'))), route: UpdateRoute.direct);
    return UpdateCheckResult(current: r.current, at: r.at, release: r.release, route: r.route, mirror: r.mirror, proxy: proxy, failures: r.failures);
  }

  @override
  List<String> get assetKeys => keys;

  @override
  Future<String> download(
    String url,
    String fileName, {
    required String expectedSha256,
    String mirror = '',
    String proxy = '',
    int expectedSize = 0,
    void Function(int, int)? progress,
    bool Function()? cancelled,
  }) async {
    downloads.add((url, fileName, proxy));
    downloadMirrors.add(mirror);
    expectedSizes.add(expectedSize);
    progress?.call(512, 1024);
    await (downloadGate ?? Future<void>.delayed(Duration.zero));
    if (cancelled?.call() ?? false) throw const UpdateCancelled();
    if (downloadError != null) throw downloadError!;
    progress?.call(1024, 1024);
    return 'C:/Users/me/Downloads/$fileName';
  }

  @override
  Future<bool> openInBrowser(String url) async {
    opened.add(url);
    return canOpen;
  }

  @override
  Future<void> reveal(String path) async {
    revealed.add(path);
    if (revealError != null) throw revealError!;
  }

  @override
  String describe(Object error) => '$error';
}

/// A newer release as a check through [route] finds it.
UpdateCheckResult newerRelease({
  UpdateRoute route = UpdateRoute.direct,
  String mirror = '',
  List<String> failures = const [],
  String notes = '### 新功能\n- **自动更新**：检查新版本\n- 修复了 `bug`',
}) => UpdateCheckResult(
  current: '0.3.14',
  at: DateTime.now(),
  release: ReleaseInfo.fromJson(jsonDecode(_manifest('0.4.0', notes: notes))),
  route: route,
  mirror: mirror,
  failures: failures,
);
