import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../models/models.dart';
import '../app_menu.dart' show savePickedFile;
import 'body_kind.dart';

/// File extension for a Content-Type, or 'bin'.
String extensionForContentType(String? contentType) {
  final ct = mediaTypeOf(contentType);
  return switch (ct) {
    'application/json' || 'application/problem+json' || 'text/json' => 'json',
    'application/xml' || 'text/xml' => 'xml',
    'application/xhtml+xml' => 'xhtml',
    'text/html' => 'html',
    'text/plain' => 'txt',
    'text/csv' => 'csv',
    'text/css' => 'css',
    'text/markdown' => 'md',
    'text/javascript' ||
    'application/javascript' ||
    'application/x-javascript' => 'js',
    'application/yaml' || 'application/x-yaml' || 'text/yaml' => 'yaml',
    'application/x-ndjson' || 'application/ndjson' => 'ndjson',
    'application/pdf' => 'pdf',
    'image/png' => 'png',
    'image/jpeg' || 'image/jpg' => 'jpg',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    'image/avif' => 'avif',
    'image/bmp' || 'image/x-ms-bmp' => 'bmp',
    'image/tiff' => 'tiff',
    'image/x-icon' || 'image/vnd.microsoft.icon' => 'ico',
    'image/svg+xml' => 'svg',
    'application/zip' => 'zip',
    'application/gzip' || 'application/x-gzip' => 'gz',
    'application/x-tar' => 'tar',
    'application/wasm' => 'wasm',
    'audio/mpeg' => 'mp3',
    'audio/wav' || 'audio/x-wav' => 'wav',
    'audio/ogg' => 'ogg',
    'video/mp4' => 'mp4',
    'video/webm' => 'webm',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document' =>
      'docx',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' =>
      'xlsx',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation' =>
      'pptx',
    _ =>
      ct.endsWith('+json')
          ? 'json'
          : ct.endsWith('+xml')
          ? 'xml'
          : (ct.startsWith('text/') ? 'txt' : 'bin'),
  };
}

/// The extension for a response: from its Content-Type, or from the bytes
/// when the type is missing or generic.
String extensionForResponse(ResponseData res) {
  final byType = extensionForContentType(res.contentType);
  if (byType != 'bin') return byType;
  return detectBodyKind(res.contentType, res.bodyBytes).extension;
}

/// The file name a server suggests in a `Content-Disposition` header, or
/// null. `filename*=UTF-8''...` (RFC 5987) wins over `filename=`. The result
/// is sanitised with [sanitizeFileName].
String? contentDispositionFilename(String? header) {
  if (header == null || header.trim().isEmpty) return null;
  String? plain;
  String? extended;
  // The first part is the disposition type ("attachment", "inline").
  for (final param in _splitParams(header).skip(1)) {
    final eq = param.indexOf('=');
    if (eq < 0) continue;
    final name = param.substring(0, eq).trim().toLowerCase();
    final value = param.substring(eq + 1).trim();
    if (name == 'filename*') {
      extended ??= _decodeExtendedValue(value);
    } else if (name == 'filename') {
      plain ??= _unquote(value);
    }
  }
  return sanitizeFileName(extended) ?? sanitizeFileName(plain);
}

/// Splits on `;` outside double quotes.
List<String> _splitParams(String header) {
  final out = <String>[];
  final buf = StringBuffer();
  var quoted = false;
  for (var i = 0; i < header.length; i++) {
    final c = header[i];
    if (c == '\\' && quoted && i + 1 < header.length) {
      buf
        ..write(c)
        ..write(header[++i]);
      continue;
    }
    if (c == '"') quoted = !quoted;
    if (c == ';' && !quoted) {
      out.add(buf.toString());
      buf.clear();
    } else {
      buf.write(c);
    }
  }
  out.add(buf.toString());
  return out;
}

String _unquote(String v) {
  if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
    return v
        .substring(1, v.length - 1)
        .replaceAllMapped(RegExp(r'\\(.)'), (m) => m.group(1)!);
  }
  return v;
}

