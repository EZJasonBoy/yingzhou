// Cloud drives and folders (docs/protocol.md, "网盘"). The engine keeps their passwords and tokens; the client only
// learns whether there is one.

import 'engine_client.dart';
import 'vod_models.dart';

/// The kinds of drive the engine reads.
enum DriveKind {
  alist('alist', 'AList / OpenList'),
  webdav('webdav', 'WebDAV'),
  local('local', '本机文件夹');

  const DriveKind(this.wire, this.label);

  final String wire;
  final String label;

  static DriveKind parse(String s) => DriveKind.values.firstWhere((k) => k.wire == s, orElse: () => DriveKind.webdav);
}

/// Site keys of drives: a drive's folder is a video under `drive:<id>`, its files are the episodes.
const driveSitePrefix = 'drive:';

bool isDriveSite(String site) => site.startsWith(driveSitePrefix);

class DriveInfo {
  const DriveInfo({
    required this.id,
    required this.name,
    required this.kind,
    required this.url,
    this.username = '',
    this.hasPassword = false,
    this.hasToken = false,
    this.root = '/',
    this.proxy = false,
    this.lockedFolders = const [],
    this.site = '',
  });

  final String id;
  final String name;
  final DriveKind kind;

  /// The server's address, or the folder on the engine's machine.
  final String url;
  final String username;
  final bool hasPassword;
  final bool hasToken;
  final String root;

  /// Players always get files through the engine.
  final bool proxy;
  final List<String> lockedFolders;

  /// `drive:<id>`: the site key of the drive's folders in play requests and the history.
  final String site;

  factory DriveInfo.fromJson(Map<String, dynamic> j) => DriveInfo(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    kind: DriveKind.parse(j['kind'] as String? ?? ''),
    url: j['url'] as String? ?? '',
    username: j['username'] as String? ?? '',
    hasPassword: j['hasPassword'] as bool? ?? false,
    hasToken: j['hasToken'] as bool? ?? false,
    root: j['root'] as String? ?? '/',
    proxy: j['proxy'] as bool? ?? false,
    lockedFolders: [for (final f in j['lockedFolders'] as List? ?? const []) f as String],
    site: j['site'] as String? ?? '$driveSitePrefix${j['id']}',
  );
}

class DriveEntry {
  const DriveEntry({required this.name, required this.path, required this.dir, this.size = 0, this.modified = 0, this.type = 'other'});

  final String name;

  /// Inside the drive, from its "/".
  final String path;
  final bool dir;
  final int size;

  /// Epoch ms, 0 when unknown.
  final int modified;

  /// folder | video | subtitle | other
  final String type;

  bool get isVideo => type == 'video';
  bool get isSubtitle => type == 'subtitle';

  factory DriveEntry.fromJson(Map<String, dynamic> j) => DriveEntry(
    name: j['name'] as String,
    path: j['path'] as String,
    dir: j['dir'] as bool? ?? false,
    size: (j['size'] as num?)?.toInt() ?? 0,
    modified: (j['modified'] as num?)?.toInt() ?? 0,
    type: j['type'] as String? ?? 'other',
  );
}

class DriveListing {
  const DriveListing({required this.drive, required this.path, required this.entries});

  final String drive;
  final String path;
  final List<DriveEntry> entries;

  factory DriveListing.fromJson(Map<String, dynamic> j) => DriveListing(
    drive: j['drive'] as String,
    path: j['path'] as String? ?? '/',
    entries: [for (final e in j['entries'] as List? ?? const []) DriveEntry.fromJson(e as Map<String, dynamic>)],
  );
}

class DriveTestResult {
  const DriveTestResult({required this.ok, this.message = '', this.entries = 0});

  final bool ok;
  final String message;
  final int entries;

  factory DriveTestResult.fromJson(Map<String, dynamic> j) =>
      DriveTestResult(ok: j['ok'] as bool? ?? false, message: j['message'] as String? ?? '', entries: (j['entries'] as num?)?.toInt() ?? 0);
}

/// `/api/v1/drives`. For a change, fields left out stay as they are; an empty password or token removes it.
extension DriveApi on EngineClient {
  Future<List<DriveInfo>> drives() async => [for (final d in await send('GET', 'drives') as List) DriveInfo.fromJson(d as Map<String, dynamic>)];

  Future<DriveInfo> addDrive(Map<String, Object?> fields) async => DriveInfo.fromJson(await send('POST', 'drives', body: fields) as Map<String, dynamic>);

  Future<DriveInfo> updateDrive(String id, Map<String, Object?> fields) async =>
      DriveInfo.fromJson(await send('PUT', 'drives/${Uri.encodeComponent(id)}', body: fields) as Map<String, dynamic>);

  Future<void> removeDrive(String id) => send('DELETE', 'drives/${Uri.encodeComponent(id)}');

  /// Whether the drive [fields] describe can be read; with `id`, the saved drive's password and token fill in.
  Future<DriveTestResult> testDrive(Map<String, Object?> fields) async =>
      DriveTestResult.fromJson(await send('POST', 'drives/test', body: fields) as Map<String, dynamic>);

  Future<DriveListing> driveFolder(String id, String path) async =>
      DriveListing.fromJson(await send('GET', 'drives/${Uri.encodeComponent(id)}/list', query: {'path': path}) as Map<String, dynamic>);

  /// An AList folder's password; the engine keeps it once AList takes it.
  Future<DriveListing> unlockDriveFolder(String id, String path, String password) async => DriveListing.fromJson(
    await send('POST', 'drives/${Uri.encodeComponent(id)}/unlock', body: {'path': path, 'password': password}) as Map<String, dynamic>,
  );

  /// A folder as a video: its video files are the episodes of one line (what the player walks through).
  Future<VodDetail> driveDetail(String id, String path) async =>
      VodDetail.fromJson(await send('GET', 'drives/${Uri.encodeComponent(id)}/detail', query: {'path': path}) as Map<String, dynamic>);
}

/// Names compared the way people number episodes: runs of digits by value ("第2集" before "第10集"), the rest
/// without regard to case. The engine orders episodes the same way.
int naturalCompare(String a, String b) {
  var i = 0;
  var j = 0;
  bool digit(int c) => c >= 0x30 && c <= 0x39;
  while (i < a.length && j < b.length) {
    final ca = a.codeUnitAt(i);
    final cb = b.codeUnitAt(j);
    if (digit(ca) && digit(cb)) {
      var ei = i;
      while (ei < a.length && digit(a.codeUnitAt(ei))) {
        ei++;
      }
      var ej = j;
      while (ej < b.length && digit(b.codeUnitAt(ej))) {
        ej++;
      }
      final na = a.substring(i, ei).replaceFirst(RegExp(r'^0+'), '');
      final nb = b.substring(j, ej).replaceFirst(RegExp(r'^0+'), '');
      if (na.length != nb.length) return na.length - nb.length;
      final c = na.compareTo(nb);
      if (c != 0) return c;
      i = ei;
      j = ej;
    } else {
      final c = a[i].toLowerCase().compareTo(b[j].toLowerCase());
      if (c != 0) return c;
      i++;
      j++;
    }
  }
  return (a.length - i) - (b.length - j);
}

/// `1.2 GB`, `340 MB`; empty for 0.
String sizeLabel(int size) {
  if (size <= 0) return '';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = size.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = value >= 100 || unit == 0 ? value.round().toString() : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}
