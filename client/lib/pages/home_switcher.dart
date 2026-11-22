import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../diagnostics/diagnostics_page.dart' show SourceReportButton;
import '../engine/models.dart';
import '../ui/device_form.dart';
import '../ui/shell.dart' show shellUsesBottomBar;
import '../ui/tv/tv_focus.dart';
import '../ui/tv/tv_widgets.dart';

/// Where the home page's content comes from, at three levels: the saved subscription, the entry of a
/// multi-repository subscription, and the site. A level shows only when there is a choice at it.
///
/// Wide (desktop, tablet, phone on its side, TV): 「订阅 ▾ › 仓库 ▾ › 站点 ▾」, each with its own menu (on a TV, a
/// dialog for the remote). Narrow (a phone held upright): one 「站点 ▾」 that opens a panel listing the sites, with
/// 「订阅 › 仓库」 above them when there is more than one; that row steps up to the entries and the subscriptions,
/// in the same panel.
class HomeSwitcher extends StatefulWidget {
  const HomeSwitcher({super.key});

  @override
  State<HomeSwitcher> createState() => _HomeSwitcherState();
}

enum _Level { subscription, repo, site }

class _HomeSwitcherState extends State<HomeSwitcher> {
  /// The level being switched, for its spinner.
  _Level? _switching;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final levels = _Levels.of(state);
    if (shellUsesBottomBar(context)) {
      return _chip(
        key: const Key('home-site-chip'),
        icon: Icons.dns_outlined,
        label: levels.siteName,
        busy: _switching != null,
        onPressed: () => _openSheet(context),
      );
    }
    final parts = <Widget>[
      if (levels.showSubscriptions) _subscriptionChip(context, state, levels),
      if (levels.showRepos) _repoChip(context, state, levels),
      _siteChip(context, state, levels),
    ];
    return SingleChildScrollView(
      key: const Key('home-switcher'),
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < parts.length; i++) ...[
            if (i > 0) Icon(Icons.chevron_right_rounded, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
            parts[i],
          ],
        ],
      ),
    );
  }

  Widget _chip({required Key key, required IconData icon, required String label, required bool busy, required VoidCallback onPressed}) {
    return ActionChip(
      key: key,
      avatar: Icon(icon, size: 18),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(constraints: const BoxConstraints(maxWidth: 180), child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
          busy
              ? const Padding(padding: EdgeInsets.only(left: 6), child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)))
              : const Icon(Icons.arrow_drop_down, size: 20),
        ],
      ),
      // Never disabled while busy: a disabled chip would drop the TV's focus. A tap then does nothing.
      onPressed: onPressed,
    );
  }

  /// A level's chip with its menu: a [MenuAnchor] for mouse and touch, a dialog for the remote.
  Widget _levelChip<T>(
    BuildContext context, {
    required Key key,
    required _Level level,
    required IconData icon,
    required String label,
    required String title,
    required List<(T, String, int)> items,
    required T? selected,
    required Future<void> Function(T value) choose,
  }) {
    final busy = _switching == level;
    Future<void> pick(T value) async {
      if (value == selected || AppScope.read(context).busy) return;
      await _switch(context, level, () => choose(value));
    }

    if (isTv(context)) {
      return _chip(
        key: key,
        icon: icon,
        label: label,
        busy: busy,
        onPressed: () async {
          if (AppScope.read(context).busy) return;
          final value = await showTvChoiceDialog<T>(
            context,
            title: title,
            items: [for (final (v, name, _) in items) (v, name)],
            selected: selected,
            indent: (v) => items.firstWhere((e) => e.$1 == v).$3,
          );
          if (value != null && context.mounted) await pick(value);
        },
      );
    }
    return MenuAnchor(
      menuChildren: [
        for (final (value, name, depth) in items)
          MenuItemButton(
            leadingIcon: Icon(value == selected ? Icons.check : null, size: 18),
            onPressed: () => pick(value),
            child: Padding(padding: EdgeInsets.only(left: 16.0 * depth), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 360), child: Text(name, overflow: TextOverflow.ellipsis))),
          ),
      ],
      builder: (context, controller, _) => _chip(
        key: key,
        icon: icon,
        label: label,
        busy: busy,
        onPressed: () {
          if (AppScope.read(context).busy) return;
          controller.isOpen ? controller.close() : controller.open();
        },
      ),
    );
  }

  Widget _subscriptionChip(BuildContext context, AppState state, _Levels levels) => _levelChip<String>(
        context,
        key: const Key('home-sub-chip'),
        level: _Level.subscription,
        icon: Icons.rss_feed_rounded,
        label: levels.subscriptionName,
        title: '选择订阅',
        items: [for (final s in state.subscriptions) (s.id, s.label, 0)],
        selected: state.summary?.subscriptionId,
        choose: state.useSubscription,
      );

  Widget _repoChip(BuildContext context, AppState state, _Levels levels) => _levelChip<String>(
        context,
        key: const Key('home-repo-chip'),
        level: _Level.repo,
        icon: Icons.folder_copy_outlined,
        label: levels.repoName,
        title: '选择仓库',
        items: [for (final r in levels.repos) (r.url, repoLabel(r), r.depth)],
        selected: state.summary?.url,
        choose: state.switchRepo,
      );

  Widget _siteChip(BuildContext context, AppState state, _Levels levels) => _levelChip<String>(
        context,
        key: const Key('home-site-chip'),
        level: _Level.site,
        icon: Icons.dns_outlined,
        label: levels.siteName,
        title: '选择站点',
        items: [for (final s in state.browsableSites) (s.key, s.name, 0)],
        selected: state.currentSiteKey,
        choose: (key) async => state.selectSite(key),
      );

  /// Runs a switch with its chip spinning; a failure is told, and the config that was there stays.
  Future<void> _switch(BuildContext context, _Level level, Future<void> Function() action) async {
    setState(() => _switching = level);
    final state = AppScope.read(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    await action();
    if (!mounted) return;
    setState(() => _switching = null);
    final error = state.error;
    if (error != null && level != _Level.site) {
      final issue = state.actionDiagnostic;
      messenger?.showSnackBar(SnackBar(content: Text('没能切换：$error'), action: issue == null ? null : SnackBarAction(label: '故障报告', onPressed: () {
        if (mounted) SourceReportButton.open(context, [issue]);
      })));
    }
  }

  Future<void> _openSheet(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) => const FractionallySizedBox(heightFactor: 0.75, child: _SourceSheet()),
      );
}

