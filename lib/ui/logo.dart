import 'package:flutter/material.dart';

/// How the logo's background is shaped for a given platform.
enum LogoShape {
  /// Rounded square filling the canvas (Linux, Android, Windows, in-app).
  rounded,

  /// Full-bleed square; the platform applies its own mask (iOS).
  square,

  /// Rounded square inset on a transparent canvas, per the macOS icon grid.
  macos,
}

/// The ApiWorkbench mark: JSON braces around a lightning bolt on teal.
/// Drawn in a 120×120 design space and scaled to [Size].
class LogoPainter extends CustomPainter {
  const LogoPainter({this.shape = LogoShape.rounded});

  final LogoShape shape;

  static const teal = Color(0xFF0E8C8C);
  static const tealDeep = Color(0xFF0B7676);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    if (shape == LogoShape.macos) {
      // macOS: 824/1024 artwork centred on the canvas.
      final inset = size.width * 100 / 1024;
      canvas.translate(inset, inset);
      canvas.scale((size.width - 2 * inset) / 120);
    } else {
      canvas.scale(size.width / 120);
    }

    const box = Rect.fromLTWH(0, 0, 120, 120);
    final rrect = RRect.fromRectAndRadius(
      box,
      Radius.circular(shape == LogoShape.square ? 0 : 27),
    );
    canvas.drawRRect(rrect, Paint()..color = teal);
    canvas
      ..save()
      ..clipRRect(rrect)
      ..drawRect(const Rect.fromLTWH(0, 86, 120, 34), Paint()..color = tealDeep)
      ..restore();

    final stroke = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    Path brace(double Function(double) x) => Path()
      ..moveTo(x(42), 30)
      ..cubicTo(x(35), 30, x(34), 35, x(34), 42)
      ..lineTo(x(34), 50)
      ..cubicTo(x(34), 56, x(31), 60, x(25), 60)
      ..cubicTo(x(31), 60, x(34), 64, x(34), 70)
      ..lineTo(x(34), 78)
      ..cubicTo(x(34), 85, x(35), 90, x(42), 90);

    canvas
      ..drawPath(brace((v) => v), stroke)
      ..drawPath(brace((v) => 120 - v), stroke);

    final bolt = Path()
      ..moveTo(65, 32)
      ..lineTo(48, 64)
      ..lineTo(59, 64)
      ..lineTo(54, 89)
      ..lineTo(73, 55)
      ..lineTo(61, 55)
      ..lineTo(68, 32)
      ..close();
    canvas.drawPath(bolt, Paint()..color = Colors.white);
    canvas.restore();
  }

  @override
  bool shouldRepaint(LogoPainter old) => old.shape != shape;
}

/// The logo as a widget.
class LogoMark extends StatelessWidget {
  const LogoMark({super.key, this.size = 36});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: const CustomPaint(painter: LogoPainter()),
  );
}
