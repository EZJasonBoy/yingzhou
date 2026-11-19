import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import '../engine/danmaku_models.dart';
import '../settings.dart';

/// How danmaku look, remembered on this device.
class DanmakuPrefs extends ChangeNotifier {
  DanmakuPrefs(this._settings) {
    enabled = _settings.getString('$_p.enabled') != 'false';
    opacity = _double('opacity', 0.85, 0.1, 1);
    fontScale = _double('scale', 1, 0.5, 2);
    speed = _double('speed', 1, 0.5, 2);
    area = _double('area', 1, 0.25, 1);
    blockTop = _settings.getString('$_p.blockTop') == 'true';
    blockBottom = _settings.getString('$_p.blockBottom') == 'true';
    blockScroll = _settings.getString('$_p.blockScroll') == 'true';
    keywords = _settings.getString('$_p.keywords') ?? '';
  }

  final SettingsStore _settings;
  static const _p = 'danmaku';

  /// The speeds offered (1 = a comment crosses the picture in [DanmakuScheduler.baseScrollMs]).
  static final speeds = {0.6: '慢', 0.8: '较慢', 1.0: '适中', 1.25: '较快', 1.6: '快'};

  /// How much of the picture danmaku may cover, from the top.
  static final areas = {1.0: '全屏', 0.5: '半屏', 0.25: '1/4'};

  late bool enabled;
  late double opacity;
  late double fontScale;
  late double speed;
  late double area;
  late bool blockTop;
  late bool blockBottom;
  late bool blockScroll;

  /// Words to hide comments by, one per line or separated by commas; `/…/` is a regular expression.
  late String keywords;

  double _double(String key, double fallback, double min, double max) =>
      (double.tryParse(_settings.getString('$_p.$key') ?? '') ?? fallback).clamp(min, max).toDouble();

  void update({
    bool? enabled,
    double? opacity,
    double? fontScale,
    double? speed,
    double? area,
    bool? blockTop,
    bool? blockBottom,
    bool? blockScroll,
    String? keywords,
  }) {
    if (enabled != null) _save('enabled', '${this.enabled = enabled}');
    if (opacity != null) _save('opacity', (this.opacity = opacity.clamp(0.1, 1).toDouble()).toStringAsFixed(2));
    if (fontScale != null) _save('scale', (this.fontScale = fontScale.clamp(0.5, 2).toDouble()).toStringAsFixed(2));
    if (speed != null) _save('speed', '${this.speed = speed}');
    if (area != null) _save('area', '${this.area = area}');
    if (blockTop != null) _save('blockTop', '${this.blockTop = blockTop}');
    if (blockBottom != null) _save('blockBottom', '${this.blockBottom = blockBottom}');
    if (blockScroll != null) _save('blockScroll', '${this.blockScroll = blockScroll}');
    if (keywords != null) {
      this.keywords = keywords;
      _filter = null;
      _save('keywords', keywords);
    }
    notifyListeners();
  }

  void _save(String key, String value) => unawaited(_settings.setString('$_p.$key', value));

  List<Pattern>? _filter;

  /// The keyword list as patterns.
  List<Pattern> get filter => _filter ??= [
    for (final raw in keywords.split(RegExp(r'[\n,，]')))
      if (raw.trim().isNotEmpty) _pattern(raw.trim()),
  ];

  static Pattern _pattern(String word) {
    if (word.length > 2 && word.startsWith('/') && word.endsWith('/')) {
      try {
        return RegExp(word.substring(1, word.length - 1), caseSensitive: false);
      } on FormatException {
        // Not a valid expression: taken as text.
      }
    }
    return word.toLowerCase();
  }

  /// Whether a comment is to be shown at all.
  bool shows(DanmakuComment c) {
    if ((c.mode == DanmakuMode.top && blockTop) || (c.mode == DanmakuMode.bottom && blockBottom) || (c.mode == DanmakuMode.scroll && blockScroll)) {
      return false;
    }
    final f = filter;
    if (f.isEmpty) return true;
    final lower = c.text.toLowerCase();
    for (final p in f) {
      if (p is RegExp ? p.hasMatch(c.text) : lower.contains(p as String)) return false;
    }
    return true;
  }
}

