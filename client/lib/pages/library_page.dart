import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../engine/library_models.dart';
import '../engine/vod_models.dart';
import '../ui/common.dart';
import '../ui/device_form.dart';
import '../ui/poster.dart';
import '../ui/shell.dart' show shellUsesBottomBar;
import '../ui/tv/tv_widgets.dart';
import 'browse_page.dart' show errorText;
import 'detail_page.dart';
import 'downloads_tab.dart';
import 'settings_page.dart';

/// 我的：watch history (with progress) and favorites, both stored in the engine.
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.visible});

  /// Reloads whenever the page becomes visible again, so progress made elsewhere shows up.
  final bool visible;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  Future<(List<HistoryEntry>, List<FavoriteEntry>)>? _data;

  @override
  void initState() {
    super.initState();
    if (widget.visible) _reload();
  }

  @override
  void didUpdateWidget(covariant LibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible && !oldWidget.visible) _reload();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The page was on screen before the engine was there (the app opens on 我的): it loads once the engine is.
    if (widget.visible && _data == null && AppScope.of(context).connected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _data == null) _reload();
      });
    }
  }

  void _reload() {
    final state = AppScope.read(context);
    if (!state.connected) return;
    final client = state.client;
    setState(() {
      _data = Future.wait([client.history(), client.favorites()])
          .then((r) => (r[0] as List<HistoryEntry>, r[1] as List<FavoriteEntry>));
    });
  }

  Future<void> _open(String site, String id, String name, String pic) async {
    openDetail(context, VodCard(site: site, id: id, name: name, pic: pic));
  }

  Future<void> _removeHistory(HistoryEntry h) async {
    await AppScope.read(context).client.removeHistory(h.site, h.vodId);
    _reload();
  }

  Future<void> _clearHistory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空观看历史？'),
        content: const Text('所有设备上的观看记录都会被清除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('清空')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await AppScope.read(context).client.clearHistory();
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Scaffold(
      body: SafeArea(
        child: DefaultTabController(
          length: 3,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 12, 4),
                child: Row(
                  children: [
                    Text('我的', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                    const Spacer(),
                    IconButton(tooltip: '刷新', onPressed: _reload, icon: const Icon(Icons.refresh)),
                    // A phone held upright has no 设置 tab in its bottom bar: it is here.
                    if (shellUsesBottomBar(context))
                      IconButton(
                        key: const Key('open-settings'),
                        tooltip: '设置',
                        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsPage(standalone: true))),
                        icon: const Icon(Icons.settings_outlined),
                      ),
                  ],
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: Builder(
                  builder: (context) => TabBar(
                    isScrollable: true,
                    onFocusChange: tvTabFollowsFocus(context),
                    tabs: const [Tab(text: '观看历史', height: 40), Tab(text: '收藏', height: 40), Tab(text: '下载', height: 40)],
                  ),
                ),
              ),
              Expanded(
                child: !state.connected
                    ? const StatusView(icon: Icons.link_off, message: '还没有连接引擎')
                    : FutureBuilder<(List<HistoryEntry>, List<FavoriteEntry>)>(
                        future: _data,
                        builder: (context, snap) {
                          if (_data == null || snap.connectionState != ConnectionState.done) return const LoadingView();
                          if (snap.hasError) {
                            return StatusView(icon: Icons.cloud_off, message: '加载失败\n${errorText(snap.error)}', actionLabel: '重试', onAction: _reload);
                          }
                          final (history, favorites) = snap.data!;
                          return TabBarView(children: [_history(history, state), _favorites(favorites, state), const DownloadsTab()]);
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _history(List<HistoryEntry> items, AppState state) {
    if (items.isEmpty) return const StatusView(icon: Icons.history, message: '还没有观看记录');
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Row(children: [
              Text('${items.length} 部', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
              const Spacer(),
              TextButton(onPressed: _clearHistory, child: const Text('清空')),
            ]),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          sliver: SliverGrid.builder(
            gridDelegate: posterGridDelegate,
            itemCount: items.length,
            itemBuilder: (context, i) {
              final h = items[i];
              return _HistoryCard(
                entry: h,
                siteName: state.siteName(h.site),
                onTap: () => _open(h.site, h.vodId, h.name, h.pic),
                onRemove: () => _removeHistory(h),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _favorites(List<FavoriteEntry> items, AppState state) {
    if (items.isEmpty) return const StatusView(icon: Icons.favorite_border, message: '还没有收藏\n在详情页点 ♡ 收藏');
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      gridDelegate: posterGridDelegate,
      itemCount: items.length,
      itemBuilder: (context, i) {
        final f = items[i];
        return PosterCard(
          vod: VodCard(site: f.site, id: f.vodId, name: f.name, pic: f.pic, remarks: f.remarks),
          caption: state.siteName(f.site),
          onTap: () => _open(f.site, f.vodId, f.name, f.pic),
        );
      },
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.entry, required this.siteName, required this.onTap, required this.onRemove});

  final HistoryEntry entry;
  final String siteName;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onSecondaryTap: onRemove,
      onLongPress: onRemove,
      child: Stack(
        children: [
          PosterCard(
            vod: VodCard(site: entry.site, id: entry.vodId, name: entry.name, pic: entry.pic, remarks: entry.episodeName),
            caption: siteName,
            onTap: onTap,
            // The remote: hold OK or press the menu key to remove it; the progress grows with the focused poster.
            onLongPress: onRemove,
            progress: isTv(context) ? entry.progress : null,
          ),
          // Progress along the bottom edge of the poster.
          if (!isTv(context))
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: AspectRatio(
              aspectRatio: 0.7,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: IgnorePointer(
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                    child: LinearProgressIndicator(
                      value: entry.progress,
                      minHeight: 3,
                      backgroundColor: Colors.white24,
                      color: scheme.primary,
                    ),
                  ),
                ),
              ),
            ),
          ),
          // No tiny button on a TV.
          if (!isTv(context))
          Positioned(
            right: 4,
            top: 4,
            child: Material(
              color: Colors.black45,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onRemove,
                child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.close, size: 14, color: Colors.white70)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
