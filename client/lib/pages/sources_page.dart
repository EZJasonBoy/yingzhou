import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../engine/models.dart';
import '../ui/device_form.dart';
import '../ui/phone_input.dart';
import '../ui/sectioned_page.dart';
import 'cache_settings.dart';
import 'lan_section.dart';
import 'saved_subscriptions.dart';
import 'settings_page.dart';

/// 源：where the content comes from. The engine's address, importing and switching subscriptions, the repository
/// switch and the site list. How the client and the engine behave is 设置 (settings_page.dart).
class SourcesPage extends StatefulWidget {
  const SourcesPage({super.key, this.standalone = false});

  /// Opened as a page of its own (from 设置 in simple mode, which has no 源 entry): with a bar to go back.
  final bool standalone;

  @override
  State<SourcesPage> createState() => _SourcesPageState();
}

class _SourcesPageState extends State<SourcesPage> {
  late final _engineField = TextEditingController(text: AppScope.read(context).engineUrl);
  final _subscriptionField = TextEditingController();

  @override
  void dispose() {
    _engineField.dispose();
    _subscriptionField.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final info = state.info;
    final summary = state.summary;

    final engine = _card(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _engineField,
                  keyboardType: TextInputType.url,
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
            '引擎在另一台设备上时：在那台设备的「设置 → 局域网」打开「局域网共享」，在「发现局域网里的引擎」里选它，或在这里填它显示的地址，再输入配对码',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
    );
    final subscriptions = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _card(
          context,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _subscriptionField,
                      keyboardType: TextInputType.url,
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
                  if (phoneInputAvailable(context)) ...[
                    const SizedBox(width: 8),
                    PhoneInputButton(
                      key: const Key('subscription-phone-input'),
                      enabled: state.connected && !state.busy,
                      request: const PhoneInputRequest(
                        title: '订阅地址',
                        hint: 'http(s)://…、clan://…，可带 ;pk; 密钥',
                        keyboard: PhoneKeyboard.url,
                      ),
                      onReceived: (url) {
                        _subscriptionField.text = url;
                        state.importSubscription(url);
                      },
                    ),
                  ],
                ],
              ),
              SavedSubscriptions(state: state),
            ],
          ),
        ),
        if (state.busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
        if (state.error != null) ...[
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(state.error!, style: TextStyle(color: scheme.error)),
          ),
          // A subscription that does not load is often a network matter: the way there is right here.
          const _NetworkRoute(failed: true),
        ],
      ],
    );
    // The groups, their list on the left, and the sites in a column of their own on a wide window: SectionedPage.
    return SectionedPage(
      title: '源',
      standalone: widget.standalone,
      listKey: const Key('sources-list'),
      sections: [
        PageSection(
          id: 'engine',
          title: '引擎',
          icon: Icons.memory_rounded,
          children: [engine, const Padding(padding: EdgeInsets.only(top: 12), child: LanSection(part: LanPart.connect))],
        ),
        PageSection(id: 'subscriptions', title: '订阅', icon: Icons.rss_feed_rounded, children: [subscriptions]),
        if (summary != null) ...[
          PageSection(
            id: 'config',
            title: '当前配置',
            icon: Icons.tune_rounded,
            children: [
              _card(
                context,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${summary.sites} 个站点 · ${summary.parses} 个解析 · ${summary.lives} 组直播', style: Theme.of(context).textTheme.titleMedium),
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
                    const _NetworkRoute(),
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
            ],
          ),
          PageSection(id: 'sites', title: '站点', icon: Icons.dns_outlined, side: true, children: [_SiteList(state: state)]),
        ],
      ],
    );
  }

  Widget _card(BuildContext context, {required Widget child}) => Card(child: Padding(padding: const EdgeInsets.all(16), child: child));
}

/// How configs are fetched (设置 → 网络: the GitHub mirror, the HTTP proxy when it is used for configs), with a
/// button that opens 设置 on its 网络 group. Under the current config, and under an import that failed.
class _NetworkRoute extends StatelessWidget {
  const _NetworkRoute({this.failed = false});

  /// Shown under an error: says what can be tried.
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final engine = state.engineSettings;
    final github = engine ?? state.network.githubSettings;
    final proxy = engine != null && engine.proxyScopes.contains('config') ? engine.httpProxy : '';
    final parts = [
      if (github.githubProxy) 'GitHub 上的经镜像 ${Uri.tryParse(github.githubProxyPrefix)?.host ?? github.githubProxyPrefix}',
      if (proxy.isNotEmpty) '经 HTTP 代理 $proxy',
    ];
    final route = parts.isEmpty ? '直连' : parts.join('，');
    final text = failed ? '获取配置：$route。打不开时可以换 GitHub 镜像或设 HTTP 代理' : '获取配置：$route';
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        children: [
          Text(text, key: Key(failed ? 'network-route-failed' : 'network-route'), style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
          TextButton(
            key: Key(failed ? 'open-network-failed' : 'open-network'),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsPage(standalone: true, initialSection: 'network'))),
            child: const Text('网络设置'),
          ),
        ],
      ),
    );
  }
}

/// The sites of the config in use; the one browsed on 首页 is marked, and a tap chooses another. A config with many
/// sites gets a field to narrow them down by name (not with a remote, which has no keyboard at hand).
class _SiteList extends StatefulWidget {
  const _SiteList({required this.state});

  final AppState state;

  /// The filter shows from this many sites on.
  static const filterFrom = 12;

  @override
  State<_SiteList> createState() => _SiteListState();
}

class _SiteListState extends State<_SiteList> {
  String _query = '';

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
    final state = widget.state;
    final scheme = Theme.of(context).colorScheme;
    final all = state.sites;
    final filter = all.length >= _SiteList.filterFrom && !isTv(context);
    final q = filter ? _query.trim().toLowerCase() : '';
    final sites = q.isEmpty ? all : [for (final s in all) if (s.name.toLowerCase().contains(q) || s.key.toLowerCase().contains(q)) s];
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          if (filter)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: TextField(
                key: const Key('site-filter'),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  hintText: '在 ${all.length} 个站点里找',
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          if (sites.isEmpty)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text('没有名字里带「${_query.trim()}」的站点', style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
          for (final site in sites)
            ListTile(
              dense: true,
              enabled: state.supports(site.runtime),
              selected: site.key == state.currentSiteKey,
              onTap: state.supports(site.runtime) ? () => state.selectSite(site.key) : null,
              title: Text(site.name),
              subtitle: Text(
                state.supports(site.runtime)
                    ? site.key
                    : '${site.key} · ${site.runtime == SiteRuntime.py ? '需要 Python，见「设置」里的「Python 蜘蛛」' : '这台引擎还不支持这类站点'}',
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
