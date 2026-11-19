import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../engine/drives.dart';
import '../engine/library_models.dart';
import '../engine/models.dart' show EngineException;
import '../ui/common.dart';
import 'browse_page.dart' show errorText;
import 'drive_form.dart';
import 'player_page.dart';

/// 网盘: the user's AList / OpenList, WebDAV and local folders, kept in the engine. A drive opens as a folder browser.
class DrivesPage extends StatefulWidget {
  const DrivesPage({super.key, required this.visible});

  /// Reloads whenever the page becomes visible again (drives may have been added from another device).
  final bool visible;

  @override
  State<DrivesPage> createState() => _DrivesPageState();
}

class _DrivesPageState extends State<DrivesPage> {
  Future<List<DriveInfo>>? _drives;

  @override
  void initState() {
    super.initState();
    if (widget.visible) _reload();
  }

  @override
  void didUpdateWidget(covariant DrivesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible && !oldWidget.visible) _reload();
  }

  void _reload() {
    final state = AppScope.read(context);
    if (!state.connected) return;
    // The FutureBuilder shows a failure; it must not also count as an unhandled error while nothing listens yet.
    final drives = state.client.drives()..ignore();
    setState(() {
      _drives = drives;
    });
  }

  Future<void> _edit([DriveInfo? drive]) async {
    final saved = await showDriveForm(context, drive: drive);
    if (saved != null && mounted) _reload();
  }

  Future<void> _remove(DriveInfo drive) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除「${drive.name}」？'),
        content: const Text('只是从映舟里移除这个网盘，网盘里的文件不受影响。它的观看记录保留在「我的」里。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(key: const Key('drive-remove-confirm'), onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await AppScope.read(context).client.removeDrive(drive.id);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('删除失败：${errorText(e)}')));
    }
    _reload();
  }

  void _open(DriveInfo drive) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DriveFolderPage(drive: drive)));
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 4),
              child: Row(
                children: [
                  Text('网盘', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  IconButton(tooltip: '刷新', onPressed: _reload, icon: const Icon(Icons.refresh)),
                  const SizedBox(width: 4),
                  FilledButton.tonalIcon(
                    key: const Key('drive-add'),
                    onPressed: state.connected ? () => _edit() : null,
                    icon: const Icon(Icons.add),
                    label: const Text('添加'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: !state.connected
                  ? const StatusView(icon: Icons.link_off, message: '还没有连接引擎')
                  : FutureBuilder<List<DriveInfo>>(
                      future: _drives,
                      builder: (context, snap) {
                        if (_drives == null || snap.connectionState != ConnectionState.done) return const LoadingView();
                        if (snap.hasError) {
                          return StatusView(icon: Icons.cloud_off, message: '加载失败\n${errorText(snap.error)}', actionLabel: '重试', onAction: _reload);
                        }
                        final drives = snap.data!;
                        if (drives.isEmpty) {
                          return StatusView(
                            icon: Icons.cloud_outlined,
                            message: '还没有网盘\n可以添加 AList / OpenList、WebDAV，或者引擎所在电脑上的文件夹，\n直接播放里面的视频。阿里云盘、夸克、115 等请经 AList / OpenList 挂载。',
                            actionLabel: '添加网盘',
                            onAction: () => _edit(),
                          );
                        }
                        return ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                          itemCount: drives.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, i) => _DriveCard(
                            drive: drives[i],
                            onOpen: () => _open(drives[i]),
                            onEdit: () => _edit(drives[i]),
                            onRemove: () => _remove(drives[i]),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

IconData driveIcon(DriveKind kind) => switch (kind) {
  DriveKind.alist => Icons.cloud_outlined,
  DriveKind.webdav => Icons.dns_outlined,
  DriveKind.local => Icons.folder_outlined,
};

class _DriveCard extends StatelessWidget {
  const _DriveCard({required this.drive, required this.onOpen, required this.onEdit, required this.onRemove});

  final DriveInfo drive;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final details = [
      drive.kind.label,
      drive.url,
      if (drive.root != '/') '从 ${drive.root} 开始',
      if (drive.username.isNotEmpty) '账号 ${drive.username}',
      if (drive.proxy) '经引擎转发',
    ];
    return Card(
      key: Key('drive-${drive.id}'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onOpen,
        contentPadding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
        leading: CircleAvatar(backgroundColor: scheme.secondaryContainer, child: Icon(driveIcon(drive.kind), color: scheme.onSecondaryContainer)),
        title: Text(drive.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(details.join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: PopupMenuButton<String>(
          tooltip: '更多',
          onSelected: (v) => v == 'edit' ? onEdit() : onRemove(),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('编辑')),
            PopupMenuItem(value: 'remove', child: Text('删除')),
          ],
        ),
      ),
    );
  }
}

/// How a folder's entries are ordered; folders always come first.
enum DriveSort {
  name('名称'),
  date('修改时间'),
  size('大小');

  const DriveSort(this.label);

  final String label;
}

/// The entries of a folder sorted by [sort]; ties (and [DriveSort.name]) by name with numbers in order.
List<DriveEntry> sortDriveEntries(List<DriveEntry> entries, DriveSort sort, {bool descending = false}) {
  int byName(DriveEntry a, DriveEntry b) => naturalCompare(a.name, b.name);
  final out = [...entries];
  out.sort((a, b) {
    if (a.dir != b.dir) return a.dir ? -1 : 1;
    final c = switch (sort) {
      DriveSort.name => byName(a, b),
      DriveSort.date => a.modified.compareTo(b.modified),
      DriveSort.size => a.size.compareTo(b.size),
    };
    final r = c != 0 ? c : byName(a, b);
    return descending ? -r : r;
  });
  return out;
}

String _two(int n) => n.toString().padLeft(2, '0');

String _dateLabel(int ms) {
  if (ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';
}

String positionLabel(int ms) {
  final s = ms ~/ 1000;
  final h = s ~/ 3600;
  return h > 0 ? '$h:${_two(s ~/ 60 % 60)}:${_two(s % 60)}' : '${_two(s ~/ 60)}:${_two(s % 60)}';
}

/// One drive's folders: breadcrumbs, sorting, AList folder passwords, and video files that open the player. A folder
/// plays as a playlist (next / previous walk through its videos) and has a history entry of its own, so playback
/// resumes like a site's title does.
class DriveFolderPage extends StatefulWidget {
  const DriveFolderPage({super.key, required this.drive, this.path = '/'});

  final DriveInfo drive;
  final String path;

  @override
  State<DriveFolderPage> createState() => _DriveFolderPageState();
}

class _DriveFolderPageState extends State<DriveFolderPage> {
  late String _path = widget.path;
  Future<DriveListing>? _listing;
  HistoryEntry? _history;
  final _password = TextEditingController();
  String? _passwordError;
  bool _unlocking = false;
  bool _opening = false;

  static const _sortKey = 'drives.sort';
  late DriveSort _sort;
  late bool _descending;

  @override
  void initState() {
    super.initState();
    final saved = (AppScope.read(context).settings.getString(_sortKey) ?? '').split(':');
    _sort = DriveSort.values.firstWhere((s) => s.name == saved.first, orElse: () => DriveSort.name);
    _descending = saved.length > 1 && saved[1] == 'desc';
    _load();
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  void _load() {
    final client = AppScope.read(context).client;
    final path = _path;
    // A folder that wants a password fails on purpose; the FutureBuilder shows it (see DrivesPage._reload).
    final listing = client.driveFolder(widget.drive.id, path)..ignore();
    setState(() {
      _passwordError = null;
      _listing = listing;
    });
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final path = _path;
    try {
      final h = await AppScope.read(context).client.historyFor(widget.drive.site, path);
      if (mounted && path == _path) setState(() => _history = h);
    } catch (_) {
      if (mounted) setState(() => _history = null);
    }
  }

  void _go(String path) {
    if (path == _path) return;
    _password.clear();
    setState(() {
      _path = path;
      _history = null;
    });
    _load();
  }

  String get _parent {
    final i = _path.lastIndexOf('/');
    return i <= 0 ? '/' : _path.substring(0, i);
  }

  void _setSort(DriveSort sort, bool descending) {
    setState(() {
      _sort = sort;
      _descending = descending;
    });
    AppScope.read(context).settings.setString(_sortKey, '${sort.name}:${descending ? 'desc' : 'asc'}');
  }

  Future<void> _unlock() async {
    if (_password.text.isEmpty) return;
    setState(() {
      _unlocking = true;
      _passwordError = null;
    });
    try {
      final listing = await AppScope.read(context).client.unlockDriveFolder(widget.drive.id, _path, _password.text);
      if (!mounted) return;
      _password.clear();
      setState(() {
        _listing = Future.value(listing);
      });
    } catch (e) {
      if (mounted) setState(() => _passwordError = errorText(e));
    } finally {
      if (mounted) setState(() => _unlocking = false);
    }
  }

  /// Plays [file] of this folder, the folder's other videos queued after it. Carries on from the history when the
  /// file is the one last watched here.
  Future<void> _play(String file) async {
    if (_opening) return;
    setState(() => _opening = true);
    final client = AppScope.read(context).client;
    try {
      final detail = await client.driveDetail(widget.drive.id, _path);
      if (!mounted) return;
      final episodes = detail.lines.isEmpty ? const [] : detail.lines.first.episodes;
      final index = episodes.indexWhere((e) => e.id == file);
      if (index < 0) throw const EngineException('NOT_FOUND', '文件不在这个文件夹里了，请刷新');
      final h = _history;
      Duration? start;
      if (h != null && h.episodeId == file && h.positionMs > 0 && (h.durationMs <= 0 || h.positionMs < h.durationMs - 10000)) {
        start = Duration(milliseconds: h.positionMs);
      }
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlayerPage(detail: detail, line: 0, episode: index, startPosition: start)));
      if (mounted) _loadHistory();
      // The player saves where it got to as it closes; that may land a moment after this page is back.
      Future<void>.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) _loadHistory();
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('打不开：${errorText(e)}')));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Back goes up a folder first, then leaves the drive.
      canPop: _path == '/',
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _go(_parent);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.drive.name),
          actions: [
            PopupMenuButton<(DriveSort, bool)>(
              key: const Key('drive-sort'),
              tooltip: '排序',
              icon: const Icon(Icons.sort),
              onSelected: (v) => _setSort(v.$1, v.$2),
              itemBuilder: (_) => [
                for (final s in DriveSort.values)
                  CheckedPopupMenuItem(value: (s, s == _sort ? !_descending : _descending), checked: s == _sort, child: Text('按${s.label}${s == _sort ? (_descending ? ' ↓' : ' ↑') : ''}')),
              ],
            ),
            IconButton(tooltip: '刷新', onPressed: _load, icon: const Icon(Icons.refresh)),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _breadcrumbs(context),
            if (_history != null) _resumeBanner(context, _history!),
            Expanded(child: _body(context)),
          ],
        ),
      ),
    );
  }

  Widget _breadcrumbs(BuildContext context) {
    final segments = _path.split('/').where((s) => s.isNotEmpty).toList();
    final scheme = Theme.of(context).colorScheme;
    final crumbs = <Widget>[];
    for (var i = -1; i < segments.length; i++) {
      final path = i < 0 ? '/' : '/${segments.sublist(0, i + 1).join('/')}';
      final last = i == segments.length - 1;
      if (i >= 0) crumbs.add(Icon(Icons.chevron_right, size: 18, color: scheme.onSurfaceVariant));
      crumbs.add(
        TextButton(
          key: Key('crumb-$path'),
          onPressed: last ? null : () => _go(path),
          style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: const Size(0, 36)),
          child: Text(i < 0 ? widget.drive.name : segments[i]),
        ),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Row(children: crumbs),
    );
  }

  Widget _resumeBanner(BuildContext context, HistoryEntry h) {
    final scheme = Theme.of(context).colorScheme;
    final name = h.episodeName.isNotEmpty ? h.episodeName : h.episodeId.split('/').last;
    final at = h.positionMs > 0 ? ' ${positionLabel(h.positionMs)}' : '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Material(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
        child: ListTile(
          key: const Key('drive-resume'),
          dense: true,
          leading: Icon(Icons.history, color: scheme.onSecondaryContainer),
          title: Text('上次看到：$name$at', style: TextStyle(color: scheme.onSecondaryContainer)),
          trailing: FilledButton(onPressed: _opening ? null : () => _play(h.episodeId), child: const Text('继续播放')),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    return FutureBuilder<DriveListing>(
      future: _listing,
      builder: (context, snap) {
        if (_listing == null || snap.connectionState != ConnectionState.done) return const LoadingView();
        final error = snap.error;
        if (error is EngineException && error.code == 'DRIVE_PASSWORD') return _passwordPrompt(context);
        if (error != null) {
          return StatusView(icon: Icons.cloud_off, message: '打不开这个文件夹\n${errorText(error)}', actionLabel: '重试', onAction: _load);
        }
        final listing = snap.data!;
        if (listing.entries.isEmpty) return const StatusView(icon: Icons.folder_open, message: '文件夹是空的');
        final entries = sortDriveEntries(listing.entries, _sort, descending: _descending);
        final subtitled = <String>{
          for (final e in listing.entries)
            if (e.isSubtitle) e.name.split('.').first.toLowerCase(),
        };
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 24),
          itemCount: entries.length,
          itemBuilder: (context, i) => _entry(context, entries[i], subtitled),
        );
      },
    );
  }

  Widget _entry(BuildContext context, DriveEntry e, Set<String> subtitled) {
    final scheme = Theme.of(context).colorScheme;
    final base = e.name.contains('.') ? e.name.substring(0, e.name.lastIndexOf('.')) : e.name;
    final hasSubtitle = e.isVideo && subtitled.contains(base.split('.').first.toLowerCase());
    final watched = _history != null && _history!.episodeId == e.path;
    final info = [
      if (!e.dir) sizeLabel(e.size),
      _dateLabel(e.modified),
      if (hasSubtitle) '有字幕',
      if (watched && _history!.positionMs > 0) '看到 ${positionLabel(_history!.positionMs)}',
    ].where((s) => s.isNotEmpty).join(' · ');
    final icon = e.dir
        ? Icons.folder_rounded
        : e.isVideo
        ? Icons.movie_outlined
        : e.isSubtitle
        ? Icons.subtitles_outlined
        : Icons.insert_drive_file_outlined;
    final enabled = e.dir || e.isVideo;
    return ListTile(
      key: Key('entry-${e.path}'),
      enabled: enabled,
      leading: Icon(icon, color: e.dir ? scheme.primary : (e.isVideo ? scheme.tertiary : null)),
      title: Text(e.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: watched ? TextStyle(color: scheme.primary, fontWeight: FontWeight.w600) : null),
      subtitle: info.isEmpty ? null : Text(info),
      trailing: e.dir ? const Icon(Icons.chevron_right) : (e.isVideo ? const Icon(Icons.play_circle_outline) : null),
      onTap: !enabled ? null : () => e.dir ? _go(e.path) : _play(e.path),
    );
  }

  Widget _passwordPrompt(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 40, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              const Text('这个文件夹设了密码', textAlign: TextAlign.center),
              const SizedBox(height: 4),
              Text('密码对了之后由引擎记住，下次不用再输。', textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
              const SizedBox(height: 16),
              TextField(
                key: const Key('drive-folder-password'),
                controller: _password,
                obscureText: true,
                autofocus: true,
                decoration: InputDecoration(labelText: '文件夹密码', border: const OutlineInputBorder(), errorText: _passwordError),
                onSubmitted: (_) => _unlock(),
              ),
              const SizedBox(height: 12),
              FilledButton(key: const Key('drive-folder-unlock'), onPressed: _unlocking ? null : _unlock, child: Text(_unlocking ? '正在验证…' : '打开')),
            ],
          ),
        ),
      ),
    );
  }
}
