import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the players need from the phone or tablet itself: keeping the screen on, this window's brightness, the media
/// volume, picture-in-picture, full screen and the orientation. The Android side is `PlaybackChannel.kt`, channel
/// `yingzhou/playback`.
///
/// Nothing here throws: on a platform without the channel (desktop, a widget test that does not mock it) a call does
/// nothing and a read gives null.
class PlaybackHost {
  PlaybackHost._() {
    _channel.setMethodCallHandler(_onCall);
  }

  static final instance = PlaybackHost._();

  static const _channel = MethodChannel('yingzhou/playback');

  /// The app is shown as a picture-in-picture window.
  final inPip = ValueNotifier<bool>(false);

  /// Who gets the presses of the picture-in-picture window's button (the page that armed it).
  void Function(String action)? _onPipAction;
  Object? _pipOwner;

  Future<dynamic> _onCall(MethodCall call) async {
    final args = call.arguments is Map ? call.arguments as Map : const {};
    switch (call.method) {
      case 'pip':
        inPip.value = args['inPip'] == true;
      case 'pipAction':
        _onPipAction?.call('${args['action']}');
    }
    return null;
  }

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on Object catch (e) {
      debugPrint('playback host: $method: $e');
      return null;
    }
  }

  /// The screen stays on while [on] (a video is playing).
  Future<void> keepScreenOn(bool on) => _call<void>('keepScreenOn', {'on': on});

  /// This window's brightness (0..1): the one set here, else the system's. Null where it cannot be read.
  Future<double?> brightness() => _call<double>('getBrightness');

  /// Sets this window's brightness (0..1); null gives it back to the system's setting.
  Future<void> setBrightness(double? value) => _call<void>('setBrightness', {'value': value});

  /// The media volume (0..1). Null where there is none to read: the caller uses the player's own volume instead.
  Future<double?> volume() => _call<double>('getVolume');

  /// Sets the media volume (0..1); answers what the system made of it (it has steps), or null.
  Future<double?> setVolume(double value) => _call<double>('setVolume', {'value': value.clamp(0.0, 1.0)});

  /// While [enabled], leaving the app turns the window into picture-in-picture showing [owner]'s video, of
  /// [width]×[height] (its shape). [playing] chooses the window's button (pause or play); its presses go to
  /// [onAction]. Answers whether the device can do picture-in-picture at all.
  Future<bool> setPip(Object owner, {required bool enabled, int width = 0, int height = 0, bool playing = true, void Function(String action)? onAction}) async {
    if (enabled) {
      _pipOwner = owner;
      _onPipAction = onAction;
    } else if (_pipOwner != owner) {
      // Another page armed it since: leave that alone.
      return false;
    } else {
      _pipOwner = null;
      _onPipAction = null;
    }
    return await _call<bool>('setPip', {'enabled': enabled, 'width': width, 'height': height, 'playing': playing}) ?? false;
  }

  /// Turns the window into picture-in-picture now (the player's button). False where it cannot.
  Future<bool> enterPip() async => await _call<bool>('enterPip') ?? false;

  // ------------------------------------------------------------------ full screen and orientation

  /// Full screen for a video: the status and navigation bars hidden (they come back for a moment with a swipe from
  /// the edge), and on a phone the screen turned to landscape — or to portrait for a video taller than wide.
  Future<void> enterFullScreen({required bool rotate, bool portraitVideo = false}) async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (rotate) {
      await SystemChrome.setPreferredOrientations(
        portraitVideo ? const [DeviceOrientation.portraitUp] : const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
      );
    }
  }

  /// Back from full screen: the system bars return; a phone goes back to portrait, which the player page keeps while
  /// it is open ([lockPortrait]), a tablet to whatever way it is held.
  Future<void> exitFullScreen({required bool lockPortrait}) async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(lockPortrait ? const [DeviceOrientation.portraitUp] : const []);
  }

  /// Leaving a player page: the bars and every orientation back, and the screen may go off again.
  Future<void> restore() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(const []);
    await keepScreenOn(false);
  }
}
