import 'package:material_ui/material_ui.dart';

import '../pages/browse_page.dart';
import '../pages/library_page.dart';
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

  static const _destinations = [
    (icon: Icons.home_outlined, selected: Icons.home_rounded, label: '首页'),
    (icon: Icons.search_outlined, selected: Icons.search_rounded, label: '搜索'),
    (icon: Icons.video_library_outlined, selected: Icons.video_library_rounded, label: '我的'),
    (icon: Icons.dns_outlined, selected: Icons.dns_rounded, label: '源'),
  ];

  void _go(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    final children = [
      BrowsePage(onOpenSources: () => _go(3)),
      const SearchPage(),
      LibraryPage(visible: _index == 2),
      const SourcesPage(),
    ];
    // Hidden pages keep their state but stop animating.
    final pages = IndexedStack(
      index: _index,
      children: [for (var i = 0; i < children.length; i++) TickerMode(enabled: i == _index, child: children[i])],
    );
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
                for (final d in _destinations)
                  NavigationRailDestination(icon: Icon(d.icon), selectedIcon: Icon(d.selected), label: Text(d.label)),
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
        destinations: [
          for (final d in _destinations) NavigationDestination(icon: Icon(d.icon), selectedIcon: Icon(d.selected), label: d.label),
        ],
      ),
    );
  }
}
