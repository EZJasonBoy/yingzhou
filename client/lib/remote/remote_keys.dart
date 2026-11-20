import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The keys of the remote control, by the names the protocol uses (docs/protocol.md, "遥控"): what a TV box's
/// remote sends, so the TV layout's handlers (`TvKeys` in ui/tv/tv_focus.dart) take them as they are.
const remoteKeyMap = <String, (LogicalKeyboardKey, PhysicalKeyboardKey)>{
  'up': (LogicalKeyboardKey.arrowUp, PhysicalKeyboardKey.arrowUp),
  'down': (LogicalKeyboardKey.arrowDown, PhysicalKeyboardKey.arrowDown),
  'left': (LogicalKeyboardKey.arrowLeft, PhysicalKeyboardKey.arrowLeft),
  'right': (LogicalKeyboardKey.arrowRight, PhysicalKeyboardKey.arrowRight),
  'ok': (LogicalKeyboardKey.select, PhysicalKeyboardKey.select),
  'back': (LogicalKeyboardKey.goBack, PhysicalKeyboardKey.browserBack),
  'menu': (LogicalKeyboardKey.contextMenu, PhysicalKeyboardKey.contextMenu),
  'playpause': (LogicalKeyboardKey.mediaPlayPause, PhysicalKeyboardKey.mediaPlayPause),
  'next': (LogicalKeyboardKey.mediaTrackNext, PhysicalKeyboardKey.mediaTrackNext),
  'previous': (LogicalKeyboardKey.mediaTrackPrevious, PhysicalKeyboardKey.mediaTrackPrevious),
  'fastforward': (LogicalKeyboardKey.mediaFastForward, PhysicalKeyboardKey.mediaFastForward),
  'rewind': (LogicalKeyboardKey.mediaRewind, PhysicalKeyboardKey.mediaRewind),
  'channelup': (LogicalKeyboardKey.channelUp, PhysicalKeyboardKey.pageUp),
  'channeldown': (LogicalKeyboardKey.channelDown, PhysicalKeyboardKey.pageDown),
  '0': (LogicalKeyboardKey.digit0, PhysicalKeyboardKey.digit0),
  '1': (LogicalKeyboardKey.digit1, PhysicalKeyboardKey.digit1),
  '2': (LogicalKeyboardKey.digit2, PhysicalKeyboardKey.digit2),
  '3': (LogicalKeyboardKey.digit3, PhysicalKeyboardKey.digit3),
  '4': (LogicalKeyboardKey.digit4, PhysicalKeyboardKey.digit4),
  '5': (LogicalKeyboardKey.digit5, PhysicalKeyboardKey.digit5),
  '6': (LogicalKeyboardKey.digit6, PhysicalKeyboardKey.digit6),
  '7': (LogicalKeyboardKey.digit7, PhysicalKeyboardKey.digit7),
  '8': (LogicalKeyboardKey.digit8, PhysicalKeyboardKey.digit8),
  '9': (LogicalKeyboardKey.digit9, PhysicalKeyboardKey.digit9),
};

/// Presses keys for a remote that is not a keyboard of this device: real key events, so focus, shortcuts and every
/// page's own key handler behave as with a TV box's remote, with nothing written for it.
///
/// The events go in where the platform's do: `PlatformDispatcher.onKeyData`, as [ui.KeyData] marked `synthesized`.
/// The framework's `KeyEventManager.handleKeyData` dispatches a synthesized event at once (a real one waits for the
/// platform's second, legacy message, which never comes for ours): it updates [HardwareKeyboard] and runs the focus
/// tree's handlers before the call returns. It does not say whether anything took the event; [RemoteKeyProbe] at the
/// top of the app notes the ones nobody did.
class RemoteKeyboard {
  RemoteKeyboard._();

  static final instance = RemoteKeyboard._();

  /// A key that is held without a sign of life from the remote for this long is let go (the phone's connection
  /// dropped with a finger on the pad; its repeats come several times a second).
  static const holdTimeout = Duration(milliseconds: 1500);

  final _held = <String, Timer>{};
  final _clock = Stopwatch()..start();
  bool _injecting = false;
  bool _reachedTop = false;

  /// True while one of this class's events is being dispatched.
  bool get injecting => _injecting;

  /// Called by [RemoteKeyProbe]: the event being dispatched went through the whole app without being taken.
  void reachedTop() {
    if (_injecting) _reachedTop = true;
  }

