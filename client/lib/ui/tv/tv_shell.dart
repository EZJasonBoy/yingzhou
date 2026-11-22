import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../brand.dart';
import '../device_form.dart';
import 'tv_focus.dart';

/// One entry of the navigation (the same list the desktop rail shows).
typedef TvDestination = ({IconData icon, IconData selected, String label});

/// The app's frame on a TV: a column of big entries on the left and the page on the right, all driven by the remote.
///
/// - ↑/↓ move along the entries, OK opens one and moves the focus into it; → goes into the page where its focus was
///   last time; ← from the left edge of a page comes back to the entry.
/// - BACK from inside a page goes to its entry; from an entry, back to 首页; on 首页 it asks before quitting (a
///   desktop in the TV layout is also offered its desktop layout back there).
/// - Live TV in full screen ([immersive]) hides the column; the page keeps its state either way.
class TvShell extends StatefulWidget {
  const TvShell({super.key, required this.index, required this.destinations, required this.onSelect, required this.pages, this.immersive = false});

  final int index;
  final List<TvDestination> destinations;
  final ValueChanged<int> onSelect;
  final Widget pages;
  final bool immersive;

  @override
  State<TvShell> createState() => TvShellState();
}

class TvShellState extends State<TvShell> {
  final _railScope = FocusScopeNode(debugLabel: 'tv-rail');
  final _pagesScope = FocusScopeNode(debugLabel: 'tv-pages');
  late List<FocusNode> _items = _makeItems();

  /// Where the focus was in each page, to put it back when the page is entered again.
  final _lastFocus = <int, FocusNode>{};

