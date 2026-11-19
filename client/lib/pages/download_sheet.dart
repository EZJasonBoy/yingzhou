import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../engine/downloads.dart';
import '../engine/models.dart';
import '../engine/vod_models.dart';

/// 下载 on the detail page: opens [showDownloadSheet] for the line being looked at, with [episode] picked.
class DownloadButton extends StatelessWidget {
  const DownloadButton({super.key, required this.detail, required this.line, required this.watcher, this.episode});

  final VodDetail detail;
  final int line;
  final DownloadsWatcher watcher;
  final int? episode;

  @override
  Widget build(BuildContext context) => IconButton.filledTonal(
    key: const Key('download-button'),
    tooltip: '下载',
    icon: const Icon(Icons.download_rounded),
    onPressed: detail.lines.isEmpty ? null : () => showDownloadSheet(context, detail: detail, line: line, watcher: watcher, episode: episode),
  );
}

/// The episodes of a line to download: [episode] is picked to begin with ("this episode"), any others can be added,
/// or the whole line. Episodes the engine has already are marked and not added twice; a paused or failed one is
/// resumed.
Future<void> showDownloadSheet(BuildContext context, {required VodDetail detail, required int line, required DownloadsWatcher watcher, int? episode}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 760),
      builder: (_) => _DownloadSheet(detail: detail, line: line, watcher: watcher, episode: episode, messenger: ScaffoldMessenger.of(context)),
    );

class _DownloadSheet extends StatefulWidget {
  const _DownloadSheet({required this.detail, required this.line, required this.watcher, required this.messenger, this.episode});

  final VodDetail detail;
  final int line;
  final DownloadsWatcher watcher;
  final int? episode;
  final ScaffoldMessengerState messenger;

  @override
  State<_DownloadSheet> createState() => _DownloadSheetState();
}

class _DownloadSheetState extends State<_DownloadSheet> {
  late int _line = widget.line.clamp(0, widget.detail.lines.length - 1);
  late final Set<int> _picked = {if (widget.episode != null && _addable(widget.episode!)) widget.episode!};
  bool _sending = false;

  PlayLine get _current => widget.detail.lines[_line];

  @override
  void initState() {
    super.initState();
    widget.watcher.addListener(_changed);
  }

  @override
  void dispose() {
    widget.watcher.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  DownloadItem? _download(int i) {
    final episodes = widget.detail.lines[_line].episodes;
    if (i < 0 || i >= episodes.length) return null;
    return widget.watcher.find(widget.detail.site, _current.name, episodes[i].id);
  }

  /// Episodes that are not downloaded or under way can be picked (a paused or failed one is picked to go on).
  bool _addable(int i) {
    final d = _download(i);
    return d == null || d.paused || d.failed;
  }

  Future<void> _start() async {
    final client = AppScope.read(context).client;
    final picked = _picked.toList()..sort();
    final fresh = <DownloadRequest>[];
    final again = <String>[];
    for (final i in picked) {
      final d = _download(i);
      if (d == null) {
        final e = _current.episodes[i];
        fresh.add(DownloadRequest(
          site: widget.detail.site,
          line: _current.name,
          episodeId: e.id,
          vodId: widget.detail.id,
          title: widget.detail.name,
          pic: widget.detail.pic,
          episodeName: e.name,
          episodeIndex: i,
        ));
      } else {
        again.add(d.id);
      }
    }
    setState(() => _sending = true);
    try {
      final answer = <DownloadItem>[
        if (fresh.isNotEmpty) ...await client.addDownloads(fresh),
        for (final id in again) await client.resumeDownload(id),
      ];
      widget.watcher.changed(answer);
      if (mounted) Navigator.of(context).pop();
      widget.messenger.showSnackBar(SnackBar(content: Text('已加入下载：${picked.length} 集。进度在「我的 → 下载」')));
    } on EngineException catch (e) {
      if (mounted) setState(() => _sending = false);
      widget.messenger.showSnackBar(SnackBar(content: Text('下载失败：${e.message}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final episodes = _current.episodes;
    final addable = [for (var i = 0; i < episodes.length; i++) if (_addable(i)) i];
    final all = addable.isNotEmpty && addable.every(_picked.contains);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('下载 · ${widget.detail.name}', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('在引擎上下载，下载完不用网络也能播放、随意拖动', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
            if (widget.detail.lines.length > 1) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < widget.detail.lines.length; i++)
                    ChoiceChip(
                      label: Text(widget.detail.lines[i].name),
                      selected: i == _line,
                      onSelected: (_) => setState(() {
                        _line = i;
                        _picked.clear();
                      }),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < episodes.length; i++)
                      FilterChip(
                        key: Key('download-pick-$i'),
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(episodes[i].name),
                            if (_download(i) != null) ...[const SizedBox(width: 6), EpisodeDownloadMark(item: _download(i)!, compact: true)],
                          ],
                        ),
                        selected: _picked.contains(i),
                        onSelected: _addable(i) ? (on) => setState(() => on ? _picked.add(i) : _picked.remove(i)) : null,
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                TextButton(
                  key: const Key('download-pick-all'),
                  onPressed: addable.isEmpty ? null : () => setState(() => all ? _picked.clear() : _picked.addAll(addable)),
                  child: Text(all ? '全不选' : '整条线路'),
                ),
                const Spacer(),
                FilledButton.icon(
                  key: const Key('download-start'),
                  onPressed: _picked.isEmpty || _sending ? null : _start,
                  icon: const Icon(Icons.download_rounded),
                  label: Text(_picked.isEmpty ? '选择要下载的剧集' : '下载 ${_picked.length} 集'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// How far an episode's download is, under its name: 排队中, 42%, 已暂停, 已下载, 失败.
class EpisodeDownloadMark extends StatelessWidget {
  const EpisodeDownloadMark({super.key, required this.item, this.compact = false});

  final DownloadItem item;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (item.state) {
      'done' => Colors.green.shade600,
      'failed' => scheme.error,
      'running' => scheme.primary,
      _ => scheme.onSurfaceVariant,
    };
    final icon = switch (item.state) {
      'done' => Icons.download_done_rounded,
      'failed' => Icons.error_outline_rounded,
      'paused' => Icons.pause_rounded,
      'queued' => Icons.schedule_rounded,
      _ => null,
    };
    final size = compact ? 12.0 : 13.0;
    return Tooltip(
      message: item.failed && item.error.isNotEmpty ? item.error : '',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (item.running)
            SizedBox(width: size - 2, height: size - 2, child: CircularProgressIndicator(value: item.progress, strokeWidth: 2, color: color))
          else
            Icon(icon, size: size, color: color),
          const SizedBox(width: 3),
          Text(downloadBadge(item), style: TextStyle(fontSize: size - 1, color: color)),
        ],
      ),
    );
  }
}
