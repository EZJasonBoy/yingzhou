import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'release_info.dart';
import 'update_models.dart';
import 'update_service.dart';

/// What the newer release in [result] brings, and its package for this device: saved by the app on a desktop
/// (through the proxy and the way the check got through), handed to the browser on Android. Works with the D-pad:
/// the download button has the focus, ↑ goes to the notes, which ↑ / ↓ scroll.
Future<void> showUpdateDialog(BuildContext context, UpdateCheckResult result) {
  final release = result.release;
  if (release == null) return Future.value();
  return showDialog<void>(context: context, builder: (context) => UpdateDialog(result: result, release: release));
}

class UpdateDialog extends StatefulWidget {
  const UpdateDialog({super.key, required this.result, required this.release});

  final UpdateCheckResult result;
  final ReleaseInfo release;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  /// Set when the browser could not be opened: the address, for the user to take elsewhere.
  String? _address;

  Future<void> _open(UpdateService service, String url) async {
    final opened = await service.backend.openInBrowser(url);
    if (!mounted) return;
    setState(() => _address = opened ? null : url);
  }

  @override
  Widget build(BuildContext context) {
    final service = UpdateService.of(context);
    final release = widget.release;
    final result = widget.result;
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final asset = service.assetOf(release);

    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final download = service.download != null && service.download!.asset.name == asset?.name ? service.download : null;
        return AlertDialog(
          key: const Key('update-dialog'),
          title: Text(result.newer ? '发现新版本 ${release.version}' : '映舟 ${release.version}'),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [
                    '当前 ${result.current}',
                    if (release.date.isNotEmpty) '发布于 ${release.date}',
                    if (asset != null && asset.size > 0) '安装包 ${formatSize(asset.size)}',
                  ].join(' · '),
                  style: small,
                ),
                Text('更新信息${result.routeLabel.isEmpty ? '' : '：${result.routeLabel}'}', key: const Key('update-route'), style: small),
                const SizedBox(height: 12),
                Flexible(child: ReleaseNotes(notes: release.notes)),
                const SizedBox(height: 8),
                if (asset == null) Text('这次没有适合这台设备的安装包，可以到发布页看看', style: small),
                if (download != null) _DownloadLine(download: download, service: service),
                if (asset != null && !service.backend.downloadsInApp)
                  Text('浏览器下载时不经过「更新用的代理」${result.route == UpdateRoute.mirror ? '，地址已换成加速前缀' : ''}', style: small),
                if (_address != null) ...[
                  const SizedBox(height: 8),
                  Text('没有可以打开链接的浏览器。下载地址：', style: small),
                  SelectableText(_address!, key: const Key('update-address'), style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('以后再说')),
            TextButton(key: const Key('update-page'), onPressed: () => _open(service, release.page), child: const Text('发布页')),
            if (asset != null)
              if (download?.path != null)
                FilledButton(
                  key: const Key('update-reveal'),
                  autofocus: true,
                  onPressed: () => service.backend.reveal(download!.path!),
                  child: const Text('打开所在文件夹'),
                )
              else if (download?.running ?? false)
                FilledButton.tonal(key: const Key('update-cancel'), autofocus: true, onPressed: service.cancelDownload, child: const Text('取消下载'))
              else
                FilledButton(
                  key: const Key('update-download'),
                  autofocus: true,
                  onPressed: () => service.backend.downloadsInApp ? service.startDownload(release, asset) : _open(service, service.urlOf(release, asset)),
                  child: Text(download?.error != null ? '重新下载' : '下载'),
                ),
          ],
        );
      },
    );
  }
}

class _DownloadLine extends StatelessWidget {
  const _DownloadLine({required this.download, required this.service});

  final UpdateDownload download;
  final UpdateService service;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (download.error != null) {
      return Text('下载失败：${download.error}', key: const Key('update-download-error'), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error));
    }
    if (download.path != null) {
      return Text('已下载到 ${download.path}', key: const Key('update-downloaded'), style: theme.textTheme.bodySmall);
    }
    final fraction = download.fraction;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '正在下载 ${download.asset.name}　${formatSize(download.received)}${fraction == null ? '' : '（${(fraction * 100).round()}%）'}',
          key: const Key('update-downloading'),
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(value: fraction),
      ],
    );
  }
}

/// `12.3 MB`.
String formatSize(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// The release notes (Markdown from CHANGELOG.md) as plain lines: headings bold, `- ` as bullets, `**` and
/// backticks dropped. With the D-pad: focusable, ↑ / ↓ scroll it and leave it at either end.
class ReleaseNotes extends StatefulWidget {
  const ReleaseNotes({super.key, required this.notes});

  final String notes;

  @override
  State<ReleaseNotes> createState() => _ReleaseNotesState();
}

class _ReleaseNotesState extends State<ReleaseNotes> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || !_scroll.hasClients) return KeyEventResult.ignored;
    final p = _scroll.position;
    final step = p.viewportDimension * 0.6;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown && p.pixels < p.maxScrollExtent) {
      _scroll.animateTo((p.pixels + step).clamp(0, p.maxScrollExtent), duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp && p.pixels > 0) {
      _scroll.animateTo((p.pixels - step).clamp(0, p.maxScrollExtent), duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = widget.notes.trim().isEmpty ? ['（这个版本没有写更新说明）'] : widget.notes.trim().split('\n');
    return Focus(
      key: const Key('update-notes'),
      onKeyEvent: _key,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 360),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(8)),
        child: Scrollbar(
          controller: _scroll,
          child: SingleChildScrollView(
            controller: _scroll,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final line in lines) _line(theme, line)],
            ),
          ),
        ),
      ),
    );
  }

  static Widget _line(ThemeData theme, String raw) {
    final line = raw.trimRight();
    if (line.isEmpty) return const SizedBox(height: 6);
    final heading = RegExp(r'^#{1,6}\s+').firstMatch(line);
    final bullet = RegExp(r'^(\s*)[-*]\s+').firstMatch(line);
    var text = line.substring(heading?.end ?? bullet?.end ?? 0).replaceAll('**', '').replaceAll('`', '');
    // [label](address) → label
    text = text.replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]+\)'), (m) => m.group(1)!);
    if (heading != null) {
      return Padding(padding: const EdgeInsets.only(top: 4, bottom: 2), child: Text(text, style: theme.textTheme.titleSmall));
    }
    if (bullet != null) {
      return Padding(
        padding: EdgeInsets.only(left: 4.0 + bullet.group(1)!.length * 6, bottom: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('•  '), Expanded(child: Text(text))]),
      );
    }
    return Padding(padding: const EdgeInsets.only(bottom: 2), child: Text(text));
  }
}
