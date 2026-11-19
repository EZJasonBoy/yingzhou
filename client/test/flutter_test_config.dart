import 'dart:async';

import 'package:tvbox_client/ui/device_form.dart';

/// Every widget test runs as on a desktop unless it puts a [DeviceFormScope] above what it pumps. flutter_test
/// reports the platform as Android, which would give every test without a scope the phone and tablet layout; the
/// tests written for the desktop keep testing that.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  DeviceFormScope.debugFormWithoutScope = DeviceForm.desktop;
  await testMain();
}
