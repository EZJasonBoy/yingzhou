import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../engine/models.dart';
import '../engine/stream_cache_models.dart';

/// 播放缓存: the engine's stream cache on the 源 page — how much it holds, the switch, the size it may grow to, and
/// a button to empty it. Shows nothing when the connected engine has no stream cache.
class StreamCacheSettings extends StatefulWidget {
  const StreamCacheSettings({super.key});

  /// The sizes offered, in MB.
  static const sizes = [512, 1024, 2048, 5120, 10240, 20480, 51200];

  static String size(num bytes) {
    final mb = bytes / (1024 * 1024);
    if (mb < 1000) return '${mb.round()} MB';
    final gb = mb / 1024;
    return '${gb >= 10 || gb == gb.roundToDouble() ? gb.round() : gb.toStringAsFixed(1)} GB';
  }

  @override
  State<StreamCacheSettings> createState() => _StreamCacheSettingsState();
}

class _StreamCacheSettingsState extends State<StreamCacheSettings> {
  StreamCacheInfo? _info;

  /// Which engine [_info] is from: asked again when the app connects to another.
  Object? _askedOf;
  bool _clearing = false;

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

  Future<void> _load() async {
    final state = AppScope.read(context);
    final asked = _askedOf;
    StreamCacheInfo? info;
    try {
      info = await state.client.streamCache();
    } on EngineException {
      // An engine from before the stream cache: nothing to show.
      info = const StreamCacheInfo(available: false);
    } on StateError {
      return;
    }
    if (mounted && identical(asked, _askedOf)) setState(() => _info = info);
  }

  Future<void> _clear() async {
    final state = AppScope.read(context);
    setState(() => _clearing = true);
    try {
      final info = await state.client.clearStreamCache();
      if (mounted) setState(() => _info = info);
    } on EngineException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('清空失败：${e.message}')));
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _change(AppState state, {bool? enabled, int? maxMB}) async {
    await state.setStreamCache(enabled: enabled, maxMB: maxMB);
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final settings = state.engineSettings;
    final info = _info;
    if (settings == null || info == null || !info.available) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final max = settings.streamCacheMaxMB;
    final sizes = {...StreamCacheSettings.sizes, max}.toList()..sort();
    final used = info.maxBytes <= 0 ? 0.0 : (info.bytes / info.maxBytes).clamp(0.0, 1.0);

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('播放缓存', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
              const SizedBox(height: 10),
              SwitchListTile(
                key: const Key('stream-cache-switch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('把播放过和预读的视频存在磁盘上'),
                subtitle: Text(
                  settings.streamCache ? 'm3u8 视频经引擎获取并保存：往回拖、小幅快进不用重新下载，慢的片源也能多连接预读' : '已关闭：播放器直接向片源要分片，拖动进度条会重新下载',
                ),
                value: settings.streamCache,
                onChanged: state.busy ? null : (on) => _change(state, enabled: on),
              ),
              const SizedBox(height: 4),
              Text(
                '已用 ${StreamCacheSettings.size(info.bytes)} / ${StreamCacheSettings.size(info.maxBytes)}'
                '${info.streams > 0 ? ' · ${info.streams} 个视频' : ''}',
                key: const Key('stream-cache-usage'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(value: used, minHeight: 6)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('最多占用'),
                  DropdownButton<int>(
                    key: const Key('stream-cache-max'),
                    value: max,
                    items: [for (final mb in sizes) DropdownMenuItem(value: mb, child: Text(StreamCacheSettings.size(mb * 1024 * 1024)))],
                    onChanged: state.busy ? null : (mb) => mb == null || mb == max ? null : _change(state, maxMB: mb),
                  ),
                  OutlinedButton(
                    key: const Key('stream-cache-clear'),
                    onPressed: _clearing || info.bytes == 0 ? null : _clear,
                    child: Text(_clearing ? '正在清空…' : '清空缓存'),
                  ),
                  IconButton(tooltip: '刷新', onPressed: _load, icon: const Icon(Icons.refresh, size: 20)),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '放满后自动删掉最久没看的部分。位置（在引擎所在的设备上）：${info.path}',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
              // An engine that watches the disk (Android): it gives way before the device runs out of space.
              if (info.reserveBytes > 0)
                Text(
                  '${info.freeBytes >= 0 ? '设备剩余空间 ${StreamCacheSettings.size(info.freeBytes)}。' : ''}'
                  '剩余空间不到 ${StreamCacheSettings.size(info.reserveBytes)} 时，缓存会先删掉自己的旧内容，再不够就不缓存、不预读。',
                  key: const Key('stream-cache-free'),
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
