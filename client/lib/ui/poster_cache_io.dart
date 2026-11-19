import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'poster_cache.dart';

Future<PosterCache?> openPosterCache(int maxBytes) async {
  try {
    final base = await getApplicationCacheDirectory();
    return _DiskPosterCache(Directory('${base.path}${Platform.pathSeparator}posters'), maxBytes, null);
  } catch (_) {
    return null;
  }
}

PosterCache? posterCacheAt(String path, int maxBytes, Future<Uint8List> Function(Uri url, Map<String, String> headers)? fetch) =>
    _DiskPosterCache(Directory(path), maxBytes, fetch);

class _DiskPosterCache implements PosterCache {
  _DiskPosterCache(this._dir, this._maxBytes, Future<Uint8List> Function(Uri url, Map<String, String> headers)? fetch) : _fetch = fetch ?? _download;

  final Directory _dir;
  final int _maxBytes;
  final Future<Uint8List> Function(Uri url, Map<String, String> headers) _fetch;

  /// One download per image, however many widgets ask for it at once.
  final _loading = <String, Future<Uint8List>>{};
  int _written = 0;
  bool _trimmed = false;

  static final _client = http.Client();

  static Future<Uint8List> _download(Uri url, Map<String, String> headers) async {
    final response = await _client.get(url, headers: headers).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) throw HttpException('HTTP ${response.statusCode}', uri: url);
    return response.bodyBytes;
  }

  /// FNV-1a over the url, twice with different seeds: a stable 128-bit file name without a crypto dependency.
  static String _name(String url) {
    String half(int seed) {
      var h = seed;
      for (final b in utf8.encode(url)) {
        h = ((h ^ b) * 0x100000001b3) & 0x7fffffffffffffff;
      }
      return h.toRadixString(16).padLeft(16, '0');
    }

    return half(0x4bf29ce484222325) + half(0x2f29ce484222325b);
  }

  File _file(String url) => File('${_dir.path}${Platform.pathSeparator}${_name(url)}');

  @override
  Future<Uint8List> load(String url, {Map<String, String>? headers}) => _loading[url] ??= _load(url, headers ?? const {}).whenComplete(() {
    // A block, not an arrow: whenComplete would wait for the future remove() returns, which is this very one.
    _loading.remove(url);
  });

  Future<Uint8List> _load(String url, Map<String, String> headers) async {
    final file = _file(url);
    try {
      final bytes = await file.readAsBytes();
      if (bytes.isNotEmpty) {
        // "Used now", for trimming; not worth waiting for.
        file.setLastModified(DateTime.now()).ignore();
        return bytes;
      }
    } on FileSystemException {
      // Not kept yet.
    }
    final bytes = await _fetch(Uri.parse(url), headers);
    if (bytes.isEmpty) throw const FormatException('empty image');
    try {
      await _dir.create(recursive: true);
      // Written beside and renamed: a crash never leaves half an image under the real name.
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: false);
      await tmp.rename(file.path);
      _written += bytes.length;
      if (!_trimmed || _written > _maxBytes ~/ 10) _trim().ignore();
    } on FileSystemException {
      // A full or read-only disk: the image is shown all the same.
    }
    return bytes;
  }

  Future<List<FileSystemEntity>> _files() async {
    try {
      return await _dir.list().where((e) => e is File).toList();
    } on FileSystemException {
      return const [];
    }
  }

  Future<void> _trim() async {
    _trimmed = true;
    _written = 0;
    final stats = <(File, FileStat)>[];
    for (final f in await _files()) {
      stats.add((f as File, await f.stat()));
    }
    var total = stats.fold<int>(0, (sum, s) => sum + s.$2.size);
    if (total <= _maxBytes) return;
    stats.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    for (final (file, stat) in stats) {
      if (total <= _maxBytes * 8 ~/ 10) break;
      try {
        await file.delete();
        total -= stat.size;
      } on FileSystemException {
        // In use; next time.
      }
    }
  }

  @override
  Future<int> size() async {
    var total = 0;
    for (final f in await _files()) {
      try {
        total += await (f as File).length();
      } on FileSystemException {
        // Deleted meanwhile.
      }
    }
    return total;
  }

  @override
  Future<void> clear() async {
    for (final f in await _files()) {
      try {
        await f.delete();
      } on FileSystemException {
        // In use.
      }
    }
  }
}
