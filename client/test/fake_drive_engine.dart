import 'dart:convert';

import 'package:http/http.dart' as http;

import 'fake_engine.dart';

/// The fake engine with drives (`/api/v1/drives`, `drive:` sites in `/play/resolve` and the history); everything
/// else goes to [fakeEngine].
///
/// Drive `d1` (「家里的 AList」) has 剧集/ with three episodes and a subtitle, 私密/ (password `pw`), a film and a
/// text file. What the app sends ends up in [posted], [resolved] and [savedHistory].
class FakeDriveEngine extends http.BaseClient {
  FakeDriveEngine({List<Map<String, dynamic>> history = const []}) {
    for (final h in history) {
      _history['${h['site']}|${h['vodId']}'] = h;
    }
  }

  final http.Client _inner = fakeEngine(hasConfig: true);

  final drives = <Map<String, dynamic>>[
    {'id': 'd1', 'name': '家里的 AList', 'kind': 'alist', 'url': 'http://192.168.1.2:5244', 'username': 'me', 'hasPassword': true, 'hasToken': false, 'root': '/', 'proxy': false, 'lockedFolders': <String>[], 'site': 'drive:d1'},
  ];

  /// Folder -> entries, of drive d1.
  final folders = <String, List<Map<String, dynamic>>>{
    '/': [
      {'name': '剧集', 'path': '/剧集', 'dir': true, 'size': 0, 'modified': 1700000000000, 'type': 'folder'},
      {'name': '私密', 'path': '/私密', 'dir': true, 'size': 0, 'modified': 1600000000000, 'type': 'folder'},
      {'name': '大电影.mkv', 'path': '/大电影.mkv', 'dir': false, 'size': 3000000000, 'modified': 1500000000000, 'type': 'video'},
      {'name': '小短片.mp4', 'path': '/小短片.mp4', 'dir': false, 'size': 1000000, 'modified': 1800000000000, 'type': 'video'},
      {'name': '说明.txt', 'path': '/说明.txt', 'dir': false, 'size': 100, 'modified': 1400000000000, 'type': 'other'},
    ],
    '/剧集': [
      {'name': '第10集.mp4', 'path': '/剧集/第10集.mp4', 'dir': false, 'size': 300, 'modified': 3, 'type': 'video'},
      {'name': '第1集.mp4', 'path': '/剧集/第1集.mp4', 'dir': false, 'size': 100, 'modified': 1, 'type': 'video'},
      {'name': '第1集.srt', 'path': '/剧集/第1集.srt', 'dir': false, 'size': 10, 'modified': 1, 'type': 'subtitle'},
      {'name': '第2集.mp4', 'path': '/剧集/第2集.mp4', 'dir': false, 'size': 200, 'modified': 2, 'type': 'video'},
    ],
    '/私密': [
      {'name': '秘密.mp4', 'path': '/私密/秘密.mp4', 'dir': false, 'size': 1, 'modified': 1, 'type': 'video'},
    ],
  };

  bool unlocked = false;
  final posted = <Map<String, dynamic>>[];
  final resolved = <String>[];
  final savedHistory = <Map<String, dynamic>>[];
  final _history = <String, Map<String, dynamic>>{};

