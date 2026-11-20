import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../engine/danmaku_models.dart';
import 'danmaku_layer.dart';

/// The 弹幕 side panel of the player: the switch, where this episode's danmaku came from, a file from disk, and how
/// they look (opacity, size, speed, area, what to block). Everything is remembered on this device.
class DanmakuPanel extends StatefulWidget {
  const DanmakuPanel({
    super.key,
    required this.prefs,
    required this.list,
    required this.loading,
    required this.error,
    required this.onReload,
    required this.onLoadFile,
  });

  final DanmakuPrefs prefs;
  final DanmakuList list;
  final bool loading;
  final String? error;
  final VoidCallback onReload;
  final VoidCallback onLoadFile;

  @override
  State<DanmakuPanel> createState() => _DanmakuPanelState();
}

class _DanmakuPanelState extends State<DanmakuPanel> {
  late final _keywords = TextEditingController(text: widget.prefs.keywords);
  Timer? _typing;

  @override
  void dispose() {
    _typing?.cancel();
    if (_keywords.text != widget.prefs.keywords) widget.prefs.update(keywords: _keywords.text);
    _keywords.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 13);
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 6),
      child: Text(text, style: TextStyle(color: scheme.onSurfaceVariant)),
    );
    return ListenableBuilder(
      listenable: widget.prefs,
      builder: (context, _) {
        final prefs = widget.prefs;
        final list = widget.list;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SwitchListTile(
              key: const Key('danmaku-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('显示弹幕 (D)'),
              value: prefs.enabled,
              onChanged: (on) => prefs.update(enabled: on),
            ),
            if (widget.loading)
              Text('正在加载弹幕…', style: muted)
            else if (widget.error != null)
              Row(
                children: [
                  Expanded(child: Text(widget.error!, style: TextStyle(color: scheme.error, fontSize: 13))),
                  TextButton(onPressed: widget.onReload, child: const Text('重试')),
                ],
              )
            else if (list.items.isNotEmpty)
              Text('共 ${list.items.length} 条 · 来自${list.sourceLabel}', key: const Key('danmaku-count'), style: muted)
            else if (prefs.enabled)
              Text('这一集没有弹幕。站点没有给弹幕时，可以在「设置 → 弹幕」打开订阅的弹幕接口或填写自己的弹幕接口，也可以加载本地弹幕文件。', style: muted),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(onPressed: widget.onLoadFile, icon: const Icon(Icons.file_open_outlined), label: const Text('加载弹幕文件…')),
            ),
            heading('不透明度 ${(prefs.opacity * 100).round()}%'),
            Slider(value: prefs.opacity, min: 0.1, max: 1, divisions: 18, onChanged: (v) => prefs.update(opacity: v)),
            heading('字号 ${(prefs.fontScale * 100).round()}%'),
            Slider(value: prefs.fontScale, min: 0.5, max: 2, divisions: 15, onChanged: (v) => prefs.update(fontScale: v)),
            heading('速度'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final e in DanmakuPrefs.speeds.entries)
                  ChoiceChip(label: Text(e.value), selected: prefs.speed == e.key, onSelected: (_) => prefs.update(speed: e.key)),
              ],
            ),
            heading('显示区域'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final e in DanmakuPrefs.areas.entries)
                  ChoiceChip(label: Text(e.value), selected: prefs.area == e.key, onSelected: (_) => prefs.update(area: e.key)),
              ],
            ),
            heading('屏蔽'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilterChip(label: const Text('顶部'), selected: prefs.blockTop, onSelected: (v) => prefs.update(blockTop: v)),
                FilterChip(label: const Text('底部'), selected: prefs.blockBottom, onSelected: (v) => prefs.update(blockBottom: v)),
                FilterChip(label: const Text('滚动'), selected: prefs.blockScroll, onSelected: (v) => prefs.update(blockScroll: v)),
              ],
            ),
            heading('屏蔽词'),
            TextField(
              key: const Key('danmaku-keywords'),
              controller: _keywords,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(border: OutlineInputBorder(), hintText: '每行一个，或用逗号隔开；/正则/ 也行', isDense: true),
              onChanged: (text) {
                _typing?.cancel();
                _typing = Timer(const Duration(milliseconds: 400), () => prefs.update(keywords: text));
              },
            ),
          ],
        );
      },
    );
  }
}
