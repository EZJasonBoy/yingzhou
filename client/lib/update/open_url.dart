import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/services.dart';

/// Opens [url] in the system's browser; false when there is none to open it with (a TV box without a browser).
Future<bool> openInBrowser(String url) async {
  try {
    if (Platform.isAndroid) {
      // client/android/.../DeviceChannel.kt
      return await const MethodChannel('yingzhou/device').invokeMethod<bool>('openUrl', {'url': url}) ?? false;
    }
    final ProcessResult result;
    if (Platform.isWindows) {
      // Not `cmd /c start`, which would cut the address at an `&`.
      result = await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
    } else if (Platform.isMacOS) {
      result = await Process.run('open', [url]);
    } else {
      result = await Process.run('xdg-open', [url]);
    }
    return result.exitCode == 0;
  } on Object {
    return false;
  }
}

/// Shows [path] in the system's file manager.
Future<void> revealFile(String path) async {
  try {
    if (Platform.isWindows) {
      await Process.run('explorer.exe', ['/select,', path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    } else {
      await Process.run('xdg-open', [File(path).parent.path]);
    }
  } on Object {
    // Nothing to open it with; the dialog shows the path.
  }
}

/// `Platform.operatingSystem` and `Abi.current()` as [assetKeysFor] takes them, and whether this Windows copy was
/// installed (Inno Setup leaves its uninstaller next to the program) rather than unzipped.
({String os, String abi, bool installed}) currentMachine() {
  var installed = true;
  if (Platform.isWindows) {
    try {
      installed = File('${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}unins000.exe').existsSync();
    } on Object {
      installed = true;
    }
  }
  return (os: Platform.operatingSystem, abi: Abi.current().toString(), installed: installed);
}

/// Downloads are saved in the app here (desktop); Android leaves them to the browser.
bool get downloadsInApp => Platform.isWindows || Platform.isMacOS || Platform.isLinux;
