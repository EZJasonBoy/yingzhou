import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../diagnostics/diagnostics_page.dart' show SourceReportButton;
import '../engine/models.dart';
import '../ui/poster_cache.dart';

String _twoDigits(int n) => n.toString().padLeft(2, '0');

/// "今天 08:05", "11-03 21:40", or with the year when it is another one.
String formatFetchedAt(int millis, {DateTime? now}) {
  final t = DateTime.fromMillisecondsSinceEpoch(millis);
  final today = now ?? DateTime.now();
  final clock = '${_twoDigits(t.hour)}:${_twoDigits(t.minute)}';
  if (t.year == today.year && t.month == today.month && t.day == today.day) return '今天 $clock';
  final date = '${_twoDigits(t.month)}-${_twoDigits(t.day)} $clock';
  return t.year == today.year ? date : '${t.year}-$date';
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// 源 → 当前配置: how old the subscription in use is, whether it is the engine's kept copy, and 「刷新」.
class ConfigFreshness extends StatelessWidget {
  const ConfigFreshness({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final summary = state.summary;
    if (summary == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final when = summary.fetchedAt > 0 ? formatFetchedAt(summary.fetchedAt) : null;
    final issue = summary.refreshDiagnostic;
    final failed = summary.refreshError.isNotEmpty || issue != null;
    final String text;
    if (summary.refreshing) {
      text = '先用着${when == null ? '' : ' $when '}保存的副本，正在后台获取最新的…';
    } else if (failed) {
      text = '没能获取到最新的订阅，用的是${when == null ? '之前' : ' $when '}保存的副本\n${issue?.summary ?? summary.refreshError}';
    } else if (summary.stored) {
      text = '用的是${when == null ? '之前' : ' $when '}保存的副本';
    } else {
      text = when == null ? '' : '$when 获取';
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, key: const Key('config-freshness'), style: theme.textTheme.bodySmall?.copyWith(color: failed ? scheme.error : scheme.onSurfaceVariant), maxLines: 3, overflow: TextOverflow.ellipsis),
                if (issue != null && !summary.refreshing) SourceReportButton(issues: [issue]),
              ],
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            key: const Key('config-refresh'),
            onPressed: state.busy ? null : state.refreshSubscription,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('刷新'),
          ),
        ],
      ),
    );
  }
}

/// 设置 → 缓存: how much the engine keeps (subscription copies, pages of sites) and how much this device keeps
/// (posters), with one button to clear both.
class CacheSettings extends StatefulWidget {
  const CacheSettings({super.key});

  @override
  State<CacheSettings> createState() => _CacheSettingsState();
}

class _CacheSettingsState extends State<CacheSettings> {
  CacheInfo? _engine;
  int? _posters;
  bool _clearing = false;
  Object? _askedFor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    final asking = (state.connected, state.engineUrl, state.summary?.url, state.summary?.fetchedAt);
    if (asking == _askedFor) return;
    _askedFor = asking;
    _load(state);
  }

  Future<void> _load(AppState state) async {
    CacheInfo? engine;
    try {
      if (state.connected) engine = await state.client.cacheInfo();
    } on EngineException {
      // An engine without a data cache.
    } on StateError {
      // Disconnected meanwhile.
    }
    final posters = await PosterCache.instance?.size();
    if (mounted) {
      setState(() {
        _engine = engine;
        _posters = posters;
      });
    }
  }

  Future<void> _clear(AppState state) async {
    setState(() => _clearing = true);
    try {
      if (_engine != null) await state.client.clearCache();
    } on EngineException {
      // Shown by the sizes that follow.
    }
    await PosterCache.instance?.clear();
    PaintingBinding.instance.imageCache.clear();
    if (!mounted) return;
    setState(() => _clearing = false);
    await _load(state);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final engine = _engine;
    final posters = _posters;
    if (engine == null && posters == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final empty = (engine?.bytes ?? 0) == 0 && (posters ?? 0) == 0;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('缓存', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (engine != null) Text('订阅副本和站点数据：${formatBytes(engine.bytes)}（${engine.entries} 项，在引擎里）', key: const Key('cache-engine')),
                        if (posters != null) Text('海报图片：${formatBytes(posters)}（在这台设备上）', key: const Key('cache-posters')),
                        const SizedBox(height: 4),
                        Text(
                          '有了它，启动时不用等订阅下载，看过的页面和海报立刻显示，断网时也还能翻。占用有上限，旧的会自动清掉；不含播放缓存',
                          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.tonal(
                    key: const Key('cache-clear'),
                    onPressed: _clearing || empty ? null : () => _clear(state),
                    child: Text(_clearing ? '正在清除…' : '清除缓存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
