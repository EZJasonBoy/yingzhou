import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../settings.dart';

/// What kind of device the app runs on, which decides the layout and how it is driven: mouse and keyboard
/// ([desktop]), touch ([phone], [tablet]) or a remote control ([tv]).
///
/// Shared by the phone / tablet layouts and the TV layout: ask [DeviceFormScope.of] (or the helpers next to it)
/// instead of looking at the platform or the window width yourself.
enum DeviceForm { desktop, phone, tablet, tv }

/// The user's choice in 设置 → 外观 → 界面模式: let the system decide, or force the remote-control or the touch layout.
/// A desktop is [DeviceForm.desktop] unless the user chose [tv] (an HTPC on the television, driven from the sofa
/// with a remote or a phone); [touch] means nothing there.
enum DeviceFormOverride { auto, tv, touch }

/// What the system says about this device. On Android it comes from `yingzhou/device` (`DeviceChannel.kt`); elsewhere
/// it is the default (no TV, a touchscreen).
@immutable
class DeviceInfo {
  const DeviceInfo({this.tvMode = false, this.leanback = false, this.touchscreen = true});

  /// `UiModeManager.getCurrentModeType()` is `UI_MODE_TYPE_TELEVISION`.
  final bool tvMode;

  /// The system has `android.software.leanback` (Android TV, Google TV, most TV boxes).
  final bool leanback;

  /// The system has `android.hardware.touchscreen`.
  final bool touchscreen;

  /// A TV as the system sees it: in television mode, or a leanback system without a touchscreen (boxes that do not
  /// report the TV mode).
  bool get isTv => tvMode || (leanback && !touchscreen);

  static const _channel = MethodChannel('yingzhou/device');

  /// Asks the Android side once at start-up; anywhere else, or when it does not answer, the default.
  static Future<DeviceInfo> load() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return const DeviceInfo();
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('info');
      if (m == null) return const DeviceInfo();
      return DeviceInfo(tvMode: m['tv'] == true, leanback: m['leanback'] == true, touchscreen: m['touchscreen'] != false);
    } on PlatformException {
      return const DeviceInfo();
    } on MissingPluginException {
      return const DeviceInfo();
    }
  }
}

/// Decides the [DeviceForm] from [DeviceInfo], the platform and the user's [DeviceFormOverride] (kept in the
/// client's settings under `ui.form`).
class DeviceFormController extends ChangeNotifier {
  DeviceFormController({this.info = const DeviceInfo(), SettingsStore? settings, TargetPlatform? platform})
    : _settings = settings,
      _platform = platform ?? defaultTargetPlatform,
      _fixed = null {
    _override = DeviceFormOverride.values.asNameMap()[settings?.getString(overrideKey) ?? ''] ?? DeviceFormOverride.auto;
  }

  /// Always [form] (tests, previews).
  DeviceFormController.fixed(DeviceForm form) : info = const DeviceInfo(), _settings = null, _platform = defaultTargetPlatform, _fixed = form;

  static const overrideKey = 'ui.form';

  final DeviceInfo info;
  final SettingsStore? _settings;
  final TargetPlatform _platform;
  final DeviceForm? _fixed;
  DeviceFormOverride _override = DeviceFormOverride.auto;

  DeviceFormOverride get override => _override;

  /// Windows, macOS, Linux (and the web build): mouse and keyboard, whatever the window size.
  bool get isDesktopPlatform => kIsWeb || _platform == TargetPlatform.windows || _platform == TargetPlatform.macOS || _platform == TargetPlatform.linux;

  /// The layout can be chosen: everywhere but in a test that fixed it. Phones, tablets and boxes choose between
  /// what the system says, the TV layout and the touch layout; desktops between the desktop and the TV layout.
  bool get canOverride => _fixed == null;

  /// Driven with a remote control.
  bool get isTv {
    final fixed = _fixed;
    if (fixed != null) return fixed == DeviceForm.tv;
    if (isDesktopPlatform) return _override == DeviceFormOverride.tv;
    return switch (_override) {
      DeviceFormOverride.tv => true,
      DeviceFormOverride.touch => false,
      DeviceFormOverride.auto => info.isTv,
    };
  }

  /// The form for a window of [size]: phone and tablet are told apart by the shorter side (600 logical pixels), so
  /// split screen and rotation are followed.
  DeviceForm formFor(Size size) {
    final fixed = _fixed;
    if (fixed != null) return fixed;
    if (isTv) return DeviceForm.tv;
    if (isDesktopPlatform) return DeviceForm.desktop;
    return size.shortestSide >= 600 ? DeviceForm.tablet : DeviceForm.phone;
  }

  Future<void> setOverride(DeviceFormOverride value) async {
    if (value == _override) return;
    _override = value;
    notifyListeners();
    await _settings?.setString(overrideKey, value.name);
  }
}

/// Makes the [DeviceFormController] available below it (main.dart puts it above the app).
class DeviceFormScope extends InheritedNotifier<DeviceFormController> {
  const DeviceFormScope({super.key, required DeviceFormController controller, required super.child}) : super(notifier: controller);

  /// A scope that always answers [form] (tests).
  DeviceFormScope.fixed(DeviceForm form, {super.key, required super.child}) : super(notifier: DeviceFormController.fixed(form));

  static DeviceFormController? maybeControllerOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<DeviceFormScope>()?.notifier;

  /// Tests: the form when there is no scope above (flutter_test reports the platform as Android). Null: by platform and size.
  static DeviceForm? debugFormWithoutScope;

  /// The form for this context. Without a scope (widget tests that pump a page alone): [debugFormWithoutScope] when
  /// set, else desktop on a desktop platform, otherwise phone or tablet by size — never TV.
  static DeviceForm of(BuildContext context) {
    final controller = maybeControllerOf(context);
    final size = MediaQuery.maybeSizeOf(context) ?? Size.zero;
    if (controller != null) return controller.formFor(size);
    final debug = debugFormWithoutScope;
    if (debug != null) return debug;
    if (kIsWeb ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux) {
      return DeviceForm.desktop;
    }
    return size.shortestSide >= 600 ? DeviceForm.tablet : DeviceForm.phone;
  }

  /// Without listening to changes (callbacks, initState).
  static bool readIsTv(BuildContext context) =>
      context.getInheritedWidgetOfExactType<DeviceFormScope>()?.notifier?.isTv ?? (debugFormWithoutScope == DeviceForm.tv);
}

/// Driven with a remote control: the 10-foot layout, D-pad focus everywhere.
bool isTv(BuildContext context) => DeviceFormScope.of(context) == DeviceForm.tv;

/// A phone or a tablet: touch first.
bool isTouch(BuildContext context) {
  final form = DeviceFormScope.of(context);
  return form == DeviceForm.phone || form == DeviceForm.tablet;
}

bool isPhone(BuildContext context) => DeviceFormScope.of(context) == DeviceForm.phone;

bool isTablet(BuildContext context) => DeviceFormScope.of(context) == DeviceForm.tablet;

bool isDesktop(BuildContext context) => DeviceFormScope.of(context) == DeviceForm.desktop;
