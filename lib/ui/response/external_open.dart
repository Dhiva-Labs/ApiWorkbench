import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import 'body_tools.dart' show sanitizeFileName;

/// Opens [uri] outside the app. Tests replace it so nothing really launches.
Future<bool> Function(Uri uri) uriLauncher = (uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// Writes [bytes] to a file in the app's preview folder under the system
/// temp directory and returns it. The name carries a hash of the content, so
/// opening the same body twice reuses one file and different bodies with the
/// same name never collide.
Future<File> writeTempFile(String name, List<int> bytes) async {
  final dir = Directory(
    p.join(Directory.systemTemp.path, 'apiworkbench_preview'),
  );
  await dir.create(recursive: true);
  final hash = sha1.convert(bytes).toString().substring(0, 10);
  final safe = sanitizeFileName(name) ?? 'response';
  final file = File(p.join(dir.path, '$hash-$safe'));
  if (!await file.exists() || await file.length() != bytes.length) {
    await file.writeAsBytes(bytes, flush: true);
  }
  return file;
}

/// Writes [bytes] to a temporary file called [name] and opens it with the
/// system's default app. Shows a message when this device cannot (phones
/// cannot open `file:` links in another app).
Future<void> openBytesExternally(
  BuildContext context, {
  required String name,
  required List<int> bytes,
  required String app,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final file = await writeTempFile(name, bytes);
    final ok = await uriLauncher(Uri.file(file.path));
    if (!ok) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            'Could not open $app. Save the response and open the file '
            'yourself.',
          ),
        ),
      );
    }
  } catch (e) {
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          'Could not open $app on this device. Save the response and open '
          'the file yourself.',
        ),
      ),
    );
  }
}
