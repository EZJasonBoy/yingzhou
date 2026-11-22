import 'package:material_ui/material_ui.dart';

/// The 映舟 mark, drawn from the same geometry as docs/brand/yingzhou-logo.svg (and -small.svg below 40 px): an
/// indigo square, the white sail that is a play button, the coral hull and, large enough, the three-colour wave.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 36});

  final double size;

  @override
  Widget build(BuildContext context) =>
      SizedBox.square(dimension: size, child: CustomPaint(painter: _MarkPainter(small: size < 40)));
}

class _MarkPainter extends CustomPainter {
  _MarkPainter({required this.small});

  final bool small;

  static const _indigo = Color(0xFF2F2C55);
  static const _coral = Color(0xFFF4A08A);
  static const _rose = Color(0xFFEE8C86);
  static const _gold = Color(0xFFF0C670);
  static const _mint = Color(0xFF84CFAE);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 1024, size.height / 1024);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, 1024, 1024), Radius.circular(small ? 200 : 230)), Paint()..color = _indigo);
    final sail = Path();
    if (small) {
      sail..moveTo(396, 170)..lineTo(396, 600)..lineTo(750, 385)..close();
    } else {
      sail..moveTo(420, 236)..lineTo(420, 560)..lineTo(694, 398)..close();
    }
    final white = Paint()..color = Colors.white;
    canvas.drawPath(sail, white);
    canvas.drawPath(sail, Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = small ? 70 : 56
      ..strokeJoin = StrokeJoin.round);
    final hull = small
        ? (Path()..moveTo(150, 680)..lineTo(874, 680)..quadraticBezierTo(830, 890, 512, 890)..quadraticBezierTo(194, 890, 150, 680)..close())
        : (Path()..moveTo(216, 636)..lineTo(808, 636)..quadraticBezierTo(770, 806, 512, 806)..quadraticBezierTo(254, 806, 216, 636)..close());
    canvas.drawPath(hull, Paint()..color = _coral);
    if (small) return;
    Paint stroke(Color c) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = 30
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(Path()..moveTo(262, 892)..relativeQuadraticBezierTo(50, -34, 100, 0), stroke(_rose));
    canvas.drawPath(Path()..moveTo(362, 892)..relativeQuadraticBezierTo(50, 34, 100, 0)..relativeQuadraticBezierTo(50, -34, 100, 0), stroke(_gold));
    canvas.drawPath(Path()..moveTo(562, 892)..relativeQuadraticBezierTo(50, 34, 100, 0)..relativeQuadraticBezierTo(50, -34, 100, 0), stroke(_mint));
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.small != small;
}

/// The small three-colour wave under the current tab or navigation entry (the logo's wave, 22 × 6).
class WaveMark extends StatelessWidget {
  const WaveMark({super.key, required this.colors, this.width = 22, this.visible = true});

  final List<Color> colors;
  final double width;
  final bool visible;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: 6,
    child: visible ? CustomPaint(painter: WavePainter(colors)) : null,
  );
}

/// Paints the wave across its box: a rising half in the first colour, a falling half in the second, a full wave in
/// the third, as on the logo.
class WavePainter extends CustomPainter {
  WavePainter(this.colors, {this.strokeWidth = 2});

  final List<Color> colors;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) => paintWave(canvas, Offset.zero & size, colors, strokeWidth);

  @override
  bool shouldRepaint(WavePainter old) => old.colors != colors || old.strokeWidth != strokeWidth;
}

void paintWave(Canvas canvas, Rect box, List<Color> colors, double strokeWidth) {
  final seg = box.width / 4;
  final y = box.center.dy;
  final amp = box.height / 2 - strokeWidth / 2;
  Paint p(Color c) => Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = strokeWidth
    ..strokeCap = StrokeCap.round;
  final x = box.left;
  canvas.drawPath(Path()..moveTo(x, y)..quadraticBezierTo(x + seg / 2, y - amp * 2, x + seg, y), p(colors[0]));
  canvas.drawPath(Path()..moveTo(x + seg, y)..quadraticBezierTo(x + seg * 1.5, y + amp * 2, x + seg * 2, y), p(colors[1]));
  canvas.drawPath(
    Path()
      ..moveTo(x + seg * 2, y)
      ..quadraticBezierTo(x + seg * 2.5, y - amp * 2, x + seg * 3, y)
      ..quadraticBezierTo(x + seg * 3.5, y + amp * 2, x + seg * 4, y),
    p(colors[2]),
  );
}

/// A [TabBar] indicator: the wave under the selected tab's label.
class WaveTabIndicator extends Decoration {
  const WaveTabIndicator({required this.colors, this.width = 22});

  final List<Color> colors;
  final double width;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _WaveTabPainter(this);
}

class _WaveTabPainter extends BoxPainter {
  _WaveTabPainter(this.decoration);

  final WaveTabIndicator decoration;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null) return;
    final w = decoration.width;
    final box = Rect.fromLTWH(offset.dx + (size.width - w) / 2, offset.dy + size.height - 7, w, 6);
    paintWave(canvas, box, decoration.colors, 2);
  }
}
