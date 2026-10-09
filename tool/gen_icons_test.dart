// Icon generator — not part of the normal suite (lives outside test/).
// Run with: flutter test tool/gen_icons_test.dart
//
// Every platform icon is drawn from the same LogoPainter the app uses for
// its in-app mark, so they can't drift apart.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:api_workbench/ui/logo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Uint8List> _png(int size, LogoShape shape) async {
  final recorder = ui.PictureRecorder();
  LogoPainter(
    shape: shape,
  ).paint(Canvas(recorder), Size.square(size.toDouble()));
  final img = await recorder.endRecording().toImage(size, size);
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

Future<void> _save(
  int size,
  String path, [
  LogoShape shape = LogoShape.rounded,
]) async {
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(await _png(size, shape));
}

/// A Windows .ico holding PNG-encoded images (supported since Vista).
Future<void> _ico(String path, List<int> sizes) async {
  final images = [for (final s in sizes) await _png(s, LogoShape.rounded)];
  final header = BytesBuilder()
    ..add(_u16(0))
    ..add(_u16(1))
    ..add(_u16(sizes.length));
  var offset = 6 + 16 * sizes.length;
  for (var i = 0; i < sizes.length; i++) {
    final s = sizes[i];
    header
      ..addByte(s >= 256 ? 0 : s)
      ..addByte(s >= 256 ? 0 : s)
      ..addByte(0) // palette
      ..addByte(0) // reserved
      ..add(_u16(1)) // colour planes
      ..add(_u16(32)) // bits per pixel
      ..add(_u32(images[i].length))
      ..add(_u32(offset));
    offset += images[i].length;
  }
  for (final img in images) {
    header.add(img);
  }
  File(path).writeAsBytesSync(header.toBytes());
}

List<int> _u16(int v) =>
    (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List();
List<int> _u32(int v) =>
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('generate launcher icons', () async {
    // Android
    const mipmaps = {
      'mdpi': 48,
      'hdpi': 72,
      'xhdpi': 96,
      'xxhdpi': 144,
      'xxxhdpi': 192,
    };
    for (final e in mipmaps.entries) {
      await _save(
        e.value,
        'android/app/src/main/res/mipmap-${e.key}/ic_launcher.png',
      );
    }

    // Linux: app assets, Debian/PPA packaging and both snap configs.
    await _save(256, 'assets/icon/apiworkbench_256.png');
    await _save(512, 'assets/icon/apiworkbench_512.png');
    await _save(256, 'linux/packaging/icons/apiworkbench-256.png');
    await _save(512, 'linux/packaging/icons/apiworkbench-512.png');
    await _save(256, 'snap/gui/apiworkbench.png');
    await _save(256, 'linux/packaging/snap/gui/apiworkbench.png');

    // macOS: artwork inset on a transparent canvas.
    for (final s in [16, 32, 64, 128, 256, 512, 1024]) {
      await _save(
        s,
        'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$s.png',
        LogoShape.macos,
      );
    }

    // iOS: full-bleed squares (iOS applies its own mask). Sizes come from
    // the existing file names, e.g. Icon-App-83.5x83.5@2x.png → 167 px.
    final ios = Directory('ios/Runner/Assets.xcassets/AppIcon.appiconset');
    final name = RegExp(r'Icon-App-([\d.]+)x[\d.]+@(\d)x\.png$');
    for (final f in ios.listSync().whereType<File>()) {
      final m = name.firstMatch(f.path);
      if (m == null) continue;
      final px = (double.parse(m.group(1)!) * int.parse(m.group(2)!)).round();
      await _save(px, f.path, LogoShape.square);
    }

    // Windows
    await _ico('windows/runner/resources/app_icon.ico', [
      16,
      24,
      32,
      48,
      64,
      128,
      256,
    ]);
  });
}
