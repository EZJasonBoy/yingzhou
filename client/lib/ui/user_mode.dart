import 'package:flutter/foundation.dart';

import '../settings.dart';

/// How much of the app is on show (设置 → 外观 → 用法).
///
/// - [simple]: open and watch. Three entries (首页, 直播, 搜索) and 设置; 首页 starts on what was being watched; the
///   player keeps play, next, subtitles and episodes; a line that fails is replaced without asking. 设置 can be
///   locked with a four-digit code.
/// - [standard]: everything.
/// - [developer]: everything, and what is going on underneath: playback statistics over the picture, where the
///   video comes from, and the log.
enum UserMode { simple, standard, developer }

/// The user's [UserMode] and the lock on 设置, kept in the client's settings.
class UserModeController extends ChangeNotifier {
  UserModeController([this._settings])
    : _mode = UserMode.values.asNameMap()[_settings?.getString(key) ?? ''],
      // Nothing chosen and no engine ever connected: the very first start.
      firstStart = _settings != null && _settings.getString(key) == null && _settings.getString('engineUrl') == null;

  static const key = 'ui.userMode';
  static const pinKey = 'ui.settingsLock';

  final SettingsStore? _settings;
  UserMode? _mode;

  /// The app has never been used on this device: it may ask which way to use it.
  final bool firstStart;

  UserMode get mode => _mode ?? UserMode.standard;

  /// The user has picked a mode themselves.
  bool get chosen => _mode != null;

  bool get simple => mode == UserMode.simple;
  bool get developer => mode == UserMode.developer;

  Future<void> set(UserMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    await _settings?.setString(key, mode.name);
  }

  // ---- the lock on 设置 (simple mode)

  bool _unlocked = false;

  /// A code has been set.
  bool get hasPin => (_settings?.getString(pinKey) ?? '').isNotEmpty;

  /// 设置 asks for the code: in simple mode, with a code set, until it has been entered.
  bool get locked => simple && hasPin && !_unlocked;

  /// True when [pin] is the code; 设置 then stays open until [lock].
  bool unlock(String pin) {
    if (!matches(pin)) return false;
    _unlocked = true;
    notifyListeners();
    return true;
  }

  bool matches(String pin) => hasPin && _settings?.getString(pinKey) == _digest(pin);

  /// Leaving 设置 locks it again.
  void lock() {
    if (!_unlocked) return;
    _unlocked = false;
    notifyListeners();
  }

  /// Sets the code, or removes it with null. The code keeps people from changing settings by accident; it is not
  /// kept in plain text, but four digits protect nothing from someone who means to get in.
  Future<void> setPin(String? pin) async {
    await _settings?.setString(pinKey, pin == null || pin.isEmpty ? '' : _digest(pin));
    _unlocked = pin != null && pin.isNotEmpty;
    notifyListeners();
  }

  static String _digest(String pin) {
    var h = 7;
    for (var round = 0; round < 64; round++) {
      for (final c in 'yingzhou:$pin:$round'.codeUnits) {
        h = (h * 31 + c) % 1000000007;
      }
    }
    return 'v1:$h';
  }
}
