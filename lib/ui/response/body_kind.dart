import 'dart:convert';

/// What a response body is, for the Preview tab and file naming.
enum BodyKind {
  html('HTML page', 'html'),
  png('PNG image', 'png'),
  jpeg('JPEG image', 'jpg'),
  gif('GIF image', 'gif'),
  webp('WebP image', 'webp'),
  bmp('BMP image', 'bmp'),
  svg('SVG image', 'svg'),
  pdf('PDF document', 'pdf'),
  json('JSON', 'json'),
  text('Text', 'txt'),
  binary('Binary data', 'bin'),
  empty('Empty body', 'bin');

  const BodyKind(this.label, this.extension);

  /// Short description shown in the Preview tab.
  final String label;

  /// File extension used when saving a body of this kind.
  final String extension;

  /// Whether Flutter's image codecs decode this kind (SVG is drawn apart).
  bool get isRaster =>
      this == png || this == jpeg || this == gif || this == webp || this == bmp;
}

/// The media type of a Content-Type header, lower-cased and without
/// parameters. Empty when [contentType] is null.
String mediaTypeOf(String? contentType) =>
    (contentType ?? '').split(';').first.trim().toLowerCase();

/// Decides what [bytes] are. The Content-Type wins; the bytes decide when the
/// header is missing, generic (`application/octet-stream`), unknown, or
/// contradicted by the magic bytes of an image or PDF (an error page served
/// as `image/png`, say).
BodyKind detectBodyKind(String? contentType, List<int> bytes) {
  if (bytes.isEmpty) return BodyKind.empty;
  final mime = mediaTypeOf(contentType);
  final declared = _kindForMediaType(mime);

  // Declarations that the bytes can disprove.
  if (declared != null && _needsProof(declared)) {
    final sniffed = sniffBodyKind(bytes);
    if (sniffed == declared) return declared;
    if (sniffed != null) return sniffed;
    return _looksLikeText(bytes) ? BodyKind.text : BodyKind.binary;
  }
  if (declared != null) return declared;

  // XML is text, unless it is an SVG served with a generic XML type.
  final isXml = mime == 'application/xml' || mime == 'text/xml';
  if (isXml || !_isTextualMediaType(mime)) {
    final sniffed = sniffBodyKind(bytes);
    if (sniffed != null) return sniffed;
  }
  if (_isTextualMediaType(mime)) return BodyKind.text;
  return _looksLikeText(bytes) ? BodyKind.text : BodyKind.binary;
}

bool _needsProof(BodyKind k) =>
    k.isRaster || k == BodyKind.pdf || k == BodyKind.svg;

BodyKind? _kindForMediaType(String mime) => switch (mime) {
  'text/html' || 'application/xhtml+xml' => BodyKind.html,
  'image/png' => BodyKind.png,
  'image/jpeg' || 'image/jpg' || 'image/pjpeg' => BodyKind.jpeg,
  'image/gif' => BodyKind.gif,
  'image/webp' => BodyKind.webp,
  'image/bmp' || 'image/x-ms-bmp' || 'image/x-bmp' => BodyKind.bmp,
  'image/svg+xml' => BodyKind.svg,
  'application/pdf' || 'application/x-pdf' => BodyKind.pdf,
  'application/json' || 'text/json' || 'application/x-json' => BodyKind.json,
  _ when mime.endsWith('+json') => BodyKind.json,
  _ => null,
};

/// Media types that are text whatever the bytes look like.
bool _isTextualMediaType(String mime) =>
    mime.startsWith('text/') ||
    mime.endsWith('+xml') ||
    const {
      'application/xml',
      'application/javascript',
      'application/x-javascript',
      'application/ecmascript',
      'application/x-www-form-urlencoded',
      'application/graphql',
      'application/yaml',
      'application/x-yaml',
      'application/x-ndjson',
      'application/ndjson',
      'application/sql',
      'application/x-sh',
    }.contains(mime);

