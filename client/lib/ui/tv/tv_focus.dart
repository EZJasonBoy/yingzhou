import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../device_form.dart';

/// Colours of the brand (docs/brand/yingzhou-logo.svg) used for focus on a TV: the coral of the hull for the outline,
/// the warm yellow of the wave for its glow.
abstract final class TvColors {
  static const coral = Color(0xFFF4A08A);
  static const yellow = Color(0xFFF0C670);
  static const indigo = Color(0xFF2F2C55);
}

/// The keys of a remote control, by what they do. Android sends DPAD_CENTER as `select`, BACK as `goBack`, MENU as
/// `contextMenu`; a keyboard plugged into a box sends Enter, Escape and so on.
abstract final class TvKeys {
  static bool isActivate(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.select ||
      k == LogicalKeyboardKey.enter ||
      k == LogicalKeyboardKey.numpadEnter ||
      k == LogicalKeyboardKey.gameButtonA ||
      k == LogicalKeyboardKey.space;

  static bool isBack(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.goBack || k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.browserBack || k == LogicalKeyboardKey.gameButtonB;

  static bool isMenu(LogicalKeyboardKey k) => k == LogicalKeyboardKey.contextMenu || k == LogicalKeyboardKey.f1 || k == LogicalKeyboardKey.gameButtonY;

  static bool isUp(LogicalKeyboardKey k) => k == LogicalKeyboardKey.arrowUp;
  static bool isDown(LogicalKeyboardKey k) => k == LogicalKeyboardKey.arrowDown;
  static bool isLeft(LogicalKeyboardKey k) => k == LogicalKeyboardKey.arrowLeft;
  static bool isRight(LogicalKeyboardKey k) => k == LogicalKeyboardKey.arrowRight;

  static bool isChannelUp(LogicalKeyboardKey k) => k == LogicalKeyboardKey.channelUp || k == LogicalKeyboardKey.pageUp;
  static bool isChannelDown(LogicalKeyboardKey k) => k == LogicalKeyboardKey.channelDown || k == LogicalKeyboardKey.pageDown;

  static bool isPlayPause(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.mediaPlayPause || k == LogicalKeyboardKey.mediaPlay || k == LogicalKeyboardKey.mediaPause;
  static bool isNext(LogicalKeyboardKey k) => k == LogicalKeyboardKey.mediaTrackNext;
  static bool isPrevious(LogicalKeyboardKey k) => k == LogicalKeyboardKey.mediaTrackPrevious;
  static bool isFastForward(LogicalKeyboardKey k) => k == LogicalKeyboardKey.mediaFastForward;
  static bool isRewind(LogicalKeyboardKey k) => k == LogicalKeyboardKey.mediaRewind;

  /// 0–9 from the number keys of a remote or a keyboard, else null.
  static int? digit(LogicalKeyboardKey k) {
    const digits = [
      LogicalKeyboardKey.digit0,
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
      LogicalKeyboardKey.digit9,
    ];
    const numpad = [
      LogicalKeyboardKey.numpad0,
      LogicalKeyboardKey.numpad1,
      LogicalKeyboardKey.numpad2,
      LogicalKeyboardKey.numpad3,
      LogicalKeyboardKey.numpad4,
      LogicalKeyboardKey.numpad5,
      LogicalKeyboardKey.numpad6,
      LogicalKeyboardKey.numpad7,
      LogicalKeyboardKey.numpad8,
      LogicalKeyboardKey.numpad9,
    ];
    final i = digits.indexOf(k);
    if (i >= 0) return i;
    final j = numpad.indexOf(k);
    return j >= 0 ? j : null;
  }
}

/// ↑ / ↓ the way TV launchers move: to the nearest row in that direction, and in it to the item closest
/// horizontally. Flutter's own search first looks for items overlapping the current one's column, so ↓ from a button
/// on the right of a page jumps past a whole row that starts on the left (the detail page's lines) to whatever lies
/// under the button. ← / → and everything else are Flutter's.
class TvTraversalPolicy extends ReadingOrderTraversalPolicy {
  TvTraversalPolicy({super.requestFocusCallback});

  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    if (direction != TraversalDirection.up && direction != TraversalDirection.down) return super.inDirection(currentNode, direction);
    final scope = currentNode.nearestScope;
    if (scope == null || currentNode is FocusScopeNode || currentNode.context == null) return super.inDirection(currentNode, direction);
    final from = currentNode.rect;
    final down = direction == TraversalDirection.down;
    var candidates = [
      for (final n in scope.traversalDescendants)
        if (n != currentNode &&
            n is! FocusScopeNode &&
            n.context != null &&
            !n.rect.isEmpty &&
            (down ? n.rect.top >= from.bottom - 1 : n.rect.bottom <= from.top + 1))
          n,
    ];
    if (candidates.isEmpty) return super.inDirection(currentNode, direction);
    // Straight back the way it came (↑ then ↓ returns to the same item, like the default policy).
    final last = _last;
    if (last != null && last.to == currentNode && last.direction != direction && candidates.contains(last.from) && last.from.canRequestFocus) {
      _last = (from: currentNode, to: last.from, direction: direction);
      requestFocusCallback(
        last.from,
        alignmentPolicy: down ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
      return true;
    }
    // Stay in the same vertical list when it has something there (the default does the same).
    final scrollable = Scrollable.maybeOf(currentNode.context!, axis: Axis.vertical);
    if (scrollable != null) {
      final same = candidates.where((n) => Scrollable.maybeOf(n.context!, axis: Axis.vertical) == scrollable).toList();
      if (same.isNotEmpty) candidates = same;
    }
    double gap(FocusNode n) => down ? n.rect.top - from.bottom : from.top - n.rect.bottom;
    final nearest = candidates.map(gap).reduce((a, b) => a < b ? a : b);
    // The next row: everything that starts within a short distance of the nearest one.
    final row = candidates.where((n) => gap(n) <= nearest + 12).toList();
    double across(FocusNode n) {
      if (n.rect.right >= from.left && n.rect.left <= from.right) return 0;
      return n.rect.left > from.right ? n.rect.left - from.right : from.left - n.rect.right;
    }

    row.sort((a, b) {
      final c = across(a).compareTo(across(b));
      return c != 0 ? c : (a.rect.center.dx - from.center.dx).abs().compareTo((b.rect.center.dx - from.center.dx).abs());
    });
    _last = (from: currentNode, to: row.first, direction: direction);
    requestFocusCallback(row.first, alignmentPolicy: down ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd : ScrollPositionAlignmentPolicy.keepVisibleAtStart);
    return true;
  }

  /// The last ↑ / ↓ move, to come straight back.
  static ({FocusNode from, FocusNode to, TraversalDirection direction})? _last;
}

/// Focus nodes that draw their own focus (a [TvFocusable]); the [TvFocusRing] leaves them alone.
final Expando<bool> _ownsFocusLook = Expando<bool>('tvOwnsFocusLook');

/// Marks [node] as drawing its own focus, so [TvFocusRing] does not draw a second outline around it.
void tvOwnFocusLook(FocusNode node) => _ownsFocusLook[node] = true;

/// Scopes whose owner puts the focus back itself when it falls on them (the TV shell's rail and pages).
final Expando<bool> _healsItself = Expando<bool>('tvHealsItself');

/// Marks [scope] as looked after by its owner: [TvFocusRing] does not move the focus out of it.
void tvHealsItself(FocusScopeNode scope) => _healsItself[scope] = true;

/// On a TV, an outline in the brand colours follows the focused widget across the whole app (pages, dialogs, menus),
/// so the focus is obvious from across the room whatever widget has it. It glides from one item to the next and keeps
/// up with scrolling. A [TvFocusable] draws its own (with a scale) and is skipped; so are large containers (a page's
/// key handler, a player) that hold the focus without being an item.
///
/// It also keeps the focus from getting lost: when the focus falls back to a scope with nothing in it (a button that
/// was focused went away, a text field gave up the focus after submitting), it goes back to the last item focused in
/// that scope, or the first one.
class TvFocusRing extends StatefulWidget {
  const TvFocusRing({super.key, required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  State<TvFocusRing> createState() => _TvFocusRingState();
}

class _TvFocusRingState extends State<TvFocusRing> with SingleTickerProviderStateMixin {
  final _paintKey = GlobalKey();
  final _repaint = _Repaint();
  late final Ticker _ticker = createTicker(_tick);
  Duration _tickerStarted = Duration.zero;
  Duration _lastTick = Duration.zero;

  FocusNode? _node;
  FocusNode? _lastLeaf;
  Rect? _from; // where the ring was when the focus moved
  Rect? _drawn; // where it was last painted
  double _move = 1; // 0 → 1 while gliding from _from to the node
  Duration _moveStart = Duration.zero;
  bool _pendingRescue = false;

  static const _glide = Duration(milliseconds: 140);
  static const _follow = Duration(milliseconds: 700);

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_focusChanged);
    if (widget.enabled) _setup();
  }

  @override
  void didUpdateWidget(TvFocusRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && !oldWidget.enabled) _setup();
    if (!widget.enabled && oldWidget.enabled) {
      _node = null;
      _drawn = null;
      _repaint.ping();
    }
  }

  void _setup() {
    // Remote controls only ever produce keys: show focus the way a keyboard does.
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    _focusChanged();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_focusChanged);
    _ticker.dispose();
    super.dispose();
  }

  void _focusChanged() {
    if (!widget.enabled || !mounted) return;
    final node = FocusManager.instance.primaryFocus;
    if (node != _node) {
      _from = _drawn;
      _node = node;
      _move = _from == null ? 1 : 0;
      _moveStart = _lastTick;
      if (node != null && node is! FocusScopeNode && node.context != null) {
        _lastLeaf = node;
        // Two frames on: after the traversal's own scrolling and a TvFocusable's centring have been asked for.
        SchedulerBinding.instance.addPostFrameCallback((_) {
          SchedulerBinding.instance.addPostFrameCallback((_) => _revealEdge(node));
          SchedulerBinding.instance.scheduleFrame();
        });
      }
    }
    if (node is FocusScopeNode && node != FocusManager.instance.rootScope && _healsItself[node] != true) _scheduleRescue();
    _follow0();
  }

  /// When the item that just took the focus would still be in full view with its list scrolled to the very top (or
  /// the very end), the list goes there. What lies above the first row that can take the focus (a page's title and
  /// year over its buttons) is never reached by the focus itself: moving up only brings the row to the edge, so once
  /// the page had scrolled, that part stayed out of sight for good.
  void _revealEdge(FocusNode node) {
    if (!mounted || !widget.enabled || !node.hasPrimaryFocus) return;
    final context = node.context;
    if (context == null) return;
    final scrollable = Scrollable.maybeOf(context, axis: Axis.vertical);
    final box = scrollable?.context.findRenderObject();
    if (scrollable == null || scrollable.axisDirection != AxisDirection.down || box is! RenderBox || !box.attached || !box.hasSize) return;
    final position = scrollable.position;
    if (!position.hasPixels || !position.hasContentDimensions || position.maxScrollExtent <= position.minScrollExtent) return;
    final viewport = box.localToGlobal(Offset.zero) & box.size;
    final item = node.rect;
    // Where the item is along the list, whatever the list's offset is now.
    final top = position.pixels + item.top - viewport.top;
    final bottom = top + item.height;
    final double target;
    if (bottom - position.minScrollExtent <= viewport.height) {
      target = position.minScrollExtent;
    } else if (top >= position.maxScrollExtent) {
      target = position.maxScrollExtent;
    } else {
      return;
    }
    if ((position.pixels - target).abs() < 1) return;
    position.animateTo(target, duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
  }

  /// The focus is on a scope with nothing in it: give it back to an item after this frame (a route that was just
  /// pushed focuses its own first item by then).
  void _scheduleRescue() {
    if (_pendingRescue) return;
    _pendingRescue = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _pendingRescue = false;
      if (!mounted || !widget.enabled) return;
      final node = FocusManager.instance.primaryFocus;
      if (node is! FocusScopeNode || node == FocusManager.instance.rootScope) return;
      final scope = node;
      final last = _lastLeaf;
      if (last != null && last.context != null && last.canRequestFocus && last.ancestors.contains(scope)) {
        last.requestFocus();
        return;
      }
      final first = _firstIn(scope);
      first?.requestFocus();
    });
  }

