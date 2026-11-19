// The engine's downloads for offline viewing (docs/protocol.md, "离线下载").

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'engine_client.dart';
import 'models.dart';

/// One episode in the engine's download list.
class DownloadItem {
  const DownloadItem({
    required this.id,
    required this.site,
    required this.line,
    required this.episodeId,
    required this.state,
    this.vodId = '',
    this.title = '',
    this.pic = '',
    this.episodeName = '',
    this.episodeIndex = -1,
    this.kind = '',
    this.bytes = 0,
    this.totalBytes = -1,
    this.progress = 0,
    this.speed = 0,
    this.partsDone = 0,
    this.parts = 0,
    this.durationMs = 0,
    this.error = '',
    this.createdAt = 0,
    this.finishedAt = 0,
  });

  final String id;
  final String site;
  final String line;
  final String episodeId;
  final String vodId;
  final String title;
  final String pic;
  final String episodeName;
  final int episodeIndex;

  /// queued | running | paused | done | failed
  final String state;

  /// "" until resolved; hls | file.
  final String kind;
  final int bytes;
  final int totalBytes;
  final double progress;

  /// Bytes a second; 0 when not running.
  final int speed;
  final int partsDone;
  final int parts;
  final int durationMs;
  final String error;
  final int createdAt;
  final int finishedAt;

  bool get done => state == 'done';
  bool get running => state == 'running';
  bool get queued => state == 'queued';
  bool get paused => state == 'paused';
  bool get failed => state == 'failed';

  /// Waiting or under way: something will still happen to it by itself.
  bool get active => running || queued;

  factory DownloadItem.fromJson(Map<String, dynamic> j) => DownloadItem(
    id: j['id'] as String,
    site: j['site'] as String? ?? '',
    line: j['line'] as String? ?? '',
    episodeId: j['episodeId'] as String? ?? '',
    vodId: j['vodId'] as String? ?? '',
    title: j['title'] as String? ?? '',
    pic: j['pic'] as String? ?? '',
    episodeName: j['episodeName'] as String? ?? '',
    episodeIndex: (j['episodeIndex'] as num?)?.toInt() ?? -1,
    state: j['state'] as String? ?? 'queued',
    kind: j['kind'] as String? ?? '',
    bytes: (j['bytes'] as num?)?.toInt() ?? 0,
    totalBytes: (j['totalBytes'] as num?)?.toInt() ?? -1,
    progress: (j['progress'] as num?)?.toDouble() ?? 0,
    speed: (j['speed'] as num?)?.toInt() ?? 0,
    partsDone: (j['partsDone'] as num?)?.toInt() ?? 0,
    parts: (j['parts'] as num?)?.toInt() ?? 0,
    durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
    error: j['error'] as String? ?? '',
    createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
    finishedAt: (j['finishedAt'] as num?)?.toInt() ?? 0,
  );
}

/// An episode to download: what `/play/resolve` takes, and what the list shows.
class DownloadRequest {
  const DownloadRequest({
    required this.site,
    required this.line,
    required this.episodeId,
    this.vodId = '',
    this.title = '',
    this.pic = '',
    this.episodeName = '',
    this.episodeIndex = -1,
  });

  final String site;
  final String line;
  final String episodeId;
  final String vodId;
  final String title;
  final String pic;
  final String episodeName;
  final int episodeIndex;

  Map<String, Object> toJson() => {
    'site': site,
    'line': line,
    'episodeId': episodeId,
    'vodId': vodId,
    'title': title,
    'pic': pic,
    'episodeName': episodeName,
    'episodeIndex': episodeIndex,
  };
}

/// `GET /api/v1/downloads/settings`.
class DownloadSettingsInfo {
  const DownloadSettingsInfo({
    required this.available,
    this.dir = '',
    this.path = '',
    this.defaultPath = '',
    this.concurrency = 2,
    this.maxConcurrency = 5,
    this.freeBytes = -1,
    this.reserveBytes = 0,
    this.bytes = 0,
    this.locations = const [],
  });

  final bool available;

  /// What the user chose; empty for the default.
  final String dir;

  /// Where new downloads go, on the engine's machine.
  final String path;
  final String defaultPath;
  final int concurrency;
  final int maxConcurrency;
  final int freeBytes;
  final int reserveBytes;

  /// Everything downloaded.
  final int bytes;