/// Recognises a body from its first bytes alone, or returns null.
BodyKind? sniffBodyKind(List<int> b) {
  bool at(int i, List<int> sig) {
    if (b.length < i + sig.length) return false;
    for (var k = 0; k < sig.length; k++) {
      if (b[i + k] != sig[k]) return false;
    }
    return true;
  }

  if (at(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return BodyKind.png;
  }
  if (at(0, const [0xFF, 0xD8, 0xFF])) return BodyKind.jpeg;
  if (at(0, const [0x47, 0x49, 0x46, 0x38]) &&
      b.length > 5 &&
      (b[4] == 0x37 || b[4] == 0x39) &&
      b[5] == 0x61) {
    return BodyKind.gif;
  }
  if (at(0, const [0x52, 0x49, 0x46, 0x46]) &&
      at(8, const [0x57, 0x45, 0x42, 0x50])) {
    return BodyKind.webp;
  }
  // "BM" alone is too common a prefix: also require the reserved fields to
  // be zero and a known DIB header size.
  if (at(0, const [0x42, 0x4D]) &&
      b.length >= 26 &&
      b[6] == 0 &&
      b[7] == 0 &&
      b[8] == 0 &&
      b[9] == 0 &&
      const {12, 40, 52, 56, 64, 108, 124}.contains(_le32(b, 14))) {
    return BodyKind.bmp;
  }
  // Some producers put a few bytes of junk before the PDF header.
  final head = b.length < 1024 ? b : b.sublist(0, 1024);
  for (var i = 0; i + 5 <= head.length; i++) {
    if (at(i, const [0x25, 0x50, 0x44, 0x46, 0x2D])) return BodyKind.pdf;
  }

  final text = _headText(b);
  if (text.startsWith('<!doctype html') || text.startsWith('<html')) {
    return BodyKind.html;
  }
  if (text.startsWith('<') && text.contains('<svg')) return BodyKind.svg;
  return null;
}

/// The first ~2 KB as lower-case text, minus a UTF-8 byte-order mark and
/// leading whitespace.
String _headText(List<int> b) {
  final n = b.length < 2048 ? b.length : 2048;
  var s = latin1.decode(b.sublist(0, n)).toLowerCase();
  if (s.startsWith('ï»¿')) s = s.substring(3);
  return s.trimLeft();
}

bool _looksLikeText(List<int> b) {
  final n = b.length < 1024 ? b.length : 1024;
  var control = 0;
  for (var i = 0; i < n; i++) {
    final c = b[i];
    if (c == 0) return false;
    if (c < 0x20 && c != 0x09 && c != 0x0A && c != 0x0D && c != 0x0C) {
      control++;
    }
  }
  return control * 20 < n;
}

int _le16(List<int> b, int i) => b[i] | (b[i + 1] << 8);
int _be16(List<int> b, int i) => (b[i] << 8) | b[i + 1];
int _be32(List<int> b, int i) =>
    (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
int _le32(List<int> b, int i) =>
    b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);

/// Width and height in pixels read from the file header of a PNG, JPEG, GIF,
/// WebP or BMP, or null when the header is short or unrecognised. Reading
/// the header avoids decoding the whole image just to show its size.
({int width, int height})? imageDimensions(List<int> b, BodyKind kind) {
  try {
    switch (kind) {
      case BodyKind.png:
        if (b.length < 24) return null;
        return (width: _be32(b, 16), height: _be32(b, 20));
      case BodyKind.gif:
        if (b.length < 10) return null;
        return (width: _le16(b, 6), height: _le16(b, 8));
      case BodyKind.bmp:
        if (b.length < 26) return null;
        if (_le32(b, 14) == 12) {
          return (width: _le16(b, 18), height: _le16(b, 20));
        }
        if (b.length < 30) return null;
        // 32-bit signed; a negative height means a top-down bitmap.
        int signed(int v) => v >= 0x80000000 ? v - 0x100000000 : v;
        return (
          width: signed(_le32(b, 18)).abs(),
          height: signed(_le32(b, 22)).abs(),
        );
      case BodyKind.jpeg:
        return _jpegSize(b);
      case BodyKind.webp:
        return _webpSize(b);
      default:
        return null;
    }
  } on RangeError {
    return null;
  }
}

({int width, int height})? _jpegSize(List<int> b) {
  var i = 2;
  while (i + 4 <= b.length) {
    if (b[i] != 0xFF) {
      i++;
      continue;
    }
    var marker = b[i + 1];
    while (marker == 0xFF && i + 2 < b.length) {
      i++;
      marker = b[i + 1];
    }
    // Standalone markers carry no length.
    if (marker == 0xD8 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2;
      continue;
    }
    final isFrame =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isFrame) {
      if (i + 9 > b.length) return null;
      return (width: _be16(b, i + 7), height: _be16(b, i + 5));
    }
    i += 2 + _be16(b, i + 2);
  }
  return null;
}

