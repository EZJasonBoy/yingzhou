import 'dart:io';

String? _dir;
bool _looked = false;

/// The folder libmpv writes its cache files to on desktop; null elsewhere, or when it cannot be made.
///
/// libmpv deletes a cache file when its video is closed. What a crash left behind is swept away the first time the
/// folder is asked for; a file another running copy of the app has open cannot be deleted, and stays.
String? playerCacheDir() {
  if (_looked) return _dir;
  _looked = true;
  if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) return null;
  try {
    final dir = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}yingzhou-player-cache')..createSync(recursive: true);
    for (final leftover in dir.listSync()) {
      try {
        leftover.deleteSync(recursive: true);
      } on FileSystemException {
        // In use.
      }
    }
    _dir = dir.path;
  } on FileSystemException {
    _dir = null;
  }
  return _dir;
}
