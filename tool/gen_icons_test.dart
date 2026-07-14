// Icon generator — not part of the normal suite (lives outside test/).
// Run with: flutter test tool/gen_icons_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ui.Image> _draw(int size) async {
  final s = size.toDouble();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);

  // Background: rounded square, indigo -> violet diagonal gradient.
  final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, s, s), Radius.circular(s * 0.22));
  canvas.drawRRect(
    bgRect,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        Offset(s, s),
        const [Color(0xFF6D7DF3), Color(0xFFA070EE)],
      ),
  );
  // Subtle darker footer band for depth.
  canvas.save();
  canvas.clipRRect(bgRect);
  canvas.drawRect(
    Rect.fromLTWH(0, s * 0.72, s, s * 0.28),
    Paint()..color = const Color(0x22000000),
  );
  canvas.restore();

  // Two opposing arrows: request (top, to the right) and response (bottom,
  // to the left) — the request/response cycle.
  final stroke = Paint()
    ..color = Colors.white
    ..strokeWidth = s * 0.075
    ..strokeCap = StrokeCap.round
    ..style = PaintingStyle.stroke;
  final fill = Paint()..color = Colors.white;

  void arrow(double y, bool toRight) {
    final x1 = toRight ? s * 0.24 : s * 0.76;
    final x2 = toRight ? s * 0.62 : s * 0.38;
    final tip = toRight ? s * 0.78 : s * 0.22;
    canvas.drawLine(Offset(x1, y), Offset(x2, y), stroke);
    final head = Path()
      ..moveTo(tip, y)
      ..lineTo(x2 - (toRight ? 0 : s * 0.005), y - s * 0.085)
      ..lineTo(x2 + (toRight ? s * 0.005 : 0), y + s * 0.085)
      ..close();
    canvas.drawPath(head, fill);
  }

  arrow(s * 0.385, true);
  arrow(s * 0.615, false);

  return recorder.endRecording().toImage(size, size);
}

Future<void> _save(int size, String path) async {
  final img = await _draw(size);
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('generate launcher icons', () async {
    const mipmaps = {
      'mdpi': 48,
      'hdpi': 72,
      'xhdpi': 96,
      'xxhdpi': 144,
      'xxxhdpi': 192,
    };
    for (final e in mipmaps.entries) {
      await _save(e.value,
          'android/app/src/main/res/mipmap-${e.key}/ic_launcher.png');
    }
    await _save(256, 'assets/icon/apiworkbench_256.png');
    await _save(512, 'assets/icon/apiworkbench_512.png');
  });
}
