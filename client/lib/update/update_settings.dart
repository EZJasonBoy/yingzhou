import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import 'release_info.dart';
import 'update_dialog.dart';
import 'update_models.dart';
import 'update_service.dart';

/// 更新: this version, 「检查更新」, the switch for the daily automatic check, and the HTTP proxy update checks and
/// downloads go through. Self-contained (state in [UpdateService]); shows nothing where updates are not checked
/// (the web build).
class UpdateSettings extends StatefulWidget {
  const UpdateSettings({super.key});

  @override
  State<UpdateSettings> createState() => _UpdateSettingsState();
}

class _UpdateSettingsState extends State<UpdateSettings> {
  late final UpdateService _service = UpdateService.of(context);
  late final _proxyField = TextEditingController(text: _service.proxy);
  String? _proxyError;

  @override
  void dispose() {
    _proxyField.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final result = await _service.check(mirror: UpdateService.mirrorOf(AppScope.read(context)));
    if (result != null && result.newer && mounted) await showUpdateDialog(context, result);
  }

  Future<void> _saveProxy() async {
    final ok = await _service.setProxy(_proxyField.text);
    if (!mounted) return;
    setState(() => _proxyError = ok ? null : '格式是 主机:端口，如 127.0.0.1:7890');
    if (ok) {
      _proxyField.text = _service.proxy;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(_service.proxy.isEmpty ? '已清除更新用的代理' : '检查和下载更新将经过 ${_service.proxy}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = _service;
    if (!service.supported) return const SizedBox.shrink();
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final mirror = UpdateService.mirrorOf(state);

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
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('update-proxy'),
                          controller: _proxyField,
                          keyboardType: TextInputType.url,
                          decoration: InputDecoration(labelText: '更新用的代理（HTTP）', hintText: '如 127.0.0.1:7890，留空不用', errorText: _proxyError),
                          onSubmitted: (_) => _saveProxy(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: FilledButton.tonal(key: const Key('update-proxy-save'), onPressed: _saveProxy, child: const Text('使用')),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '先直连 GitHub；连不上时${mirror.isEmpty ? '，可以在「网络」里打开 GitHub 加速代理，检查更新也会经它重试' : '经 GitHub 加速代理 ${mirrorHost(mirror)} 重试'}。'
                    '代理只用于检查和下载更新，引擎和播放不经过它',
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
