import 'dart:io';

import 'package:flutter/services.dart';

/// Loads Roboto from the Flutter SDK so widget tests lay text out with real
/// glyph widths. Without it tests render every glyph as a wide square and
/// report overflows that never happen on a device. Does nothing when the SDK
/// fonts cannot be found.
Future<void> loadRoboto() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final dir = '$root/bin/cache/artifacts/material_fonts';
  final loader = FontLoader('Roboto');
  var any = false;
  for (final name in ['Regular', 'Medium', 'Bold']) {
    final file = File('$dir/Roboto-$name.ttf');
    if (!file.existsSync()) continue;
    loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    any = true;
  }
  if (any) await loader.load();
}
