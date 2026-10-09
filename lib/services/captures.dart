import 'dart:convert';

import '../models/models.dart';
import 'assertions.dart';

/// Reads the values named in [captures] from [res]. Each source is
/// `body.<path>` (or a bare JSON path such as `data.items[0].id`),
/// `header.<name>` or `status`. Sources that are absent are skipped.
Map<String, String> captureValues(
  Map<String, String> captures,
  ResponseData res,
) {
  final out = <String, String>{};
  Object? json;
  var parsed = false;
  captures.forEach((name, source) {
    final key = name.trim();
    final src = source.trim();
    if (key.isEmpty || src.isEmpty) return;
    String? value;
    if (src == 'status') {
      value = '${res.statusCode}';
    } else if (src.startsWith('header.')) {
      final h = src.substring(7).toLowerCase();
      for (final e in res.headers.entries) {
        if (e.key.toLowerCase() == h) value = e.value.join(', ');
      }
    } else {
      if (!parsed) {
        parsed = true;
        try {
          json = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
        } catch (_) {}
      }
      final v = jsonAtPath(
        json,
        src.startsWith('body.') ? src.substring(5) : src,
      );
      if (jsonPathFound(v) && v != null) {
        value = v is String ? v : jsonEncode(v);
      }
    }
    if (value != null) out[key] = value;
  });
  return out;
}

/// Parses one-per-line `name = source` text (the capture editors' format).
Map<String, String> parseCaptureText(String text) {
  final out = <String, String>{};
  for (final line in text.split('\n')) {
    final i = line.indexOf('=');
    if (i <= 0) continue;
    final k = line.substring(0, i).trim();
    if (k.isNotEmpty) out[k] = line.substring(i + 1).trim();
  }
  return out;
}

String captureText(Map<String, String> m) =>
    m.entries.map((e) => '${e.key} = ${e.value}').join('\n');
