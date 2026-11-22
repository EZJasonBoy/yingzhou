// What the release job publishes about the newest version (`latest.json`, see .github/workflows/desktop.yml) and how
// it compares with the running one.

/// This build's version, the `version:` of pubspec.yaml without the build number. A test keeps the two the same
/// (test/update_test.dart); `--dart-define=APP_VERSION=0.1.0` pretends to be another version (to try updating).
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '0.4.1468250');

/// The repository the releases are published in.
const releaseRepository = 'Sa1koro/yingzhou';

/// `latest.json` on the rolling release `channel`: a plain download, so no GitHub API (and its rate limit) is
/// involved, and GitHub accelerating proxies, which pass downloads but not the API, can fetch it too.
const latestJsonUrl = 'https://github.com/$releaseRepository/releases/download/channel/latest.json';

/// One file of a release.
class ReleaseAsset {
  const ReleaseAsset({required this.name, this.size = 0, this.sha256 = ''});

  final String name;

  /// In bytes; 0 when not known.
  final int size;
  final String sha256;
}

/// The newest release, as `latest.json` describes it.
class ReleaseInfo {
  const ReleaseInfo({required this.version, this.tag = '', this.date = '', this.notes = '', this.page = '', this.download = '', this.assets = const {}});

  /// `0.4.0`, without a leading `v`.
  final String version;
  final String tag;

  /// `2026-11-21`.
  final String date;

  /// What changed: the CHANGELOG.md section of this version (Markdown).
  final String notes;

  /// The release's page on GitHub.
  final String page;

  /// Where its files are: `https://github.com/<repo>/releases/download/<tag>/`, the file name goes after it.
  final String download;

  /// By platform: `windows-x64` (installer), `windows-x64-zip`, `macos-arm64`, `android-arm64-v8a`, ...
  final Map<String, ReleaseAsset> assets;

  /// Reads `latest.json`; throws [FormatException] when it is not one.
  factory ReleaseInfo.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) throw const FormatException('not a JSON object');
    final version = (json['version'] as Object? ?? '').toString().trim().replaceFirst(RegExp('^v'), '');
    if (parseVersion(version) == null) throw FormatException('no version: "$version"');
    final tag = json['tag'] is String ? json['tag'] as String : 'v$version';
    final assets = <String, ReleaseAsset>{};
    final raw = json['assets'];
    if (raw is Map<String, dynamic>) {
      raw.forEach((key, value) {
        // An asset is its file name, or {name, size}.
        if (value is String && value.isNotEmpty) assets[key] = ReleaseAsset(name: value);
        if (value is Map<String, dynamic> && value['name'] is String) {
          assets[key] = ReleaseAsset(name: value['name'] as String, size: (value['size'] as num?)?.toInt() ?? 0, sha256: value['sha256'] as String? ?? '');
        }
      });
    }
    String text(String key) => json[key] is String ? json[key] as String : '';
    // Addresses stay on this repository's releases, whoever passed the file on (an accelerating proxy).
    const releases = 'https://github.com/$releaseRepository/releases/';
    final page = text('page'), download = text('download');
    return ReleaseInfo(
      version: version,
      tag: tag,
      date: text('date'),
      notes: text('notes'),
      page: page.startsWith(releases) ? page : '${releases}tag/$tag',
      download: download.startsWith('${releases}download/') ? (download.endsWith('/') ? download : '$download/') : '${releases}download/$tag/',
      assets: assets,
    );
  }

  /// The address of [asset] on GitHub.
  String urlOf(ReleaseAsset asset) => '$download${Uri.encodeComponent(asset.name)}';
}

/// `0.3.14`, `v0.4.0`, `0.4.0-beta.1+5` as its numbers (the digits as written) and a pre-release label; null when it
/// is not a version.
(List<String>, String)? parseVersion(String version) {
  final m = RegExp(r'^v?(\d+(?:\.\d+)*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$').firstMatch(version.trim());
  if (m == null) return null;
  return (m.group(1)!.split('.'), m.group(2) ?? '');
}

/// Negative when [a] is older than [b], 0 when the same, positive when newer. The build number (`+4`) does not
/// count; a pre-release (`0.4.0-beta.1`) comes before its release. Something that is not a version is the oldest.
///
/// Version numbers follow the digits of a constant: `0.4.1421356` is 0.41421356…, `0.4.1468` is 0.41468…. So the
/// first two numbers are whole numbers, and from the third on each number is the digits of a decimal: `0.4.1468`
/// is newer than `0.4.1421356` (0.41468 > 0.41421356), `0.4.14` and `0.4.140` are the same.
int compareVersions(String a, String b) {
  final x = parseVersion(a), y = parseVersion(b);
  if (x == null || y == null) return (x == null ? 0 : 1) - (y == null ? 0 : 1);
  for (var i = 0; i < x.$1.length || i < y.$1.length; i++) {
    final p = i < x.$1.length ? x.$1[i] : '0', q = i < y.$1.length ? y.$1[i] : '0';
    final int d;
    if (i < 2) {
      d = int.parse(p) - int.parse(q);
    } else {
      // Digits after the point: the same length, then digit by digit.
      final width = p.length > q.length ? p.length : q.length;
      d = p.padRight(width, '0').compareTo(q.padRight(width, '0'));
    }
    if (d != 0) return d.sign;
  }
  if (x.$2 == y.$2) return 0;
  if (x.$2.isEmpty) return 1;
  if (y.$2.isEmpty) return -1;
  return x.$2.compareTo(y.$2).sign;
}

/// The key in [ReleaseInfo.assets] of the package for the machine this runs on: [os] as `Platform.operatingSystem`,
/// [abi] as `Abi.current().toString()` (`windows_x64`, `android_arm64`...). [installed]: on Windows, whether this
/// copy came from the installer (it has an uninstaller next to it) rather than the zip.
List<String> assetKeysFor({required String os, required String abi, bool installed = true}) => switch (os) {
  'windows' => installed ? ['windows-x64', 'windows-x64-zip'] : ['windows-x64-zip', 'windows-x64'],
  'macos' => switch (abi) {
    'macos_x64' => ['macos-x86_64'],
    'macos_arm64' => ['macos-arm64'],
    _ => const [],
  },
  'android' => switch (abi) {
    'android_arm' => ['android-armeabi-v7a'],
    'android_x64' => ['android-x86_64'],
    _ => ['android-arm64-v8a'],
  },
  'linux' => ['linux-x64'],
  _ => const [],
};

/// The package of [release] for this machine (see [assetKeysFor]); null when the release has none for it.
ReleaseAsset? assetFor(ReleaseInfo release, List<String> keys) {
  for (final key in keys) {
    final asset = release.assets[key];
    if (asset != null) return asset;
  }
  // Linux packages are named by the job that makes them: any of them.
  if (keys.contains('linux-x64')) {
    for (final e in release.assets.entries) {
      if (e.key.startsWith('linux')) return e.value;
    }
  }
  return null;
}
