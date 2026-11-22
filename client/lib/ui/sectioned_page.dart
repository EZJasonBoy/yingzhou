import 'dart:math' as math;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'device_form.dart';
import 'tv/tv_focus.dart';

/// One group of a [SectionedPage]: a heading and the cards under it.
class PageSection {
  const PageSection({required this.id, required this.title, required this.icon, required this.children, this.gap = 10, this.side = false});

  final String id;
  final String title;
  final IconData icon;
  final List<Widget> children;

  /// Under the heading: none where the first card brings its own 12 above itself.
  final double gap;

  /// On a wide window this group stands in a column of its own on the right, next to the others (a long list that
  /// should stay in sight, like the sites next to the subscriptions).
  final bool side;
}

/// A page of settings made of groups ([PageSection]). It is one scrolling page on every device, so nothing is hidden
/// behind a level, and it uses the width it gets:
///
/// - a window wide enough has the list of groups on the left: an entry scrolls its group to the top (with a remote
///   the page follows the focus along the list, and OK or → goes into the group), and the entry of the group in view
///   is marked;
/// - the cards of a group stand in two columns when there is room, so the page is half as long;
/// - a narrow window (a phone) has the groups as a row of chips above the page instead.
///
/// A group whose cards all have nothing to show on this engine is left out: no heading, no entry.
class SectionedPage extends StatefulWidget {
  const SectionedPage({super.key, required this.title, required this.sections, this.listKey, this.standalone = false, this.initialSection});

  final String title;
  final List<PageSection> sections;

  /// The key of the scrolling page.
  final Key? listKey;

  /// Opened as a page of its own, with a bar to go back.
  final bool standalone;

  /// The group the page opens on, once it is laid out; the top when null.
  final String? initialSection;

  /// The list of groups shows from this page width on. A TV shows it sooner: its screen is 960 wide with a margin
  /// all round, and a remote needs the list more than it needs room.
  static const indexFrom = 860.0;
  static const indexFromOnTv = 620.0;

  /// Cards stand in two columns when the page beside the list is at least this wide.
  static const twoColumnsFrom = 880.0;

  @override
  State<SectionedPage> createState() => _SectionedPageState();
}

class _SectionedPageState extends State<SectionedPage> {
  final _scroll = ScrollController();
  final _headings = <String, GlobalKey>{};
  final _groups = <String, FocusNode>{};
  final _flows = <String, GlobalKey>{};
  String? _current;

  /// The groups whose cards take no room (measured after each layout).
  Set<String> _empty = const {};
  bool _measuring = false;

  /// The group an entry sent the page to: the mark stays on it while the page scrolls there.
  String? _goingTo;

