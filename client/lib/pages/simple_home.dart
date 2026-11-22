import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../engine/episode_names.dart';
import '../engine/library_models.dart';
import '../engine/vod_models.dart';
import '../ui/common.dart';
import '../ui/device_form.dart';
import '../ui/poster.dart';
import '../ui/tv/tv_focus.dart';
import 'detail_page.dart';

/// 首页 → 继续看, in every mode: the title watched last, with one big button that carries on where it stopped; under
/// it what else was watched lately, and the favourites. In simple mode it also stands in for 我的, which that mode
/// has no entry for.
class SimpleHomeTab extends StatefulWidget {
  const SimpleHomeTab({super.key});

  @override
  State<SimpleHomeTab> createState() => _SimpleHomeTabState();
}

class _SimpleHomeTabState extends State<SimpleHomeTab> {
  late Future<(List<HistoryEntry>, List<FavoriteEntry>)> _data;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<(List<HistoryEntry>, List<FavoriteEntry>)> _load() async {
    final client = AppScope.read(context).client;
    // Either may fail on its own (an older engine): the other still shows.
    final history = await client.history(limit: 30).catchError((Object _) => const <HistoryEntry>[]);
    final favorites = await client.favorites().catchError((Object _) => const <FavoriteEntry>[]);
    return (history, favorites);
  }

  void _reload() {
    if (mounted) setState(() => _data = _load());
  }

  /// Opens the title; with [resume] it starts playing where it stopped as soon as it has loaded. Whatever was
  /// watched meanwhile shows when the page comes back.
  Future<void> _open(VodCard card, {bool resume = false}) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DetailPage(preview: card, resume: resume)));
    _reload();
  }

  static VodCard _card(HistoryEntry h) => VodCard(site: h.site, id: h.vodId, name: h.name, pic: h.pic, remarks: EpisodeNaming.brief(EpisodeNaming.clean(h.episodeName), columns: 16));

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(List<HistoryEntry>, List<FavoriteEntry>)>(
      future: _data,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done && !snap.hasData) return const LoadingView();
        final (history, favorites) = snap.data ?? (const <HistoryEntry>[], const <FavoriteEntry>[]);
        if (history.isEmpty && favorites.isEmpty) {
          return const StatusView(icon: Icons.play_circle_outline_rounded, message: '还没有看过的片子\n到「推荐」里挑一部，下次打开就从这里接着看');
        }
        return ListView(
          key: const Key('simple-home'),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          children: [
            if (history.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 960),
                  child: _Hero(entry: history.first, onResume: () => _open(_card(history.first), resume: true), onOpen: () => _open(_card(history.first))),
                ),
              ),
            if (history.length > 1)
              _PosterRow(
                title: '最近看过',
                cards: [for (final h in history.skip(1).take(12)) (card: _card(h), progress: h.progress)],
                onTap: (c) => _open(c, resume: true),
              ),
            if (favorites.isNotEmpty)
              _PosterRow(
                title: '收藏',
                cards: [for (final f in favorites.take(24)) (card: VodCard(site: f.site, id: f.vodId, name: f.name, pic: f.pic, remarks: f.remarks), progress: null)],
                onTap: _open,
              ),
          ],
        );
      },
    );
  }
}

/// The title watched last: poster, where it stopped, and 继续播放.
class _Hero extends StatelessWidget {
  const _Hero({required this.entry, required this.onResume, required this.onOpen});

  final HistoryEntry entry;
  final VoidCallback onResume;
  final VoidCallback onOpen;

  /// 「第 3 集 · 还剩 12 分钟」
  static String where(HistoryEntry h) {
    final episode = EpisodeNaming.brief(EpisodeNaming.clean(h.episodeName), columns: 28);
    final left = h.durationMs - h.positionMs;
    final String time;
    if (h.durationMs <= 0) {
      time = '';
    } else if (left < 60000) {
      time = '快看完了';
    } else {
      time = '还剩 ${(left / 60000).ceil()} 分钟';
    }
    return [episode, time].where((s) => s.isNotEmpty).join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tv = isTv(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 560;
        final posterWidth = wide ? (tv ? 140.0 : 132.0) : 96.0;
        final poster = ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(width: posterWidth, height: posterWidth / 0.7, child: NetImage(entry.pic)),
        );
        final info = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('继续看', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
            const SizedBox(height: 4),
            Text(entry.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: (wide ? theme.textTheme.headlineSmall : theme.textTheme.titleLarge)?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(where(entry), key: const Key('simple-resume-where'), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(value: entry.progress, minHeight: 5, backgroundColor: scheme.surfaceContainerHighest, color: scheme.primary),
            ),
          ],
        );
        final padding = EdgeInsets.symmetric(horizontal: wide ? 28 : 20, vertical: tv ? 16 : 18);
        final resume = TvAutofocus(
          child: FilledButton.icon(
            key: const Key('simple-resume'),
            onPressed: onResume,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('继续播放'),
            style: FilledButton.styleFrom(padding: padding, textStyle: theme.textTheme.titleMedium),
          ),
        );
        final other = OutlinedButton(key: const Key('simple-episodes'), onPressed: onOpen, style: OutlinedButton.styleFrom(padding: padding), child: const Text('选别的集'));
        return Container(
          padding: EdgeInsets.all(wide ? 20 : 14),
          decoration: BoxDecoration(color: scheme.surfaceContainer, borderRadius: BorderRadius.circular(16)),
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    poster,
                    const SizedBox(width: 24),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          info,
                          const SizedBox(height: 18),
                          Wrap(spacing: 12, runSpacing: 10, children: [resume, other]),
                        ],
                      ),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [poster, const SizedBox(width: 14), Expanded(child: info)]),
                    const SizedBox(height: 14),
                    resume,
                    const SizedBox(height: 8),
                    other,
                  ],
                ),
        );
      },
    );
  }
}

/// A heading and one row of posters that scrolls sideways.
class _PosterRow extends StatelessWidget {
  const _PosterRow({required this.title, required this.cards, required this.onTap});

  final String title;
  final List<({VodCard card, double? progress})> cards;
  final ValueChanged<VodCard> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = isTv(context) ? 136.0 : (MediaQuery.sizeOf(context).width < 560 ? 104.0 : 128.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 24, 4, 10),
          child: Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        ),
        SizedBox(
          // The poster, the gap under it and two lines of title; the focused poster grows a little into the padding.
          height: width / 0.7 + 8 + 46,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            itemCount: cards.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (context, i) => SizedBox(
              width: width,
              child: PosterCard(vod: cards[i].card, progress: cards[i].progress, onTap: () => onTap(cards[i].card)),
            ),
          ),
        ),
      ],
    );
  }
}