  List<FocusNode> _makeItems() => [for (var i = 0; i < widget.destinations.length; i++) FocusNode(debugLabel: 'tv-rail-$i')];

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_focusChanged);
    tvHealsItself(_railScope);
    tvHealsItself(_pagesScope);
    // Start on 首页's entry (the shell's own autofocus puts the focus on a container first; see _focusChanged).
    _healSoon();
  }

  @override
  void didUpdateWidget(TvShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.destinations.length != widget.destinations.length) {
      for (final n in _items) {
        n.dispose();
      }
      _items = _makeItems();
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_focusChanged);
    for (final n in _items) {
      n.dispose();
    }
    _tileTimer?.cancel();
    _railScope.dispose();
    _pagesScope.dispose();
    super.dispose();
  }

  void _focusChanged() {
    final node = FocusManager.instance.primaryFocus;
    if (_lostIn(node)) {
      _healSoon();
      return;
    }
    if (node == null || node is FocusScopeNode) return;
    if (node.ancestors.contains(_pagesScope)) _lastFocus[widget.index] = node;
  }

  /// The focus sits on a container of the shell (the app's own key handler, the route, the rail's or the pages'
  /// scope) instead of an item: the remote would have nothing to move from.
  bool _lostIn(FocusNode? node) {
    if (node == null) return false;
    if (node == _pagesScope || node == _railScope) return true;
    final item = _items[widget.index];
    return item.context != null && item.ancestors.contains(node);
  }

  bool _healing = false;

  /// After this frame (pages and routes put their own focus first), back to the page's last item or the entry.
  void _healSoon() {
    if (_healing) return;
    _healing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _healing = false;
      if (!mounted || !_lostIn(FocusManager.instance.primaryFocus)) return;
      if (FocusManager.instance.primaryFocus == _pagesScope && enterPage()) return;
      focusRail();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  bool get _inPages => FocusManager.instance.primaryFocus?.ancestors.contains(_pagesScope) ?? false;

  /// Puts the focus on the current page's entry.
  void focusRail() => _items[widget.index].requestFocus();

  /// Puts the focus back where it was in the current page, else on its first item; false when it has none.
  bool enterPage() {
    final last = _lastFocus[widget.index];
    if (last != null && last.context != null && last.context!.mounted && last.canRequestFocus && last.ancestors.contains(_pagesScope)) {
      last.requestFocus();
      return true;
    }
    final first = _firstItem();
    if (first == null) return false;
    first.requestFocus();
    return true;
  }

  /// The first item of the page: the first poster or tile when there is one, else whatever comes first.
  FocusNode? _firstItem() {
    FocusNode? any;
    for (final n in _pagesScope.traversalDescendants) {
      if (n is FocusScopeNode || n.context == null) continue;
      any ??= n;
      if (_isTile(n)) return n;
    }
    return any;
  }

  static bool _isTile(FocusNode n) {
    final w = n.context?.findAncestorWidgetOfExactType<TvFocusable>();
    return w != null && w.onTap != null;
  }

  void _select(int i) {
    if (i != widget.index) widget.onSelect(i);
    // Into the page once it has been built (live TV and others start loading when shown).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!enterPage()) _items[i].requestFocus();
      _preferTileSoon(i);
    });
  }

  Timer? _tileTimer;

  /// A page that loads its content after it is entered (我的, 网盘) first offers only its header buttons: when its
  /// posters or tiles show up within a couple of seconds, and the focus has not been moved meanwhile, it goes to the
  /// first of them.
  void _preferTileSoon(int index) {
    _tileTimer?.cancel();
    // Where entering the page put the focus: known once that request has been applied, i.e. at the first tick.
    FocusNode? landed;
    var ticks = 0;
    _tileTimer = Timer.periodic(const Duration(milliseconds: 250), (t) {
      final now = FocusManager.instance.primaryFocus;
      landed ??= now;
      if (!mounted || widget.index != index || now == null || now != landed || _isTile(now) || !_inPages || ++ticks > 10) {
        t.cancel();
        return;
      }
      for (final n in _pagesScope.traversalDescendants) {
        if (n is! FocusScopeNode && n.context != null && _isTile(n)) {
          t.cancel();
          n.requestFocus();
          return;
        }
      }
    });
  }

  /// BACK on the main screen: out of the page, then to 首页, then ask before quitting.
  Future<void> handleBack() async {
    if (_inPages) {
      focusRail();
      return;
    }
    if (widget.index != 0) {
      widget.onSelect(0);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _items[0].requestFocus();
      });
      return;
    }
    // A computer in the TV layout (full screen): the way back to its desktop layout is offered here too.
    final forms = DeviceFormScope.maybeControllerOf(context);
    final desktop = forms != null && forms.isDesktopPlatform;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出映舟？'),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
          if (desktop && forms.canOverride)
            TextButton(key: const Key('tv-leave-mode'), onPressed: () => Navigator.of(context).pop('desktop'), child: const Text('回到桌面界面')),
          FilledButton(onPressed: () => Navigator.of(context).pop('quit'), child: const Text('退出')),
        ],
      ),
    );
    if (choice == 'desktop') {
      await forms?.setOverride(DeviceFormOverride.auto);
    } else if (choice == 'quit') {
      // Desktops have no "back out of the app"; they are asked to close it.
      if (desktop) {
        await ServicesBinding.instance.exitApplication(ui.AppExitType.cancelable);
      } else {
        await SystemNavigator.pop();
      }
    }
  }

  void _onEdge(TraversalDirection direction) {
    if (direction == TraversalDirection.left && _inPages) {
      focusRail();
    } else if (direction == TraversalDirection.right && !_inPages) {
      enterPage();
    }
  }

  /// The column is wide (labels) while it has the focus, and only icons while a page has it.
  bool _railOpen = false;

  static const collapsedWidth = 76.0;
  static const openWidth = 188.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final left = MediaQuery.paddingOf(context).left;
    final rail = Offstage(
      offstage: widget.immersive,
      child: ExcludeFocus(
        excluding: widget.immersive,
        child: FocusScope(
          node: _railScope,
          onFocusChange: (f) => setState(() => _railOpen = f),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            width: left + (_railOpen ? openWidth : collapsedWidth),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLowest,
              boxShadow: _railOpen ? [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 24)] : null,
            ),
            child: SafeArea(right: false, child: _buildRail(context)),
          ),
        ),
      ),
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) handleBack();
      },
      child: Actions(
        actions: {DirectionalFocusIntent: _EdgeAwareDirectionalFocusAction(_onEdge)},
        child: Scaffold(
          backgroundColor: widget.immersive ? Colors.black : null,
          // The system keyboard does not squeeze the column of entries (it would overflow); the page under it makes
          // room for its own text field.
          resizeToAvoidBottomInset: false,
          body: Stack(
            children: [
              // The page starts right of the closed column; the open one lies over it, so nothing reflows.
              Positioned.fill(
                left: widget.immersive ? 0 : left + collapsedWidth,
                child: MediaQuery.removePadding(
                  context: context,
                  removeLeft: !widget.immersive,
                  child: FocusScope(node: _pagesScope, child: widget.pages),
                ),
              ),
              Positioned(left: 0, top: 0, bottom: 0, child: rail),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRail(BuildContext context) {
    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: 0,
        maxWidth: double.infinity,
        child: SizedBox(
          width: _railOpen ? openWidth : collapsedWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 8, 8, 22),
                child: Row(
                  children: [
                    const BrandMark(size: 30),
                    if (_railOpen) ...[
                      const SizedBox(width: 10),
                      Text('映舟', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                    ],
                  ],
                ),
              ),
              // Eight entries (the developer mode's) are taller than a 540-high screen: the list scrolls with the focus.
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < widget.destinations.length; i++)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
                          child: _RailItem(
                            key: Key('tv-rail-$i'),
                            focusNode: _items[i],
                            destination: widget.destinations[i],
                            selected: i == widget.index,
                            open: _railOpen,
                            onTap: () => _select(i),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({super.key, required this.focusNode, required this.destination, required this.selected, required this.open, required this.onTap});

  final FocusNode focusNode;
  final TvDestination destination;
  final bool selected;

  /// With its label (the column has the focus) or only the icon.
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onPrimaryContainer : scheme.onSurface;
    return TvFocusable(
      focusNode: focusNode,
      onTap: onTap,
      center: false,
      scale: 1.06,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 50,
        padding: EdgeInsets.symmetric(horizontal: open ? 16 : 0),
        alignment: open ? Alignment.centerLeft : Alignment.center,
        decoration: BoxDecoration(color: selected ? scheme.primaryContainer : Colors.transparent, borderRadius: BorderRadius.circular(999)),
        child: Row(
          mainAxisSize: open ? MainAxisSize.max : MainAxisSize.min,
          children: [
            Icon(selected ? destination.selected : destination.icon, size: 28, color: fg),
            if (open) ...[
              const SizedBox(width: 14),
              Text(
                destination.label,
                style: TextStyle(fontSize: 18, fontWeight: selected ? FontWeight.w700 : FontWeight.w500, color: fg),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Moves the focus like the default arrow-key action, and when there is nothing in that direction (the edge of the
/// rail or of the page) tells the shell, which moves between the two.
class _EdgeAwareDirectionalFocusAction extends DirectionalFocusAction {
  _EdgeAwareDirectionalFocusAction(this.onEdge);

  final ValueChanged<TraversalDirection> onEdge;

  @override
  void invoke(DirectionalFocusIntent intent) {
    final node = FocusManager.instance.primaryFocus;
    if (node == null) return;
    if (!node.focusInDirection(intent.direction)) onEdge(intent.direction);
  }
}
