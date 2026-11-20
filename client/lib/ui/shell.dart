import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../pages/browse_page.dart';
import '../pages/drives_page.dart';
import '../pages/library_page.dart';
import '../pages/live_page.dart';
import '../pages/search_page.dart';
import '../pages/settings_page.dart';
import '../pages/sources_page.dart';
import 'device_form.dart';
import 'tv/tv_shell.dart';

/// Whether the main screen has its bottom bar: only on a phone held upright (or a narrow window). Tablets and phones
/// on their side get the rail, a TV its own navigation. The bottom bar has no 设置 tab; 我的 offers it there.
bool shellUsesBottomBar(BuildContext context) {
  final form = DeviceFormScope.of(context);
  if (form == DeviceForm.tv) return false;
  final size = MediaQuery.sizeOf(context);
  return !(size.width >= 760 || form == DeviceForm.tablet || (form == DeviceForm.phone && size.width > size.height));
}

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
    (icon: Icons.settings_outlined, selected: Icons.settings_rounded, label: '设置'),
  ];

  /// The bottom bar of a phone held upright has room for this many; 设置, the last, is reached from 我的 there.
  static const _bottomBarCount = 6;

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

  /// Phones and tablets: the system's back on another tab goes to 首页 first; on 首页 it leaves the app. Live TV in full
  /// screen handles back itself (it leaves full screen). TVs have their own back in TvShell.
  Widget _backToHome(Widget child) {
    if (!isTouch(context)) return child;
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
      const SettingsPage(),
    ];
    // Hidden pages keep their state but stop animating.
    final pages = KeyedSubtree(
      key: _pagesKey,
      child: IndexedStack(
        index: _index,
        children: [for (var i = 0; i < children.length; i++) TickerMode(enabled: i == _index, child: children[i])],
      ),
    );
    // A TV: big entries on the left, everything driven by the remote (ui/tv/tv_shell.dart).
    if (isTv(context)) return TvShell(index: _index, destinations: _destinations, onSelect: _go, immersive: _immersive && _index == 1, pages: pages);
    if (_immersive && _index == 1) return Scaffold(backgroundColor: Colors.black, body: pages);
    // The rail for everything but a phone held upright. With seven entries it is taller than the smallest desktop
    // window (520 high), so desktops get the same rail as tablets: it scrolls, and a short window labels only the
    // entry that is showing.
    if (!shellUsesBottomBar(context)) {
      return Scaffold(body: Row(children: [_rail(context, MediaQuery.sizeOf(context).height < 600), Expanded(child: pages)]));
    }
    return Scaffold(
      body: pages,
      bottomNavigationBar: NavigationBar(
        // 设置 was opened while the rail was showing (the phone was on its side): 我的 is where it is reached from here.
        selectedIndex: _index < _bottomBarCount ? _index : 3,
        onDestinationSelected: _go,
        destinations: [
          for (final d in _destinations.take(_bottomBarCount)) NavigationDestination(icon: Icon(d.icon), selectedIcon: Icon(d.selected), label: d.label),
        ],
      ),
    );
  }
}