({int width, int height})? _webpSize(List<int> b) {
  if (b.length < 30) return null;
  final fourCc = latin1.decode(b.sublist(12, 16));
  switch (fourCc) {
    case 'VP8 ':
      return (width: _le16(b, 26) & 0x3FFF, height: _le16(b, 28) & 0x3FFF);
    case 'VP8L':
      final w = 1 + (b[21] | ((b[22] & 0x3F) << 8));
      final h = 1 + ((b[22] >> 6) | (b[23] << 2) | ((b[24] & 0x0F) << 10));
      return (width: w, height: h);
    case 'VP8X':
      final w = 1 + (b[24] | (b[25] << 8) | (b[26] << 16));
      final h = 1 + (b[27] | (b[28] << 8) | (b[29] << 16));
      return (width: w, height: h);
  }
  return null;
}

/// The page count of a PDF when it is stored in plain text, or null.
///
/// Reads the `/Count` of the page tree root. PDFs that keep their page tree
/// in compressed object streams give null rather than a wrong number; the
/// scan is skipped above [maxBytes] to stay cheap.
int? pdfPageCount(List<int> b, {int maxBytes = 8 * 1024 * 1024}) {
  if (b.length > maxBytes) return null;
  final s = latin1.decode(b, allowInvalid: true);
  // A page tree node: "/Type /Pages ... /Count N". The root has the largest.
  var best = 0;
  for (final m in RegExp(
    r'/Type\s*/Pages\b[^>]*?/Count\s+(\d+)|/Count\s+(\d+)[^>]*?/Type\s*/Pages\b',
    dotAll: true,
  ).allMatches(s)) {
    final n = int.tryParse(m.group(1) ?? m.group(2) ?? '') ?? 0;
    if (n > best) best = n;
  }
  if (best > 0) return best;
  final leaves = RegExp(r'/Type\s*/Page\b(?!s)').allMatches(s).length;
  return leaves > 0 ? leaves : null;
}

/// [html] with a `<base href>` so relative links and images resolve against
/// [baseUrl] when the page is opened from a temporary file. Pages that set
/// their own `<base>` are left alone.
String htmlWithBase(String html, String? baseUrl) {
  final uri = baseUrl == null ? null : Uri.tryParse(baseUrl);
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
    return html;
  }
  if (RegExp(r'<base[\s>]', caseSensitive: false).hasMatch(html)) return html;
  final href = const HtmlEscape(HtmlEscapeMode.attribute).convert('$uri');
  final tag = '<base href="$href">';
  final head = RegExp(
    r'<head(\s[^>]*)?>',
    caseSensitive: false,
  ).firstMatch(html);
  if (head != null) {
    return html.replaceRange(head.end, head.end, tag);
  }
  final root = RegExp(
    r'<html(\s[^>]*)?>',
    caseSensitive: false,
  ).firstMatch(html);
  if (root != null) {
    return html.replaceRange(root.end, root.end, '<head>$tag</head>');
  }
  // No <head> or <html>: keep a leading doctype first, or the browser
  // would drop into quirks mode.
  final doctype = RegExp(
    r'^\s*<!doctype[^>]*>',
    caseSensitive: false,
  ).firstMatch(html);
  if (doctype != null) {
    return html.replaceRange(doctype.end, doctype.end, tag);
  }
  return '$tag$html';
}