/// A comment on the screen: where it is drawn from, and what it looks like (made once, when it comes on).
class ActiveDanmaku {
  ActiveDanmaku(this.comment, this.lane, this.startMs, this.width, this.height, {this.span = 1});

  final DanmakuComment comment;

  /// The first lane it takes, and how many (a large comment is taller than one).
  final int lane;
  final int span;

  bool takes(int l) => l >= lane && l < lane + span;

  /// The video time it entered at (its own time, also after a seek into the middle of its run).
  final int startMs;
  final double width;
  final double height;

  /// The pre-rendered text; null until the painter made it.
  ui.Image? image;
  ui.Picture? picture;

  void dispose() {
    image?.dispose();
    picture?.dispose();
    image = null;
    picture = null;
  }
}

/// Which comments are on the screen at a moment of the video, and in which lane: pure arithmetic, so it can be tested
/// without painting. Scrolling comments cross the screen right to left in [scrollMs] of video time (longer ones a bit
/// faster, as on Bilibili); a lane takes a new one only when the last one in it has fully come in and cannot be caught
/// up with before it leaves. Top and bottom ones stay [fixedMs] in the middle. A comment with no lane free is
/// dropped, which keeps a dense file readable.
class DanmakuScheduler {
  DanmakuScheduler({required this.measure});

  /// The size a comment is drawn at.
  final Size Function(DanmakuComment comment) measure;

  static const baseScrollMs = 9000;
  static const fixedMs = 4000;
  static const gap = 24.0;

  List<DanmakuComment> _items = const [];
  int _next = 0;
  final scroll = <ActiveDanmaku>[];
  final top = <ActiveDanmaku>[];
  final bottom = <ActiveDanmaku>[];

  /// Comments that came on, and that found no room, since the list was set.
  int shown = 0;
  int dropped = 0;

  Size _size = Size.zero;
  double lineHeight = 30;
  int scrollMs = baseScrollMs;

  Iterable<ActiveDanmaku> get active sync* {
    yield* scroll;
    yield* top;
    yield* bottom;
  }

  /// A new list (sorted by time), starting at [atMs].
  void setItems(List<DanmakuComment> items, int atMs) {
    _items = items;
    seek(atMs);
    shown = 0;
    dropped = 0;
  }

  /// Clears the screen and carries on from [atMs]; comments that started up to a scroll's length before it come
  /// back on where they would be by now.
  void seek(int atMs) {
    _clear();
    _next = _lowerBound(atMs - scrollMs);
  }

  void _clear() {
    for (final a in active) {
      a.dispose();
    }
    scroll.clear();
    top.clear();
    bottom.clear();
  }

  int _lowerBound(int ms) {
    var lo = 0;
    var hi = _items.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_items[mid].timeMs < ms) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// The screen is [size] with lines [lineHeight] high; comments cross it in [scrollMs]. A change of size clears it.
  void layout(Size size, double lineHeight, int scrollMs) {
    if (size != _size || (lineHeight - this.lineHeight).abs() > 0.5 || scrollMs != this.scrollMs) {
      final keep = _size != Size.zero && size == _size;
      _size = size;
      this.lineHeight = lineHeight;
      this.scrollMs = scrollMs;
      if (!keep) _clear();
    }
  }

  double speedOf(ActiveDanmaku a) => (_size.width + a.width) / scrollMs;

  /// Scrolling comment's left edge at [nowMs].
  double xOf(ActiveDanmaku a, int nowMs) => _size.width - speedOf(a) * (nowMs - a.startMs);

