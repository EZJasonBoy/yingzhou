import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../engine/downloads.dart';
import '../engine/library_models.dart';
import '../engine/vod_models.dart';
import '../ui/common.dart';
import 'browse_page.dart' show errorText;
import 'download_sheet.dart';
import 'player_page.dart';

void openDetail(BuildContext context, VodCard vod) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DetailPage(preview: vod)));
}

class DetailPage extends StatefulWidget {
  const DetailPage({super.key, required this.preview});

  /// What we already know from the poster wall; shown while the detail loads.
  final VodCard preview;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  late Future<VodDetail> _detail;
  int _line = 0;
  bool _expanded = false;
  HistoryEntry? _history;
  bool _favorite = false;
  bool _lineFromHistory = false;

  /// The engine's downloads, for marking the episodes that are downloaded or under way.
  late final DownloadsWatcher _downloads = DownloadsWatcher(AppScope.read(context).client)..addListener(_downloadsChanged);

  @override
  void initState() {
    super.initState();
    _load();
    _loadLibrary();
    _downloads.start();
  }

  @override
  void dispose() {
    _downloads.dispose();
    super.dispose();
  }

  void _downloadsChanged() {
    if (mounted) setState(() {});
  }

  void _load({bool refresh = false}) {
    _detail = AppScope.read(context).client.detail(widget.preview.site, widget.preview.id, refresh: refresh);
  }

  Future<void> _loadLibrary() async {
    final client = AppScope.read(context).client;
    final site = widget.preview.site;
    final id = widget.preview.id;
    try {
      final results = await Future.wait([client.historyFor(site, id), client.isFavorite(site, id)]);
      if (!mounted) return;
      setState(() {
        _history = results[0] as HistoryEntry?;
        _favorite = results[1] as bool;
      });
    } catch (_) {
      // Library is a nice-to-have on this page; browsing still works without it.
    }
  }

  Future<void> _toggleFavorite(VodDetail d) async {
    final client = AppScope.read(context).client;
    final next = !_favorite;
    setState(() => _favorite = next);
    try {
      if (next) {
        await client.putFavorite(FavoriteEntry(site: d.site, vodId: d.id, name: d.name, pic: d.pic, remarks: d.remarks));
      } else {
        await client.removeFavorite(d.site, d.id);
      }
    } catch (_) {
      if (mounted) setState(() => _favorite = !next);
    }
  }

