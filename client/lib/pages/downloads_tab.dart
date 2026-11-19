import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../engine/download_files.dart';
import '../engine/downloads.dart';
import '../engine/models.dart';
import '../engine/vod_models.dart';
import '../ui/common.dart';
import 'detail_page.dart';
import 'player_page.dart';

/// 我的 → 下载: everything the engine downloads or has downloaded, by title — progress, speed, pause / resume /
/// retry, play (offline), export as one file, delete.
class DownloadsTab extends StatefulWidget {
  const DownloadsTab({super.key});

  @override
  State<DownloadsTab> createState() => _DownloadsTabState();
}

class _DownloadsTabState extends State<DownloadsTab> {
  late final DownloadsWatcher _watcher = DownloadsWatcher(AppScope.read(context).client)..addListener(_changed);

  @override
  void initState() {
    super.initState();
    _watcher.start();
  }

  @override
  void dispose() {
    _watcher.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _say(String text, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), action: action, duration: Duration(seconds: action == null ? 4 : 8)));
  }

  Future<void> _act(Future<DownloadItem> Function() call) async {
    try {
      _watcher.changed([await call()]);
    } on EngineException catch (e) {
      _say('操作失败：${e.message}');
    }
  }

  Future<void> _delete(DownloadItem d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这个下载？'),
        content: Text('《${d.title}》${d.episodeName}\n下载的文件会从引擎上删掉；以后要看就要重新联网。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(key: const Key('download-delete-confirm'), onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await AppScope.read(context).client.deleteDownload(d.id);
      _watcher.removed(d.id);
    } on EngineException catch (e) {
      _say('删除失败：${e.message}');
    }
  }

  /// Plays a downloaded episode: the title's downloaded episodes of that line make the list the player steps through.
  Future<void> _play(DownloadItem d) async {
    final mine = _watcher.items.where((i) => i.site == d.site && i.vodId == d.vodId && i.title == d.title && i.line == d.line && i.done).toList()
      ..sort(_order);
    final detail = VodDetail(
      site: d.site,
      id: d.vodId,
      name: d.title,
      pic: d.pic,
      lines: [PlayLine(name: d.line, episodes: [for (final i in mine) Episode(id: i.episodeId, name: i.episodeName)])],
    );
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlayerPage(detail: detail, line: 0, episode: mine.indexWhere((i) => i.id == d.id).clamp(0, mine.length - 1))));
    _watcher.refresh();
  }

  Future<void> _export(DownloadItem d) async {
    final client = AppScope.read(context).client;
    final local = client.isLocalEngine;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出为文件'),
        content: Text(
          '把《${d.title}》${d.episodeName}存成一个视频文件，可以拷走或用别的播放器看。\n\n'
          '${d.kind == 'file' ? '直链下载的文件原样导出。' : 'HLS 视频的分片会按顺序拼成一个 .ts 文件（加密的分片先解密），大多数播放器都能播。分片是 fMP4 的拼成 .mp4。'}\n'
          '想转成普通的 .mp4 需要 ffmpeg：映舟没有附带 ffmpeg，也不会替你安装。\n\n'
          '${local ? '保存到这台电脑的「下载」文件夹。' : '从引擎传到这台设备的「下载」文件夹。'}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(key: const Key('download-export-confirm'), onPressed: () => Navigator.pop(context, true), child: const Text('导出')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _say('正在导出…');
    try {
      final path = local ? (await client.exportDownload(d.id)).path : await DownloadFiles.saveExport(client, d.id);
      _say('已导出：$path', action: DownloadFiles.supported ? SnackBarAction(label: '打开文件夹', onPressed: () => DownloadFiles.reveal(path)) : null);
    } on EngineException catch (e) {
      _say('导出失败：${e.message}');
    } catch (e) {
      _say('导出失败：$e');
    }
  }

  static int _order(DownloadItem a, DownloadItem b) {
    final line = a.line.compareTo(b.line);
    if (line != 0) return line;
    if (a.episodeIndex != b.episodeIndex) return a.episodeIndex.compareTo(b.episodeIndex);
    return a.createdAt.compareTo(b.createdAt);
  }

  @override
  Widget build(BuildContext context) {
    final available = _watcher.available;
    if (available == null) {
      return _watcher.error != null
          ? StatusView(icon: Icons.cloud_off, message: '加载失败\n${_watcher.error}', actionLabel: '重试', onAction: _watcher.refresh)
          : const LoadingView();
    }
    if (!available) return const StatusView(icon: Icons.download_for_offline_outlined, message: '这台引擎不能下载\n（安卓 App 内置的引擎没有下载功能，可以连接电脑或 NAS 上的引擎）');
    final items = _watcher.items;
    if (items.isEmpty) return const StatusView(icon: Icons.download_for_offline_outlined, message: '还没有下载\n在详情页点 ↓ 下载剧集，下载完不用网络也能看');

    // By title, the title with the newest download first.
    final groups = <String, List<DownloadItem>>{};
    for (final d in items) {
      groups.putIfAbsent('${d.site}|${d.vodId}|${d.title}', () => []).add(d);
    }
    final ordered = groups.values.toList()..sort((a, b) => b.map((d) => d.createdAt).reduce((x, y) => x > y ? x : y).compareTo(a.map((d) => d.createdAt).reduce((x, y) => x > y ? x : y)));
    final running = items.where((d) => d.running).toList();
    final speed = running.fold<int>(0, (s, d) => s + d.speed);
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        Text(
          [
            '${items.length} 集',
            if (running.isNotEmpty) '${running.length} 集在下载 · ${formatBytes(speed)}/s',
            if (items.any((d) => d.queued)) '${items.where((d) => d.queued).length} 集排队',
            '已下载 ${items.where((d) => d.done).length} 集',
          ].join(' · '),
          key: const Key('downloads-summary'),
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        ),
        const SizedBox(height: 8),
        for (final group in ordered) _group(group..sort(_order)),
      ],
    );
  }

  Widget _group(List<DownloadItem> list) {
    final first = list.first;
    final scheme = Theme.of(context).colorScheme;
    final done = list.where((d) => d.done).length;
    final bytes = list.fold<int>(0, (s, d) => s + d.bytes);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: first.vodId.isEmpty ? null : () => openDetail(context, VodCard(site: first.site, id: first.vodId, name: first.title, pic: first.pic)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 8, 8),
              child: Row(
                children: [
                  ClipRRect(borderRadius: BorderRadius.circular(6), child: SizedBox(width: 40, height: 56, child: NetImage(first.pic))),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(first.title.isEmpty ? '（没有片名）' : first.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                        const SizedBox(height: 2),
                        Text('已下载 $done / ${list.length} 集 · ${formatBytes(bytes)}', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
                      ],
                    ),
                  ),
                  if (first.vodId.isNotEmpty) Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          for (final d in list) _tile(d),
        ],
      ),
    );
  }

  Widget _tile(DownloadItem d) {
    final scheme = Theme.of(context).colorScheme;
    final client = AppScope.read(context).client;
    final estimate = d.totalBytes > 0 ? d.totalBytes : (d.progress > 0.02 && d.bytes > 0 ? (d.bytes / d.progress).round() : -1);
    final size = estimate > 0 ? '${formatBytes(d.bytes)} / ${d.totalBytes > 0 ? '' : '约 '}${formatBytes(estimate)}' : formatBytes(d.bytes);
    final percent = '${(d.progress * 100).floor()}%';
    final status = switch (d.state) {
      'running' => '下载中 $percent · ${formatBytes(d.speed)}/s · $size',
      'queued' => d.progress > 0 ? '排队中 · $percent' : '排队中',
      'paused' => '已暂停 · $percent · $size',
      'done' => '已下载 · ${formatBytes(d.bytes)} · 不用网络也能播放',
      'failed' => '失败：${d.error.isEmpty ? '未知原因' : d.error}',
      _ => d.state,
    };
    return Padding(
      key: Key('download-${d.id}'),
      padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d.episodeName.isEmpty ? d.episodeId : d.episodeName, style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  status,
                  key: Key('download-status-${d.id}'),
                  style: TextStyle(fontSize: 12, color: d.failed ? scheme.error : scheme.onSurfaceVariant),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (!d.done) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(value: d.progress, minHeight: 4, color: d.failed ? scheme.error : null),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (d.running || d.queued)
            IconButton(key: Key('download-pause-${d.id}'), tooltip: '暂停', icon: const Icon(Icons.pause_rounded), onPressed: () => _act(() => client.pauseDownload(d.id))),
          if (d.paused)
            IconButton(key: Key('download-resume-${d.id}'), tooltip: '继续', icon: const Icon(Icons.download_rounded), onPressed: () => _act(() => client.resumeDownload(d.id))),
          if (d.failed)
            IconButton(key: Key('download-retry-${d.id}'), tooltip: '重试（重新解析地址）', icon: const Icon(Icons.refresh_rounded), onPressed: () => _act(() => client.resumeDownload(d.id))),
          if (d.done) ...[
            IconButton(key: Key('download-play-${d.id}'), tooltip: '播放（离线）', icon: const Icon(Icons.play_circle_outline_rounded), onPressed: () => _play(d)),
            IconButton(key: Key('download-export-${d.id}'), tooltip: '导出为文件', icon: const Icon(Icons.ios_share_rounded), onPressed: () => _export(d)),
          ],
          IconButton(key: Key('download-delete-${d.id}'), tooltip: '删除', icon: const Icon(Icons.delete_outline_rounded), onPressed: () => _delete(d)),
        ],
      ),
    );
  }
}
