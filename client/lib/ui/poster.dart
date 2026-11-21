import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../engine/vod_models.dart';
import 'common.dart';
import 'device_form.dart';
import 'tv/tv_focus.dart';

/// Grid delegate shared by every poster wall: ~160px wide cards, poster ratio 0.7 plus a two-line title; three to a
/// row on a phone held upright ([PosterGridDelegate]).
const posterGridDelegate = PosterGridDelegate();

/// The poster wall's columns, by the width it has: below [narrow] (a phone held upright) three columns of smaller
/// posters filling the width, as phone video apps do; from there on cards of about 160 dp.
class PosterGridDelegate extends SliverGridDelegate {
  const PosterGridDelegate();

  static const narrow = 560.0;

  static const _wide = SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: 168,
    mainAxisSpacing: 18,
    crossAxisSpacing: 14,
    childAspectRatio: 0.56,
  );

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final width = constraints.crossAxisExtent;
    if (width >= narrow) return _wide.getLayout(constraints);
    const spacing = 10.0;
    final columns = width < 300 ? 2 : 3;
    final itemWidth = (width - spacing * (columns - 1)) / columns;
    // The poster, the gap under it and two lines of title (with room for a larger system font).
    final itemHeight = itemWidth / 0.7 + 8 + 46;
    return SliverGridRegularTileLayout(
      crossAxisCount: columns,
      mainAxisStride: itemHeight + 12,
      crossAxisStride: itemWidth + spacing,
      childMainAxisExtent: itemHeight,
      childCrossAxisExtent: itemWidth,
      reverseCrossAxis: axisDirectionIsReversed(constraints.crossAxisDirection),
    );
  }

  @override
  bool shouldRelayout(PosterGridDelegate oldDelegate) => false;
}

class PosterCard extends StatefulWidget {
  const PosterCard({
    super.key,
    required this.vod,
    required this.onTap,
    this.caption,
    this.onLongPress,
    this.focusNode,
    this.autofocus = false,
    this.progress,
  });

  final VodCard vod;
  final VoidCallback onTap;

  /// Holding OK on the remote, or the menu key (e.g. remove from the history).
  final VoidCallback? onLongPress;
  final FocusNode? focusNode;
  final bool autofocus;

  /// How far it was watched (0–1), as a line along the bottom of the poster.
  final double? progress;

  /// Extra line under the title, e.g. the site name in search results.
  final String? caption;

  @override
  State<PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<PosterCard> {
  bool _hover = false;

  /// Has the focus (remote or keyboard); on a TV it grows more and gets the brand outline.
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final vod = widget.vod;
    final tv = isTv(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: TvFocusable(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onMenu: widget.onLongPress,
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        outline: false,
        scale: 1,
        onFocusChange: (f) => setState(() => _focus = f),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 0.7,
              child: AnimatedScale(
                scale: _focus && tv ? 1.1 : (_hover || _focus ? 1.04 : 1),
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: _focus && tv ? Border.all(color: TvColors.coral, width: 3, strokeAlign: BorderSide.strokeAlignOutside) : null,
                    boxShadow: _focus && tv
                        ? [BoxShadow(color: TvColors.yellow.withValues(alpha: 0.4), blurRadius: 18, spreadRadius: 2)]
                        : _hover || _focus
                        ? [BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 18, offset: const Offset(0, 8))]
                        : const [],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        NetImage(vod.pic),
                        if (vod.isFolder)
                          Positioned(
                            key: const Key('poster-folder'),
                            left: 6,
                            top: 6,
                            child: DecoratedBox(
                              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(6)),
                              child: const Padding(
                                padding: EdgeInsets.all(4),
                                child: Icon(Icons.folder_rounded, size: 16, color: Colors.white),
                              ),
                            ),
                          ),
                        if (vod.remarks.isNotEmpty)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [Colors.transparent, Colors.black.withValues(alpha: 0.75)],
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(8, 18, 8, 6),
                                child: Text(
                                  vod.remarks,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white, fontSize: 12),
                                ),
                              ),
                            ),
                          ),
                        if (widget.progress != null)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: LinearProgressIndicator(value: widget.progress, minHeight: 3, backgroundColor: Colors.white24, color: scheme.primary),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              vod.name,
              maxLines: widget.caption == null ? 2 : 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: _hover || _focus ? scheme.primary : scheme.onSurface,
                fontWeight: FontWeight.w500,
                height: 1.3,
              ),
            ),
            if (widget.caption != null)
              Text(
                widget.caption!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}
