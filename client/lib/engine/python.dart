// Python spiders: the engine's 「Python 蜘蛛」 settings (docs/protocol.md, "Python 蜘蛛").

import 'engine_client.dart';

/// The Python the engine uses.
class PythonFound {
  const PythonFound({required this.path, required this.version, required this.source, this.pip = false});

  final String path;
  final String version;

  /// custom (set by the user) | env (TVBOX_PYTHON) | system (found on the machine) | downloaded (by the engine).
  final String source;
  final bool pip;

  String get sourceLabel => switch (source) {
    'custom' => '指定的 Python',
    'env' => 'TVBOX_PYTHON 指定的 Python',
    'downloaded' => '下载的运行时',
    _ => '本机的 Python',
  };

  factory PythonFound.fromJson(Map<String, dynamic> j) => PythonFound(
    path: j['path'] as String? ?? '',
    version: j['version'] as String? ?? '',
    source: j['source'] as String? ?? 'system',
    pip: j['pip'] as bool? ?? false,
  );
}

class PythonSettingsData {
  const PythonSettingsData({this.path = '', this.indexUrl = '', this.downloadMirror = ''});

  final String path;
  final String indexUrl;
  final String downloadMirror;

  factory PythonSettingsData.fromJson(Map<String, dynamic> j) =>
      PythonSettingsData(path: j['path'] as String? ?? '', indexUrl: j['indexUrl'] as String? ?? '', downloadMirror: j['downloadMirror'] as String? ?? '');
}

class PythonPackageState {
  const PythonPackageState({required this.name, required this.module, required this.installed, this.where = ''});

  final String name;
  final String module;
  final bool installed;

  /// engine (the engine's folder) | python (the Python's own) | '' (not installed).
  final String where;

  factory PythonPackageState.fromJson(Map<String, dynamic> j) => PythonPackageState(
    name: j['name'] as String,
    module: j['module'] as String? ?? '',
    installed: j['installed'] as bool? ?? false,
    where: j['where'] as String? ?? '',
  );
}

/// A module a spider asked for and did not find.
class PythonMissing {
  const PythonMissing({required this.module, required this.packageName, this.site = ''});

  final String module;
  final String packageName;
  final String site;

  factory PythonMissing.fromJson(Map<String, dynamic> j) =>
      PythonMissing(module: j['module'] as String, packageName: j['packageName'] as String? ?? j['module'] as String, site: j['site'] as String? ?? '');
}

/// The CPython the engine can download (Windows).
class PythonDownloadOffer {
  const PythonDownloadOffer({required this.version, required this.url, required this.sizeBytes, this.dir = '', this.installed = false});

  final String version;
  final String url;
  final int sizeBytes;
  final String dir;
  final bool installed;

  /// Where it comes from, for the confirmation: the host of [url].
  String get host => Uri.tryParse(url)?.host ?? url;

  factory PythonDownloadOffer.fromJson(Map<String, dynamic> j) => PythonDownloadOffer(
    version: j['version'] as String? ?? '',
    url: j['url'] as String? ?? '',
    sizeBytes: (j['sizeBytes'] as num?)?.toInt() ?? 0,
    dir: j['dir'] as String? ?? '',
    installed: j['installed'] as bool? ?? false,
  );
}

/// A download or package installation (running or the last one).
class PythonTaskState {
  const PythonTaskState({required this.kind, required this.state, this.message = '', this.progress = -1, this.log = const []});

  /// download | install
  final String kind;

  /// running | done | failed
  final String state;
  final String message;

  /// 0..1, or negative when unknown.
  final double progress;
  final List<String> log;

  bool get running => state == 'running';

  factory PythonTaskState.fromJson(Map<String, dynamic> j) => PythonTaskState(
    kind: j['kind'] as String? ?? '',
    state: j['state'] as String? ?? '',
    message: j['message'] as String? ?? '',
    progress: (j['progress'] as num?)?.toDouble() ?? -1,
    log: (j['log'] as List<dynamic>? ?? const []).map((e) => e as String).toList(),
  );
}

/// `GET /api/v1/python`.
class PythonStatus {
  const PythonStatus({
    this.supported = true,
    this.available = false,
    this.python,
    this.problem = '',
    this.settings = const PythonSettingsData(),
    this.packagesDir = '',
    this.packages = const [],
    this.missing = const [],
    this.download,
    this.task,
  });

  final bool supported;
  final bool available;
  final PythonFound? python;
  final String problem;
  final PythonSettingsData settings;
  final String packagesDir;
  final List<PythonPackageState> packages;
  final List<PythonMissing> missing;
  final PythonDownloadOffer? download;
  final PythonTaskState? task;

  List<PythonPackageState> get notInstalled => [
    for (final p in packages)
      if (!p.installed) p,
  ];

  factory PythonStatus.fromJson(Map<String, dynamic> j) => PythonStatus(
    supported: j['supported'] as bool? ?? true,
    available: j['available'] as bool? ?? false,
    python: j['python'] == null ? null : PythonFound.fromJson(j['python'] as Map<String, dynamic>),
    problem: j['problem'] as String? ?? '',
    settings: j['settings'] == null ? const PythonSettingsData() : PythonSettingsData.fromJson(j['settings'] as Map<String, dynamic>),
    packagesDir: j['packagesDir'] as String? ?? '',
    packages: (j['packages'] as List<dynamic>? ?? const []).map((e) => PythonPackageState.fromJson(e as Map<String, dynamic>)).toList(),
    missing: (j['missing'] as List<dynamic>? ?? const []).map((e) => PythonMissing.fromJson(e as Map<String, dynamic>)).toList(),
    download: j['download'] == null ? null : PythonDownloadOffer.fromJson(j['download'] as Map<String, dynamic>),
    task: j['task'] == null ? null : PythonTaskState.fromJson(j['task'] as Map<String, dynamic>),
  );
}

extension PythonApi on EngineClient {
  Future<PythonStatus> pythonStatus({bool refresh = false}) async =>
      PythonStatus.fromJson(await send('GET', 'python', query: refresh ? {'refresh': '1'} : null) as Map<String, dynamic>);

  /// Fields left null stay as they are.
  Future<PythonStatus> updatePython({String? path, String? indexUrl, String? downloadMirror}) async => PythonStatus.fromJson(
    await send('PUT', 'python', body: {'path': ?path, 'indexUrl': ?indexUrl, 'downloadMirror': ?downloadMirror}) as Map<String, dynamic>,
  );

  Future<PythonStatus> downloadPython() async => PythonStatus.fromJson(await send('POST', 'python/download') as Map<String, dynamic>);

  Future<PythonStatus> removeDownloadedPython() async => PythonStatus.fromJson(await send('DELETE', 'python/download') as Map<String, dynamic>);

  /// Empty: the common packages.
  Future<PythonStatus> installPythonPackages([List<String> packages = const []]) async =>
      PythonStatus.fromJson(await send('POST', 'python/packages', body: {'packages': packages}) as Map<String, dynamic>);
}