  static FocusNode? _firstIn(FocusScopeNode scope) {
    // The scope a route is in (its focused child), down to the first item that can take the focus.
    var current = scope;
    while (true) {
      final child = current.focusedChild;
      if (child is FocusScopeNode && child.canRequestFocus) {
        current = child;
        continue;
      }
      break;
    }
    for (final n in current.traversalDescendants) {
      if (n is! FocusScopeNode && n.context != null && n.canRequestFocus) return n;
    }
    return null;
  }

  /// Repaints every frame for a little while: the ring glides, and follows its item while it scrolls or animates.
  void _follow0() {
    _tickerStarted = _lastTick;
    if (!_ticker.isActive) {
      _tickerStarted = Duration.zero;
      _lastTick = Duration.zero;
      _moveStart = Duration.zero;
      _ticker.start();
    }
    _repaint.ping();
  }

  void _tick(Duration elapsed) {
    _lastTick = elapsed;
    _move = _glide.inMicroseconds == 0 ? 1 : ((elapsed - _moveStart).inMicroseconds / _glide.inMicroseconds).clamp(0.0, 1.0);
    _repaint.ping();
    if (elapsed - _tickerStarted > _follow && _move >= 1) _ticker.stop();
  }

  bool _onScroll(ScrollNotification n) {
    if (widget.enabled && _node != null) _follow0();
    return false;
  }

