import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import 'network_settings.dart';

/// 设置 → 网络: whether files on GitHub go through an accelerating proxy (off by default) and which one, and under it
/// the engine's other network settings ([NetworkSettings]: DoH, and what the subscription's rules do).
class GithubProxySettings extends StatefulWidget {
  const GithubProxySettings({super.key});

  @override
  State<GithubProxySettings> createState() => _GithubProxySettingsState();
}

class _GithubProxySettingsState extends State<GithubProxySettings> {
  final _proxyField = TextEditingController();

  /// The prefix last seen from the engine, to refill the field when it changes there.
  String? _shownPrefix;

  @override
  void dispose() {
    _proxyField.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final engineSettings = state.engineSettings;
    if (engineSettings == null) return const SizedBox.shrink();
    if (engineSettings.githubProxyPrefix != _shownPrefix) {
      _shownPrefix = engineSettings.githubProxyPrefix;
      _proxyField.text = engineSettings.githubProxyPrefix;
    }
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('代理与 DNS', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
              const SizedBox(height: 10),
              SwitchListTile(
                key: const Key('github-proxy-switch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('GitHub 加速代理'),
                subtitle: Text(
                  engineSettings.githubProxy ? 'GitHub 上的文件经下面的代理获取，代理失败时再直连' : '已关闭：直连 GitHub，订阅里写的代理前缀（gh-proxy 等）会被去掉',
                ),
                value: engineSettings.githubProxy,
                onChanged: state.busy ? null : (on) => state.setGithubProxy(enabled: on, prefix: _proxyField.text),
              ),
              if (engineSettings.githubProxy)
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _proxyField,
                        enabled: !state.busy,
                        decoration: const InputDecoration(labelText: '代理地址', hintText: '如 https://ghfast.top/'),
                        onSubmitted: (v) => state.setGithubProxy(enabled: true, prefix: v),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.tonal(
                      onPressed: state.busy ? null : () => state.setGithubProxy(enabled: true, prefix: _proxyField.text),
                      child: const Text('应用'),
                    ),
                  ],
                ),
              const NetworkSettings(),
            ],
          ),
        ),
      ),
    );
  }
}
