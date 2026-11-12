import 'package:material_ui/material_ui.dart';

/// Centered status message with an optional action, for empty / error states.
class StatusView extends StatelessWidget {
  const StatusView({super.key, required this.icon, required this.message, this.actionLabel, this.onAction});

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
            if (actionLabel != null) ...[
              const SizedBox(height: 16),
              FilledButton.tonal(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

class LoadingView extends StatelessWidget {
  const LoadingView({super.key});

  @override
  Widget build(BuildContext context) => const Center(child: CircularProgressIndicator());
}

/// Network image with a quiet placeholder and error fallback.
class NetImage extends StatelessWidget {
  const NetImage(this.url, {super.key, this.fit = BoxFit.cover, this.headers});

  final String url;
  final BoxFit fit;
  final Map<String, String>? headers;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: scheme.surfaceContainerHigh,
      child: Center(child: Icon(Icons.movie_outlined, color: scheme.onSurfaceVariant.withValues(alpha: 0.5))),
    );
    if (url.isEmpty) return placeholder;
    return Image.network(
      url,
      fit: fit,
      headers: headers,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, wasSync) => wasSync
          ? child
          : Stack(fit: StackFit.expand, children: [
              placeholder,
              AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 220), child: child),
            ]),
      errorBuilder: (_, _, _) => placeholder,
    );
  }
}
