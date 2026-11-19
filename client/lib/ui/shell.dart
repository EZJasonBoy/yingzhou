import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../pages/browse_page.dart';
import '../pages/drives_page.dart';
import '../pages/library_page.dart';
import '../pages/live_page.dart';
import '../pages/search_page.dart';
import '../pages/sources_page.dart';

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
      child: Focus(autofocus: true, child: _layout(context)),
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
    final wide = MediaQuery.sizeOf(context).width >= 760;
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
