import 'package:material_ui/material_ui.dart';

import '../engine/line_probe.dart';
import 'brand.dart';
import 'user_mode.dart';
import 'yz_tokens.dart';

/// How the labels of the line probe are worded in [mode].
ProbeWording probeWording(UserMode mode) => switch (mode) {
  UserMode.simple => ProbeWording.simple,
  UserMode.standard => ProbeWording.standard,
  UserMode.developer => ProbeWording.developer,
};

/// The small three-colour wave of the line probe: "being measured" next to a line, "being tried" in the
/// 正在换线路 card. The design system keeps the wave for flow (loading, several lines), never decoration.
class ProbeWave extends StatelessWidget {
  const ProbeWave({super.key, this.width = 22, this.height = 8, this.strokeWidth = 2});

  final double width;
  final double height;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final t = YzTokens.of(context);
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(painter: WavePainter([t.waveRose, t.waveGold, t.waveMint], strokeWidth: strokeWidth)),
    );
  }
}

/// The 慢 mark: gold on a faint gold ground, as in the prototypes.
class SlowMark extends StatelessWidget {
  const SlowMark({super.key, this.fontSize = 12});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final gold = YzTokens.of(context).waveGold;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: gold.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(5)),
      child: Text(
        '慢',
        style: TextStyle(color: gold, fontSize: fontSize, height: 1.3),
      ),
    );
  }
}

/// What the probe says about a line, next to its name (a line button, a row of the 正在换线路 card): the wave
/// while it is measured, then its label in the colour of its state. Nothing for a line that was not measured; use
/// [LineProbeBadge.shows] to leave out the space before it.
class LineProbeBadge extends StatelessWidget {
  const LineProbeBadge({super.key, required this.probe, required this.wording, this.fontSize = 12, this.prefix = ''});

  final LineProbe probe;
  final ProbeWording wording;
  final double fontSize;

  /// Words before the label (能播 · in the card).
  final String prefix;

  /// Whether a badge for [probe] has anything to show.
  static bool shows(LineProbe? probe, ProbeWording wording) =>
      probe != null && (probe.state == LineProbeState.testing || probe.slowMark || probe.label(wording).isNotEmpty);

  @override
  Widget build(BuildContext context) {
    final t = YzTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (probe.state == LineProbeState.testing) return ProbeWave(width: fontSize * 1.8, height: fontSize * 0.66);
    final color = switch (probe.state) {
      LineProbeState.dead => t.danger,
      LineProbeState.ok when wording == ProbeWording.simple => t.success,
      _ => scheme.onSurfaceVariant,
    };
    final label = probe.label(wording);
    final text = prefix.isEmpty ? label : (label.isEmpty ? prefix.replaceAll(RegExp(r'\s*·\s*$'), '') : '$prefix$label');
    final style = TextStyle(color: color, fontSize: fontSize, fontFeatures: const [FontFeature.tabularFigures()]);
    if (!probe.slowMark) return Text(text, style: style, maxLines: 1, overflow: TextOverflow.ellipsis);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (text.isNotEmpty) ...[
          Flexible(
            child: Text(text, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 6),
        ],
        SlowMark(fontSize: fontSize),
      ],
    );
  }
}