  /// Where to draw for the focused node, in this widget's coordinates; null when nothing should be drawn.
  Rect? _target(Size screen) {
    final node = _node;
    if (node == null || node is FocusScopeNode || _ownsFocusLook[node] == true) return null;
    final context = node.context;
    if (context == null || !context.mounted) return null;
    final RenderObject? object;
    try {
      object = context.findRenderObject();
    } catch (_) {
      // Taken out of the tree this frame (a page closing): nothing to draw around.
      return null;
    }
    if (object is! RenderBox || !object.attached || !object.hasSize) return null;
    final paintBox = _paintKey.currentContext?.findRenderObject();
    if (paintBox is! RenderBox || !paintBox.attached) return null;
    final rect = Rect.fromPoints(
      paintBox.globalToLocal(object.localToGlobal(Offset.zero)),
      paintBox.globalToLocal(object.localToGlobal(object.size.bottomRight(Offset.zero))),
    );
    if (rect.isEmpty || !rect.isFinite) return null;
    // A page, a player or a list that holds the focus as a whole: no outline around the screen.
    if (rect.width * rect.height > screen.width * screen.height * 0.35) return null;
    return rect;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      textDirection: TextDirection.ltr,
      fit: StackFit.expand,
      children: [
        NotificationListener<ScrollNotification>(onNotification: _onScroll, child: widget.child),
        if (widget.enabled)
          IgnorePointer(
            child: CustomPaint(key: _paintKey, painter: _RingPainter(this)),
          ),
      ],
    );
  }
}

