import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../engine/models.dart';
import '../ui/device_form.dart';
import '../ui/phone_input.dart';
import '../ui/tv/tv_focus.dart';

/// 源 → 订阅 → 已保存的订阅: every subscription the engine has kept, the one used last first. Choosing one switches
/// to it, so going back to an earlier subscription needs no typing (on a TV, no remote-control keyboard). Rename,
/// copy the address or remove it from the menu: the ⋮ button, or on a TV holding OK / the menu key.
class SavedSubscriptions extends StatelessWidget {
  const SavedSubscriptions({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final subs = state.subscriptions;
    if (subs.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final tv = isTv(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 14),
        Text(
          tv ? '已保存的订阅（按确定切换，长按确定或按菜单键改名、删除）' : '已保存的订阅',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        ),
        const SizedBox(height: 6),
        // Keyed, so a row keeps its element (and the remote's focus) when switching moves it to the top.
        for (final sub in subs) _Row(key: ValueKey(sub.id), state: state, sub: sub, active: sub.id == state.summary?.subscriptionId),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({super.key, required this.state, required this.sub, required this.active});

  final AppState state;
  final Subscription sub;
  final bool active;

  void _use() {
    if (!active && !state.busy) state.useSubscription(sub.id);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tv = isTv(context);
    final leading = Icon(active ? Icons.check_circle_rounded : Icons.history_rounded, color: active ? scheme.primary : scheme.onSurfaceVariant);
    final title = Text(sub.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: active ? FontWeight.w600 : null));
    final subtitle = Text(
      active ? '正在使用 · ${sub.url}' : sub.url,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
    );
    if (tv) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: TvFocusable(
          key: Key('saved-sub-${sub.id}'),
          onTap: _use,
          onLongPress: () => _actions(context),
          onMenu: () => _actions(context),
          scale: 1.02,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: active ? scheme.primaryContainer.withValues(alpha: 0.45) : scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                leading,
                const SizedBox(width: 14),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [title, subtitle])),
              ],
            ),
          ),
        ),
      );
    }
    return ListTile(
      key: Key('saved-sub-${sub.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      dense: true,
      selected: active,
      leading: leading,
      title: title,
      subtitle: subtitle,
      onTap: active || state.busy ? null : _use,
      onLongPress: () => _actions(context),
      trailing: PopupMenuButton<_Action>(
        key: Key('saved-sub-menu-${sub.id}'),
        tooltip: '更多',
        onSelected: (a) => _run(context, a),
        itemBuilder: (_) => [
          const PopupMenuItem(value: _Action.rename, child: Text('重命名')),
          const PopupMenuItem(value: _Action.copy, child: Text('复制地址')),
          const PopupMenuItem(value: _Action.remove, child: Text('删除')),
        ],
      ),
    );
  }

  /// The menu as a dialog (TV: hold OK or the menu key; touch: long press).
  Future<void> _actions(BuildContext context) async {
    final tv = isTv(context);
    final action = await showDialog<_Action>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(sub.label, maxLines: 2, overflow: TextOverflow.ellipsis),
        children: [
          if (!active) SimpleDialogOption(onPressed: () => Navigator.pop(context, _Action.use), child: const Text('切换到这个订阅')),
          SimpleDialogOption(key: const Key('saved-sub-rename'), onPressed: () => Navigator.pop(context, _Action.rename), child: const Text('重命名')),
          if (!tv) SimpleDialogOption(onPressed: () => Navigator.pop(context, _Action.copy), child: const Text('复制地址')),
          SimpleDialogOption(key: const Key('saved-sub-remove'), onPressed: () => Navigator.pop(context, _Action.remove), child: const Text('删除')),
          SimpleDialogOption(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        ],
      ),
    );
    if (action != null && context.mounted) await _run(context, action);
  }

  Future<void> _run(BuildContext context, _Action action) async {
    switch (action) {
      case _Action.use:
        _use();
      case _Action.copy:
        await Clipboard.setData(ClipboardData(text: sub.url));
        if (context.mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('已复制订阅地址')));
      case _Action.rename:
        final name = await showDialog<String>(context: context, builder: (_) => _RenameDialog(sub: sub));
        if (name != null) await state.renameSubscription(sub.id, name);
      case _Action.remove:
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('删除「${sub.label}」？'),
            content: Text(
              active ? '这是正在用的订阅，删除后首页会变空，要再选一个订阅。订阅本身不受影响，以后可以再导入。' : '只是从这个列表里去掉，订阅本身不受影响，以后可以再导入。',
            ),
            actions: [
              TextButton(autofocus: true, onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
              FilledButton(key: const Key('saved-sub-remove-confirm'), onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
            ],
          ),
        );
        if (ok == true) await state.removeSubscription(sub.id);
    }
  }
}

enum _Action { use, rename, copy, remove }

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.sub});

  final Subscription sub;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _field = TextEditingController(text: widget.sub.named ? widget.sub.name : '');

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名订阅'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('saved-sub-name'),
              controller: _field,
              autofocus: !isTv(context),
              decoration: InputDecoration(labelText: '名称', hintText: widget.sub.label, helperText: '留空就显示订阅地址'),
              onSubmitted: (v) => Navigator.pop(context, v),
            ),
            if (phoneInputAvailable(context)) ...[
              const SizedBox(height: 12),
              PhoneInputButton(
                request: const PhoneInputRequest(title: '订阅名称', hint: '如：家里的'),
                onReceived: (t) => _field.text = t,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(key: const Key('saved-sub-name-save'), onPressed: () => Navigator.pop(context, _field.text), child: const Text('保存')),
      ],
    );
  }
}
