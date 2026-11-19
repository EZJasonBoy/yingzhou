import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// A stretch of the film that is there without waiting for the network.
typedef BufferedRange = ({Duration start, Duration end});

/// The player's progress bar.
///
/// It seeks once, when the pointer is let go: dragging along a stream costs nothing until then. Meanwhile the thumb
/// follows the pointer and a label says where it would land; the same label shows the time under a hovering mouse.
/// Behind the played part the bar shows which parts are buffered ([buffered]).
class SeekBar extends StatefulWidget {
  const SeekBar({super.key, required this.position, required this.duration, this.buffered = const [], required this.onSeek, this.onInteraction});

  final Duration position;

  /// Zero while the media is not loaded: the bar is then inert.
  final Duration duration;
  final List<BufferedRange> buffered;

  /// The place the user chose, once per click or drag.
  final ValueChanged<Duration> onSeek;

  /// The pointer is on the bar (so the controls should stay up).
  final VoidCallback? onInteraction;

  /// The track stops this far short of both ends of the widget, so the thumb never hangs over the edge.
  static const inset = 14.0;

  static String format(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  /// Where the pointer is while a button is down on the bar, and while it merely hovers; in logical pixels.
  double? _dragX;
  double? _hoverX;
  int? _pointer;

  /// The place just sought to. The thumb stays there until the player reports a position from there (it may report
  /// a few more from where it was first), or for two seconds if it never does.
  Duration? _sought;
  Timer? _soughtTimeout;
  Timer? _held;

  bool get _enabled => widget.duration > Duration.zero;

  @override
  void didUpdateWidget(SeekBar old) {
    super.didUpdateWidget(old);
    if (_sought != null && (widget.position - _sought!).abs() < const Duration(seconds: 2)) _clearSought();
  }

  @override
  void dispose() {
    _soughtTimeout?.cancel();
    _held?.cancel();
    super.dispose();
  }

  void _clearSought() {
    _soughtTimeout?.cancel();
    _sought = null;
  }

  Duration _timeAt(double x, double width) {
    final track = width - 2 * SeekBar.inset;
    final fraction = track <= 0 ? 0.0 : ((x - SeekBar.inset) / track).clamp(0.0, 1.0);
    return Duration(milliseconds: (widget.duration.inMilliseconds * fraction).round());
  }

  void _down(PointerDownEvent e) {
    if (!_enabled || _pointer != null) return;
    _pointer = e.pointer;
    setState(() => _dragX = e.localPosition.dx);
    widget.onInteraction?.call();
    // A pointer that is held still sends nothing: say now and then that the bar is still in use.
    _held?.cancel();
    _held = Timer.periodic(const Duration(seconds: 1), (_) => widget.onInteraction?.call());
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    setState(() => _dragX = e.localPosition.dx);
    widget.onInteraction?.call();
  }

  void _up(PointerUpEvent e, double width) {
    if (e.pointer != _pointer) return;
    _held?.cancel();
    final target = _timeAt(e.localPosition.dx, width);
    _soughtTimeout?.cancel();
    _soughtTimeout = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(_clearSought);
    });
    setState(() {
      _pointer = null;
      _dragX = null;
      _sought = target;
    });
    widget.onSeek(target);
  }

  void _cancel(PointerCancelEvent e) {
    if (e.pointer != _pointer) return;
    _held?.cancel();
    setState(() {
      _pointer = null;
      _dragX = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final dragging = _dragX != null;
        final aimed = dragging ? _dragX : _hoverX;
        final shown = dragging ? _timeAt(_dragX!, width) : (_sought ?? widget.position);
        final label = _enabled && aimed != null ? _timeAt(aimed, width) : null;
        return MouseRegion(
          onHover: (e) {
            if (!_enabled) return;
            setState(() => _hoverX = e.localPosition.dx);
            widget.onInteraction?.call();
          },
          onExit: (_) => setState(() => _hoverX = null),
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _down,
            onPointerMove: _move,
            onPointerUp: (e) => _up(e, width),
            onPointerCancel: _cancel,
            child: Semantics(
              slider: true,
              label: '播放进度',
              value: '${SeekBar.format(shown)} / ${SeekBar.format(widget.duration)}',
              child: SizedBox(
                height: 28,
                width: width,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _BarPainter(
                          fraction: _enabled ? (shown.inMilliseconds / widget.duration.inMilliseconds).clamp(0.0, 1.0) : 0,
                          buffered: [
                            if (_enabled)
                              for (final r in widget.buffered)
                                (
                                  (r.start.inMilliseconds / widget.duration.inMilliseconds).clamp(0.0, 1.0),
                                  (r.end.inMilliseconds / widget.duration.inMilliseconds).clamp(0.0, 1.0),
                                ),
                          ],
                          active: dragging || _hoverX != null,
                          dragging: dragging,
                        ),
                      ),
                    ),
                    if (label != null)
                      Positioned(
                        // Centred over the pointer, kept inside the bar's width.
                        left: (aimed!.clamp(SeekBar.inset, width - SeekBar.inset) - 36).clamp(0.0, width - 72),
                        bottom: 26,
                        width: 72,
                        child: IgnorePointer(
                          child: Center(
                            child: DecoratedBox(
                              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.75), borderRadius: BorderRadius.circular(6)),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                child: Text(
                                  SeekBar.format(label),
                                  key: const Key('seek-target'),
                                  style: const TextStyle(color: Colors.white, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({required this.fraction, required this.buffered, required this.active, required this.dragging});

  /// How far the film has got, and the buffered stretches as (start, end): all as fractions of the bar's length.
  final double fraction;
  final List<(double, double)> buffered;
  final bool active;
  final bool dragging;

  @override
  void paint(Canvas canvas, Size size) {
    final left = SeekBar.inset;
    final length = size.width - 2 * SeekBar.inset;
    if (length <= 0) return;
    final height = active ? 5.0 : 3.0;
    final top = (size.height - height) / 2;
    final radius = Radius.circular(height / 2);
    RRect span(double from, double to) => RRect.fromLTRBR(left + length * from, top, left + length * to, top + height, radius);

    canvas.drawRRect(span(0, 1), Paint()..color = Colors.white24);
    final bufferedPaint = Paint()..color = Colors.white.withValues(alpha: 0.42);
    for (final (start, end) in buffered) {
      if (end > start) canvas.drawRRect(span(start, end), bufferedPaint);
    }
    canvas.drawRRect(span(0, fraction), Paint()..color = Colors.white);
    canvas.drawCircle(Offset(left + length * fraction, size.height / 2), dragging ? 8 : 6, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.fraction != fraction || old.active != active || old.dragging != dragging || !listEquals(old.buffered, buffered);
}
