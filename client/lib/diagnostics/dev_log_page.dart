import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../ui/tv/tv_focus.dart';
import 'dev_log.dart';
import 'diagnostics.dart';
import 'redact.dart';

/// 日志 (developer mode): what this client did to get a video on the screen ([DevLog]), newest first, by level and by
/// what it says; a line shows what belongs to it (the address, the answer) when chosen. On a desktop, the last lines
/// the bundled engine printed are a second list. What is copied goes through the diagnostics' redaction first, so it
/// can be pasted into an issue.
class DevLogPage extends StatefulWidget {
  const DevLogPage({super.key, this.standalone = false, this.log});

  /// Opened as a page of its own, with a bar to go back.
  final bool standalone;

  /// The log to show; the app's own when null.
  final DevLog? log;

  @override
  State<DevLogPage> createState() => _DevLogPageState();
}

class _DevLogPageState extends State<DevLogPage> {
  DevLevel? _level;
  String _query = '';
  DevLogEntry? _selected;
  bool _engine = false;

  DevLog get _log => widget.log ?? DevLog.instance;

  Color _color(DevLevel level, ColorScheme scheme) => switch (level) {
    DevLevel.info => scheme.onSurfaceVariant,
    DevLevel.warn => const Color(0xFFF0C670),
    DevLevel.error => scheme.error,
  };

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: Diagnostics.instance.redactForSharing(text)));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已复制$what（订阅地址和密钥已去掉）'), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final engineOutput = AppScope.of(context).engineOutput;
    return Scaffold(
      appBar: widget.standalone ? AppBar(title: const Text('日志')) : null,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _log,
          builder: (context, _) {
            final all = _log.entries.reversed.toList();
            final q = _query.trim().toLowerCase();
            final shown = [
              for (final e in all)
                if ((_level == null || e.level == _level) && (q.isEmpty || e.line.toLowerCase().contains(q))) e,
            ];
            int count(DevLevel? l) => l == null ? all.length : all.where((e) => e.level == l).length;
            final selected = _selected != null && shown.contains(_selected) ? _selected : null;
            Widget chip(String label, DevLevel? level) => Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    key: Key('log-level-${level?.name ?? 'all'}'),
                    label: Text('$label ${count(level)}'),
                    selected: !_engine && _level == level,
                    showCheckmark: false,
                    onSelected: (_) => setState(() {
                      _engine = false;
                      _level = level;
                    }),
                  ),
                );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(20, widget.standalone ? 4 : 14, 12, 4),
                  child: Row(
                    children: [
                      if (!widget.standalone) ...[
                        Text('日志', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(width: 12),
                      ],
                      Expanded(
                        child: Text('这台设备上的播放过程，最新的在上面，最多留 ${DevLog.capacity} 条', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
                      ),
                      TextButton.icon(
                        key: const Key('log-copy'),
                        onPressed: shown.isEmpty && !_engine ? null : () => _copy(_engine ? Redactor(homes: Diagnostics.instance.homes).sharedLog(engineOutput.join('\n')) : shown.reversed.map((e) => e.shareLine).join('\n'), '日志'),
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        label: const Text('复制'),
                      ),
                      TextButton.icon(
                        key: const Key('log-clear'),
                        onPressed: all.isEmpty ? null : () => setState(_log.clear),
                        icon: const Icon(Icons.delete_outline_rounded, size: 18),
                        label: const Text('清空'),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    runSpacing: 8,
                    children: [
                      chip('全部', null),
                      chip('信息', DevLevel.info),
                      chip('警告', DevLevel.warn),
                      chip('错误', DevLevel.error),
                      if (engineOutput.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            key: const Key('log-engine'),
                            label: const Text('内置引擎的输出'),
                            selected: _engine,
                            showCheckmark: false,
                            onSelected: (_) => setState(() => _engine = true),
                          ),
                        ),
                      if (!_engine)
                        SizedBox(
                          width: 260,
                          child: TextField(
                            key: const Key('log-search'),
                            decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search, size: 20), hintText: '搜网址、模块或报错'),
                            onChanged: (v) => setState(() => _query = v),
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: _engine
                      ? _EngineOutput(lines: engineOutput)
                      : shown.isEmpty
                      ? Center(
                          child: Text(
                            all.isEmpty ? '还没有记录。放一部片子，这里就有它是怎么找到地址、怎么换线路的。' : '没有符合的记录',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        )
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            final wide = constraints.maxWidth >= 900;
                            final list = ListView.builder(
                              key: const Key('log-list'),
                              padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                              itemCount: shown.length,
                              itemBuilder: (context, i) {
                                final e = shown[i];
                                return _LogRow(
                                  entry: e,
                                  color: _color(e.level, scheme),
                                  selected: e == selected,
                                  onTap: () {
                                    setState(() => _selected = e);
                                    if (!wide) {
                                      showModalBottomSheet<void>(
                                        context: context,
                                        showDragHandle: true,
                                        builder: (context) => SingleChildScrollView(child: _LogDetail(entry: e, color: _color(e.level, scheme), onCopy: () => _copy(e.shareLine, '这一条'))),
                                      );
                                    }
                                  },
                                );
                              },
                            );
                            if (!wide) return list;
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: list),
                                SizedBox(
                                  width: 380,
                                  child: selected == null
                                      ? Padding(
                                          padding: const EdgeInsets.all(24),
                                          child: Text('选一条，看它的网址和回应', style: TextStyle(color: scheme.onSurfaceVariant)),
                                        )
                                      : SingleChildScrollView(
                                          padding: const EdgeInsets.only(right: 20, bottom: 24),
                                          child: Card(child: _LogDetail(entry: selected, color: _color(selected.level, scheme), onCopy: () => _copy(selected.shareLine, '这一条'))),
                                        ),
                                ),
                              ],
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

const _mono = ['Cascadia Mono', 'Consolas', 'Menlo', 'monospace'];

class _LogRow extends StatelessWidget {
  const _LogRow({required this.entry, required this.color, required this.selected, required this.onTap});

  final DevLogEntry entry;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final strong = entry.level != DevLevel.info;
    return TvFocusable(
      onTap: onTap,
      scale: 1,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? scheme.surfaceContainerHigh : null,
          borderRadius: BorderRadius.circular(8),
          border: Border(left: BorderSide(color: selected ? color : Colors.transparent, width: 3)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 96,
              child: Text(entry.clock, style: TextStyle(fontFamilyFallback: _mono, fontSize: 12, height: 1.6, color: scheme.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])),
            ),
            SizedBox(width: 40, child: Text(entry.levelLabel, style: TextStyle(fontSize: 12, height: 1.6, color: color, fontWeight: strong ? FontWeight.w700 : null))),
            SizedBox(width: 56, child: Text(entry.module, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, height: 1.6, color: scheme.onSurfaceVariant))),
            Expanded(
              child: Text(entry.message, style: TextStyle(fontSize: 13, height: 1.5, color: strong ? color : scheme.onSurface)),
            ),
          ],
        ),
      ),
    );
  }
}

