import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../device_form.dart';
import 'tv_focus.dart';

/// A list to pick one entry from with the remote (instead of a drop-down menu, which BACK would not close and the
/// D-pad does not enter): the current entry has the focus, OK picks, BACK cancels.
Future<T?> showTvChoiceDialog<T>(
  BuildContext context, {
  required String title,
  required List<(T, String)> items,
  T? selected,
  String? Function(T value)? subtitle,
  bool Function(T value)? enabled,
  int Function(T value)? indent,
}) {
  return showDialog<T>(
    context: context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      final size = MediaQuery.sizeOf(context);
      final current = items.indexWhere((e) => e.$1 == selected);
      return AlertDialog(
        title: Text(title),
        contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
        content: SizedBox(
          width: 420,
          height: (items.length * 56.0 + 8).clamp(56.0, size.height * 0.6),
          child: ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, i) {
              final (value, label) = items[i];
              final on = enabled?.call(value) ?? true;
              final sub = subtitle?.call(value);
              return Padding(
                // Entries of a list inside a list (a multi-repository subscription) are set in.
                padding: EdgeInsets.only(top: 3, bottom: 3, left: 20.0 * (indent?.call(value) ?? 0)),
                child: TvFocusable(
                  key: Key('tv-choice-$i'),
                  autofocus: i == (current < 0 ? 0 : current),
                  onTap: on ? () => Navigator.of(context).pop(value) : null,
                  scale: 1.03,
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 50),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: i == current ? scheme.primaryContainer : scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(i == current ? Icons.check_rounded : null, size: 20, color: scheme.onPrimaryContainer),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 16, color: on ? null : scheme.onSurfaceVariant.withValues(alpha: 0.6)),
                              ),
                              if (sub != null)
                                Text(
                                  sub,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
    },
  );
}

/// For a [TabBar] on a TV: a tab that keeps the focus for a moment is opened, the way TVBox's category bar follows
/// the focus, so the page under it shows what the tab holds before OK is pressed. Null elsewhere (tabs open on click).
void Function(bool focused, int index)? tvTabFollowsFocus(BuildContext context) {
  if (!isTv(context)) return null;
  return (focused, index) {
    _tabTimer?.cancel();
    if (!focused) return;
    _tabTimer = Timer(const Duration(milliseconds: 350), () {
      if (!context.mounted) return;
      final controller = DefaultTabController.maybeOf(context);
      if (controller != null && controller.index != index) controller.animateTo(index);
    });
  };
}

Timer? _tabTimer;
