import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../pages/browse_page.dart';
import '../pages/drives_page.dart';
import '../pages/library_page.dart';
import '../pages/live_page.dart';
import '../pages/search_page.dart';
import '../pages/sources_page.dart';
import 'form_factor.dart';

/// Top-level navigation: a rail on wide screens, a bottom bar on phones.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  bool _immersive = false; // live TV in fullscreen: no rail or bottom bar
  // Keeps the pages (and a playing live channel) alive when the layout around them changes: rail / bottom bar /
  // fullscreen, or the window crossing the phone-width breakpoint.
  final _pagesKey = GlobalKey();
  final _searchFocus = FocusNode();

  @override
  void dispose() {
    _searchFocus.dispose();
    super.dispose();
  }

  void _openSearch() {
    _go(2);
    WidgetsBinding.instance.addPostFrameCallback((_) => _searchFocus.requestFocus());
  }

  static const _destinations = [
    (icon: Icons.home_outlined, selected: Icons.home_rounded, label: '首页'),
    (icon: Icons.live_tv_outlined, selected: Icons.live_tv_rounded, label: '直播'),
    (icon: Icons.search_outlined, selected: Icons.search_rounded, label: '搜索'),
    (icon: Icons.video_library_outlined, selected: Icons.video_library_rounded, label: '我的'),
    (icon: Icons.dns_outlined, selected: Icons.dns_rounded, label: '源'),
    (icon: Icons.cloud_outlined, selected: Icons.cloud_rounded, label: '网盘'),
  ];

  void _go(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    // Ctrl+F (Cmd+F on macOS) jumps to search from anywhere in the main window.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _openSearch,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): _openSearch,
      },
      child: Focus(autofocus: true, child: _backToHome(_layout(context))),
    );
  }

  /// Phones, tablets and TVs: the system's back on another tab goes to 首页 first; on 首页 it leaves the app. Live TV in
  /// full screen handles back itself (it leaves full screen).
  Widget _backToHome(Widget child) {
    if (FormFactors.isDesktop) return child;
    // The status and navigation bars are see-through, their icons following the theme (pages with an app bar set
    // their own).
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bars = (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarContrastEnforced: false,
    );
    return AnnotatedRegion<SystemUiOverlayStyle>(value: bars, child: PopScope(
      canPop: _index == 0 && !_immersive,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_immersive && _index != 0) _go(0);
      },
      child: child,
    ));
  }

  /// The rail on a tablet or a phone held sideways. Short windows (a phone in landscape) label only the tab shown,
  /// and scroll the rail if even that does not fit.
  Widget _rail(BuildContext context, bool short) {
    final rail = NavigationRail(
      selectedIndex: _index,
      onDestinationSelected: _go,
      labelType: short ? NavigationRailLabelType.selected : NavigationRailLabelType.all,
      groupAlignment: -0.9,
      leading: short
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 20),
              child: Icon(Icons.live_tv_rounded, size: 30, color: Theme.of(context).colorScheme.primary),
            ),
      destinations: [
        for (final d in _destinations) NavigationRailDestination(icon: Icon(d.icon), selectedIcon: Icon(d.selected), label: Text(d.label)),
      ],
    );
    return ColoredBox(
      color: Theme.of(context).navigationRailTheme.backgroundColor ?? Colors.transparent,
      child: SafeArea(
        right: false,
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(constraints: BoxConstraints(minHeight: constraints.maxHeight), child: IntrinsicHeight(child: rail)),
          ),
        ),
      ),
    );
  }

  Widget _layout(BuildContext context) {
    final children = [
      BrowsePage(onOpenSources: () => _go(4)),
      LivePage(visible: _index == 1, onImmersiveChanged: (v) => setState(() => _immersive = v)),
      SearchPage(focusNode: _searchFocus),
      LibraryPage(visible: _index == 3),
      const SourcesPage(),
      DrivesPage(visible: _index == 5),
    ];
    // Hidden pages keep their state but stop animating.
    final pages = KeyedSubtree(
      key: _pagesKey,
      child: IndexedStack(
        index: _index,
        children: [for (var i = 0; i < children.length; i++) TickerMode(enabled: i == _index, child: children[i])],
      ),
    );
    if (_immersive && _index == 1) return Scaffold(backgroundColor: Colors.black, body: pages);
    final size = MediaQuery.sizeOf(context);
    final formFactor = FormFactors.of(context);
    // Bottom bar only on a phone held upright (or a narrow window); tablets and phones on their side get the rail.
    final wide = size.width >= 760 || formFactor == FormFactor.tablet || (formFactor == FormFactor.phone && size.width > size.height);
    if (wide && formFactor != FormFactor.desktop && formFactor != FormFactor.tv) {
      return Scaffold(body: Row(children: [_rail(context, size.height < 560), Expanded(child: pages)]));
    }
    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: _go,
              labelType: NavigationRailLabelType.all,
              groupAlignment: -0.9,
              leading: Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 20),
                child: Icon(Icons.live_tv_rounded, size: 30, color: Theme.of(context).colorScheme.primary),
              ),
              destinations: [
                for (final d in _destinations) NavigationRailDestination(icon: Icon(d.icon), selectedIcon: Icon(d.selected), label: Text(d.label)),
              ],
            ),
            Expanded(child: pages),
          ],
        ),
      );
    }
    return Scaffold(
      body: pages,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _go,
        destinations: [for (final d in _destinations) NavigationDestination(icon: Icon(d.icon), selectedIcon: Icon(d.selected), label: d.label)],
      ),
    );
  }
}
