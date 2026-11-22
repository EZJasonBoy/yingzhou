import 'package:material_ui/material_ui.dart';

import '../engine/episode_names.dart';
import 'device_form.dart';

/// The episodes of a line, laid out by how they are named ([EpisodeNaming]): short names in a grid of small buttons,
/// long ones in rows with the number in front and room for two lines of title, as many columns of rows as fit.
///
/// The page brings its own button ([button]): this widget only decides the size and what is written on it.
class EpisodeButtons extends StatelessWidget {
  const EpisodeButtons({
    super.key,
    required this.naming,
    required this.button,
    this.buttonWidth = 112,
    this.rowMinWidth = 260,
    this.maxColumns = 4,
    this.spacing = 8,
    this.mark,
    this.reserveMark = false,
  });

  final EpisodeNaming naming;

  /// The page's button for episode [i] around [label]. [row] is true in the rows layout, where the label is laid
  /// out from the left and is two lines tall.
  final Widget Function(BuildContext context, int i, Widget label, bool row) button;

  /// How wide a grid button is.
  final double buttonWidth;

  /// Rows are at least this wide; as many columns of them as fit, up to [maxColumns].
  final double rowMinWidth;
  final int maxColumns;
  final double spacing;

  /// Something to show with episode [i] (how far its download is): under the name in the grid, at the end of a row.
  final Widget? Function(int i)? mark;

  /// In the grid every button keeps room for a mark, so the buttons line up when only some have one.
  final bool reserveMark;

  /// How tall a row is: two lines of title.
  static const rowHeight = 60.0;

  @override
  Widget build(BuildContext context) {
    final labels = naming.labels;
    if (naming.compact) {
      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: [
          for (var i = 0; i < labels.length; i++) SizedBox(width: buttonWidth, child: button(context, i, _withTip(context, labels[i], _gridLabel(labels[i], i)), false)),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = ((width + spacing) / (rowMinWidth + spacing)).floor().clamp(1, maxColumns);
        final rowWidth = (width - spacing * (columns - 1)) / columns - 0.01;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (var i = 0; i < labels.length; i++)
              SizedBox(width: rowWidth, height: rowHeight, child: button(context, i, _withTip(context, labels[i], _RowLabel(label: labels[i], mark: mark?.call(i))), true)),
          ],
        );
      },
    );
  }

  Widget _gridLabel(EpisodeLabel label, int i) {
    final text = Text(label.text, maxLines: 1, overflow: TextOverflow.ellipsis);
    if (!reserveMark) return text;
    return Column(mainAxisSize: MainAxisSize.min, children: [text, const SizedBox(height: 2), SizedBox(height: 16, child: mark?.call(i))]);
  }

  /// With a mouse, the name as the site gave it shows when the pointer rests on a name that was shortened.
  Widget _withTip(BuildContext context, EpisodeLabel label, Widget child) {
    if (!isDesktop(context) || label.full.trim() == label.text) return child;
    return Tooltip(message: label.full, waitDuration: const Duration(milliseconds: 400), child: child);
  }
}

/// A row: the number, the title on up to two lines, and under a number-only name what another line calls it.
class _RowLabel extends StatelessWidget {
  const _RowLabel({required this.label, this.mark});

  final EpisodeLabel label;
  final Widget? mark;

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    final quiet = style.copyWith(color: style.color?.withValues(alpha: 0.62), fontFeatures: const [FontFeature.tabularFigures()]);
    final also = label.also;
    // A line that only numbers its episodes: the number stands alone in front, the borrowed title is the text.
    final title = also ?? label.text;
    return Row(
      children: [
        SizedBox(width: 34, child: Text('${label.number}', maxLines: 1, style: quiet)),
        Expanded(
          child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.start, style: style.copyWith(height: 1.3)),
        ),
        if (mark != null) ...[const SizedBox(width: 8), mark!],
      ],
    );
  }
}
