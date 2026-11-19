import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import '../mobile/playback_host.dart';

/// What a horizontal drag across the picture does.
enum TouchSwipe {
  /// Seeks: the target time shows while the finger moves, the player goes there once it is lifted (video on demand).
  seek,

  /// Steps: a swipe to the left or right is one step, [TouchGestureLayer.onSwipe] (live: the next or previous channel).
  step,
}

/// The picture of a player on a touch screen and what fingers do on it, as in phone video apps:
///
/// - tap: [onTap] (the page shows or hides its controls);
/// - double tap: [onDoubleTap] with the third of the picture it was in, -1 left, 0 middle, 1 right (seek back, play /
///   pause, seek forward);
/// - drag sideways: seek with a preview of the time ([TouchSwipe.seek]), or a step to either side ([TouchSwipe.step]);
/// - drag up or down on the left half: this window's brightness; on the right half: the media volume (the player's
///   own volume where the system's cannot be set);
/// - long press: 2× speed while the finger stays down ([longPressSpeed]).
///
/// While [locked] only a tap gets through. Drags that start in the system's gesture areas at the edges are left to
/// the system (back, the notification shade). The feedback for drags is drawn over the picture here; the page's
/// controls go on top of this layer as its siblings, so their buttons never wait for a double tap to be ruled out.
class TouchGestureLayer extends StatefulWidget {
  const TouchGestureLayer({
    super.key,
    required this.player,
    required this.child,
    required this.onTap,
    this.onDoubleTap,
    this.swipe = TouchSwipe.seek,
    this.onSeek,
    this.onSwipe,
    this.longPressSpeed = true,
    this.locked = false,
    this.onBrightness,
    this.host,
  });

  final Player player;

  /// The picture.
  final Widget child;
  final VoidCallback onTap;
  final ValueChanged<int>? onDoubleTap;
  final TouchSwipe swipe;

  /// Where a seek drag ended up ([TouchSwipe.seek]); null: no seeking by dragging.
  final ValueChanged<Duration>? onSeek;

  /// A swipe to the left (-1) or right (1) ([TouchSwipe.step]).
  final ValueChanged<int>? onSwipe;
  final bool longPressSpeed;
  final bool locked;

  /// The window's brightness was changed (the page gives it back to the system when it closes).
  final VoidCallback? onBrightness;

  /// The phone's brightness and volume; [PlaybackHost.instance] unless a test gives another.
  final PlaybackHost? host;

  /// How much of the film a drag across the whole picture covers, at most.
  static const seekSpan = Duration(minutes: 3);

  @override
  State<TouchGestureLayer> createState() => TouchGestureLayerState();
}

enum _Drag { none, seek, step, brightness, volume }

@visibleForTesting
class TouchGestureLayerState extends State<TouchGestureLayer> {
  PlaybackHost get _host => widget.host ?? PlaybackHost.instance;

  Offset? _down;
  _Drag _drag = _Drag.none;
  Size _size = Size.zero;

  // Seek drag: where it started and where it would land.
  Duration _seekFrom = Duration.zero;
  Duration _seekTarget = Duration.zero;
  double _dragDx = 0;

  // Brightness / volume drag: the value when the drag began (null until the phone answered) and the distance since.
  double? _levelFrom;
  double _levelDy = 0;
  double? _level;
  bool _systemVolume = true;
  double? _lastBrightness;
  double? _lastVolume;

  // Long press: the speed to go back to.
  double? _rateBefore;

  // Double tap on a side: a short highlight there.
  int? _flashSide;
  Timer? _flashTimer;

  @override
  void dispose() {
    _flashTimer?.cancel();
    _endLongPress();
    super.dispose();
  }

  /// In the area at the edges where the system's own gestures start (back, notification shade).
  bool _inSystemArea(Offset local) {
    final insets = MediaQuery.systemGestureInsetsOf(context);
    final screen = MediaQuery.sizeOf(context);
    final box = context.findRenderObject();
    // The picture is not always the whole screen (above the episodes on a phone held upright).
    final p = box is RenderBox && box.hasSize ? box.localToGlobal(local) : local;
    return p.dx < insets.left || p.dx > screen.width - insets.right || p.dy < insets.top || p.dy > screen.height - insets.bottom;
  }

