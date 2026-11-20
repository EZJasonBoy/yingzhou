import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import '../settings.dart';

/// The app's own window on Windows / macOS / Linux: fullscreen for the player, and the size and position the user
/// left it at. Everything is a no-op on Android and the web.
class DesktopWindow {
  DesktopWindow._(this._window);

  final Window? _window;
  Timer? _saveTimer;

  static DesktopWindow? _instance;
  static DesktopWindow get instance => _instance ??= DesktopWindow._(_current());

  static bool get isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.linux);

  static Window? _current() {
    if (!isDesktop) return null;
    try {
      return WindowManager.instance.getCurrent();
    } catch (_) {
      return null;
    }
  }

  static const _boundsKey = 'window.bounds';

  bool get supported => _window != null;

  bool get isFullScreen => _guard(() => _window?.isFullScreen ?? false, false);

  set fullScreen(bool value) => _guard(() {
    // Pinned (the TV layout on a desktop): pages that leave full screen when they close do not take the app out of it.
    if (_pinned && !value) return;
    if (_window != null && _window.isFullScreen != value) _window.isFullScreen = value;
  }, null);

  bool _pinned = false;
  bool _fullScreenBeforePin = false;

  /// Whether the window is held in full screen ([pinFullScreen]).
  bool get pinnedFullScreen => _pinned;

  /// Holds the window in full screen until it is let go again: the TV layout on a desktop (an HTPC) fills the
  /// screen like a TV app, and the player or live TV closing does not drop back to a window. Letting go puts the
  /// window back as it was before.
  set pinFullScreen(bool value) {
    if (value == _pinned) return;
    if (value) {
      _fullScreenBeforePin = isFullScreen;
      fullScreen = true;
      _pinned = true;
    } else {
      _pinned = false;
      fullScreen = _fullScreenBeforePin;
    }
  }

  void toggleFullScreen() => fullScreen = !isFullScreen;

  set title(String value) => _guard(() => _window?.title = value, null);

  /// Puts the window back where the user left it, then keeps track of where it goes.
  void restoreAndTrack(SettingsStore settings) {
    final window = _window;
    if (window == null) return;
    _guard(() {
      window.minimumSize = const Size(800, 520).toNative();
      final saved = settings.getString(_boundsKey)?.split(',');
      if (saved != null && saved.length == 5) {
        final v = saved.take(4).map(double.tryParse).toList();
        if (v.every((e) => e != null) && v[2]! >= 800 && v[3]! >= 520 && v[0]! > -10000 && v[1]! > -10000) {
          window.bounds = Rect.fromLTWH(v[0]!, v[1]!, v[2]!, v[3]!).toNative();
        }
        if (saved[4] == '1') window.maximize();
      }
      WindowManager.instance.addListener((event) {
        if (event is WindowMovedEvent || event is WindowResizedEvent || event is WindowMaximizedEvent || event is WindowRestoredEvent) {
          _saveTimer?.cancel();
          _saveTimer = Timer(const Duration(milliseconds: 600), () => _save(settings));
        }
      });
    }, null);
  }

  void _save(SettingsStore settings) => _guard(() {
    final window = _window!;
    // Fullscreen and minimized are not where the window "is".
    if (window.isFullScreen || window.isMinimized) return;
    final maximized = window.isMaximized;
    final previous = settings.getString(_boundsKey)?.split(',');
    final r = window.bounds.toRect();
    // While maximized keep the last normal bounds, so un-maximizing next time lands somewhere sensible.
    final bounds = maximized && previous != null && previous.length == 5
        ? previous.take(4).join(',')
        : [r.left, r.top, r.width, r.height].map((e) => e.round()).join(',');
    settings.setString(_boundsKey, '$bounds,${maximized ? 1 : 0}');
  }, null);

  T _guard<T>(T Function() f, T fallback) {
    try {
      return f();
    } catch (e) {
      debugPrint('window: $e');
      return fallback;
    }
  }
}