class _LogDetail extends StatelessWidget {
  const _LogDetail({required this.entry, required this.color, required this.onCopy});

  final DevLogEntry entry;
  final Color color;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      key: const Key('log-detail'),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(6)),
                child: Text(entry.levelLabel, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 8),
              Text('${entry.clock} · ${entry.module}', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 10),
          SelectableText(entry.message, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, height: 1.4)),
          for (final d in entry.detail.entries) ...[
            const SizedBox(height: 10),
            Text(d.key, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 2),
            SelectableText(d.value, style: const TextStyle(fontFamilyFallback: _mono, fontSize: 12, height: 1.5)),
          ],
          const SizedBox(height: 14),
          FilledButton.tonalIcon(key: const Key('log-copy-one'), onPressed: onCopy, icon: const Icon(Icons.copy_rounded, size: 18), label: const Text('复制这一条')),
        ],
      ),
    );
  }
}

class _EngineOutput extends StatelessWidget {
  const _EngineOutput({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView.builder(
      key: const Key('log-engine-output'),
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      itemCount: lines.length,
      itemBuilder: (context, i) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: SelectableText(lines[i], style: TextStyle(fontFamilyFallback: _mono, fontSize: 12, height: 1.5, color: scheme.onSurface)),
      ),
    );
  }
}
