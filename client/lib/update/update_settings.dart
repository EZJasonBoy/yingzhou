import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import 'release_info.dart';
import 'update_dialog.dart';
import 'update_models.dart';
import 'update_service.dart';

class UpdateSettings extends StatefulWidget {
  const UpdateSettings({super.key});

  @override
  State<UpdateSettings> createState() => _UpdateSettingsState();
}

class _UpdateSettingsState extends State<UpdateSettings> {
  late final UpdateService _service = UpdateService.of(context);

  Future<void> _check() async {
    final result = await _service.check();
    if (result != null && result.newer && mounted) await showUpdateDialog(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final service = _service;
    if (!service.supported) return const SizedBox.shrink();
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final mirror = state.network.updateMirror;
    final proxy = state.network.updateProxy;

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ListenableBuilder(
            listenable: service,
            builder: (context, _) {
              final last = service.last;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('更新', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(child: Text('映舟 $appVersion', key: const Key('update-version'), style: theme.textTheme.titleMedium)),
                      if (last != null && last.newer)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: FilledButton(key: const Key('update-show'), onPressed: () => showUpdateDialog(context, last), child: const Text('查看新版本')),
                        ),
                      FilledButton.tonal(
                        key: const Key('update-check'),
                        onPressed: service.checking ? null : _check,
                        child: Text(service.checking ? '正在检查…' : '检查更新'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  _status(context, service, last),
                  const SizedBox(height: 4),
                  SwitchListTile(
                    key: const Key('update-auto'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('自动检查更新'),
                    subtitle: Text(
                      service.autoCheck
                          ? '启动后每天最多检查一次：向 GitHub 取一个小文件（latest.json），不发送其他信息；有新版本时提示一次'
                          : '已关闭：只在点「检查更新」时访问 GitHub',
                    ),
                    value: service.autoCheck,
                    onChanged: service.setAutoCheck,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '检查和下载更新遵循「设置 → 网络」：${mirror.isEmpty ? '直连 GitHub' : '优先使用 ${mirrorHost(mirror)}，失败时尝试直连'}'
                    '${proxy.isEmpty ? '' : '，经 HTTP 代理 $proxy'}。',
                    key: const Key('update-route-explain'),
                    style: small,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _status(BuildContext context, UpdateService service, UpdateCheckResult? last) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final lines = <Widget>[];
    if (last == null) {
      final at = service.lastCheckAt;
      lines.add(Text(at == null ? '还没有检查过' : '上次成功检查：${_time(at)}', key: const Key('update-status'), style: small));
    } else if (!last.ok) {
      lines.add(
        Text(
          '检查失败：${last.failures.join('；')}${last.proxy.isEmpty ? '' : '（经代理 ${last.proxy}）'}',
          key: const Key('update-status'),
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
        ),
      );
    } else {
      final release = last.release!;
      final what = switch (last.comparison) {
        > 0 => '发现新版本 ${release.version}${release.date.isEmpty ? '' : '（${release.date}）'}',
        0 => '已是最新版本',
        _ => '这一版比最新发布的 ${release.version} 还新',
      };
      lines.add(Text('$what · ${_time(last.at)}', key: const Key('update-status'), style: last.newer ? theme.textTheme.bodyMedium : small));
      // Which way it came, and what failed before.
      lines.add(
        Text(
          '获取途径：${[...last.failures, '${last.failures.isEmpty ? '' : '改为'}${last.routeLabel}'].join('；')}',
          key: const Key('update-status-route'),
          style: small,
        ),
      );
    }
    final download = service.download;
    if (download != null) {
      lines.add(
        Text(
          download.error != null
              ? '下载失败：${download.error}'
              : download.path != null
              ? '已下载到 ${download.path}'
              : '正在下载 ${download.asset.name}${download.fraction == null ? '' : '（${(download.fraction! * 100).round()}%）'}',
          key: const Key('update-download-status'),
          style: small,
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: lines);
  }

  static String _time(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    final now = DateTime.now();
    final day = t.year == now.year && t.month == now.month && t.day == now.day ? '今天' : '${t.month}-${t.day}';
    return '$day ${two(t.hour)}:${two(t.minute)}';
  }
}