  /// The folders to choose from where no other folder can be written (an Android engine: internal storage, SD
  /// cards, USB drives). Empty: any folder of the engine's machine can be typed in.
  final List<DownloadLocation> locations;

  factory DownloadSettingsInfo.fromJson(Map<String, dynamic> j) => DownloadSettingsInfo(
    available: j['available'] as bool? ?? false,
    dir: j['dir'] as String? ?? '',
    path: j['path'] as String? ?? '',
    defaultPath: j['defaultPath'] as String? ?? '',
    concurrency: (j['concurrency'] as num?)?.toInt() ?? 2,
    maxConcurrency: (j['maxConcurrency'] as num?)?.toInt() ?? 5,
    freeBytes: (j['freeBytes'] as num?)?.toInt() ?? -1,
    reserveBytes: (j['reserveBytes'] as num?)?.toInt() ?? 0,
    bytes: (j['bytes'] as num?)?.toInt() ?? 0,
    locations: [for (final l in j['locations'] as List? ?? const []) DownloadLocation.fromJson(l as Map<String, dynamic>)],
  );
}

/// A folder an engine offers for downloads (`DownloadSettingsInfo.locations`).
class DownloadLocation {
  const DownloadLocation({required this.name, required this.dir, required this.path, this.freeBytes = -1, this.totalBytes = -1, this.removable = false});

  /// For people: 内部存储, SD 卡…
  final String name;

  /// What to send as the downloads folder; empty for the default.
  final String dir;
  final String path;
  final int freeBytes;
  final int totalBytes;

  /// An SD card or USB drive: its downloads are gone while it is out.
  final bool removable;

  factory DownloadLocation.fromJson(Map<String, dynamic> j) => DownloadLocation(
    name: j['name'] as String? ?? '',
    dir: j['dir'] as String? ?? '',
    path: j['path'] as String? ?? '',
    freeBytes: (j['freeBytes'] as num?)?.toInt() ?? -1,
    totalBytes: (j['totalBytes'] as num?)?.toInt() ?? -1,
    removable: j['removable'] as bool? ?? false,
  );
}

/// What `POST /api/v1/downloads/{id}/export` wrote.
class DownloadExportResult {
  const DownloadExportResult({required this.path, required this.bytes, required this.format, this.uri = ''});

  /// On the engine's machine (Android: where people find it, e.g. `Download/映舟/…`).
  final String path;
  final int bytes;
  final String format;

  /// Android: a `content://` address of the file for the share sheet; empty elsewhere.
  final String uri;

  factory DownloadExportResult.fromJson(Map<String, dynamic> j) => DownloadExportResult(
    path: j['path'] as String? ?? '',
    bytes: (j['bytes'] as num?)?.toInt() ?? 0,
    format: j['format'] as String? ?? '',
    uri: j['uri'] as String? ?? '',
  );
}

/// The downloads part of the engine's API.
extension DownloadsApi on EngineClient {
  /// Whether the engine downloads at all (engines before 0.2.0 do not), and its list.
  Future<(bool, List<DownloadItem>)> downloads() async {
    final j = await send('GET', 'downloads') as Map<String, dynamic>;
    return (j['available'] as bool? ?? false, [for (final i in j['items'] as List? ?? const []) DownloadItem.fromJson(i as Map<String, dynamic>)]);
  }

  Future<List<DownloadItem>> addDownloads(List<DownloadRequest> items) async {
    final j = await send('POST', 'downloads', body: {'items': [for (final i in items) i.toJson()]}) as Map<String, dynamic>;
    return [for (final i in j['items'] as List? ?? const []) DownloadItem.fromJson(i as Map<String, dynamic>)];
  }

  Future<DownloadItem> pauseDownload(String id) async => DownloadItem.fromJson(await send('POST', 'downloads/${Uri.encodeComponent(id)}/pause'));

  /// Resumes a paused download, or tries a failed one again.
  Future<DownloadItem> resumeDownload(String id) async => DownloadItem.fromJson(await send('POST', 'downloads/${Uri.encodeComponent(id)}/resume'));

  Future<void> deleteDownload(String id) => send('DELETE', 'downloads/${Uri.encodeComponent(id)}');

  /// Writes the download as one file on the engine's machine: into [path] (a folder or a file), or its default folder.
  Future<DownloadExportResult> exportDownload(String id, {String path = ''}) async =>
      DownloadExportResult.fromJson(await send('POST', 'downloads/${Uri.encodeComponent(id)}/export', body: {'path': path}));

