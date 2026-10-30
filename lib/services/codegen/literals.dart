/// String literals for the code-snippet generators.
///
/// Every generator quotes text through one of these, so a body, header or
/// field value with quotes, backslashes, newlines, `$` or non-ASCII text
/// stays one valid literal in the target language. Multi-line text gets a
/// multi-line literal where the language has a safe one, so JSON bodies stay
/// readable.
library;

String _hex2(int u) =>
    u > 0xff ? _u4(u) : '\\x${u.toRadixString(16).padLeft(2, '0')}';
String _u4(int u) => '\\u${u.toRadixString(16).padLeft(4, '0')}';
String _ubrace(int u) => '\\u{${u.toRadixString(16)}}';

String _phpControl(int u) => u > 0xff ? _ubrace(u) : _hex2(u);

/// Control characters other than newline, tab and carriage return, plus the
/// Unicode line separators that some languages treat as line ends.
bool _isControl(int u) => u < 0x20 || u == 0x7f || u == 0x2028 || u == 0x2029;

/// True when [s] can sit unescaped inside a raw literal that only newlines
/// and tabs may break: no control characters and no carriage returns.
bool _rawSafe(String s) {
  for (final u in s.codeUnits) {
    if (u == 0x0a || u == 0x09) continue;
    if (_isControl(u) || u == 0x0d) return false;
  }
  return true;
}

/// Escapes [s] for a literal delimited by [quote] (or by three of them, with
/// [tripleQuote]). [extra] adds per-character
/// escapes (for `$` or `#` interpolation), [control] spells control
/// characters, and [asciiOnly] spells everything above U+007E as `\uXXXX` per
/// UTF-16 unit. With [keepNewlines] a newline stays a real line break, for
/// multi-line literals.
String _escape(
  String s, {
  required String quote,
  Map<String, String> extra = const {},
  String Function(int unit) control = _u4,
  bool asciiOnly = false,
  bool keepNewlines = false,
  bool tripleQuote = false,
}) {
  final b = StringBuffer();
  final units = s.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    final c = String.fromCharCode(unit);
    final custom = extra[c];
    if (custom != null) {
      b.write(custom);
    } else if (c == r'\') {
      b.write(r'\\');
    } else if (c == quote) {
      // Inside a triple-quoted literal a lone quote needs no escape; only
      // a run that could close it, or a quote at the very end, does.
      final closes =
          i == units.length - 1 ||
          (i + 2 < units.length &&
              units[i + 1] == unit &&
              units[i + 2] == unit);
      b.write(!tripleQuote || closes ? '\\$quote' : quote);
    } else if (unit == 0x0a) {
      b.write(keepNewlines ? '\n' : r'\n');
    } else if (unit == 0x0d) {
      b.write(r'\r');
    } else if (unit == 0x09) {
      b.write(r'\t');
    } else if (_isControl(unit)) {
      b.write(control(unit));
    } else if (asciiOnly && unit > 0x7e) {
      b.write(_u4(unit));
    } else {
      b.write(c);
    }
  }
  return b.toString();
}

/// POSIX shell: single quotes, which keep everything literal.
String shQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// PowerShell: single quotes, which take everything literally; `'` and the
/// typographic quotes PowerShell also reads as quotes are doubled. Text with
/// carriage returns or other control characters cannot sit in a single-quoted
/// string, so it becomes a double-quoted one with backtick escapes.
String psQuote(String s) {
  const singles = "'\u2018\u2019\u201a\u201b";
  const doubles = '"\u201c\u201d\u201e';
  final plain = s.codeUnits.every(
    (u) => u == 0x09 || u == 0x0a || !_isControl(u) && u != 0x0d,
  );
  final b = StringBuffer(plain ? "'" : '"');
  for (final ch in s.split('')) {
    final u = ch.codeUnitAt(0);
    if (plain) {
      b.write(singles.contains(ch) ? '$ch$ch' : ch);
    } else if (ch == r'$' || ch == '`') {
      b.write('`$ch');
    } else if (doubles.contains(ch)) {
      b.write('$ch$ch');
    } else if (u == 0x0d) {
      b.write('`r');
    } else if (u == 0x09) {
      b.write('`t');
    } else if (u == 0x0a) {
      b.write('\n');
    } else if (_isControl(u)) {
      b.write('\$([char]$u)');
    } else {
      b.write(ch);
    }
  }
  b.write(plain ? "'" : '"');
  return b.toString();
}

