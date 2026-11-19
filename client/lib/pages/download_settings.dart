import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../engine/downloads.dart';
import '../engine/models.dart';

/// 离线下载 on the 源 page: where the engine puts downloads, how many run at once, and how much room is left. Shows
/// nothing when the connected engine does not download.
class DownloadSettings extends StatefulWidget {
  const DownloadSettings({super.key});

  @override
  State<DownloadSettings> createState() => _DownloadSettingsState();
}

class _DownloadSettingsState extends State<DownloadSettings> {
  DownloadSettingsInfo? _info;
  final _folder = TextEditingController();
  bool _saving = false;
  String? _error;

  /// Which engine [_info] is from: asked again when the app connects to another.
  Object? _askedOf;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    final engine = state.connected ? state.client : null;
    if (!identical(engine, _askedOf)) {
      _askedOf = engine;
      _info = null;
      if (engine != null) _load();
    }
  }

  @override
  void dispose() {
    _folder.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final asked = _askedOf;
    DownloadSettingsInfo info;
    try {
      info = await AppScope.read(context).client.downloadSettings();
    } on EngineException {
      // An engine from before downloads: nothing to show.
      info = const DownloadSettingsInfo(available: false);
    } on StateError {
      return;
    }
    if (!mounted || !identical(asked, _askedOf)) return;
    setState(() {
      _info = info;
      _folder.text = info.dir;
    });
  }

  Future<void> _save({String? dir, int? concurrency}) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final info = await AppScope.read(context).client.updateDownloadSettings(dir: dir, concurrency: concurrency);
      if (!mounted) return;
      setState(() {
        _info = info;
        _folder.text = info.dir;
      });
    } on EngineException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    if (info == null || !info.available) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final low = info.freeBytes >= 0 && info.freeBytes < info.reserveBytes * 2;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('离线下载', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
              const SizedBox(height: 10),
              Text(
                '已下载 ${formatBytes(info.bytes)}'
                '${info.freeBytes >= 0 ? ' · 剩余空间 ${formatBytes(info.freeBytes)}' : ''}',
                key: const Key('download-settings-usage'),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(color: low ? scheme.error : null),
              ),
              const SizedBox(height: 4),
              Text(
                '下载在引擎上进行：连着这台引擎的设备都能看。磁盘只剩 ${formatBytes(info.reserveBytes)} 时下载会停下。',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('同时下载'),
                  DropdownButton<int>(
                    key: const Key('download-concurrency'),
                    value: info.concurrency.clamp(1, info.maxConcurrency),
                    items: [for (var n = 1; n <= info.maxConcurrency; n++) DropdownMenuItem(value: n, child: Text('$n 集'))],
                    onChanged: _saving ? null : (n) => n == null || n == info.concurrency ? null : _save(concurrency: n),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('download-folder'),
                      controller: _folder,
                      decoration: InputDecoration(
                        labelText: '下载位置（引擎所在设备上的文件夹）',
                        hintText: '留空：默认位置',
                        helperText: '现在：${info.path}',
                        helperMaxLines: 2,
                        errorText: _error,
                      ),
                      onSubmitted: (v) => _save(dir: v.trim()),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.tonal(key: const Key('download-folder-save'), onPressed: _saving ? null : () => _save(dir: _folder.text.trim()), child: const Text('保存')),
                  if (info.dir.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    TextButton(onPressed: _saving ? null : () => _save(dir: ''), child: const Text('恢复默认')),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '默认和播放缓存放在一起（看过的部分不用再下载，清空缓存也不会删掉下载）。换位置只影响以后的下载，已经下载的留在原处。',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