class _Repaint extends ChangeNotifier {
  void ping() => notifyListeners();
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.state) : super(repaint: state._repaint);

  final _TvFocusRingState state;

  @override
  void paint(Canvas canvas, Size size) {
    final target = state._target(size);
    if (target == null) {
      state._drawn = null;
      return;
    }
    final from = state._from;
    final t = Curves.easeOutCubic.transform(state._move);
    final rect = from == null || t >= 1 ? target : Rect.lerp(from, target, t)!;
    state._drawn = rect;
    final outer = rect.inflate(4);
    final radius = Radius.circular(math.min(14, outer.shortestSide / 2));
    final rrect = RRect.fromRectAndRadius(outer, radius);
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = TvColors.yellow.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = TvColors.coral
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => true;
}

/// A focusable item for the remote: OK (or Enter / Space) activates it, the menu key and holding OK can do something
/// else; when focused on a TV it grows and gets an outline in the brand colours, and its scrollables bring it to the
/// middle of the view. Off TV it is a plain clickable widget (the mouse and touch behave as before) that can also
/// be reached with the keyboard.
class TvFocusable extends StatefulWidget {
  const TvFocusable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onMenu,
    this.onFocusChange,
    this.focusNode,
    this.autofocus = false,
    this.scale = 1.06,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.outline = true,
    this.center = true,
    this.mouseCursor = SystemMouseCursors.click,
  });

  final Widget child;
  final VoidCallback? onTap;

  /// Holding OK on the remote (a long press with touch or a secondary click with the mouse are up to the child).
  final VoidCallback? onLongPress;

  /// The menu key while this item has the focus.
  final VoidCallback? onMenu;
  final ValueChanged<bool>? onFocusChange;
  final FocusNode? focusNode;
  final bool autofocus;

  /// How much it grows when focused on a TV.
  final double scale;
  final BorderRadius borderRadius;

  /// Draw the outline (some items show their focus differently, e.g. a filled background).
  final bool outline;

  /// Scroll the item to the middle of its scrollables when it gets the focus on a TV.
  final bool center;
  final MouseCursor mouseCursor;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  FocusNode? _own;
  FocusNode get _node => widget.focusNode ?? (_own ??= FocusNode(debugLabel: 'TvFocusable'));
  bool _focused = false;
  bool _longPressed = false;
  bool _okDown = false;

  @override
  void initState() {
    super.initState();
    tvOwnFocusLook(_node);
  }

  @override
  void didUpdateWidget(TvFocusable oldWidget) {
    super.didUpdateWidget(oldWidget);
    tvOwnFocusLook(_node);
  }

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  void _focusChanged(bool focused) {
    setState(() => _focused = focused);
    widget.onFocusChange?.call(focused);
    if (focused && widget.center && DeviceFormScope.readIsTv(context)) {
      // After the traversal's own scrolling, which only brings the item to the edge.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_node.hasPrimaryFocus) return;
        Scrollable.ensureVisible(context, alignment: 0.5, duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
      });
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (widget.onMenu != null && TvKeys.isMenu(key)) {
      if (event is KeyDownEvent) widget.onMenu!();
      return KeyEventResult.handled;
    }
    if (widget.onLongPress == null || !TvKeys.isActivate(key)) return KeyEventResult.ignored;
    // With a long-press action, OK acts when it is let go: held, it is the long press instead.
    if (event is KeyDownEvent) {
      _okDown = true;
      _longPressed = false;
    } else if (event is KeyRepeatEvent) {
      if (_okDown && !_longPressed) {
        _longPressed = true;
        widget.onLongPress!();
      }
    } else if (event is KeyUpEvent) {
      if (_okDown && !_longPressed) widget.onTap?.call();
      _okDown = false;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final tv = isTv(context);
    final lit = tv && _focused;
    Widget child = widget.child;
    if (widget.outline) {
      child = DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: widget.borderRadius,
          border: lit ? Border.all(color: TvColors.coral, width: 3, strokeAlign: BorderSide.strokeAlignOutside) : null,
          boxShadow: lit ? [BoxShadow(color: TvColors.yellow.withValues(alpha: 0.35), blurRadius: 14, spreadRadius: 1)] : null,
        ),
        child: child,
      );
    }
    if (tv) {
      child = AnimatedScale(scale: lit ? widget.scale : 1, duration: const Duration(milliseconds: 140), curve: Curves.easeOut, child: child);
    }
    return Actions(
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      child: Focus(
        focusNode: _node,
        autofocus: widget.autofocus,
        canRequestFocus: widget.onTap != null || widget.onLongPress != null || widget.onMenu != null,
        onFocusChange: _focusChanged,
        onKeyEvent: _onKey,
        child: MouseRegion(
          cursor: widget.onTap == null ? MouseCursor.defer : widget.mouseCursor,
          child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: widget.onTap, child: child),
        ),
      ),
    );
  }
}