/// Python 3: double quotes, or `"""` for multi-line text.
String pyStr(String s) => s.contains('\n')
    ? '"""${_escape(s, quote: '"', control: _hex2, keepNewlines: true, tripleQuote: true)}"""'
    : '"${_escape(s, quote: '"', control: _hex2)}"';

/// JavaScript: double quotes, or a template literal for multi-line text.
String jsStr(String s) => s.contains('\n')
    ? '`${_escape(s, quote: '`', extra: const {r'$': r'\$'}, control: _hex2, keepNewlines: true)}`'
    : '"${_escape(s, quote: '"', control: _hex2)}"';

/// Java: ASCII only (`\uXXXX`), so the source compiles under any default
/// encoding. Multi-line text becomes `"..." +` lines indented by [indent]
/// (text blocks need Java 15).
String javaStr(String s, {String indent = '        ', bool split = true}) {
  String one(String part) => '"${_escape(part, quote: '"', asciiOnly: true)}"';
  if (!split || !s.contains('\n')) return one(s);
  final parts = <String>[];
  var start = 0;
  while (true) {
    final i = s.indexOf('\n', start);
    if (i < 0) {
      if (start < s.length) parts.add(s.substring(start));
      break;
    }
    parts.add(s.substring(start, i + 1));
    start = i + 1;
  }
  return parts.map(one).join(' +\n$indent');
}

/// Kotlin: `"..."` with `$` escaped, or `"""` raw text when that is safe.
String ktStr(String s) {
  if (s.contains('\n') &&
      _rawSafe(s) &&
      !s.contains(r'$') &&
      !s.contains('"""') &&
      !s.endsWith('"')) {
    return '"""$s"""';
  }
  return '"${_escape(s, quote: '"', extra: const {r'$': r'\$'})}"';
}

/// C#: regular `"..."`, or a verbatim `@"..."` for multi-line text.
String csStr(String s) {
  if (s.contains('\n') && _rawSafe(s)) {
    return '@"${s.replaceAll('"', '""')}"';
  }
  return '"${_escape(s, quote: '"')}"';
}

/// Go: `"..."`, or a backtick raw string for multi-line text.
String goStr(String s) {
  if (s.contains('\n') && _rawSafe(s) && !s.contains('`')) return '`$s`';
  return '"${_escape(s, quote: '"', control: _hex2)}"';
}

/// PHP: single quotes where nothing needs escaping, else double quotes.
String phpStr(String s) {
  if (_rawSafe(s)) {
    return "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";
  }
  return '"${_escape(s, quote: '"', extra: const {r'$': r'\$'}, control: _phpControl)}"';
}

/// Ruby: single quotes where nothing needs escaping, else double quotes
/// (with `#` escaped so `#{...}` is not interpolated).
String rbStr(String s) {
  if (_rawSafe(s)) {
    return "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";
  }
  return '"${_escape(s, quote: '"', extra: const {'#': r'\#'}, control: _hex2)}"';
}

/// Swift: `"..."`, or a `"""` block (opening and closing delimiters on their
/// own lines) for multi-line text.
String swiftStr(String s) => s.contains('\n')
    ? '"""\n${_escape(s, quote: '"', control: _ubrace, keepNewlines: true, tripleQuote: true)}\n"""'
    : '"${_escape(s, quote: '"', control: _ubrace)}"';

/// Dart: single quotes with `$` escaped, or `'''` for multi-line text.
String dartStr(String s) {
  const dollar = {r'$': r'\$'};
  // A newline right after ''' is dropped by Dart, so such text is escaped.
  if (s.contains('\n') && !s.startsWith('\n')) {
    return "'''${_escape(s, quote: "'", extra: dollar, control: _hex2, keepNewlines: true, tripleQuote: true)}'''";
  }
  return "'${_escape(s, quote: "'", extra: dollar, control: _hex2)}'";
}

/// Rust: a raw `r#"..."#` string when the text has quotes, backslashes or
/// line breaks, else a plain string.
String rustStr(String s) {
  final special = s.contains('"') || s.contains(r'\') || s.contains('\n');
  if (special && _rawSafe(s)) {
    var hashes = '';
    while (s.contains('"$hashes')) {
      hashes += '#';
    }
    return 'r$hashes"$s"$hashes';
  }
  return '"${_escape(s, quote: '"', control: _ubrace)}"';
}