/// Decodes `charset'language'percent-encoded`; null for an unknown charset
/// so the plain `filename` is used instead.
String? _decodeExtendedValue(String v) {
  final first = v.indexOf("'");
  final second = first < 0 ? -1 : v.indexOf("'", first + 1);
  if (second < 0) return null;
  final charset = v.substring(0, first).toLowerCase();
  final enc = v.substring(second + 1);
  final bytes = <int>[];
  for (var i = 0; i < enc.length; i++) {
    final c = enc.codeUnitAt(i);
    if (c == 0x25 && i + 2 < enc.length) {
      final hex = int.tryParse(enc.substring(i + 1, i + 3), radix: 16);
      if (hex != null) {
        bytes.add(hex);
        i += 2;
        continue;
      }
    }
    // Raw (non-escaped) characters are not valid here but do occur.
    if (c < 0x80) {
      bytes.add(c);
    } else {
      bytes.addAll(utf8.encode(String.fromCharCode(c)));
    }
  }
  return switch (charset) {
    'utf-8' || 'utf8' => utf8.decode(bytes, allowMalformed: true),
    'iso-8859-1' || 'latin1' => latin1.decode(bytes),
    _ => null,
  };
}

final _reservedNames = RegExp(
  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$',
  caseSensitive: false,
);

/// Makes [name] safe to use as a file name on every platform, or returns null
/// when nothing usable is left. Keeps only the last path segment (so
/// `../../etc/passwd` becomes `passwd`), replaces characters Windows forbids
/// and control characters, avoids reserved device names and caps the length
/// while keeping the extension.
String? sanitizeFileName(String? name, {int maxLength = 120}) {
  if (name == null) return null;
  var s = name.split(RegExp(r'[\\/]')).last;
  s = s.replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"|?*]'), '_');
  s = s.trim().replaceAll(RegExp(r'[. ]+$'), '');
  if (s.isEmpty || RegExp(r'^\.+$').hasMatch(s)) return null;
  if (_reservedNames.hasMatch(s)) s = '_$s';
  if (s.length > maxLength) {
    final ext = p.extension(s);
    final keep = ext.length < 16 ? ext : '';
    s = s.substring(0, maxLength - keep.length) + keep;
  }
  return s;
}

/// The file name to propose when saving [res]: the server's
/// `Content-Disposition` name, else the last URL segment when it has an
/// extension, else the request name with an extension from the Content-Type.
String suggestedFileName(ResponseData res, RequestModel request) {
  for (final e in res.headers.entries) {
    if (e.key.toLowerCase() != 'content-disposition') continue;
    for (final v in e.value) {
      final n = contentDispositionFilename(v);
      if (n != null) return n;
    }
  }

  final url = res.finalUrl;
  final uri = url == null ? null : Uri.tryParse(url);
  if (uri != null && uri.pathSegments.isNotEmpty) {
    final last = sanitizeFileName(uri.pathSegments.last);
    if (last != null && RegExp(r'\.[A-Za-z0-9]{1,10}$').hasMatch(last)) {
      return last;
    }
  }

  final named = request.name == 'Untitled request'
      ? ''
      : request.name.replaceAll(RegExp(r'[^\w\- ]'), '').trim();
  return '${named.isEmpty ? 'response' : named}.${extensionForResponse(res)}';
}

/// "1.4 KB" style size.
String formatByteSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// Saves the full response body (not just the 64 KB preview) to a file the
/// user picks, proposing a name from the response headers, URL or request.
Future<void> saveResponseBody(
  BuildContext context,
  ResponseData res,
  RequestModel request,
) async {
  final name = suggestedFileName(res, request);
  final dot = name.lastIndexOf('.');
  final suffix = dot > 0 ? name.substring(dot + 1) : '';
  final ext = RegExp(r'^[A-Za-z0-9]{1,10}$').hasMatch(suffix)
      ? suffix.toLowerCase()
      : extensionForResponse(res);
  try {
    final path = await savePickedFile(
      dialogTitle: 'Save response',
      fileName: name,
      extensions: [ext],
      bytes: res.bodyBytes is Uint8List
          ? res.bodyBytes as Uint8List
          : Uint8List.fromList(res.bodyBytes),
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
