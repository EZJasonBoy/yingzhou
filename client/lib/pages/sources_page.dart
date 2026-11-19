import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../engine/models.dart';
import 'cache_settings.dart';
import 'danmaku_service_settings.dart';
import 'download_settings.dart';
import 'network_settings.dart';
import 'stream_cache_settings.dart';
import 'python_settings.dart';
import 'lan_section.dart';
import 'ui_mode_settings.dart';

/// 源：engine connection, subscription import, repository switch and the site list.
class SourcesPage extends StatefulWidget {
  const SourcesPage({super.key});

  @override
  State<SourcesPage> createState() => _SourcesPageState();
}

class _SourcesPageState extends State<SourcesPage> {
  late final _engineField = TextEditingController(text: AppScope.read(context).engineUrl);
  final _subscriptionField = TextEditingController();
  final _proxyField = TextEditingController();

  /// The prefix last seen from the engine, to refill the field when it changes there.
  String? _shownPrefix;

  @override
  void dispose() {
    _engineField.dispose();
    _subscriptionField.dispose();
    _proxyField.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final info = state.info;
    final summary = state.summary;
    final engineSettings = state.engineSettings;
    if (engineSettings != null && engineSettings.githubProxyPrefix != _shownPrefix) {
      _shownPrefix = engineSettings.githubProxyPrefix;
      _proxyField.text = engineSettings.githubProxyPrefix;
    }

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              children: [
                Text('源', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 16),
                const UiModeSettings(),
                _section(
                  context,
                  title: '引擎',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _engineField,
                              decoration: const InputDecoration(labelText: '引擎地址'),
                              onSubmitted: (v) => state.connect(v),
                            ),
                          ),
                          const SizedBox(width: 12),
                          FilledButton.tonal(onPressed: state.busy ? null : () => state.connect(_engineField.text), child: const Text('连接')),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        info == null ? '未连接' : '已连接：${info.name} ${info.version}（${info.platform}，协议 v${info.protocol}）',
                        key: const Key('engine-status'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '引擎在另一台设备上时：在那台设备打开「局域网共享」，在下面「发现局域网里的引擎」里选它，或在这里填它显示的地址，再输入配对码',
                        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const LanSection(),
                const SizedBox(height: 12),
                _section(
                  context,
                  title: '订阅',
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _subscriptionField,
                          enabled: state.connected && !state.busy,
                          decoration: const InputDecoration(labelText: '订阅地址', hintText: '支持 http(s)、clan://、;pk; 密钥后缀'),
                          onSubmitted: (v) => state.importSubscription(v),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        onPressed: state.connected && !state.busy ? () => state.importSubscription(_subscriptionField.text) : null,
                        child: const Text('导入'),
                      ),
                    ],
                  ),
                ),
                if (engineSettings != null) ...[
                  const SizedBox(height: 12),
                  _section(
                    context,
                    title: '网络',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SwitchListTile(
                          key: const Key('github-proxy-switch'),
                          contentPadding: EdgeInsets.zero,
                          title: const Text('GitHub 加速代理'),
                          subtitle: Text(
                            engineSettings.githubProxy
                                ? 'GitHub 上的文件经下面的代理获取，代理失败时再直连'
                                : '已关闭：直连 GitHub，订阅里写的代理前缀（gh-proxy 等）会被去掉',
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
                ],
                const CacheSettings(),
                const StreamCacheSettings(),
                const DanmakuServiceSettings(),
                const DownloadSettings(),
                const PythonSettings(),
                if (state.busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
                if (state.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(state.error!, style: TextStyle(color: scheme.error)),
                  ),
                if (summary != null) ...[
                  const SizedBox(height: 12),
                  _section(
                    context,
                    title: '当前配置',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${summary.sites} 个站点 · ${summary.parses} 个解析 · ${summary.lives} 组直播',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 4),
                        Text(summary.url, style: Theme.of(context).textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                        if (summary.fetchedUrl.isNotEmpty && summary.fetchedUrl != summary.url)
                          Text(
                            '实际访问：${summary.fetchedUrl}',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        const ConfigFreshness(),
                        if (summary.repos.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          DropdownButton<String>(
                            value: summary.repos.any((r) => r.url == summary.url) ? summary.url : null,
                            isExpanded: true,
                            hint: const Text('选择仓库'),
                            items: [
                              for (final r in summary.repos)
                                DropdownMenuItem(
                                  value: r.url,
                                  child: Padding(
                                    padding: EdgeInsets.only(left: 16.0 * r.depth),
                                    child: Text(r.group ? '${r.name}（多仓）' : r.name, overflow: TextOverflow.ellipsis),
                                  ),
                                ),
                            ],
                            onChanged: state.busy ? null : (url) => url == null ? null : state.switchRepo(url),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _SiteList(state: state),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _section(BuildContext context, {required String title, required Widget child}) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
              const SizedBox(height: 10),
              child,
            ],
          ),
        ),
      );
}

class _SiteList extends StatelessWidget {
  const _SiteList({required this.state});

  final AppState state;

  static const _labels = {
    SiteRuntime.cms: '采集',
    SiteRuntime.js: 'JS',
    SiteRuntime.jar: 'JAR',
    SiteRuntime.py: 'PY',
    SiteRuntime.remote: '远程',
    SiteRuntime.unknown: '未知',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (final site in state.sites)
            ListTile(
              dense: true,
              enabled: state.supports(site.runtime),
              selected: site.key == state.currentSiteKey,
              onTap: state.supports(site.runtime) ? () => state.selectSite(site.key) : null,
              title: Text(site.name),
              subtitle: Text(
                state.supports(site.runtime)
                    ? site.key
                    : '${site.key} · ${site.runtime == SiteRuntime.py ? '需要 Python，见上方「Python 蜘蛛」' : '这台引擎还不支持这类站点'}',
              ),
              leading: Container(
                width: 44,
                padding: const EdgeInsets.symmetric(vertical: 2),
                decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(6)),
                alignment: Alignment.center,
                child: Text(_labels[site.runtime]!, style: TextStyle(fontSize: 12, color: scheme.onSecondaryContainer)),
              ),
              trailing: site.searchable ? const Icon(Icons.search, size: 18) : null,
            ),
        ],
      ),
    );
  }
}
