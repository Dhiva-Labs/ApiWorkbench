import 'dart:convert';

import 'package:flutter/material.dart';

import '../theme.dart';

const _mono = TextStyle(
    fontFamily: 'monospace', fontSize: 13, height: 1.5, color: Palette.text);

/// Pretty-prints and syntax-highlights JSON. Falls back to plain selectable
/// text for non-JSON or very large payloads (highlighting 5 MB would jank).
class JsonView extends StatelessWidget {
  const JsonView({super.key, required this.text});

  final String text;

  static String? tryPretty(String raw) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final pretty = text.length < 512 * 1024 ? tryPretty(text) : null;
    if (pretty == null) {
      return SelectableText(text, style: _mono);
    }
    if (pretty.length > 512 * 1024) {
      return SelectableText(pretty, style: _mono);
    }
    return SelectableText.rich(TextSpan(children: _highlight(pretty)));
  }

  List<TextSpan> _highlight(String src) {
    final spans = <TextSpan>[];
    // One pass over the pretty-printed output: strings (keys vs values),
    // numbers, booleans/null, punctuation.
    final re = RegExp(
        r'("(?:[^"\\]|\\.)*")(\s*:)?|(-?\d+\.?\d*(?:[eE][+-]?\d+)?)|(\btrue\b|\bfalse\b|\bnull\b)');
    var last = 0;
    for (final m in re.allMatches(src)) {
      if (m.start > last) {
        spans.add(TextSpan(
            text: src.substring(last, m.start),
            style: _mono.copyWith(color: Palette.textDim)));
      }
      if (m.group(1) != null) {
        final isKey = m.group(2) != null;
        spans.add(TextSpan(
            text: m.group(1),
            style: _mono.copyWith(
                color: isKey ? Palette.put : Palette.get_)));
        if (isKey) {
          spans.add(TextSpan(
              text: m.group(2),
              style: _mono.copyWith(color: Palette.textDim)));
        }
      } else if (m.group(3) != null) {
        spans.add(TextSpan(
            text: m.group(3), style: _mono.copyWith(color: Palette.post)));
      } else {
        spans.add(TextSpan(
            text: m.group(4), style: _mono.copyWith(color: Palette.patch)));
      }
      last = m.end;
    }
    if (last < src.length) {
      spans.add(TextSpan(
          text: src.substring(last),
          style: _mono.copyWith(color: Palette.textDim)));
    }
    return spans;
  }
}