/// Simple mode's 首页: one button with the site's name; it opens [openSourcePanel].
class SourcePanelChip extends StatelessWidget {
  const SourcePanelChip({super.key, required this.siteName});

  final String siteName;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      key: const Key('home-source-panel'),
      avatar: const Icon(Icons.dns_outlined, size: 18),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(constraints: const BoxConstraints(maxWidth: 220), child: Text(siteName, maxLines: 1, overflow: TextOverflow.ellipsis)),
          const Icon(Icons.chevron_right_rounded, size: 20),
        ],
      ),
      onPressed: () => openSourcePanel(context),
    );
  }
}

/// The sites (and a step up to the entries and the subscriptions) in a panel that slides in from the right, over
/// the page. Choosing a site closes it; BACK, a tap beside it or Esc close it too. Works with a remote: the site in
/// use has the focus.
Future<void> openSourcePanel(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, _, _) => Align(
      alignment: Alignment.centerRight,
      child: Material(
        key: const Key('source-panel'),
        color: Theme.of(context).colorScheme.surfaceContainer,
        elevation: 8,
        child: SizedBox(
          width: width < 480 ? width * 0.88 : 420,
          height: double.infinity,
          child: const SafeArea(left: false, child: _SourceSheet()),
        ),
      ),
    ),
    transitionBuilder: (context, animation, _, child) => SlideTransition(
      position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}

/// How an entry of a multi-repository subscription is named in the lists.
String repoLabel(RepoInfo r) => r.group ? '${r.name}（多仓）' : r.name;

/// What the levels hold right now.
class _Levels {
  const _Levels({required this.subscriptionName, required this.repoName, required this.siteName, required this.repos, required this.showSubscriptions});

  factory _Levels.of(AppState state) {
    final summary = state.summary;
    final sub = state.subscriptions.where((s) => s.id == summary?.subscriptionId).firstOrNull;
    final repos = summary?.repos ?? const <RepoInfo>[];
    final repo = repos.where((r) => r.url == summary?.url).firstOrNull;
    return _Levels(
      subscriptionName: sub?.label ?? '订阅',
      repoName: repo?.name ?? '选择仓库',
      siteName: state.currentSite?.name ?? '选择站点',
      repos: repos,
      showSubscriptions: state.subscriptions.length > 1,
    );
  }

  final String subscriptionName;
  final String repoName;
  final String siteName;
  final List<RepoInfo> repos;
  final bool showSubscriptions;

  bool get showRepos => repos.length > 1;
}

/// The narrow form's panel: the sites, and above them a way up to the entries and the subscriptions.
class _SourceSheet extends StatefulWidget {
  const _SourceSheet();

  @override
  State<_SourceSheet> createState() => _SourceSheetState();
}

