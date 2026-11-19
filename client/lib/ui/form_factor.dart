import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// What kind of device the app is on. It decides the layout and the input the pages design for: touch on phones and
/// tablets, the remote's D-pad on TVs, mouse and keyboard on desktops.
enum FormFactor { phone, tablet, tv, desktop }

/// Which [FormFactor] the app runs on, the one answer every page asks.
///
/// - Desktop: Windows, macOS, Linux.
/// - TV: Android that says it is a TV — the UI mode is television, the system has the leanback feature, or there
///   is no touchscreen (many boxes run phone Android without saying they are TVs). Asked once, in [init].
/// - Phone or tablet: any other Android or iOS device, by the size of the window: its shorter side below 600 dp is
///   a phone (Android's own tablet line). So a tablet in split screen gets the phone layout, which fits it.
///
/// `--dart-define=FORM_FACTOR=phone|tablet|tv|desktop` forces one, to try a layout on a device that is not that
/// (the TV layout on a phone emulator, the phone layout on a desktop). Widget tests set [debugOverride].
class FormFactors {
  FormFactors._();

  static const _channel = MethodChannel('yingzhou/device');
  static const _forced = String.fromEnvironment('FORM_FACTOR');

  static bool _androidTv = false;
  static bool _touchscreen = true;
  static bool _emulator = false;

  /// Tests: the form factor to pretend to be (null: the real one). Set it back to null in `tearDown`.
  static FormFactor? debugOverride;

  /// Asks the Android host whether this is a TV. Awaited in `main` before the app is built; does nothing elsewhere.
  static Future<void> init() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final info = await _channel.invokeMapMethod<String, Object?>('info');
      _androidTv = info?['tv'] == true;
      _touchscreen = info?['touchscreen'] != false;
      _emulator = info?['emulator'] == true;
    } on Object catch (e) {
      // A host without the channel (an older build, a test): a touch device.
      debugPrint('form factor: $e');
    }
  }

  static FormFactor? get _fixed => debugOverride ?? _named(_forced);

  static FormFactor? _named(String name) => switch (name) {
    'phone' => FormFactor.phone,
    'tablet' => FormFactor.tablet,
    'tv' => FormFactor.tv,
    'desktop' => FormFactor.desktop,
    _ => null,
  };

  static bool get _desktopPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.linux);

  /// An Android TV or box: remote control, 10-foot layout.
  static bool get isTv {
    final fixed = _fixed;
    if (fixed != null) return fixed == FormFactor.tv;
    return _androidTv;
  }

  /// Windows / macOS / Linux: mouse and keyboard.
  static bool get isDesktop {
    final fixed = _fixed;
    if (fixed != null) return fixed == FormFactor.desktop;
    return _desktopPlatform;
  }

  /// A phone or a tablet: touch first.
  static bool get isMobile => !isTv && !isDesktop;

  /// The device has a touchscreen (false on most TV boxes). Only what Android said; true everywhere else.
  static bool get hasTouchscreen => _touchscreen;

  /// The Android emulator (not a form factor, but asked in the same place: the player sets up its video output for it).
  static bool get isAndroidEmulator => _emulator;

  /// The form factor for laying out [context]: fixed for TVs and desktops, by the window's size on phones and tablets.
  static FormFactor of(BuildContext context) {
    final fixed = _fixed;
    if (fixed != null) return fixed;
    if (_desktopPlatform) return FormFactor.desktop;
    if (_androidTv) return FormFactor.tv;
    return MediaQuery.sizeOf(context).shortestSide < 600 ? FormFactor.phone : FormFactor.tablet;
  }

  /// A phone, in the layout sense: the window's shorter side is below 600 dp.
  static bool isPhone(BuildContext context) => of(context) == FormFactor.phone;
}