  /// One step of a key: `down`, `repeat`, `up`, or `press` (down and up at once). Answers whether the key exists.
  /// [unhandledBack] is called when a press of `back` was taken by nothing in the app: what the system's own back
  /// would then do (close the page) is the caller's to do.
  bool send(String name, String action, {VoidCallback? unhandledBack}) {
    final key = remoteKeyMap[name];
    if (key == null) return false;
    switch (action) {
      case 'down':
        _down(name, key, unhandledBack);
      case 'repeat':
        if (_held.containsKey(name)) {
          _dispatch(ui.KeyEventType.repeat, key);
          _watch(name, key, unhandledBack);
        } else {
          _down(name, key, unhandledBack);
        }
      case 'up':
        _up(name, key, unhandledBack);
      default:
        _down(name, key, unhandledBack);
        _up(name, key, unhandledBack);
    }
    return true;
  }

  /// Lets go of everything that is held (the remote went away).
  void releaseAll() {
    for (final name in _held.keys.toList()) {
      _up(name, remoteKeyMap[name]!, null);
    }
  }

  final _downUnhandled = <String>{};

  void _down(String name, (LogicalKeyboardKey, PhysicalKeyboardKey) key, VoidCallback? unhandledBack) {
    // Already down (held on a real keyboard too, or a second remote): the framework wants a key to go down once.
    final pressed = HardwareKeyboard.instance.physicalKeysPressed.contains(key.$2);
    final unhandled = _dispatch(pressed ? ui.KeyEventType.repeat : ui.KeyEventType.down, key);
    if (unhandled) {
      _downUnhandled.add(name);
    } else {
      _downUnhandled.remove(name);
    }
    _watch(name, key, unhandledBack);
  }

  void _up(String name, (LogicalKeyboardKey, PhysicalKeyboardKey) key, VoidCallback? unhandledBack) {
    _held.remove(name)?.cancel();
    if (!HardwareKeyboard.instance.physicalKeysPressed.contains(key.$2)) return;
    final unhandled = _dispatch(ui.KeyEventType.up, key);
    // Android goes back a page when BACK is let go and the app took neither half of the press.
    if (name == 'back' && unhandled && _downUnhandled.remove(name)) unhandledBack?.call();
  }

  void _watch(String name, (LogicalKeyboardKey, PhysicalKeyboardKey) key, VoidCallback? unhandledBack) {
    _held[name]?.cancel();
    _held[name] = Timer(holdTimeout, () => _up(name, key, null));
  }

  /// Dispatches one event; true when it went through the app untaken (as far as [RemoteKeyProbe] can tell).
  bool _dispatch(ui.KeyEventType type, (LogicalKeyboardKey, PhysicalKeyboardKey) key) {
    final handler = WidgetsBinding.instance.platformDispatcher.onKeyData;
    if (handler == null) return false;
    final data = ui.KeyData(
      timeStamp: _clock.elapsed,
      type: type,
      physical: key.$2.usbHidUsage,
      logical: key.$1.keyId,
      character: null,
      synthesized: true,
    );
    _reachedTop = false;
    _injecting = true;
    try {
      handler(data);
    } finally {
      _injecting = false;
    }
    return _reachedTop;
  }
}

/// Sits above the whole app's key handlers: an event [RemoteKeyboard] sent that arrives here was taken by nobody
/// below. (The app's default shortcuts — arrows, Enter — are further up, so this only tells for keys they do not
/// know, which is all it is used for: BACK.)
///
/// It also gives a desktop in the TV layout what Android gives a TV box: a back key (Esc, a remote's Back) that no
/// page took goes back a page, [onBack].
class RemoteKeyProbe extends StatelessWidget {
  const RemoteKeyProbe({super.key, required this.child, this.systemBack = false, this.onBack});

  final Widget child;

  /// Act on an untaken back key of the device's own keyboard ([onBack]), as Android's system back would.
  final bool systemBack;
  final VoidCallback? onBack;

  static bool _isBack(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.goBack || k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.browserBack || k == LogicalKeyboardKey.gameButtonB;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        final remote = RemoteKeyboard.instance;
        if (remote.injecting) {
          remote.reachedTop();
          return KeyEventResult.ignored;
        }
        if (systemBack && onBack != null && _isBack(event.logicalKey)) {
          if (event is KeyDownEvent) onBack!();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}