class _SourceSheetState extends State<_SourceSheet> {
  _Level _level = _Level.site;
  bool _loading = false;
  String? _error;

  Future<void> _load(Future<void> Function() action) async {
    final state = AppScope.read(context);
    setState(() {
      _loading = true;
      _error = null;
    });
    await action();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = state.error;
      // On to the sites of what was loaded; after a failure the list stays where it was, with the reason.
      if (_error == null) _level = _Level.site;
    });
  }

  /// One level down (system back), or out of the panel from the sites.
  void _back() => setState(() => _level = _level == _Level.subscription && _Levels.of(AppScope.read(context)).showRepos ? _Level.repo : _Level.site);

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final levels = _Levels.of(state);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget title(String text, {bool back = false, Widget? trailing}) => Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Row(
            children: [
              if (back) IconButton(key: const Key('sheet-back'), icon: const Icon(Icons.chevron_left_rounded), tooltip: '返回', onPressed: _back) else const SizedBox(width: 12),
              Expanded(child: Text(text, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
              ?trailing,
            ],
          ),
        );

    final tv = isTv(context);
    Widget row({required Key key, required String text, required bool current, int depth = 0, required VoidCallback onTap}) => tv
        // The remote: big rows with the brand's focus ring; the one in use takes the focus when the list shows.
        ? Padding(
            padding: EdgeInsets.fromLTRB(12 + 20.0 * depth, 3, 12, 3),
            child: TvFocusable(
              key: key,
              autofocus: current,
              scale: 1.03,
              onTap: _loading ? null : onTap,
              child: Container(
                constraints: const BoxConstraints(minHeight: 50),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(color: current ? scheme.primaryContainer : scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  Icon(current ? Icons.check_rounded : null, size: 20),
                  const SizedBox(width: 10),
                  Expanded(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16))),
                ]),
              ),
            ),
          )
        : ListTile(
            key: key,
            contentPadding: EdgeInsets.only(left: 16 + 20.0 * depth, right: 16),
            leading: Icon(current ? Icons.check_rounded : null),
            title: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: _loading ? null : onTap,
          );

    final List<Widget> head;
    final List<Widget> rows;
    switch (_level) {
      case _Level.site:
        final context = [if (levels.showSubscriptions) levels.subscriptionName, if (levels.showRepos) levels.repoName];
        head = [
          title('选择站点'),
          if (context.isNotEmpty)
            ListTile(
              key: const Key('sheet-context'),
              dense: true,
              leading: Icon(levels.showRepos ? Icons.folder_copy_outlined : Icons.rss_feed_rounded, size: 20),
              title: Text(context.join(' › '), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.primary)),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _loading ? null : () => setState(() => _level = levels.showRepos ? _Level.repo : _Level.subscription),
            ),
        ];
        rows = [
          for (final s in state.browsableSites)
            row(
              key: Key('sheet-site-${s.key}'),
              text: s.name,
              current: s.key == state.currentSiteKey,
              onTap: () {
                state.selectSite(s.key);
                Navigator.of(this.context).pop();
              },
            ),
        ];
      case _Level.repo:
        head = [
          title(
            '选择仓库',
            back: true,
            trailing: levels.showSubscriptions
                ? TextButton(key: const Key('sheet-to-subscriptions'), onPressed: _loading ? null : () => setState(() => _level = _Level.subscription), child: const Text('换订阅'))
                : null,
          ),
        ];
        rows = [
          for (var i = 0; i < levels.repos.length; i++)
            row(
              key: Key('sheet-repo-$i'),
              text: repoLabel(levels.repos[i]),
              depth: levels.repos[i].depth,
              current: levels.repos[i].url == state.summary?.url,
              onTap: () => levels.repos[i].url == state.summary?.url ? setState(() => _level = _Level.site) : _load(() => state.switchRepo(levels.repos[i].url)),
            ),
        ];
      case _Level.subscription:
        head = [title('选择订阅', back: true)];
        rows = [
          for (final sub in state.subscriptions)
            row(
              key: Key('sheet-sub-${sub.id}'),
              text: sub.label,
              current: sub.id == state.summary?.subscriptionId,
              onTap: () => sub.id == state.summary?.subscriptionId ? setState(() => _level = _Level.site) : _load(() => state.useSubscription(sub.id)),
            ),
        ];
    }

    return PopScope(
      canPop: _level == _Level.site,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...head,
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_error != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
              child: Text('没能切换：$_error', key: const Key('sheet-error'), style: TextStyle(color: scheme.error)),
            ),
            if (state.actionDiagnostic case final issue?) SourceReportButton(issues: [issue]),
          ],
          Expanded(child: ListView(children: rows)),
        ],
      ),
    );
  }
}