  @override
  void initState() {
    super.initState();
    final first = widget.initialSection;
    if (first != null) {
      // Two frames: the first lays the page out, the second has the heading's place.
      WidgetsBinding.instance.addPostFrameCallback((_) => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _go(first);
      }));
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    for (final n in _groups.values) {
      n.dispose();
    }
    super.dispose();
  }

  /// After this frame: which groups are empty. Cards come and go as the engine answers, so this is asked again
  /// whenever a group changes size.
  void _measureSoon() {
    if (_measuring) return;
    _measuring = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measuring = false;
      if (!mounted) return;
      final empty = <String>{};
      for (final s in widget.sections) {
        final box = _flows[s.id]?.currentContext?.findRenderObject();
        // Less than any card: nothing, or only the padding a hidden card was wrapped in.
        if (box is RenderBox && box.hasSize && box.size.height < 16) empty.add(s.id);
      }
      if (!setEquals(empty, _empty)) setState(() => _empty = empty);
    });
  }

  GlobalKey _heading(String id) => _headings.putIfAbsent(id, () => GlobalKey(debugLabel: 'section-$id'));
  FocusNode _group(String id) => _groups.putIfAbsent(id, () => FocusNode(debugLabel: 'section-$id', canRequestFocus: false, skipTraversal: true));

  /// How far the page is scrolled when [id]'s heading is at its top; null while it is not laid out.
  double? _offsetOf(String id) {
    final box = _headings[id]?.currentContext?.findRenderObject();
    if (box == null || !box.attached) return null;
    return RenderAbstractViewport.maybeOf(box)?.getOffsetToReveal(box, 0).offset;
  }

  void _go(String id) {
    final offset = _offsetOf(id);
    if (offset == null || !_scroll.hasClients) return;
    final target = (offset - 4).clamp(0.0, _scroll.position.maxScrollExtent);
    setState(() => _current = _goingTo = id);
    _scroll.animateTo(target, duration: const Duration(milliseconds: 220), curve: Curves.easeOut).whenComplete(() {
      if (_goingTo == id) _goingTo = null;
    });
  }

  /// Into the group: its first control takes the focus (the remote's OK or → on its entry).
  void _enter(String id) {
    _go(id);
    for (final n in _groups[id]?.traversalDescendants ?? const <FocusNode>[]) {
      if (n.canRequestFocus && n.context != null) {
        n.requestFocus();
        return;
      }
    }
  }

  /// The group in view: the last one whose heading has reached the top of the page.
  void _spy() {
    if (_goingTo != null || !_scroll.hasClients) return;
    String? current;
    for (final s in widget.sections) {
      if (_empty.contains(s.id)) continue;
      final offset = _offsetOf(s.id);
      if (offset == null) continue;
      current ??= s.id;
      if (offset <= _scroll.offset + 32) current = s.id;
    }
    if (current != _current) setState(() => _current = current);
  }

  @override
  Widget build(BuildContext context) {
    _measureSoon();
    final sections = [for (final s in widget.sections) if (!_empty.contains(s.id)) s];
    final current = sections.any((s) => s.id == _current) ? _current : (sections.isEmpty ? null : sections.first.id);
    return Scaffold(
      appBar: widget.standalone ? AppBar(title: Text(widget.title)) : null,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final withIndex = constraints.maxWidth >= (isTv(context) ? SectionedPage.indexFromOnTv : SectionedPage.indexFrom);
            if (!withIndex) {
              return Column(
                children: [
                  if (sections.length > 2) _chips(context, sections, current),
                  Expanded(child: _page(context, constraints.maxWidth, withIndex: false)),
                ],
              );
            }
            final indexWidth = isTv(context) ? 168.0 : 184.0;
            final width = math.min(constraints.maxWidth, 1480.0);
            return Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: width,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: indexWidth, child: _index(context, sections, current)),
                    Expanded(child: _page(context, width - indexWidth, withIndex: true)),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _index(BuildContext context, List<PageSection> sections, String? current) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!widget.standalone)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 0, 14),
              child: Text(widget.title, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            ),
          for (final s in sections)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: _IndexEntry(
                key: Key('section-index-${s.id}'),
                section: s,
                selected: s.id == current,
                onTap: () => isTv(context) ? _enter(s.id) : _go(s.id),
                onEnter: () => _enter(s.id),
                onFocus: () {
                  if (isTv(context)) _go(s.id);
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _chips(BuildContext context, List<PageSection> sections, String? current) {
    return SizedBox(
      height: 52,
      child: ListView(
        key: const Key('section-chips'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        children: [
          for (final s in sections)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: ChoiceChip(
                  key: Key('section-chip-${s.id}'),
                  label: Text(s.title),
                  selected: s.id == current,
                  showCheckmark: false,
                  onSelected: (_) => _go(s.id),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _page(BuildContext context, double width, {required bool withIndex}) {
    final theme = Theme.of(context);
    final sections = widget.sections;
    final left = withIndex ? 12.0 : 20.0;
    final inner = width - left - 20;
    final wide = inner >= SectionedPage.twoColumnsFrom;
    final columns = wide ? 2 : 1;
    final twoPanes = wide && sections.any((s) => s.side) && sections.any((s) => !s.side);

    Widget section(PageSection s, int columns) => Focus(
          focusNode: _group(s.id),
          canRequestFocus: false,
          skipTraversal: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Kept in the tree while its group is empty, so it is there again the moment a card shows up.
              Offstage(
                offstage: _empty.contains(s.id),
                child: Padding(
                  key: _heading(s.id),
                  padding: EdgeInsets.fromLTRB(4, 22, 4, s.gap),
                  child: Text(s.title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                ),
              ),
              NotificationListener<SizeChangedLayoutNotification>(
                onNotification: (_) {
                  _measureSoon();
                  return true;
                },
                child: SizeChangedLayoutNotifier(child: ColumnsFlow(key: _flows.putIfAbsent(s.id, () => GlobalKey(debugLabel: 'flow-${s.id}')), columns: columns, gap: 16, children: s.children)),
              ),
            ],
          ),
        );

    return NotificationListener<ScrollUpdateNotification>(
      onNotification: (n) {
        if (n.depth == 0) _spy();
        return false;
      },
      // All of it is built, not only what is on screen: a remote's ↓ can only go to an item that exists.
      child: SingleChildScrollView(
        key: widget.listKey,
        controller: _scroll,
        padding: EdgeInsets.fromLTRB(left, withIndex || widget.standalone ? 0 : 16, 20, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!withIndex && !widget.standalone) Text(widget.title, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            if (twoPanes)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final s in sections) if (!s.side) section(s, 1)]),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final s in sections) if (s.side) section(s, 1)]),
                  ),
                ],
              )
            else
              for (final s in sections) section(s, columns),
          ],
        ),
      ),
    );
  }
}

