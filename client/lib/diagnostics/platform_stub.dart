import 'package:flutter/services.dart';

/// The web build keeps no files.
Future<String?> diagnosticsDirectory() async => null;

List<String> homeFolders() => const [];

String describePlatform() => 'web';

bool get isAndroid => false;

bool get isDesktop => false;

Future<bool> openUrlOnDesktop(String url) async => false;

const androidChannel = MethodChannel('yingzhou/diagnostics');