  http.StreamedResponse _json(Object body, [int status = 200]) =>
      http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(body))), status, headers: {'content-type': 'application/json; charset=utf-8'});

  http.StreamedResponse _error(String code, String message, int status) => _json({
    'error': {'code': code, 'message': message},
  }, status);

  /// The folder as the engine's detail: its videos in name order, ids their paths.
  Map<String, dynamic> _detail(String site, String path) {
    final names = {'/': '家里的 AList'};
    final videos = (folders[path] ?? const []).where((e) => e['type'] == 'video').toList()
      ..sort((a, b) => _natural(a['name'] as String).compareTo(_natural(b['name'] as String)));
    return {
      'site': site,
      'id': path,
      'name': names[path] ?? path.split('/').last,
      'lines': [
        {
          'name': '家里的 AList',
          'episodes': [for (final v in videos) {'id': v['path'], 'name': (v['name'] as String).split('.').first}],
        },
      ],
    };
  }

  /// Good enough for the names here: the number in them, zero-padded.
  static String _natural(String s) => s.replaceAllMapped(RegExp(r'\d+'), (m) => m[0]!.padLeft(6, '0'));

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final segments = request.url.pathSegments;
    final body = request is http.Request && request.body.isNotEmpty ? jsonDecode(request.body) : null;
    final q = request.url.queryParameters;

    if (segments.length >= 3 && segments[2] == 'drives') {
      final rest = segments.sublist(3);
      switch ((request.method, rest)) {
        case ('GET', []):
          return _json(drives);
        case ('POST', []):
          posted.add(body as Map<String, dynamic>);
          final id = 'd${drives.length + 1}';
          final drive = {
            'id': id,
            'name': (body['name'] as String?)?.isNotEmpty == true ? body['name'] : Uri.parse(body['url'] as String).host,
            'kind': body['kind'],
            'url': body['url'],
            'username': body['username'] ?? '',
            'hasPassword': (body['password'] as String? ?? '').isNotEmpty,
            'hasToken': (body['token'] as String? ?? '').isNotEmpty,
            'root': body['root'] ?? '/',
            'proxy': body['proxy'] ?? false,
            'lockedFolders': <String>[],
            'site': 'drive:$id',
          };
          drives.add(drive);
          return _json(drive, 201);
        case ('POST', ['test']):
          posted.add(body as Map<String, dynamic>);
          return _json({'ok': true, 'message': '连接成功，有 5 项', 'entries': 5});
        case ('PUT', [final id]):
          posted.add(body as Map<String, dynamic>);
          final drive = drives.firstWhere((d) => d['id'] == id);
          drive['name'] = body['name'];
          return _json(drive);
        case ('DELETE', [final id]):
          drives.removeWhere((d) => d['id'] == id);
          return http.StreamedResponse(const Stream.empty(), 204);
        case ('GET', [_, 'list']):
          final path = q['path'] ?? '/';
          if (path.startsWith('/私密') && !unlocked) return _error('DRIVE_PASSWORD', '这个文件夹需要密码：/私密', 403);
          final entries = folders[path];
          if (entries == null) return _error('NOT_FOUND', '文件夹不存在：$path', 404);
          return _json({'drive': rest[0], 'path': path, 'entries': entries});
        case ('POST', [_, 'unlock']):
          if ((body as Map<String, dynamic>)['password'] != 'pw') return _error('DRIVE_PASSWORD', '文件夹密码不对：/私密', 403);
          unlocked = true;
          return _json({'drive': rest[0], 'path': body['path'], 'entries': folders[body['path']]});
        case ('GET', [final id, 'detail']):
          return _json(_detail('drive:$id', q['path'] ?? '/'));
      }
      return _error('NOT_FOUND', request.url.path, 404);
    }

    // The history of drive folders (site keys "drive:..."); the list has only those.
    if (request.method == 'GET' && request.url.path == '/api/v1/history') return _json(_history.values.toList());
    if (segments.length == 5 && segments[2] == 'history' && segments[3].startsWith('drive:')) {
      final key = '${segments[3]}|${segments[4]}';
      switch (request.method) {
        case 'GET':
          final h = _history[key];
          return h == null ? _error('NOT_FOUND', 'none', 404) : _json(h);
        case 'PUT':
          final entry = {...body as Map<String, dynamic>, 'site': segments[3], 'vodId': segments[4]};
          _history[key] = entry;
          savedHistory.add(entry);
          return _json(entry);
      }
    }

    if (request.method == 'POST' && request.url.path == '/api/v1/play/resolve' && (body as Map<String, dynamic>)['site'].toString().startsWith('drive:')) {
      final file = body['episodeId'] as String;
      resolved.add(file);
      return _json({'kind': 'direct', 'url': 'http://127.0.0.1:9978/drive/d1${Uri.encodeFull(file)}', 'headers': <String, String>{}, 'subtitles': <Object>[]});
    }
    if (request.method == 'GET' && segments.length == 5 && segments[2] == 'sites' && segments[3].startsWith('drive:')) {
      return _json(_detail(segments[3], q['id'] ?? '/'));
    }

    // fakeEngine reads the request again: hand it a fresh copy.
    final copy = http.Request(request.method, request.url)..headers.addAll(request.headers);
    if (request is http.Request) copy.bodyBytes = request.bodyBytes;
    return _inner.send(copy);
  }
}
