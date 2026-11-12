import 'package:material_ui/material_ui.dart';

import '../engine/vod_models.dart';
import 'common.dart';

/// Grid delegate shared by every poster wall: ~160px wide cards, poster ratio 0.7 plus a two-line title.
const posterGridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: 168,
  mainAxisSpacing: 18,
  crossAxisSpacing: 14,
  childAspectRatio: 0.56,
);

class PosterCard extends StatefulWidget {
  const PosterCard({super.key, required this.vod, required this.onTap, this.caption});

  final VodCard vod;
  final VoidCallback onTap;

  /// Extra line under the title, e.g. the site name in search results.
  final String? caption;

  @override
  State<PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<PosterCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final vod = widget.vod;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 0.7,
              child: AnimatedScale(
                scale: _hover ? 1.04 : 1,
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: _hover
                        ? [BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 18, offset: const Offset(0, 8))]
                        : const [],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        NetImage(vod.pic),
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
                color: _hover ? scheme.primary : scheme.onSurface,
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