  /// Moves the screen on to [nowMs]: what has run its course goes, what is due comes on (if [shows] lets it and there
  /// is room in [area], a fraction of the height from the top).
  void advance(int nowMs, {required double area, required bool Function(DanmakuComment) shows}) {
    if (_size.isEmpty) return;
    scroll.removeWhere((a) => _gone(a, nowMs >= a.startMs + scrollMs));
    top.removeWhere((a) => _gone(a, nowMs >= a.startMs + fixedMs));
    bottom.removeWhere((a) => _gone(a, nowMs >= a.startMs + fixedMs));
    final lanes = math.max(1, (_size.height * area / lineHeight).floor());
    while (_next < _items.length && _items[_next].timeMs <= nowMs) {
      final c = _items[_next++];
      final late = nowMs - c.timeMs;
      if (late > (c.mode == DanmakuMode.scroll ? scrollMs : fixedMs) || !shows(c)) continue;
      final s = measure(c);
      final span = math.max(1, (s.height / lineHeight - 0.05).ceil());
      final lane = switch (c.mode) {
        DanmakuMode.scroll => _scrollLane(c.timeMs, s.width, nowMs, lanes, span),
        DanmakuMode.top => _fixedLane(top, lanes, span),
        DanmakuMode.bottom => _fixedLane(bottom, lanes, span),
      };
      if (lane < 0) {
        dropped++;
        continue;
      }
      shown++;
      final a = ActiveDanmaku(c, lane, c.timeMs, s.width, s.height, span: span);
      (c.mode == DanmakuMode.scroll ? scroll : (c.mode == DanmakuMode.top ? top : bottom)).add(a);
    }
  }

  bool _gone(ActiveDanmaku a, bool over) {
    if (over) a.dispose();
    return over;
  }

  /// The first of [span] lanes next to each other that a comment entering now can take, or -1.
  int _scrollLane(int startMs, double width, int nowMs, int lanes, int span) {
    final speed = (_size.width + width) / scrollMs;
    // The last comment to have entered each lane.
    final last = List<ActiveDanmaku?>.filled(lanes, null);
    for (final a in scroll) {
      for (var l = a.lane; l < a.lane + a.span && l < lanes; l++) {
        if (last[l] == null || a.startMs > last[l]!.startMs) last[l] = a;
      }
    }
    bool free(int lane) {
      final prev = last[lane];
      if (prev == null) return true;
      // The one before has fully come in…
      final tail = xOf(prev, nowMs) + prev.width;
      if (tail + gap > _size.width - speed * (nowMs - startMs)) return false;
      // …and this one, if faster, does not reach it before it has left.
      final leaves = prev.startMs + scrollMs;
      return _size.width - speed * (leaves - startMs) >= gap;
    }

    for (var lane = 0; lane + span <= lanes; lane++) {
      var ok = true;
      for (var l = lane; l < lane + span && ok; l++) {
        ok = free(l);
      }
      if (ok) return lane;
    }
    return -1;
  }

  int _fixedLane(List<ActiveDanmaku> list, int lanes, int span) {
    for (var lane = 0; lane + span <= lanes; lane++) {
      var ok = true;
      for (var l = lane; l < lane + span && ok; l++) {
        ok = !list.any((a) => a.takes(l));
      }
      if (ok) return lane;
    }
    return -1;
  }

  void dispose() => _clear();
}

/// The danmaku over the picture: follows the player's clock (play, pause, seek, speed, buffering), draws only the
/// comments on the screen, each from an image made once when it comes on. Lets every click through.
class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({super.key, required this.player, required this.comments, required this.prefs});

  final Player player;
  final List<DanmakuComment> comments;
  final DanmakuPrefs prefs;

  /// Numbers for measuring a dense file: frames painted, comments drawn in them, and on the screen now.
  static final stats = DanmakuStats();

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class DanmakuStats {
  int frames = 0;
  int drawn = 0;
  int onScreen = 0;
  int shown = 0;
  int dropped = 0;
  int maxOnScreen = 0;

  void reset() => frames = drawn = onScreen = shown = dropped = maxOnScreen = 0;

  Map<String, Object> toJson() => {
    'frames': frames,
    'avgDrawn': frames == 0 ? 0 : (drawn / frames).toStringAsFixed(1),
    'maxOnScreen': maxOnScreen,
    'shown': shown,
    'dropped': dropped,
  };
}