  Future<DownloadSettingsInfo> downloadSettings() async => DownloadSettingsInfo.fromJson(await send('GET', 'downloads/settings'));

  Future<DownloadSettingsInfo> updateDownloadSettings({String? dir, int? concurrency}) async =>
      DownloadSettingsInfo.fromJson(await send('PUT', 'downloads/settings', body: {'dir': ?dir, 'concurrency': ?concurrency}));

  /// The download as one file, streamed by the engine (for saving it on this device when the engine is another).
  Uri downloadExportUri(String id) => baseUrl.resolve('/dl/${Uri.encodeComponent(id)}/export');

  /// Whether the engine runs on this machine (then exports are written by the engine itself).
  bool get isLocalEngine => baseUrl.host == '127.0.0.1' || baseUrl.host == 'localhost';

  /// The export request for download [id], with this client's token (an engine on another device wants it).
  http.Request exportRequest(String id) {
    final request = http.Request('GET', downloadExportUri(id));
    final t = token;
    if (t != null && t.isNotEmpty) request.headers['Authorization'] = 'Bearer $t';
    return request;
  }
}

/// The engine's download list, kept up to date while someone looks at it: asked again every second while something
/// is queued or running, and every few seconds otherwise. Listeners hear of it only when something changed.
class DownloadsWatcher extends ChangeNotifier {
  DownloadsWatcher(this.client, {this.busyEvery = const Duration(seconds: 1), this.idleEvery = const Duration(seconds: 5)});

  final EngineClient client;
  final Duration busyEvery;
  final Duration idleEvery;

  /// Null until the engine has answered.
  bool? available;
  List<DownloadItem> items = const [];
  String? error;

  Timer? _timer;
  bool _disposed = false;
  bool _loading = false;
  String _seen = '';

  void start() => refresh();

  /// The download of an episode, if it is in the list.
  DownloadItem? find(String site, String line, String episodeId) {
    for (final i in items) {
      if (i.site == site && i.line == line && i.episodeId == episodeId) return i;
    }
    return null;
  }

  Future<void> refresh() async {
    if (_disposed || _loading) return;
    _loading = true;
    _timer?.cancel();
    try {
      final (ok, list) = await client.downloads();
      if (_disposed) return;
      final seen = '$ok|${list.map((i) => '${i.id}:${i.state}:${i.bytes}:${i.speed}:${i.partsDone}:${i.error}').join(',')}';
      error = null;
      if (seen != _seen || available != ok) {
        _seen = seen;
        available = ok;
        items = list;
        notifyListeners();
      }
    } on EngineException catch (e) {
      if (_disposed) return;
      // An engine from before downloads answers 404: it has none.
      if (e.statusCode == 404) {
        if (available != false) {
          available = false;
          notifyListeners();
        }
      } else if (error != e.message) {
        error = e.message;
        notifyListeners();
      }
    } on StateError {
      return;
    } finally {
      _loading = false;
      if (!_disposed && available != false) _timer = Timer(items.any((i) => i.active) ? busyEvery : idleEvery, refresh);
    }
  }

  /// Something was asked of the engine: shows its answer and looks again soon.
  void changed(Iterable<DownloadItem> answer) {
    final byId = {for (final i in answer) i.id: i};
    final known = items.map((i) => i.id).toSet();
    items = [for (final i in items) byId[i.id] ?? i, for (final i in answer) if (!known.contains(i.id)) i];
    _seen = '';
    notifyListeners();
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 300), refresh);
  }

  void removed(String id) {
    items = [for (final i in items) if (i.id != id) i];
    _seen = '';
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// Bytes as people read them: 900 KB, 12.3 MB, 1.4 GB.
String formatBytes(num bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  final mb = bytes / (1024 * 1024);
  if (mb < 1000) return '${mb < 10 ? mb.toStringAsFixed(1) : mb.round()} MB';
  return '${(mb / 1024).toStringAsFixed(1)} GB';
}

/// What a download's state reads as, short: 排队中, 42%, 已暂停, 已下载, 失败.
String downloadBadge(DownloadItem d) => switch (d.state) {
  'done' => '已下载',
  'running' => '${(d.progress * 100).floor()}%',
  'queued' => '排队中',
  'paused' => '已暂停',
  'failed' => '失败',
  _ => d.state,
};
