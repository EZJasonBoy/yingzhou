import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../ui/pin_pad.dart';
import '../ui/user_mode.dart';

/// What each [UserMode] is called and what it does, for 设置 and for the first start.
extension UserModeText on UserMode {
  String get label => switch (this) {
    UserMode.simple => '简单',
    UserMode.standard => '标准',
    UserMode.developer => '开发者',
  };

  IconData get icon => switch (this) {
    UserMode.simple => Icons.play_circle_outline_rounded,
    UserMode.standard => Icons.dashboard_outlined,
    UserMode.developer => Icons.tune_rounded,
  };

  String get summary => switch (this) {
    UserMode.simple => '打开就看：上次没看完的、收藏和推荐。按钮少，线路坏了自动换。',
    UserMode.standard => '全部功能：多个站点、搜索和筛选、下载、网盘、直播回看。',
    UserMode.developer => '标准之上：播放统计、片源从哪来、日志，方便排查和调订阅。',
  };

  String get audience => switch (this) {
    UserMode.simple => '适合客厅的电视、家里的长辈',
    UserMode.standard => '全部功能都在',
    UserMode.developer => '给调订阅、写蜘蛛的人',
  };
}

/// 设置 → 外观 → 用法: simple, standard or developer, and in simple mode the four-digit lock on 设置.
class UserModeSettings extends StatelessWidget {
  const UserModeSettings({super.key});

  Future<void> _setPin(BuildContext context, UserModeController mode) async {
    final pin = await askNewPin(context);
    if (pin != null) await mode.setPin(pin);
  }

  @override
  Widget build(BuildContext context) {
    final mode = AppScope.of(context).userMode;
    final scheme = Theme.of(context).colorScheme;
    final quiet = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('用法', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
              const SizedBox(height: 10),
              SegmentedButton<UserMode>(
                key: const Key('user-mode'),
                showSelectedIcon: false,
                segments: [for (final m in UserMode.values) ButtonSegment(value: m, icon: Icon(m.icon), label: Text(m.label))],
                selected: {mode.mode},
                onSelectionChanged: (s) => mode.set(s.first),
              ),
              const SizedBox(height: 8),
              Text(mode.mode.summary, key: const Key('user-mode-summary'), style: quiet),
              if (mode.simple) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    Icon(mode.hasPin ? Icons.lock_rounded : Icons.lock_open_rounded, size: 20, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(mode.hasPin ? '设置已上锁' : '给设置上锁'),
                          Text(mode.hasPin ? '进「设置」要先输 4 位密码；看片不受影响。' : '设一个 4 位密码，免得订阅和用法被误改。', style: quiet),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (mode.hasPin) ...[
                      TextButton(key: const Key('lock-remove'), onPressed: () => mode.setPin(null), child: const Text('取消')),
                      FilledButton.tonal(key: const Key('lock-change'), onPressed: () => _setPin(context, mode), child: const Text('改密码')),
                    ] else
                      FilledButton.tonal(key: const Key('lock-set'), onPressed: () => _setPin(context, mode), child: const Text('设密码')),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// What each [StartPage] is called and does, for 设置.
extension StartPageText on StartPage {
  String get label => switch (this) {
    StartPage.resume => '继续看',
    StartPage.home => '站点推荐',
    StartPage.library => '我的',
  };

  IconData get icon => switch (this) {
    StartPage.resume => Icons.play_circle_outline_rounded,
    StartPage.home => Icons.home_outlined,
    StartPage.library => Icons.video_library_outlined,
  };

  String get summary => switch (this) {
    StartPage.resume => '首页的「继续看」：上次没看完的那部、最近看过的和收藏。还没看过东西时是站点的推荐。',
    StartPage.home => '首页上这个站点的推荐；「继续看」在它左边的标签里。',
    StartPage.library => '「我的」：观看记录、收藏和下载。',
  };
}

/// 设置 → 外观 → 打开映舟时先显示: 继续看, the site's recommendations, or 我的 (not in simple mode, which has no
/// such entry). The same in every mode; it takes effect the next time the app starts.
class StartPageSettings extends StatelessWidget {
  const StartPageSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final mode = AppScope.of(context).userMode;
    final scheme = Theme.of(context).colorScheme;
    final choices = [
      for (final p in StartPage.values)
        if (p != StartPage.library || !mode.simple) p,
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('打开映舟时先显示', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
              const SizedBox(height: 10),
              SegmentedButton<StartPage>(
                key: const Key('start-page'),
                showSelectedIcon: false,
                segments: [for (final p in choices) ButtonSegment(value: p, icon: Icon(p.icon), label: Text(p.label))],
                selected: {mode.startsOn},
                onSelectionChanged: (s) => mode.setStartPage(s.first),
              ),
              const SizedBox(height: 8),
              Text('${mode.startsOn.summary}下次打开映舟时生效。', key: const Key('start-page-summary'), style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}
