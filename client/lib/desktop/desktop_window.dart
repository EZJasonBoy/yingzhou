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

  /// `x,y,width,height,maximized`: the frame's corner and size; on Linux the frame's corner and the content's size.
  static const _boundsKey = 'window.bounds';

  /// On Linux the window manager draws the frame, and GTK learns how thick it is only once the window is on screen.
  /// A frame size given before that is taken for the content's, and the window would grow by its title bar at every
  /// start; so there the content's size is what is kept.
  static bool get _frameDrawnLater => defaultTargetPlatform == TargetPlatform.linux;

  /// Runs [f] once [window] is on screen, or after five seconds.
  void _whenShown(Window window, void Function() f) {
    var waited = 0;
    Timer.periodic(const Duration(milliseconds: 100), (timer) {
      waited += 100;
      if (!_guard(() => window.isVisible, true) && waited < 5000) return;
      timer.cancel();
      // Shown is not yet mapped and framed by the window manager.
      Timer(const Duration(milliseconds: 300), () => _guard(f, null));
    });
  }

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
          final r = Rect.fromLTWH(v[0]!, v[1]!, v[2]!, v[3]!);
          if (_frameDrawnLater) {
            window.contentSize = r.size.toNative();
            window.position = r.topLeft.toNative();
            // GTK places a window that is not on screen yet where the window manager likes; move it once it is.
            if (saved[4] != '1') _whenShown(window, () => window.position = r.topLeft.toNative());
          } else {
            window.bounds = r.toNative();
          }
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
    final r = _frameDrawnLater ? window.position.toOffset() & window.contentSize.toSize() : window.bounds.toRect();
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