/// An entry of the list of groups.
class _IndexEntry extends StatelessWidget {
  const _IndexEntry({super.key, required this.section, required this.selected, required this.onTap, required this.onEnter, required this.onFocus});

  final PageSection section;
  final bool selected;
  final VoidCallback onTap;

  /// → on the entry: into the group.
  final VoidCallback onEnter;
  final VoidCallback onFocus;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.arrowRight) {
          onEnter();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: TvFocusable(
        onTap: onTap,
        onFocusChange: (focused) {
          if (focused) onFocus();
        },
        scale: 1.04,
        center: false,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(color: selected ? scheme.surfaceContainerHigh : Colors.transparent, borderRadius: BorderRadius.circular(10)),
          child: Row(
            children: [
              Icon(section.icon, size: 20, color: fg),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  section.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, fontWeight: selected ? FontWeight.w700 : FontWeight.w500, color: selected ? scheme.onSurface : scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lays its children out in [columns] columns of the same width, each child in the column that is shortest so far.
/// A child without height (a card that has nothing to show on this engine) takes no place.
class ColumnsFlow extends MultiChildRenderObjectWidget {
  const ColumnsFlow({super.key, required this.columns, this.gap = 16, super.children});

  final int columns;
  final double gap;

  @override
  RenderColumnsFlow createRenderObject(BuildContext context) => RenderColumnsFlow(columns: columns, gap: gap);

  @override
  void updateRenderObject(BuildContext context, RenderColumnsFlow renderObject) {
    renderObject
      ..columns = columns
      ..gap = gap;
  }
}

class _FlowParentData extends ContainerBoxParentData<RenderBox> {}

class RenderColumnsFlow extends RenderBox with ContainerRenderObjectMixin<RenderBox, _FlowParentData>, RenderBoxContainerDefaultsMixin<RenderBox, _FlowParentData> {
  RenderColumnsFlow({required int columns, required double gap}) : _columns = columns, _gap = gap; // ignore: prefer_initializing_formals

  int _columns;
  int get columns => _columns;
  set columns(int value) {
    if (value == _columns) return;
    _columns = value;
    markNeedsLayout();
  }

  double _gap;
  double get gap => _gap;
  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _FlowParentData) child.parentData = _FlowParentData();
  }

  double _columnWidth(double width) => math.max(0, (width - _gap * (_columns - 1)) / _columns);

  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final width = constraints.maxWidth;
    final columnWidth = _columnWidth(width);
    final inner = BoxConstraints.tightFor(width: columnWidth);
    final heights = List<double>.filled(_columns, 0);
    var child = firstChild;
    while (child != null) {
      final size = dry ? child.getDryLayout(inner) : (child..layout(inner, parentUsesSize: true)).size;
      var column = 0;
      for (var i = 1; i < _columns; i++) {
        if (heights[i] < heights[column] - 0.5) column = i;
      }
      if (!dry) (child.parentData! as _FlowParentData).offset = Offset(column * (columnWidth + _gap), heights[column]);
      heights[column] += size.height;
      child = childAfter(child);
    }
    return constraints.constrain(Size(width, heights.reduce(math.max)));
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => _layout(constraints, dry: true);

  @override
  void performLayout() => size = _layout(constraints, dry: false);

  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) => 0;

  @override
  double computeMinIntrinsicHeight(double width) => computeMaxIntrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) {
    final columnWidth = _columnWidth(width);
    final heights = List<double>.filled(_columns, 0);
    var child = firstChild;
    while (child != null) {
      var column = 0;
      for (var i = 1; i < _columns; i++) {
        if (heights[i] < heights[column] - 0.5) column = i;
      }
      heights[column] += child.getMaxIntrinsicHeight(columnWidth);
      child = childAfter(child);
    }
    return heights.reduce(math.max);
  }

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) => defaultHitTestChildren(result, position: position);
}
