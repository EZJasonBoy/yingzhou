import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../diagnostics/dev_log_page.dart';
import '../diagnostics/diagnostics_page.dart';
import '../ui/sectioned_page.dart';
import '../update/update_settings.dart';
import 'cache_settings.dart';
import 'danmaku_service_settings.dart';
import 'download_settings.dart';
import 'github_proxy_settings.dart';
import 'http_proxy_settings.dart';
import 'lan_section.dart';
import 'network_settings.dart';
import 'python_settings.dart';
import 'sources_page.dart';
import 'stream_cache_settings.dart';
import 'theme_mode_settings.dart';
import 'ui_mode_settings.dart';
import 'user_mode_settings.dart';

/// 设置：how this client and its engine behave, apart from where the content comes from (that is 源: the engine's
/// address, the subscriptions, the sites). Each card looks after itself and hides when its engine has no such thing.
/// The groups, their list on the left and the two columns of cards are [SectionedPage]'s.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, this.standalone = false, this.initialSection});

  /// Opened as a page of its own (from 我的 on a phone held upright, whose bottom bar has no room for a 设置 tab):
  /// with a bar to go back.
  final bool standalone;

  /// The group to show first (`network` from 源's 「网络设置」); the top of the page when null.
  final String? initialSection;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final info = state.info;
    final about = Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('映舟 Yingzhou', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                info == null ? '引擎未连接' : '引擎 ${info.version}（${info.platform}，协议 v${info.protocol}）',
                key: const Key('about-engine'),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Text(
                'AGPL-3.0 开源 · github.com/Sa1koro/yingzhou\n映舟只是播放器，不内置、不提供任何影视内容或订阅源。',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 12, height: 1.6),
              ),
            ],
          ),
        ),
      ),
    );
    // [PageSection.gap] under a heading: none where the first card of the group brings its own 12 above itself.
    return SectionedPage(
      title: '设置',
      standalone: standalone,
      initialSection: initialSection,
      listKey: const Key('settings-list'),
      sections: [
        // Simple mode has no 源 entry: the subscriptions and sites are reached from here (behind the lock, if set).
        if (state.userMode.simple)
          PageSection(
            id: 'content',
            title: '内容',
            icon: Icons.dns_outlined,
            gap: 0,
            children: [
              _card(
                context,
                title: '订阅与站点',
                children: [
                  Text(
                    state.summary == null ? '还没有导入订阅。' : '「${state.currentSite?.name ?? '没有可用的站点'}」 · ${state.summary!.sites} 个站点',
                    key: const Key('simple-content-summary'),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.tonal(
                    key: const Key('open-sources'),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SourcesPage(standalone: true))),
                    child: const Text('导入订阅、换站点'),
                  ),
                ],
              ),
            ],
          ),
        const PageSection(id: 'look', title: '外观', icon: Icons.palette_outlined, children: [UserModeSettings(), UiModeSettings(), ThemeModeSettings()]),
        const PageSection(id: 'play', title: '播放', icon: Icons.play_circle_outline_rounded, gap: 0, children: [StreamCacheSettings(), DanmakuServiceSettings()]),
        // Always there: the GitHub mirror and the proxy for updates are this device's own and work without an engine.
        // One card per kind of route, so on a wide window they stand side by side.
        PageSection(
          id: 'network',
          title: '网络',
          icon: Icons.public_rounded,
          gap: 0,
          children: [
            _card(context, title: 'GitHub 镜像', children: const [GithubProxySettings()]),
            _card(context, title: 'HTTP 代理', children: const [HttpProxySettings()]),
            if (state.engineSettings != null) _card(context, title: '安全 DNS 与订阅的网络规则', children: const [NetworkSettings()]),
          ],
        ),
        const PageSection(
          id: 'lan',
          title: '局域网',
          icon: Icons.wifi_tethering_rounded,
          gap: 0,
          children: [Padding(padding: EdgeInsets.only(top: 12), child: LanSection(part: LanPart.share))],
        ),
        const PageSection(id: 'data', title: '下载与数据', icon: Icons.download_outlined, gap: 0, children: [DownloadSettings(), CacheSettings(), PythonSettings()]),
        PageSection(id: 'about', title: '关于', icon: Icons.info_outline_rounded, gap: 0, children: [about, const UpdateSettings(), const DiagnosticsSettings()]),
        if (state.userMode.developer)
          PageSection(
            id: 'developer',
            title: '开发者',
            icon: Icons.terminal_rounded,
            gap: 0,
            children: [
              _card(
                context,
                title: '日志',
                children: [
                  const Text('播放器里按 I 看播放统计，「链路」看片源从哪来；这里是每一步的记录。'),
                  const SizedBox(height: 10),
                  FilledButton.tonal(
                    key: const Key('open-log'),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DevLogPage(standalone: true))),
                    child: const Text('打开日志'),
                  ),
                ],
              ),
            ],
          ),
      ],
    );
  }

  /// A card with a small title above its rows, like the cards that look after themselves.
  static Widget _card(BuildContext context, {required String title, required List<Widget> children}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
              const SizedBox(height: 10),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}