/// On a TV, puts the focus on the first focusable widget inside [child] when it first appears, even when something
/// else in the route already has the focus (`autofocus` only works in a route that has nothing focused yet, and a
/// page that loads its content has usually focused its back button by then). Off TV it does nothing.
class TvAutofocus extends StatefulWidget {
  const TvAutofocus({super.key, required this.child, this.enabled = true});

  final Widget child;
  final bool enabled;

  @override
  State<TvAutofocus> createState() => _TvAutofocusState();
}

class _TvAutofocusState extends State<TvAutofocus> {
  final _node = FocusNode(debugLabel: 'TvAutofocus', canRequestFocus: false, skipTraversal: true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.enabled || !DeviceFormScope.readIsTv(context)) return;
      for (final n in _node.traversalDescendants) {
        if (n.context != null && n.canRequestFocus) {
          n.requestFocus();
          return;
        }
      }
    });
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(focusNode: _node, child: widget.child);
}

/// Scales its child up while anything inside it has the focus, on a TV (for buttons that keep their own look).
class TvFocusScale extends StatefulWidget {
  const TvFocusScale({super.key, required this.child, this.scale = 1.08});

  final Widget child;
  final double scale;

  @override
  State<TvFocusScale> createState() => _TvFocusScaleState();
}

class _TvFocusScaleState extends State<TvFocusScale> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    if (!isTv(context)) return widget.child;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) => setState(() => _focused = f),
      child: AnimatedScale(scale: _focused ? widget.scale : 1, duration: const Duration(milliseconds: 140), child: widget.child),
    );
  }
}
