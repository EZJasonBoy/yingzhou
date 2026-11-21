import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// The folder for crash records and the engine log: `diagnostics` in the app's support directory
/// (`%APPDATA%\Yingzhou\Yingzhou` on Windows, `~/Library/Application Support/<bundle id>` on macOS, the app's files
/// directory on Android, which `CrashRecorder.kt` writes to as well).
Future<String?> diagnosticsDirectory() async => '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}diagnostics';

/// The user's home folder as this process sees it, to take out of what is shown.
List<String> homeFolders() {
  final env = Platform.environment;
  return [
    ?env['USERPROFILE'],
    ?env['HOME'],
    if (env['HOMEDRIVE'] != null && env['HOMEPATH'] != null) '${env['HOMEDRIVE']}${env['HOMEPATH']}',
  ].where((h) => h.length > 3).toList();
}

/// `Windows 10 Education 10.0 (Build 19045) · windows_x64`; Android asks its side for something better.
String describePlatform() {
  final version = Platform.operatingSystemVersion.replaceAll('"', '').trim();
  return '$version · ${Abi.current()}';
}

bool get isAndroid => Platform.isAndroid;

bool get isDesktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// What runs a command for [openUrlOnDesktop]: `Process.start` (tests swap it).
typedef StartProcess = Future<Process> Function(String executable, List<String> arguments);

/// Opens [url] in the default browser: `rundll32 url.dll,FileProtocolHandler` on Windows (no shell, so `&` in the
/// address stays as it is), `open` on macOS, `xdg-open` on Linux.
Future<bool> openUrlOnDesktop(String url, {StartProcess? start}) async {
  if (!url.startsWith('https://') && !url.startsWith('http://')) return false;
  // `flutter test` never opens the developer's browser.
  if (start == null && Platform.environment['FLUTTER_TEST'] == 'true') return false;
  final run = start ?? (exe, args) => Process.start(exe, args, mode: ProcessStartMode.detached);
  final (exe, args) = desktopOpenCommand(url);
  try {
    await run(exe, args);
    return true;
  } on ProcessException {
    return false;
  }
}

/// The command [openUrlOnDesktop] runs on this platform.
(String, List<String>) desktopOpenCommand(String url, {String? os}) => switch (os ?? Platform.operatingSystem) {
  'windows' => ('rundll32', ['url.dll,FileProtocolHandler', url]),
  'macos' => ('open', [url]),
  _ => ('xdg-open', [url]),
};

/// `yingzhou/diagnostics` on Android (`DiagnosticsChannel.kt`).
const androidChannel = MethodChannel('yingzhou/diagnostics');
