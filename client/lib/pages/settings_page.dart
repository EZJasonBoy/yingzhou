import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../diagnostics/diagnostics_page.dart';
import '../update/update_settings.dart';
import 'cache_settings.dart';
import 'danmaku_service_settings.dart';
import 'download_settings.dart';
import 'github_proxy_settings.dart';
import 'lan_section.dart';
import 'network_settings.dart';
import 'python_settings.dart';
import 'stream_cache_settings.dart';
import 'theme_mode_settings.dart';
import 'ui_mode_settings.dart';

/// 设置：how this client and its engine behave, apart from where the content comes from (that is 源: the engine's
/// address, the subscriptions, the sites). Each card looks after itself and hides when its engine has no such thing.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, this.standalone = false});

  /// Opened as a page of its own (from 我的 on a phone held upright, whose bottom bar has no room for a 设置 tab):
  /// with a bar to go back.
  final bool standalone;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final info = state.info;
    // [gap] under the heading: none where the first card of the group brings its own 12 above itself.
    Widget heading(String text, {double gap = 10}) => Padding(
      padding: EdgeInsets.fromLTRB(4, 22, 4, gap),
      child: Text(text, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
    );
    return Scaffold(
      appBar: standalone ? AppBar(title: const Text('设置')) : null,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            // All of it is built, not only what is on screen: a remote's ↓ can only go to an item that exists.
            child: SingleChildScrollView(
              key: const Key('settings-list'),
              padding: EdgeInsets.fromLTRB(20, standalone ? 0 : 16, 20, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!standalone) Text('设置', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                  heading('外观'),
                  const UiModeSettings(),
                  const ThemeModeSettings(),
                  heading('播放', gap: 0),
                  const StreamCacheSettings(),
                  const DanmakuServiceSettings(),
                  if (state.engineSettings != null) ...[
                    heading('网络', gap: 0),
                    _card(context, title: '代理与 DNS', children: const [GithubProxySettings(), NetworkSettings()]),
                  ],
                  heading('局域网'),
                  const LanSection(part: LanPart.share),
                  heading('下载与数据', gap: 0),
                  const DownloadSettings(),
                  const CacheSettings(),
                  const PythonSettings(),
                  heading('关于'),
                  Card(
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
                  const UpdateSettings(),
                  const DiagnosticsSettings(),
                ],
              ),
            ),
          ),
        ),
      ),
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
