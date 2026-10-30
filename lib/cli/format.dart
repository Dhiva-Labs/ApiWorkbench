// Small formatting helpers shared by the reporters.

/// 512B, 1.5kB, 2.3MB.
String formatBytes(int n) {
  if (n < 1024) return '${n}B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)}kB';
  return '${(n / (1024 * 1024)).toStringAsFixed(1)}MB';
}

/// 85ms, 1.2s, 2m 3s.
String formatMs(int ms) {
  if (ms < 1000) return '${ms}ms';
  if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
  final s = ms ~/ 1000;
  return '${s ~/ 60}m ${s % 60}s';
}

/// Seconds with millisecond precision, as JUnit's `time` wants.
String seconds(int ms) => (ms / 1000).toStringAsFixed(3);

/// [s] safe for XML 1.0 and HTML text and attributes: markup characters
/// escaped, characters XML cannot hold removed.
String xmlEscape(String s) {
  final clean = s.replaceAll(
    RegExp('[\u0000-\u0008\u000B\u000C\u000E-\u001F￾￿]'),
    '',
  );
  final out = StringBuffer();
  for (final c in clean.runes) {
    switch (c) {
      case 0x26:
        out.write('&amp;');
      case 0x3C:
        out.write('&lt;');
      case 0x3E:
        out.write('&gt;');
      case 0x22:
        out.write('&quot;');
      case 0x27:
        out.write('&#39;');
      default:
        out.writeCharCode(c);
    }
  }
  return out.toString();
}

/// "Orders / Refunds", or the empty string for the top level.
String folderLabel(String folder) => folder.replaceAll('/', ' / ');

/// [s] cut to [max] characters with an ellipsis.
String clip(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}...';