  Future<void> _play(VodDetail detail, int line, int episode, {Duration? start}) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PlayerPage(detail: detail, line: line, episode: episode, startPosition: start),
    ));
    if (mounted) _loadLibrary();
  }

  /// Where the history says we were: (line, episode, position), matched by line name and episode id.
  (int, int, Duration)? _resumePoint(VodDetail d) {
    final h = _history;
    if (h == null || d.lines.isEmpty) return null;
    var line = d.lines.indexWhere((l) => l.name == h.line);
    if (line < 0) line = _line.clamp(0, d.lines.length - 1);
    final episodes = d.lines[line].episodes;
    if (episodes.isEmpty) return null;
    // Prefer the recorded position when it still holds the same episode: sites sometimes reuse one url
    // for several episodes, so matching by id alone can land on the wrong one.
    final atIndex = h.episodeIndex >= 0 && h.episodeIndex < episodes.length && episodes[h.episodeIndex].id == h.episodeId;
    var ep = atIndex ? h.episodeIndex : episodes.indexWhere((e) => e.id == h.episodeId);
    if (ep < 0) ep = h.episodeIndex.clamp(0, episodes.length - 1);
    return (line, ep, Duration(milliseconds: h.positionMs));
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        actions: [
          // The engine keeps details for a while; this asks the site again (new episodes, repaired lines).
          IconButton(key: const Key('detail-refresh'), tooltip: '刷新（重新向站点获取）', icon: const Icon(Icons.refresh), onPressed: () => setState(() => _load(refresh: true))),
          const SizedBox(width: 8),
        ],
      ),
      body: FutureBuilder<VodDetail>(
        future: _detail,
        builder: (context, snap) {
          final pic = snap.data?.pic.isNotEmpty == true ? snap.data!.pic : widget.preview.pic;
          return Stack(
            children: [
              _Backdrop(pic: pic),
              if (snap.connectionState != ConnectionState.done)
                const LoadingView()
              else if (snap.hasError)
                StatusView(
                  icon: Icons.cloud_off,
                  message: '详情加载失败\n${errorText(snap.error)}',
                  actionLabel: '重试',
                  onAction: () => setState(_load),
                )
              else
                _content(context, snap.data!, state.siteName(snap.data!.site)),
            ],
          );
        },
      ),
    );
  }

  Widget _content(BuildContext context, VodDetail d, String siteName) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final resume = _resumePoint(d);
    if (resume != null && !_lineFromHistory) {
      // Start on the line the user watched last time.
      _lineFromHistory = true;
      _line = resume.$1;
    }
    final line = d.lines.isEmpty ? null : d.lines[_line.clamp(0, d.lines.length - 1)];
    // Some episode of this line is downloaded or under way: every episode button keeps room for its mark.
    final marked = line != null && line.episodes.any((e) => _downloads.find(d.site, line.name, e.id) != null);
    final meta = [d.year, d.area, d.type, d.remarks].where((s) => s.isNotEmpty).join(' · ');

    final poster = ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(width: wide ? 200 : 112, height: wide ? 286 : 160, child: NetImage(d.pic.isNotEmpty ? d.pic : widget.preview.pic)),
    );
    // Narrow (a phone held upright): the title and facts go beside a small poster, the buttons under both.
    final heading = [
      Text(d.name, style: (wide ? theme.textTheme.headlineMedium : theme.textTheme.titleLarge)?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      if (meta.isNotEmpty) Text(meta, style: TextStyle(color: scheme.onSurfaceVariant)),
      const SizedBox(height: 4),
      Text('来源：$siteName', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
      if (d.director.isNotEmpty) ...[const SizedBox(height: 10), _kv('导演', d.director, scheme)],
      if (d.actor.isNotEmpty) ...[const SizedBox(height: 4), _kv('主演', d.actor, scheme)],
    ];
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (wide) ...heading,
        const SizedBox(height: 18),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (resume != null)
              FilledButton.icon(
                onPressed: () => _play(d, resume.$1, resume.$2, start: resume.$3),
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text('继续播放 ${d.lines[resume.$1].episodes[resume.$2].name}  ${_fmt(resume.$3)}'),
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16)),
              )
            else
              FilledButton.icon(
                onPressed: line == null || line.episodes.isEmpty ? null : () => _play(d, _line, 0),
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(line == null ? '暂无播放线路' : '播放'),
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16)),
              ),
            if (resume != null && line != null && line.episodes.isNotEmpty)
              OutlinedButton(
                onPressed: () => _play(d, _line, 0),
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16)),
                child: const Text('从头播放'),
              ),
            IconButton.filledTonal(
              tooltip: _favorite ? '取消收藏' : '收藏',
              onPressed: () => _toggleFavorite(d),
              icon: Icon(_favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  color: _favorite ? Colors.pinkAccent : null),
            ),
            // Not for drive folders: their files are the user's own already, and the engine's download queue
            // resolves episodes through the sites, which drives are not.
            if (_downloads.available == true && line != null && !d.site.startsWith('drive:'))
              DownloadButton(detail: d, line: _line, watcher: _downloads, episode: resume != null && resume.$1 == _line ? resume.$2 : 0),
          ],
        ),
      ],
    );

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 56, 24, 32),
        children: [
          wide
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [poster, const SizedBox(width: 28), Expanded(child: info)])
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [poster, const SizedBox(width: 16), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: heading))],
                    ),
                    info,
                  ],
                ),
          if (d.content.isNotEmpty) ...[
            const SizedBox(height: 24),
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Text(
                _plain(d.content),
                maxLines: _expanded ? null : 3,
                overflow: _expanded ? null : TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.6),
              ),
            ),
          ],
          if (d.lines.isNotEmpty) ...[
            const SizedBox(height: 28),
            Text('线路', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < d.lines.length; i++)
                  ChoiceChip(
                    label: Text('${d.lines[i].name}  ${d.lines[i].episodes.length}'),
                    selected: i == _line,
                    onSelected: (_) => setState(() => _line = i),
                  ),
              ],
            ),
            const SizedBox(height: 22),
            Text('选集', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < line!.episodes.length; i++)
                  SizedBox(
                    width: wide ? 112 : _narrowEpisodeWidth(context),
                    child: OutlinedButton(
                      onPressed: () => _play(d, _line, i),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
                        // The episode watched last time is highlighted.
                        backgroundColor: resume != null && resume.$1 == _line && resume.$2 == i ? scheme.primaryContainer : null,
                        side: BorderSide(color: scheme.outlineVariant),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: _episodeLabel(line.episodes[i].name, _downloads.find(d.site, line.name, line.episodes[i].id), i, marked),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// An episode's name, and under it how far its download is when there is one (a downloaded one plays offline).
  /// When any episode of the line has a download ([marked]), all of them keep room for it, so the buttons line up.
  Widget _episodeLabel(String name, DownloadItem? download, int i, bool marked) {
    final text = Text(name, maxLines: 1, overflow: TextOverflow.ellipsis);
    if (!marked) return text;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      text,
      const SizedBox(height: 2),
      SizedBox(height: 16, child: download == null ? null : EpisodeDownloadMark(key: Key('download-mark-$i'), item: download, compact: true)),
    ]);
  }

  /// On a narrow screen the episode buttons fill the row: as many of about 84 dp as fit, at least three.
  static double _narrowEpisodeWidth(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final width = MediaQuery.sizeOf(context).width - padding.left - padding.right - 48;
    final columns = ((width + 8) / 92).floor().clamp(3, 8);
    return (width - 8 * (columns - 1)) / columns - 0.5;
  }

  Widget _kv(String k, String v, ColorScheme scheme) => Text.rich(
        TextSpan(children: [
          TextSpan(text: '$k  ', style: TextStyle(color: scheme.onSurfaceVariant)),
          TextSpan(text: v),
        ]),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  /// Site descriptions often contain HTML.
  static String _plain(String html) => html
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .trim();
}

/// Blurred poster behind the header, fading into the page background.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.pic});

  final String pic;

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).colorScheme.surface;
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      height: 420,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (pic.isNotEmpty)
              ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 40, sigmaY: 40, tileMode: TileMode.mirror),
                child: Opacity(opacity: 0.45, child: NetImage(pic)),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [bg.withValues(alpha: 0.15), bg.withValues(alpha: 0.75), bg],
                  stops: const [0, 0.6, 0.95],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
