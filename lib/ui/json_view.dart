import 'dart:convert';

import 'package:flutter/material.dart';

import '../theme.dart';
import 'response/find.dart';

// A getter, not a final: the palette can change at runtime.
TextStyle get _mono => TextStyle(
  fontFamily: 'monospace',
  fontSize: 13,
  height: 1.5,
  color: Palette.text,
);

/// The monospace style response bodies are drawn in.
TextStyle get bodyMono => _mono;

/// Bodies at or above this many characters are shown as plain text instead of
/// being indented and coloured.
const _colourLimit = 64 * 1024;

/// Pretty-prints and syntax-highlights JSON. Falls back to plain selectable
/// text for non-JSON or very large payloads (highlighting 5 MB would jank).
///
/// With a [find] controller, the matches of an open find bar are highlighted
/// in the text shown (see [displayText]).
class JsonView extends StatefulWidget {
  const JsonView({super.key, required this.text, this.find});

  final String text;

  /// The find bar's state, or null for no search highlighting.
  final FindController? find;

  static String? _lastRaw;
  static String? _lastShown;

  /// The text [JsonView] draws for [raw]: the indented JSON when it parses
  /// and stays small enough to colour, otherwise [raw] itself. Offsets in
  /// the find bar refer to this text.
  static String displayText(String raw) {
    if (identical(raw, _lastRaw)) return _lastShown!;
    String shown = raw;
    if (raw.length < _colourLimit) {
      final pretty = tryPretty(raw);
      if (pretty != null && pretty.length <= _colourLimit) shown = pretty;
    }
    _lastRaw = raw;
    _lastShown = shown;
    return shown;
  }

  static String? tryPretty(String raw) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  @override
  State<JsonView> createState() => _JsonViewState();
}

class _JsonViewState extends State<JsonView> {
  late Widget _content;

  /// What [_content] shows, and its coloured spans (null when plain).
  late String _shown;
  List<TextSpan>? _spans;

  /// The palette [_content] was coloured with; a theme switch recolours it.
  String? _paletteId;

  @override
  void didUpdateWidget(JsonView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _paletteId = null;
  }

  void _prepare() {
    final text = widget.text;
    _shown = JsonView.displayText(text);
    if (identical(_shown, text)) {
      _spans = null;
      _content = SelectableText(text, style: _mono);
    } else {
      _spans = jsonSpans(_shown);
      _content = SelectableText.rich(TextSpan(children: _spans));
    }
    _paletteId = Palette.current.id;
  }

  @override
  Widget build(BuildContext context) {
    if (_paletteId != Palette.current.id) _prepare();
    final find = widget.find;
    if (find == null) return _content;
    return ListenableBuilder(
      listenable: find,
      builder: (context, _) {
        final matches = find.matchesFor(_shown);
        if (matches.isEmpty) return _content;
        return SelectableText.rich(
          TextSpan(
            children: overlayMatches(
              _spans ?? [TextSpan(text: _shown, style: _mono)],
              matches,
              find.queryLength,
              find.current,
              matchColor: findMatchColor,
              currentColor: findCurrentColor,
            ),
          ),
        );
      },
    );
  }
}

/// Syntax-highlights pretty-printed JSON [src] as flat spans that cover it
/// exactly: keys, strings, numbers and literals each get a colour.
List<TextSpan> jsonSpans(String src) {
  final spans = <TextSpan>[];
  // One pass over the pretty-printed output: strings (keys vs values),
  // numbers, booleans/null, punctuation.
  final re = RegExp(
    r'("(?:[^"\\]|\\.)*")(\s*:)?|(-?\d+\.?\d*(?:[eE][+-]?\d+)?)|(\btrue\b|\bfalse\b|\bnull\b)',
  );
  var last = 0;
  for (final m in re.allMatches(src)) {
    if (m.start > last) {
      spans.add(
        TextSpan(
          text: src.substring(last, m.start),
          style: _mono.copyWith(color: Palette.textDim),
        ),
      );
    }
    if (m.group(1) != null) {
      final isKey = m.group(2) != null;
      spans.add(
        TextSpan(
          text: m.group(1),
          style: _mono.copyWith(color: isKey ? Palette.put : Palette.get_),
        ),
      );
      if (isKey) {
        spans.add(
          TextSpan(
            text: m.group(2),
            style: _mono.copyWith(color: Palette.textDim),
          ),
        );
      }
    } else if (m.group(3) != null) {
      spans.add(
        TextSpan(
          text: m.group(3),
          style: _mono.copyWith(color: Palette.post),
        ),
      );
    } else {
      spans.add(
        TextSpan(
          text: m.group(4),
          style: _mono.copyWith(color: Palette.patch),
        ),
      );
    }
    last = m.end;
  }
  if (last < src.length) {
    spans.add(
      TextSpan(
        text: src.substring(last),
        style: _mono.copyWith(color: Palette.textDim),
      ),
    );
  }
  return spans;
}