  void _onDoubleTapDown(TapDownDetails d) {
    final x = d.localPosition.dx / (_size.width <= 0 ? 1 : _size.width);
    final side = x < 1 / 3 ? -1 : (x > 2 / 3 ? 1 : 0);
    _flashTimer?.cancel();
    setState(() => _flashSide = side);
    _flashTimer = Timer(const Duration(milliseconds: 450), () {
      if (mounted) setState(() => _flashSide = null);
    });
    widget.onDoubleTap?.call(side);
  }

  void _onPanDown(DragDownDetails d) => _down = d.localPosition;

  void _onPanStart(DragStartDetails d) {
    final down = _down ?? d.localPosition;
    if (widget.locked || _inSystemArea(down)) {
      _drag = _Drag.none;
      return;
    }
    final moved = d.localPosition - down;
    if (moved.dx.abs() >= moved.dy.abs()) {
      final duration = widget.player.state.duration;
      if (widget.swipe == TouchSwipe.seek && widget.onSeek != null && duration > Duration.zero) {
        _seekFrom = _seekTarget = widget.player.state.position;
        _dragDx = 0;
        setState(() => _drag = _Drag.seek);
      } else if (widget.swipe == TouchSwipe.step && widget.onSwipe != null) {
        _dragDx = 0;
        _drag = _Drag.step;
      } else {
        _drag = _Drag.none;
      }
      return;
    }
    _levelDy = 0;
    _levelFrom = null;
    final brightness = down.dx < _size.width / 2;
    setState(() {
      _drag = brightness ? _Drag.brightness : _Drag.volume;
      _level = brightness ? _lastBrightness : _lastVolume;
    });
    // The level is read again at every drag: the volume keys or the system may have changed it.
    final read = brightness ? _host.brightness() : _host.volume();
    read.then((value) {
      if (!mounted || _drag == _Drag.none) return;
      if (brightness) {
        _levelFrom = value ?? _lastBrightness ?? 0.5;
      } else {
        _systemVolume = value != null;
        _levelFrom = value ?? widget.player.state.volume / 100;
      }
      _applyLevel();
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    switch (_drag) {
      case _Drag.seek:
        _dragDx += d.delta.dx;
        final duration = widget.player.state.duration;
        final span = duration < TouchGestureLayer.seekSpan ? duration : TouchGestureLayer.seekSpan;
        final width = _size.width <= 0 ? 1 : _size.width;
        var target = _seekFrom + span * (_dragDx / width);
        if (target < Duration.zero) target = Duration.zero;
        if (target > duration) target = duration;
        setState(() => _seekTarget = target);
      case _Drag.step:
        _dragDx += d.delta.dx;
      case _Drag.brightness || _Drag.volume:
        _levelDy += d.delta.dy;
        _applyLevel();
      case _Drag.none:
        break;
    }
  }

  /// A drag over 80% of the picture's height goes from nothing to full.
  void _applyLevel() {
    final from = _levelFrom;
    if (from == null) return;
    final height = _size.height <= 0 ? 1 : _size.height;
    final value = (from - _levelDy / (height * 0.8)).clamp(0.0, 1.0);
    setState(() => _level = value);
    if (_drag == _Drag.brightness) {
      _lastBrightness = value;
      _host.setBrightness(value);
      widget.onBrightness?.call();
    } else if (_systemVolume) {
      _lastVolume = value;
      _host.setVolume(value);
    } else {
      _lastVolume = value;
      widget.player.setVolume(value * 100);
    }
  }

  void _onPanEnd([DragEndDetails? _]) {
    final drag = _drag;
    _down = null;
    if (drag == _Drag.seek && _seekTarget != _seekFrom) widget.onSeek?.call(_seekTarget);
    // A step needs a real swipe: a sixth of the picture.
    if (drag == _Drag.step && _dragDx.abs() > _size.width / 6) widget.onSwipe?.call(_dragDx < 0 ? 1 : -1);
    if (drag != _Drag.none) setState(() => _drag = _Drag.none);
  }

  void _onLongPressStart(LongPressStartDetails _) {
    if (widget.locked || !widget.longPressSpeed || !widget.player.state.playing) return;
    final rate = widget.player.state.rate;
    if (rate >= 2) return;
    setState(() => _rateBefore = rate);
    widget.player.setRate(2);
  }

  void _endLongPress([Object? _]) {
    final before = _rateBefore;
    if (before == null) return;
    _rateBefore = null;
    widget.player.setRate(before);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        return Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              key: const Key('touch-gestures'),
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              onDoubleTapDown: widget.locked || widget.onDoubleTap == null ? null : _onDoubleTapDown,
              onDoubleTap: widget.locked || widget.onDoubleTap == null ? null : () {},
              onLongPressStart: widget.longPressSpeed && !widget.locked ? _onLongPressStart : null,
              onLongPressEnd: widget.longPressSpeed && !widget.locked ? _endLongPress : null,
              onLongPressCancel: widget.longPressSpeed && !widget.locked ? _endLongPress : null,
              onPanDown: widget.locked ? null : _onPanDown,
              onPanStart: widget.locked ? null : _onPanStart,
              onPanUpdate: widget.locked ? null : _onPanUpdate,
              onPanEnd: widget.locked ? null : _onPanEnd,
              onPanCancel: widget.locked ? null : _onPanEnd,
              child: widget.child,
            ),
            if (_flashSide != null && _flashSide != 0) IgnorePointer(child: _SideFlash(side: _flashSide!)),
            if (_rateBefore != null)
              const IgnorePointer(
                child: Align(
                  alignment: Alignment(0, -0.8),
                  child: _Pill(key: Key('gesture-speed'), child: Text('▶▶ 2 倍速播放中', style: _Pill.text)),
                ),
              ),
            if (_drag == _Drag.seek) IgnorePointer(child: Center(child: _seekPreview())),
            if ((_drag == _Drag.brightness || _drag == _Drag.volume) && _level != null) IgnorePointer(child: Center(child: _levelPanel())),
          ],
        );
      },
    );
  }

  Widget _seekPreview() {
    final duration = widget.player.state.duration;
    final delta = _seekTarget - _seekFrom;
    final sign = delta.isNegative ? '-' : '+';
    return _Pill(
      key: const Key('gesture-seek'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$sign${formatTouchTime(delta.abs())}', style: _Pill.text.copyWith(fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('${formatTouchTime(_seekTarget)} / ${formatTouchTime(duration)}', style: _Pill.text),
          const SizedBox(height: 8),
          SizedBox(
            width: 160,
            child: LinearProgressIndicator(
              value: duration.inMilliseconds <= 0 ? 0 : _seekTarget.inMilliseconds / duration.inMilliseconds,
              minHeight: 3,
              color: Colors.white,
              backgroundColor: Colors.white24,
            ),
          ),
        ],
      ),
    );
  }

  Widget _levelPanel() {
    final value = _level ?? 0;
    final brightness = _drag == _Drag.brightness;
    final icon = brightness
        ? (value < 0.34 ? Icons.brightness_low_rounded : (value < 0.67 ? Icons.brightness_medium_rounded : Icons.brightness_high_rounded))
        : (value == 0 ? Icons.volume_off_rounded : (value < 0.5 ? Icons.volume_down_rounded : Icons.volume_up_rounded));
    return _Pill(
      key: Key(brightness ? 'gesture-brightness' : 'gesture-volume'),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 22),
          const SizedBox(width: 10),
          SizedBox(
            width: 120,
            child: LinearProgressIndicator(value: value, minHeight: 4, color: Colors.white, backgroundColor: Colors.white24),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 40,
            child: Text('${(value * 100).round()}%', textAlign: TextAlign.end, style: _Pill.text),
          ),
        ],
      ),
    );
  }
}

/// mm:ss, or h:mm:ss from an hour.
String formatTouchTime(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

class _Pill extends StatelessWidget {
  const _Pill({super.key, required this.child});

  final Widget child;

  static const text = TextStyle(color: Colors.white, fontSize: 14, fontFeatures: [FontFeature.tabularFigures()]);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(12)),
      child: child,
    );
  }
}

/// The side of the picture a double tap seeked on lights up for a moment.
class _SideFlash extends StatelessWidget {
  const _SideFlash({required this.side});

  final int side;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: side < 0 ? Alignment.centerLeft : Alignment.centerRight,
      child: FractionallySizedBox(
        widthFactor: 1 / 3,
        heightFactor: 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.10),
            borderRadius: side < 0
                ? const BorderRadius.horizontal(right: Radius.elliptical(400, 600))
                : const BorderRadius.horizontal(left: Radius.elliptical(400, 600)),
          ),
          child: Center(child: Icon(side < 0 ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded, color: Colors.white70, size: 36)),
        ),
      ),
    );
  }
}
