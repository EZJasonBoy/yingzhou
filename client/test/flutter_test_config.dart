import 'dart:async';

import 'package:tvbox_client/ui/form_factor.dart';

/// Every widget test runs as on a desktop unless it says otherwise. flutter_test reports the platform as Android,
/// which would give every test the phone and tablet layout; the tests written for the desktop keep testing that.
/// A test of another form factor sets [FormFactors.debugOverride] and puts [FormFactor.desktop] back in tearDown.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  FormFactors.debugOverride = FormFactor.desktop;
  await testMain();
}
