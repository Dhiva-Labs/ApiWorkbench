import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../app_menu.dart' show savePickedFile;

/// File extension for a Content-Type, or 'bin'.
String extensionForContentType(String? contentType) {
  final ct = (contentType ?? '').split(';').first.trim().toLowerCase();
  return switch (ct) {
    'application/json' || 'application/problem+json' => 'json',
    'application/xml' || 'text/xml' => 'xml',
    'text/html' => 'html',
    'text/plain' => 'txt',
    'text/csv' => 'csv',
    'application/pdf' => 'pdf',
    'image/png' => 'png',
    'image/jpeg' => 'jpg',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    'image/svg+xml' => 'svg',
    'application/zip' => 'zip',
    _ =>
      ct.endsWith('+json') ? 'json' : (ct.startsWith('text/') ? 'txt' : 'bin'),
  };
}

/// Saves the full response body to a file the user picks (issue #20 adds
/// Content-Disposition names and find-in-body).
Future<void> saveResponseBody(
  BuildContext context,
  ResponseData res,
  RequestModel request,
) async {
  final ext = extensionForContentType(res.contentType);
  final base = request.name == 'Untitled request'
      ? 'response'
      : request.name.replaceAll(RegExp(r'[^\w\- ]'), '').trim();
  try {
    final path = await savePickedFile(
      dialogTitle: 'Save response',
      fileName: '${base.isEmpty ? 'response' : base}.$ext',
      extensions: [ext],
      bytes: Uint8List.fromList(res.bodyBytes),
    );
    if (path != null && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Response saved')));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }
}