class _DanmakuOverlayState extends State<DanmakuOverlay> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _repaint = ValueNotifier<int>(0);
  final _subs = <StreamSubscription<dynamic>>[];
  late final DanmakuScheduler _scheduler = DanmakuScheduler(measure: _measure);

  // The clock: the video time at [_baseWall] (a frame's time stamp, ms), moving at [_rate] while playing. Frame time
  // stamps are vsync times in the app and the test's own clock in widget tests. Null: anchored at the next frame
  // (between frames the last stamp may be old, e.g. after a pause).
  int _basePos = 0;
  int? _baseWall;
  double _rate = 1;
  bool _playing = false;
  bool _buffering = false;
  double _fontSize = 25;
  double _dpr = 1;

  static int get _frameMs => SchedulerBinding.instance.currentSystemFrameTimeStamp.inMilliseconds;

  int get _now {
    final wall = _baseWall;
    if (!_playing || _buffering || wall == null) return _basePos;
    return _basePos + ((_frameMs - wall) * _rate).round();
  }

  void _rebase(int pos) {
    _basePos = pos;
    _baseWall = null;
  }

  @override
  void initState() {
    super.initState();
    final p = widget.player;
    _playing = p.state.playing;
    _rate = p.state.rate;
    _buffering = p.state.buffering;
    _rebase(p.state.position.inMilliseconds);
    _scheduler.setItems(widget.comments, _now);
    _subs
      ..add(p.stream.position.listen(_position))
      ..add(p.stream.playing.listen((playing) {
        _rebase(_now);
        _playing = playing;
        _run();
      }))
      ..add(p.stream.buffering.listen((buffering) {
        _rebase(_now);
        _buffering = buffering;
        _run();
      }))
      ..add(p.stream.rate.listen((rate) {
        _rebase(_now);
        _rate = rate;
      }));
    widget.prefs.addListener(_prefsChanged);
    _run();
  }

  /// The player says where it is: small differences are the clock's own, big ones a seek.
  void _position(Duration position) {
    final p = position.inMilliseconds;
    final diff = p - _now;
    if (diff.abs() > 1500) {
      _rebase(p);
      _scheduler.seek(p);
      _repaint.value++;
    } else if (diff.abs() > 120 || !_playing) {
      _rebase(p);
    }
  }

  void _prefsChanged() {
    // Blocking takes the hidden ones off at once; the rest takes effect for comments that come on from now.
    final prefs = widget.prefs;
    for (final list in [_scheduler.scroll, _scheduler.top, _scheduler.bottom]) {
      list.removeWhere((a) {
        final hide = !prefs.shows(a.comment);
        if (hide) a.dispose();
        return hide;
      });
    }
    _repaint.value++;
    _run();
  }

  @override
  void didUpdateWidget(DanmakuOverlay old) {
    super.didUpdateWidget(old);
    if (!identical(old.comments, widget.comments)) {
      _rebase(widget.player.state.position.inMilliseconds);
      _scheduler.setItems(widget.comments, _now);
      _repaint.value++;
    }
    if (!identical(old.prefs, widget.prefs)) {
      old.prefs.removeListener(_prefsChanged);
      widget.prefs.addListener(_prefsChanged);
    }
    _run();
  }

  /// The ticker runs only while there is something to move.
  void _run() {
    final moving = _playing && !_buffering && widget.comments.isNotEmpty;
    if (moving && !_ticker.isActive) {
      _ticker.start();
    } else if (!moving && _ticker.isActive) {
      _ticker.stop();
      _repaint.value++;
    }
  }

  void _tick(Duration _) => _repaint.value++;

  Size _measure(DanmakuComment c) {
    final painter = TextPainter(
      text: TextSpan(text: c.text, style: _style(c)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final size = Size(painter.width + 4, painter.height + 2);
    painter.dispose();
    return size;
  }

  TextStyle _style(DanmakuComment c) => TextStyle(
    fontSize: _fontSize * (c.size / 25).clamp(0.6, 1.6),
    fontWeight: FontWeight.w600,
    height: 1.15,
    color: Color(0xFF000000 | c.color),
  );

  /// The comment as an image: text with a dark outline (light for dark text), rendered once at the screen's density.
  void _render(ActiveDanmaku a) {
    final c = a.comment;
    final style = _style(c);
    final luminance = ((c.color >> 16 & 0xFF) * 0.299 + (c.color >> 8 & 0xFF) * 0.587 + (c.color & 0xFF) * 0.114);
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.5, style.fontSize! / 14)
      ..strokeJoin = StrokeJoin.round
      ..color = luminance < 60 ? const Color(0xE6FFFFFF) : const Color(0xE6000000);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(_dpr);
    final stroke = TextPainter(text: TextSpan(text: c.text, style: style.copyWith(foreground: outline, color: null)), textDirection: TextDirection.ltr, maxLines: 1)
      ..layout();
    final fill = TextPainter(text: TextSpan(text: c.text, style: style), textDirection: TextDirection.ltr, maxLines: 1)..layout();
    stroke.paint(canvas, const Offset(2, 1));
    fill.paint(canvas, const Offset(2, 1));
    stroke.dispose();
    fill.dispose();
    final picture = recorder.endRecording();
    try {
      a.image = picture.toImageSync((a.width * _dpr).ceil(), (a.height * _dpr).ceil());
      picture.dispose();
    } catch (_) {
      // No GPU image here (some test or headless setups): draw the recording itself.
      a.picture = picture;
    }
  }

  @override
  void dispose() {
    widget.prefs.removeListener(_prefsChanged);
    for (final s in _subs) {
      s.cancel();
    }
    _ticker.dispose();
    _scheduler.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest;
        final prefs = widget.prefs;
        _fontSize = (size.height * 0.036).clamp(16.0, 36.0) * prefs.fontScale;
        return RepaintBoundary(
          child: CustomPaint(
            size: size,
            painter: _DanmakuPainter(this, _repaint),
          ),
        );
      },
    );
  }

  void _paint(Canvas canvas, Size size) {
    final prefs = widget.prefs;
    _baseWall ??= _frameMs;
    final now = _now;
    _scheduler.layout(size, _fontSize * 1.25 + 4, (DanmakuScheduler.baseScrollMs / prefs.speed).round());
    _scheduler.advance(now, area: prefs.area, shows: prefs.shows);
    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..color = Color.fromRGBO(0, 0, 0, prefs.opacity);
    final line = _scheduler.lineHeight;
    final areaBottom = size.height * prefs.area;
    var drawn = 0;
    void draw(ActiveDanmaku a, double x, double y) {
      if (x > size.width || x + a.width < 0) return;
      if (a.image == null && a.picture == null) _render(a);
      final image = a.image;
      if (image != null) {
        canvas.drawImageRect(image, Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()), Rect.fromLTWH(x, y, a.width, a.height), paint);
      } else {
        canvas.saveLayer(Rect.fromLTWH(x, y, a.width, a.height), paint);
        canvas.translate(x, y);
        canvas.scale(1 / _dpr);
        canvas.drawPicture(a.picture!);
        canvas.restore();
      }
      drawn++;
    }

    for (final a in _scheduler.scroll) {
      draw(a, _scheduler.xOf(a, now), a.lane * line + 2);
    }
    for (final a in _scheduler.top) {
      draw(a, (size.width - a.width) / 2, a.lane * line + 2);
    }
    for (final a in _scheduler.bottom) {
      draw(a, (size.width - a.width) / 2, areaBottom - (a.lane + a.span) * line - 2);
    }
    final stats = DanmakuOverlay.stats
      ..frames += 1
      ..drawn += drawn
      ..onScreen = drawn
      ..shown = _scheduler.shown
      ..dropped = _scheduler.dropped;
    if (drawn > stats.maxOnScreen) stats.maxOnScreen = drawn;
  }
}

class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter(this.state, Listenable repaint) : super(repaint: repaint);

  final _DanmakuOverlayState state;

  @override
  void paint(Canvas canvas, Size size) => state._paint(canvas, size);

  @override
  bool shouldRepaint(_DanmakuPainter old) => !identical(old.state, state);
}
