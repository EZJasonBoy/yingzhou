import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../engine/vod_models.dart';
import '../ui/common.dart';
import 'browse_page.dart' show errorText;
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _detail = AppScope.read(context).client.detail(widget.preview.site, widget.preview.id);
  }

  void _play(VodDetail detail, int line, int episode) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PlayerPage(detail: detail, line: line, episode: episode),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(backgroundColor: Colors.transparent),
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
    final line = d.lines.isEmpty ? null : d.lines[_line.clamp(0, d.lines.length - 1)];
    final meta = [d.year, d.area, d.type, d.remarks].where((s) => s.isNotEmpty).join(' · ');

    final poster = ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(width: wide ? 200 : 140, height: wide ? 286 : 200, child: NetImage(d.pic.isNotEmpty ? d.pic : widget.preview.pic)),
    );
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(d.name, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        if (meta.isNotEmpty) Text(meta, style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        Text('来源：$siteName', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
        if (d.director.isNotEmpty) ...[const SizedBox(height: 10), _kv('导演', d.director, scheme)],
        if (d.actor.isNotEmpty) ...[const SizedBox(height: 4), _kv('主演', d.actor, scheme)],
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: line == null || line.episodes.isEmpty ? null : () => _play(d, _line, 0),
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(line == null ? '暂无播放线路' : '播放'),
          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16)),
        ),
      ],
    );

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 56, 24, 32),
        children: [
          wide
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [poster, const SizedBox(width: 28), Expanded(child: info)])
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [poster, const SizedBox(height: 18), info]),
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
                    width: 112,
                    child: OutlinedButton(
                      onPressed: () => _play(d, _line, i),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
                        side: BorderSide(color: scheme.outlineVariant),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: Text(line.episodes[i].name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _kv(String k, String v, ColorScheme scheme) => Text.rich(
        TextSpan(children: [
          TextSpan(text: '$k  ', style: TextStyle(color: scheme.onSurfaceVariant)),
          TextSpan(text: v),
        ]),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );

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
