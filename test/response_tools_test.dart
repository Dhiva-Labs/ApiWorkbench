// Response pane tools: the Preview tab (content detection, HTML, images, SVG,
// PDF, hex), save-to-file naming, and find-in-body with the full body view.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/theme.dart';
import 'package:api_workbench/ui/json_view.dart';
import 'package:api_workbench/ui/response/body_kind.dart';
import 'package:api_workbench/ui/response/body_text.dart';
import 'package:api_workbench/ui/response/body_tools.dart';
import 'package:api_workbench/ui/response/external_open.dart';
import 'package:api_workbench/ui/response/find.dart';
import 'package:api_workbench/ui/response/full_body.dart';
import 'package:api_workbench/ui/response/hex_view.dart';
import 'package:api_workbench/ui/response/preview_tab.dart';
import 'package:api_workbench/ui/response_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:provider/provider.dart';

// --- fixtures ---------------------------------------------------------------

int _crc(List<int> data) {
  var c = 0xFFFFFFFF;
  for (final b in data) {
    c ^= b;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB88320 : c >> 1;
    }
  }
  return c ^ 0xFFFFFFFF;
}

/// A valid [w] x [h] red PNG, built from scratch.
Uint8List makePng(int w, int h) {
  List<int> be32(int v) => [v >> 24, (v >> 16) & 255, (v >> 8) & 255, v & 255];
  List<int> chunk(String type, List<int> data) {
    final body = [...ascii.encode(type), ...data];
    return [...be32(data.length), ...body, ...be32(_crc(body))];
  }

  final raw = <int>[];
  for (var y = 0; y < h; y++) {
    raw.add(0);
    for (var x = 0; x < w; x++) {
      raw.addAll([255, 0, 0]);
    }
  }
  return Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    ...chunk('IHDR', [...be32(w), ...be32(h), 8, 2, 0, 0, 0]),
    ...chunk('IDAT', ZLibCodec().encode(raw)),
    ...chunk('IEND', const []),
  ]);
}

const _svg =
    '<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" '
    'viewBox="0 0 10 10"><rect width="10" height="10" fill="red"/></svg>';

Map<String, List<String>> _h(String contentType, [Map<String, String>? more]) =>
    {
      'content-type': [contentType],
      for (final e in (more ?? {}).entries) e.key: [e.value],
    };

ResponseData _res(
  List<int> body, {
  String? type,
  Map<String, String>? headers,
  String? url,
}) => ResponseData(
  statusCode: 200,
  statusMessage: 'OK',
  headers: type == null
      ? (headers == null ? {} : _h('', headers))
      : _h(type, headers),
  bodyBytes: body,
  finalUrl: url,
);

void main() {
  group('content detection', () {
    test('the Content-Type decides when it is specific', () {
      expect(
        detectBodyKind('text/html; charset=utf-8', utf8.encode('x')),
        BodyKind.html,
      );
      expect(
        detectBodyKind('application/json', utf8.encode('{}')),
        BodyKind.json,
      );
      expect(
        detectBodyKind('application/vnd.api+json', utf8.encode('{}')),
        BodyKind.json,
      );
      expect(
        detectBodyKind('text/plain', utf8.encode('<html>')),
        BodyKind.text,
      );
      expect(detectBodyKind('text/csv', utf8.encode('a,b')), BodyKind.text);
      expect(detectBodyKind('image/png', makePng(2, 2)), BodyKind.png);
      expect(
        detectBodyKind('application/pdf', utf8.encode('%PDF-1.4')),
        BodyKind.pdf,
      );
      expect(detectBodyKind('image/svg+xml', utf8.encode(_svg)), BodyKind.svg);
      expect(detectBodyKind(null, const []), BodyKind.empty);
    });

    test('magic bytes decide when the header is missing or generic', () {
      final png = makePng(1, 1);
      for (final type in [null, '', 'application/octet-stream', 'binary/x']) {
        expect(detectBodyKind(type, png), BodyKind.png, reason: '$type');
      }
      expect(
        detectBodyKind(null, [0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10]),
        BodyKind.jpeg,
      );
      expect(detectBodyKind(null, ascii.encode('GIF89a....')), BodyKind.gif);
      expect(detectBodyKind(null, ascii.encode('GIF87a....')), BodyKind.gif);
      expect(
        detectBodyKind(null, [
          ...ascii.encode('RIFF'),
          1,
          0,
          0,
          0,
          ...ascii.encode('WEBPVP8 '),
        ]),
        BodyKind.webp,
      );
      final bmp = Uint8List(40)
        ..[0] = 0x42
        ..[1] = 0x4D
        ..[14] = 40;
      expect(detectBodyKind(null, bmp), BodyKind.bmp);
      expect(detectBodyKind(null, ascii.encode('%PDF-1.7\n...')), BodyKind.pdf);
      expect(
        detectBodyKind(null, ascii.encode('junk\n%PDF-1.7')),
        BodyKind.pdf,
      );
      expect(
        detectBodyKind(
          'application/octet-stream',
          utf8.encode('  <!DOCTYPE html><p>'),
        ),
        BodyKind.html,
      );
      expect(
        detectBodyKind(null, utf8.encode('<HTML lang="en">')),
        BodyKind.html,
      );
      expect(
        detectBodyKind(
          null,
          utf8.encode('\uFEFF<?xml version="1.0"?>\n<svg width="1"/>'),
        ),
        BodyKind.svg,
      );
      // An XML type that actually holds an SVG.
      expect(
        detectBodyKind('application/xml', utf8.encode(_svg)),
        BodyKind.svg,
      );
      expect(
        detectBodyKind('application/xml', utf8.encode('<a/>')),
        BodyKind.text,
      );
    });

    test('a wrong Content-Type is corrected by the bytes', () {
      // An HTML error page served as an image, a JPEG labelled PNG.
      expect(
        detectBodyKind('image/png', utf8.encode('<html>404</html>')),
        BodyKind.html,
      );
      expect(
        detectBodyKind('image/png', [0xFF, 0xD8, 0xFF, 0xE0]),
        BodyKind.jpeg,
      );
      expect(
        detectBodyKind('image/png', utf8.encode('not an image')),
        BodyKind.text,
      );
      expect(detectBodyKind('application/pdf', [0, 1, 2, 3]), BodyKind.binary);
    });

    test('unknown bodies are text or binary by their content', () {
      expect(
        detectBodyKind(null, utf8.encode('just some words\nand lines')),
        BodyKind.text,
      );
      expect(detectBodyKind(null, utf8.encode('{"a": 1}')), BodyKind.text);
      expect(
        detectBodyKind('application/octet-stream', [0, 1, 2, 3, 0xFE, 0xFF]),
        BodyKind.binary,
      );
      expect(
        detectBodyKind(
          'application/octet-stream',
          List.generate(300, (i) => i % 31),
        ),
        BodyKind.binary,
      );
      expect(
        detectBodyKind('application/zip', [0x50, 0x4B, 3, 4, 0, 0]),
        BodyKind.binary,
      );
    });

    test('image dimensions come from the file header', () {
      expect(imageDimensions(makePng(37, 21), BodyKind.png), (
        width: 37,
        height: 21,
      ));
      expect(
        imageDimensions([
          ...ascii.encode('GIF89a'),
          5,
          0,
          7,
          0,
          0,
          0,
        ], BodyKind.gif),
        (width: 5, height: 7),
      );
      // JPEG: APP0 segment, then a SOF0 frame header of 12 x 34.
      final jpeg = [
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x4A, 0x46, //
        0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 34, 0x00, 12, 0x03,
      ];
      expect(imageDimensions(jpeg, BodyKind.jpeg), (width: 12, height: 34));
      final bmp = Uint8List(30)
        ..[0] = 0x42
        ..[1] = 0x4D
        ..[14] = 40
        ..[18] = 100
        ..[22] =
            0xF0 // -16: a top-down bitmap
        ..[23] = 0xFF
        ..[24] = 0xFF
        ..[25] = 0xFF;
      expect(imageDimensions(bmp, BodyKind.bmp), (width: 100, height: 16));
      List<int> webp(String fourCc, List<int> payload) => [
        ...ascii.encode('RIFF'), 0, 0, 0, 0, ...ascii.encode('WEBP'), //
        ...ascii.encode(fourCc), 0, 0, 0, 0, ...payload,
      ];
      expect(
        imageDimensions(
          webp('VP8X', [0, 0, 0, 0, 99, 0, 0, 49, 0, 0, 0, 0]),
          BodyKind.webp,
        ),
        (width: 100, height: 50),
      );
      expect(
        imageDimensions(
          webp('VP8 ', [0, 0, 0, 0x9D, 0x01, 0x2A, 64, 0, 32, 0, 0, 0]),
          BodyKind.webp,
        ),
        (width: 64, height: 32),
      );
      expect(
        imageDimensions(
          // 0x2F signature, then width - 1 = 15 and height - 1 = 7, each in
          // 14 bits: 15 | (7 & 3) << 6 in byte 2, 7 >> 2 in byte 3.
          webp('VP8L', [0x2F, 15, 0xC0, 1, 0, 0, 0, 0, 0, 0]),
          BodyKind.webp,
        ),
        (width: 16, height: 8),
      );
      expect(imageDimensions([1, 2, 3], BodyKind.png), isNull);
      expect(imageDimensions(const [], BodyKind.jpeg), isNull);
    });

    test('PDF page counts come from the page tree when it is readable', () {
      String pdf(String body) => '%PDF-1.4\n$body\n%%EOF';
      expect(
        pdfPageCount(
          latin1.encode(
            pdf(
              '1 0 obj << /Type /Pages /Kids [2 0 R] /Count 3 >> endobj\n'
              '2 0 obj << /Type /Page /Parent 1 0 R >> endobj',
            ),
          ),
        ),
        3,
      );
      // /Count before /Type, and the root (largest count) wins.
      expect(
        pdfPageCount(
          latin1.encode(
            pdf(
              '1 0 obj << /Count 12 /Type /Pages >> endobj\n'
              '3 0 obj << /Type /Pages /Count 4 /Parent 1 0 R >> endobj',
            ),
          ),
        ),
        12,
      );
      // No tree in sight: count the page leaves.
      expect(
        pdfPageCount(
          latin1.encode(
            pdf('<< /Type /Page >> << /Type /Page >> << /Type /Pages >>'),
          ),
        ),
        2,
      );
      expect(
        pdfPageCount(latin1.encode(pdf('stream of compressed bytes'))),
        isNull,
      );
      expect(pdfPageCount(Uint8List(100), maxBytes: 10), isNull);
    });

    test('a base tag is added so a saved page keeps its links', () {
      const url = 'https://example.com/docs/page.html';
      expect(
        htmlWithBase('<html><head><title>x</title></head></html>', url),
        '<html><head><base href="https://example.com/docs/page.html"><title>x</title></head></html>',
      );
      expect(
        htmlWithBase('<html><body>hi</body></html>', url),
        contains('<html><head><base href='),
      );
      expect(htmlWithBase('<p>hi</p>', url), startsWith('<base href='));
      expect(
        htmlWithBase('<!DOCTYPE html><p>hi</p>', url),
        startsWith('<!DOCTYPE html><base href='),
      );
      // The page's own <base> and non-web addresses are left alone.
      const own = '<head><base href="/x/"></head>';
      expect(htmlWithBase(own, url), own);
      expect(htmlWithBase('<p>hi</p>', 'file:///tmp/a.html'), '<p>hi</p>');
      expect(htmlWithBase('<p>hi</p>', null), '<p>hi</p>');
    });
  });

  group('file names', () {
    test('Content-Disposition: filename*, filename, quoting', () {
      String? cd(String v) => contentDispositionFilename(v);
      expect(cd('attachment; filename="report.pdf"'), 'report.pdf');
      expect(cd('attachment; filename=report.pdf'), 'report.pdf');
      expect(
        cd('inline; FILENAME="Q1 Report.xlsx"; size=10'),
        'Q1 Report.xlsx',
      );
      // filename* wins, whichever order they come in.
      expect(
        cd(
          "attachment; filename=\"fallback.txt\"; filename*=UTF-8''na%C3%AFve%20caf%C3%A9.txt",
        ),
        'naïve café.txt',
      );
      expect(
        cd(
          "attachment; filename*=UTF-8''%E2%82%AC%20rates.csv; filename=\"x.csv\"",
        ),
        '€ rates.csv',
      );
      expect(cd("attachment; filename*=iso-8859-1'en'caf%E9.txt"), 'café.txt');
      // An unknown charset falls back to the plain name.
      expect(
        cd("attachment; filename*=klingon''a.txt; filename=\"b.txt\""),
        'b.txt',
      );
      // A semicolon inside quotes, and escaped quotes.
      expect(cd('attachment; filename="a;b.txt"'), 'a;b.txt');
      expect(cd(r'attachment; filename="say \"hi\".txt"'), 'say _hi_.txt');
      expect(cd('attachment'), isNull);
      expect(cd('attachment; filename=""'), isNull);
      expect(cd(''), isNull);
      expect(contentDispositionFilename(null), isNull);
    });

    test('names are sanitised for every platform', () {
      expect(sanitizeFileName('../../etc/passwd'), 'passwd');
      expect(sanitizeFileName(r'C:\Users\me\file.txt'), 'file.txt');
      expect(sanitizeFileName('a<b>c:d"e|f?g*h.txt'), 'a_b_c_d_e_f_g_h.txt');
      expect(sanitizeFileName('tab\there\n.txt'), 'tab_here_.txt');
      expect(sanitizeFileName('  spaced.txt. '), 'spaced.txt');
      expect(sanitizeFileName('..'), isNull);
      expect(sanitizeFileName('...'), isNull);
      expect(sanitizeFileName(''), isNull);
      expect(sanitizeFileName(null), isNull);
      expect(sanitizeFileName('CON'), '_CON');
      expect(sanitizeFileName('nul.txt'), '_nul.txt');
      expect(sanitizeFileName('console.log'), 'console.log');
      final long = sanitizeFileName('${'a' * 300}.json')!;
      expect(long.length, 120);
      expect(long, endsWith('.json'));
    });

    test(
      'the suggestion prefers Content-Disposition, then the URL, then the request',
      () {
        final request = RequestModel(name: 'Get users');
        // 1. Content-Disposition.
        expect(
          suggestedFileName(
            _res(
              utf8.encode('{}'),
              type: 'application/json',
              headers: {
                'Content-Disposition': 'attachment; filename="export.json"',
              },
              url: 'https://api.test/users.csv',
            ),
            request,
          ),
          'export.json',
        );
        // A header that gives nothing usable falls through.
        expect(
          suggestedFileName(
            _res(
              utf8.encode('x'),
              type: 'text/plain',
              headers: {'content-disposition': 'attachment'},
              url: 'https://api.test/files/notes.txt?download=1',
            ),
            request,
          ),
          'notes.txt',
        );
        // 2. The last path segment, but only with an extension.
        expect(
          suggestedFileName(
            _res(
              [1],
              type: 'image/png',
              url: 'https://cdn.test/a/b/logo%20v2.png',
            ),
            request,
          ),
          'logo v2.png',
        );
        // 3. Request name + the Content-Type's extension.
        expect(
          suggestedFileName(
            _res(
              utf8.encode('{}'),
              type: 'application/json',
              url: 'https://api.test/users',
            ),
            request,
          ),
          'Get users.json',
        );
        expect(
          suggestedFileName(
            _res(
              utf8.encode('<p>'),
              type: 'text/html',
              url: 'https://api.test/',
            ),
            RequestModel(),
          ),
          'response.html',
        );
        // The extension can come from the bytes when the type says nothing.
        expect(
          suggestedFileName(
            _res(makePng(1, 1), type: 'application/octet-stream'),
            request,
          ),
          'Get users.png',
        );
        expect(
          suggestedFileName(
            _res(const [0, 1, 2], type: 'application/octet-stream'),
            request,
          ),
          'Get users.bin',
        );
      },
    );

    test('extensions map from content types', () {
      const cases = {
        'application/json; charset=utf-8': 'json',
        'application/problem+json': 'json',
        'application/vnd.api+json': 'json',
        'text/html': 'html',
        'text/plain': 'txt',
        'text/x-unknown': 'txt',
        'application/xml': 'xml',
        'application/atom+xml': 'xml',
        'image/jpeg': 'jpg',
        'image/png': 'png',
        'image/svg+xml': 'svg',
        'application/pdf': 'pdf',
        'application/zip': 'zip',
        'text/csv': 'csv',
        'application/javascript': 'js',
        'application/octet-stream': 'bin',
        '': 'bin',
      };
      cases.forEach((type, ext) {
        expect(extensionForContentType(type), ext, reason: type);
      });
      expect(extensionForContentType(null), 'bin');
      expect(extensionForContentType('IMAGE/PNG'), 'png');
    });

    test('sizes are formatted for people', () {
      expect(formatByteSize(512), '512 B');
      expect(formatByteSize(1536), '1.5 KB');
      expect(formatByteSize(5 * 1024 * 1024), '5.00 MB');
    });
  });

  group('hex view', () {
    test('rows have an offset, hex and ASCII column', () {
      final bytes = [...ascii.encode('HTTP/1.1'), 0, 0x7f, 0xff, 0x41];
      final r = formatHexRow(bytes, 0, 16);
      expect(r.offset, '000000');
      expect(r.hex.startsWith('48 54 54 50 2f 31 2e 31  00 7f ff 41'), isTrue);
      expect(r.hex.length, 48); // padded so columns line up
      expect(r.ascii, 'HTTP/1.1...A');
    });

    test('rows follow the offset and the width', () {
      final bytes = List.generate(40, (i) => 0x30 + i % 10);
      expect(formatHexRow(bytes, 16, 16).offset, '000010');
      expect(
        formatHexRow(bytes, 32, 16).ascii,
        '23456789',
      ); // last, partial row
      final r4 = formatHexRow(bytes, 4, 4);
      expect(r4.offset, '000004');
      expect(r4.hex, '34 35 36 37');
      expect(r4.ascii, '4567');
      // A full row is exactly hexRowChars wide, for every row size.
      for (final n in [16, 8, 4, 2]) {
        final r = formatHexRow(bytes, 0, n);
        expect('${r.offset}  ${r.hex}  ${r.ascii}'.length, hexRowChars(n));
      }
    });

    test('non-printable bytes show as dots', () {
      final r = formatHexRow([0x1f, 0x20, 0x7e, 0x7f, 0x80], 0, 8);
      expect(r.ascii, '. ~..');
    });
  });

  group('find', () {
    test('counts non-overlapping matches', () {
      expect(findMatches('abcabcabc', 'abc').starts, [0, 3, 6]);
      expect(findMatches('aaaa', 'aa').starts, [0, 2]);
      expect(findMatches('hello', 'xyz').starts, isEmpty);
      expect(findMatches('hello', '').starts, isEmpty);
      expect(findMatches('', 'a').starts, isEmpty);
    });

    test('case sensitivity', () {
      const text = 'Alpha alpha ALPHA';
      expect(findMatches(text, 'alpha').starts, [0, 6, 12]);
      expect(findMatches(text, 'alpha', caseSensitive: true).starts, [6]);
      expect(findMatches(text, 'ALPHA', caseSensitive: true).starts, [12]);
    });

    test('offsets stay exact when lower-casing changes the length', () {
      // U+0130 lower-cases to two code units.
      final text = 'İİİ needle';
      expect(findMatches(text, 'needle').starts, [4]);
      expect(text.substring(4), 'needle');
    });

    test('searching stops at the cap', () {
      final r = findMatches('a' * 50, 'a', max: 10);
      expect(r.starts.length, 10);
      expect(r.capped, isTrue);
      expect(findMatches('a' * 10, 'a', max: 10).capped, isFalse);
    });

    test('the controller counts, navigates and wraps', () {
      final c = FindController();
      const text = 'one two one two one';
      c.setText(text);
      c.open();
      c.setQuery('one');
      expect(c.count, 3);
      expect(c.current, 0);
      expect(c.label, '1 of 3');
      c.next();
      expect(c.label, '2 of 3');
      c.next();
      c.next();
      expect(c.label, '1 of 3'); // wrapped
      c.previous();
      expect(c.label, '3 of 3'); // wrapped backwards
      expect(c.currentStart, 16);
      c.setCaseSensitive(true);
      c.setQuery('ONE');
      expect(c.count, 0);
      expect(c.label, 'No results');
      expect(c.current, -1);
      c.next(); // nothing to move to
      expect(c.current, -1);
      c.setQuery('');
      expect(c.label, '');
      c.dispose();
    });

    test('highlights only appear for the text that was searched', () {
      final c = FindController();
      final pretty = '{\n  "a": 1\n}';
      final raw = '{"a":1}';
      c.setText(pretty);
      c.open();
      c.setQuery('a');
      expect(c.matchesFor(pretty), isNotEmpty);
      expect(c.matchesFor(raw), isEmpty);
      c.setText(raw);
      expect(c.matchesFor(pretty), isEmpty);
      expect(c.matchesFor(raw), [2]);
      c.close();
      expect(c.matchesFor(raw), isEmpty);
      // Reopening keeps the query.
      c.open();
      expect(c.query, 'a');
      expect(c.matchesFor(raw), [2]);
      c.dispose();
    });

    test('highlights survive the Pretty text being rebuilt', () {
      // JsonView.displayText caches only its last answer; a second response
      // evicts it, and the next call builds an equal but new string.
      const a = '{"k":"alpha","list":[1,2]}';
      const b = '{"other":true}';
      final first = JsonView.displayText(a);
      final c = FindController()..setText(first);
      c.open();
      c.setQuery('alpha');
      JsonView.displayText(b);
      final again = JsonView.displayText(a);
      expect(identical(first, again), isFalse);
      expect(c.matchesFor(again), isNotEmpty);
      c.setText(again); // no new search for equal text
      expect(c.count, 1);
      c.dispose();
    });

    test('moving the current match changes the navigation stamp', () {
      final c = FindController()..setText('x x x');
      c.open();
      c.setQuery('x');
      final before = c.navStamp;
      c.next();
      expect(c.navStamp, isNot(before));
      c.dispose();
    });

    test('big texts are searched off the UI thread', () async {
      final text = '${'lorem ipsum ' * 30000}needle${' dolor' * 10}needle';
      expect(text.length, greaterThan(findAsyncThreshold));
      final c = FindController()..setText(text);
      c.open();
      final done = Completer<void>();
      void listener() {
        if (!c.busy && c.count > 0 && !done.isCompleted) done.complete();
      }

      c.addListener(listener);
      c.setCaseSensitive(true); // searches once; empty query finds nothing
      c.setQuery('needle');
      expect(c.busy, isTrue);
      expect(c.label, 'Searching…');
      await done.future.timeout(const Duration(seconds: 20));
      expect(c.count, 2);
      expect(c.label, '1 of 2');
      c.removeListener(listener);
      c.dispose();
    });

    test('an older search never overwrites a newer one', () async {
      final text = 'abc ' * 100000;
      final c = FindController()..setText(text);
      c.open();
      final done = Completer<void>();
      c.addListener(() {
        if (c.query == 'zzz' && !c.busy && !done.isCompleted) done.complete();
      });
      c.setQuery('abc');
      // Let the first search start in the background, then replace it.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      c.setQuery('zzz');
      await done.future.timeout(const Duration(seconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(c.query, 'zzz');
      expect(c.count, 0);
      c.dispose();
    });

    test('match highlights split spans exactly', () {
      const style = TextStyle(fontSize: 10);
      final out = overlayMatches(
        [
          const TextSpan(text: 'hello ', style: style),
          const TextSpan(text: 'world'),
        ],
        [0, 6],
        5,
        1,
        matchColor: const Color(0xFF111111),
        currentColor: const Color(0xFF222222),
      );
      expect(out.map((s) => s.text).join(), 'hello world');
      final hl = out.where((s) => s.style?.backgroundColor != null).toList();
      expect(hl.map((s) => s.text), ['hello', 'world']);
      expect(hl[0].style!.backgroundColor, const Color(0xFF111111));
      expect(hl[1].style!.backgroundColor, const Color(0xFF222222)); // current
      expect(hl[0].style!.fontSize, 10); // keeps the base style
    });

    test('a match across two spans is highlighted in both', () {
      final out = overlayMatches(
        [const TextSpan(text: 'ab'), const TextSpan(text: 'cd')],
        [1],
        2,
        0,
        matchColor: const Color(0xFF111111),
        currentColor: const Color(0xFF222222),
      );
      expect(out.map((s) => s.text).toList(), ['a', 'b', 'c', 'd']);
      expect(out.map((s) => s.style?.backgroundColor != null).toList(), [
        false,
        true,
        true,
        false,
      ]);
    });
  });

  group('full body', () {
    test('rows split at line breaks and long lines', () {
      final idx = indexRows('ab\r\ncd\n\nefghij', maxColumns: 4);
      final rows = [for (var i = 0; i < idx.rowCount; i++) idx.rowText(i)];
      expect(rows, ['ab', 'cd', '', 'efgh', 'ij']);
      expect(idx.longestRow, 4);
      expect(idx.rowOf(0), 0);
      expect(idx.rowOf(5), 1); // the "d"
      expect(idx.rowOf(11), 3); // inside "efgh"
      expect(idx.rowOf(13), 4);
      expect(indexRows('').rowCount, 0);
      expect(indexRows('one\n').rowCount, 1);
    });

    test('a surrogate pair is never split across rows', () {
      final idx = indexRows('abc\u{1F600}def', maxColumns: 4);
      for (var i = 0; i < idx.rowCount; i++) {
        final t = idx.rowText(i);
        expect(
          t.runes.every((r) => r != 0xFFFD) && !t.endsWith('\uD83D'),
          isTrue,
          reason: 'row $i: $t',
        );
      }
      expect(
        [for (var i = 0; i < idx.rowCount; i++) idx.rowText(i)].join(),
        'abc\u{1F600}def',
      );
    });

    test('JSON is indented, other text and big JSON is not', () {
      final json = buildFullBody(utf8.encode('{"a":[1,2],"b":{"c":null}}'));
      expect(json.pretty, isNotNull);
      expect(json.pretty!.rowText(0), '{');
      expect(json.pretty!.rowText(1), '  "a": [');
      expect(json.raw.rowCount, 1);
      expect(json.cut, isFalse);
      expect(buildFullBody(utf8.encode('plain text')).pretty, isNull);
      expect(buildFullBody(utf8.encode('{"broken": ')).pretty, isNull);
    });

    test('invalid UTF-8 falls back to Latin-1 like the copy button', () {
      final data = buildFullBody([0x63, 0x61, 0x66, 0xE9]);
      expect(data.raw.text, 'café');
    });

    test(
      'prepareFullBody gives the same answer on or off the isolate',
      () async {
        final big = utf8.encode(
          '{"rows":[${List.filled(80000, '{"id":1,"name":"abc"}').join(',')}]}',
        );
        expect(big.length, greaterThan(1024 * 1024));
        final remote = await prepareFullBody(big);
        final local = buildFullBody(big);
        expect(remote.raw.text.length, local.raw.text.length);
        expect(remote.pretty!.rowCount, local.pretty!.rowCount);
        expect(remote.totalBytes, big.length);
      },
    );
  });

  group('preview tab', () {
    // The sizes the brief asks for: a phone and a desktop.
    const sizes = [Size(360, 640), Size(1280, 800)];
    late List<Uri> launched;

    setUp(() {
      launched = [];
      uriLauncher = (uri) async {
        launched.add(uri);
        return true;
      };
    });

    Future<void> show(WidgetTester tester, ResponseData res, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: DefaultTabController(
              length: 2,
              child: ResponsePreview(response: res),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    for (final size in sizes) {
      final label = '${size.width.toInt()}x${size.height.toInt()}';

      testWidgets('HTML renders without overflow at $label', (tester) async {
        final html = '''
<!doctype html><html><head><title>t</title><style>p{color:red}</style>
<script>document.write("SCRIPT RAN")</script></head>
<body><h1>Welcome page</h1><p>Hello <b>there</b>, this is a long paragraph
that has to wrap on a narrow phone screen without any overflow at all.</p>
<ul><li>one</li><li>two</li></ul>
<img src="https://tracker.example/pixel.png" alt="Banner photo">
<img src="/relative/logo.png" width="1" height="1">
<table><tr><td>a table cell with quite a lot of words in it</td><td>b</td></tr></table>
<a href="https://example.com/next">Next page</a>
</body></html>''';
        await show(
          tester,
          _res(
            utf8.encode(html),
            type: 'text/html',
            url: 'https://example.com/index.html',
          ),
          size,
        );
        expect(tester.takeException(), isNull);
        expect(
          find.textContaining('Welcome page', findRichText: true),
          findsOneWidget,
        );
        // Scripts never run.
        expect(
          find.textContaining('SCRIPT RAN', findRichText: true),
          findsNothing,
        );
        // Remote pictures are held back until asked for.
        expect(find.text('Banner photo'), findsOneWidget);
        final toggle = tester.widget<Switch>(find.byType(Switch));
        expect(toggle.value, isFalse);
        expect(find.text('Open in browser'), findsOneWidget);
        expect(find.text('Load remote images'), findsOneWidget);
      });

      testWidgets('a PNG renders with its size at $label', (tester) async {
        final png = makePng(48, 32);
        await show(tester, _res(png, type: 'image/png'), size);
        await tester.runAsync(() async {
          final ctx = tester.element(find.byType(Image));
          await precacheImage(MemoryImage(png), ctx);
        });
        await tester.pump(const Duration(milliseconds: 50));
        expect(tester.takeException(), isNull);
        expect(find.byType(Image), findsOneWidget);
        expect(find.byType(InteractiveViewer), findsOneWidget);
        expect(find.text('PNG image'), findsOneWidget);
        expect(find.text('48 × 32 px'), findsOneWidget);
        expect(find.text(formatByteSize(png.length)), findsOneWidget);
      });

      testWidgets('an SVG renders at $label', (tester) async {
        await show(
          tester,
          _res(utf8.encode(_svg), type: 'image/svg+xml'),
          size,
        );
        expect(tester.takeException(), isNull);
        expect(find.text('SVG image'), findsOneWidget);
        expect(find.byType(InteractiveViewer), findsOneWidget);
      });

      testWidgets('binary data gets a hex view at $label', (tester) async {
        final bytes = Uint8List.fromList(
          List.generate(5000, (i) => i * 7 % 256),
        );
        await show(tester, _res(bytes, type: 'application/octet-stream'), size);
        expect(tester.takeException(), isNull);
        expect(find.text('Binary data'), findsOneWidget);
        expect(
          find.textContaining('000000', findRichText: true),
          findsOneWidget,
        );
        // It is virtualized: far rows are not built.
        final rows = tester.widgetList(find.byType(RichText)).length;
        expect(rows, lessThan(80));
      });

      testWidgets('a PDF shows a card at $label', (tester) async {
        final pdf = latin1.encode(
          '%PDF-1.4\n1 0 obj << /Type /Pages /Count 7 >> endobj\n%%EOF',
        );
        await show(tester, _res(pdf, type: 'application/pdf'), size);
        expect(tester.takeException(), isNull);
        expect(find.text('PDF document'), findsOneWidget);
        expect(find.textContaining('7 pages'), findsOneWidget);
        expect(find.text('Open in viewer'), findsOneWidget);
        expect(find.text('Save'), findsOneWidget);
      });

      testWidgets('text and JSON point to Pretty and Raw at $label', (
        tester,
      ) async {
        await show(
          tester,
          _res(utf8.encode('{"a":1}'), type: 'application/json'),
          size,
        );
        expect(tester.takeException(), isNull);
        expect(find.textContaining('nothing to render'), findsOneWidget);
        expect(find.text('Open Pretty'), findsOneWidget);
        expect(find.text('Open Raw'), findsOneWidget);
      });
    }

    testWidgets('a hex view is capped at 1 MB with a note', (tester) async {
      final big = Uint8List(hexViewLimit + hexViewLimit ~/ 2);
      for (var i = 0; i < big.length; i++) {
        big[i] = i % 251;
      }
      await show(
        tester,
        _res(big, type: 'application/octet-stream'),
        sizes.last,
      );
      expect(tester.takeException(), isNull);
      expect(
        find.textContaining('Showing the first 1.00 MB of 1.50 MB'),
        findsOneWidget,
      );
      final list = tester.widget<ListView>(find.byType(ListView));
      // 16 bytes a row on a wide pane, and never more than the cap.
      expect(list.childrenDelegate.estimatedChildCount, hexViewLimit ~/ 16);
    });

    for (final kind in ['html', 'png', 'svg', 'binary']) {
      testWidgets('a very short pane scrolls instead of overflowing ($kind)', (
        tester,
      ) async {
        final res = switch (kind) {
          'html' => _res(
            utf8.encode('<h1>Short</h1><p>Hello</p>'),
            type: 'text/html',
          ),
          'png' => _res(makePng(8, 8), type: 'image/png'),
          'svg' => _res(utf8.encode(_svg), type: 'image/svg+xml'),
          _ => _res(Uint8List(300), type: 'application/octet-stream'),
        };
        await show(tester, res, const Size(320, 150));
        expect(tester.takeException(), isNull);
        expect(find.byType(SingleChildScrollView), findsWidgets);
      });
    }

    testWidgets('an empty body says so', (tester) async {
      await show(tester, _res(const [], type: 'text/plain'), sizes.first);
      expect(find.text('The response has no body.'), findsOneWidget);
    });

    testWidgets('Open in browser writes a temp file with a base tag', (
      tester,
    ) async {
      await show(
        tester,
        _res(
          utf8.encode('<html><head></head><body>hi</body></html>'),
          type: 'text/html',
          url: 'https://example.com/a/b.html',
        ),
        sizes.last,
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('Open in browser'));
        for (var i = 0; i < 100 && launched.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(launched, hasLength(1));
      expect(launched.single.scheme, 'file');
      final file = File.fromUri(launched.single);
      expect(file.path, endsWith('.html'));
      expect(
        file.readAsStringSync(),
        contains('<base href="https://example.com/a/b.html">'),
      );
      file.deleteSync();
    });

    testWidgets('links open on the web only', (tester) async {
      await show(
        tester,
        _res(
          utf8.encode('<p><a href="https://example.com/x">web</a></p>'),
          type: 'text/html',
        ),
        sizes.last,
      );
      final onTap = tester
          .widget<HtmlWidget>(find.byType(HtmlWidget))
          .onTapUrl!;
      // Every tap is handled, but only web and mail links leave the app.
      for (final url in [
        'https://example.com/x',
        'file:///etc/passwd',
        'javascript:alert(1)',
        'mailto:me@example.com',
        'content://contacts/people',
      ]) {
        expect(await onTap(url), isTrue);
      }
      expect(launched.map((u) => u.toString()), [
        'https://example.com/x',
        'mailto:me@example.com',
      ]);
    });

    testWidgets('Open Raw switches the tab', (tester) async {
      tester.view.physicalSize = sizes.first;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late TabController tabs;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: DefaultTabController(
              length: 3,
              initialIndex: 2,
              child: Builder(
                builder: (context) {
                  tabs = DefaultTabController.of(context);
                  return ResponsePreview(
                    response: _res(utf8.encode('plain'), type: 'text/plain'),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open Raw'));
      await tester.pump();
      expect(tabs.index, 1);
    });
  });

  group('response view', () {
    late Directory dir;
    late AppState state;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('aw_response_tools_');
    });

    Future<RequestTab> pump(
      WidgetTester tester,
      ResponseData res,
      Size size,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        state = AppState(storage: Storage(overrideDir: dir));
        while (!state.loaded) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      final tab = RequestTab(request: RequestModel(name: 'Demo'))
        ..response = res;
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            theme: buildTheme(),
            home: Scaffold(body: ResponseView(tab: tab)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tab;
    }

    tearDown(() async {
      Palette.use(PaletteData.tealLight);
      state.dispose();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    final jsonRes = _res(
      utf8.encode('{"name":"Ada","tags":["alpha","beta","Alpha"],"n":42}'),
      type: 'application/json',
    );

    final fieldFinder = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == 'Find in body',
    );

    /// Background-highlighted pieces of the (single) selectable body text.
    List<TextSpan> highlights(WidgetTester tester) {
      final text = tester.widget<SelectableText>(
        find.byType(SelectableText).first,
      );
      final out = <TextSpan>[];
      text.textSpan!.visitChildren((s) {
        if (s is TextSpan && s.style?.backgroundColor != null) out.add(s);
        return true;
      });
      return out;
    }

    for (final size in const [Size(360, 640), Size(1280, 800)]) {
      final label = '${size.width.toInt()}x${size.height.toInt()}';

      testWidgets('the find bar flow works at $label', (tester) async {
        await pump(tester, jsonRes, size);
        expect(fieldFinder, findsNothing);

        await tester.tap(find.byIcon(Icons.search));
        await tester.pumpAndSettle();
        expect(fieldFinder, findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.enterText(fieldFinder, 'alpha');
        await tester.pump();
        // Case-insensitive by default: "alpha" and "Alpha".
        expect(find.text('1 of 2'), findsOneWidget);
        var hl = highlights(tester);
        expect(hl.map((s) => s.text), ['alpha', 'Alpha']);
        // Exactly one is the emphasised current match.
        expect(
          hl.where((s) => s.style!.backgroundColor == findCurrentColor).length,
          1,
        );
        expect(hl.first.style!.backgroundColor, findCurrentColor);

        await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
        await tester.pump();
        expect(find.text('2 of 2'), findsOneWidget);
        expect(
          highlights(tester).last.style!.backgroundColor,
          findCurrentColor,
        );
        await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
        await tester.pump();
        expect(find.text('1 of 2'), findsOneWidget); // wraps
        await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
        await tester.pump();
        expect(find.text('2 of 2'), findsOneWidget);

        // Match case.
        await tester.tap(find.text('Aa'));
        await tester.pump();
        expect(find.text('1 of 1'), findsOneWidget);
        expect(highlights(tester).single.text, 'alpha');
        await tester.enterText(fieldFinder, 'ALPHA');
        await tester.pump();
        expect(find.text('No results'), findsOneWidget);
        expect(highlights(tester), isEmpty);
        await tester.tap(find.text('Aa'));
        await tester.pump();
        expect(find.text('1 of 2'), findsOneWidget);

        // Escape closes the bar and clears the highlights.
        await tester.tap(fieldFinder);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(fieldFinder, findsNothing);
        expect(highlights(tester), isEmpty);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('Enter and Shift+Enter move between matches', (tester) async {
      await pump(tester, jsonRes, const Size(1280, 800));
      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      await tester.enterText(fieldFinder, 'a');
      await tester.pump();
      final total = RegExp(
        'a',
        caseSensitive: false,
      ).allMatches(JsonView.displayText(jsonRes.bodyPreview)).length;
      expect(find.text('1 of $total'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.text('2 of $total'), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(find.text('1 of $total'), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(find.text('$total of $total'), findsOneWidget); // wrapped back
    });

    testWidgets('Ctrl+F opens the bar, and it follows the Raw tab', (
      tester,
    ) async {
      await pump(tester, jsonRes, const Size(1280, 800));
      await tester.tap(find.byType(SelectableText).first); // focus the pane
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(fieldFinder, findsOneWidget);

      await tester.enterText(fieldFinder, '"name"');
      await tester.pump();
      expect(find.text('1 of 1'), findsOneWidget);

      // Raw is a different text (not indented); the bar searches it too.
      await tester.tap(find.text('Raw'));
      await tester.pumpAndSettle();
      expect(fieldFinder, findsOneWidget);
      expect(find.text('1 of 1'), findsOneWidget);
      expect(highlights(tester).single.text, '"name"');

      // Other tabs have nothing to search: the bar steps aside.
      await tester.tap(find.textContaining('Headers'));
      await tester.pumpAndSettle();
      expect(fieldFinder, findsNothing);
      // Ctrl+F from there goes back to Pretty with the bar open.
      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      expect(fieldFinder, findsOneWidget);
      expect(find.text('1 of 1'), findsOneWidget);
    });

    testWidgets('long bodies scroll to the current match', (tester) async {
      final lines = [for (var i = 0; i < 1500; i++) 'line $i of the response'];
      lines[1400] = 'the unique-marker is here';
      // Under the 64 KB preview limit, so it is one scrolling text.
      final body = lines.join('\n');
      expect(body.length, lessThan(ResponseData.previewByteLimit));
      await pump(
        tester,
        _res(utf8.encode(body), type: 'text/plain'),
        const Size(1280, 800),
      );
      await tester.tap(find.text('Raw'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      await tester.enterText(fieldFinder, 'unique-marker');
      await tester.pumpAndSettle();
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(FindScroll),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(scroll.position.pixels, greaterThan(1000));
      expect(
        scroll.position.pixels,
        lessThanOrEqualTo(scroll.position.maxScrollExtent),
      );
    });

    final bigText = [
      for (var i = 0; i < 6000; i++) 'row $i: ${'x' * 20}',
    ].join('\n');

    testWidgets('a cut-off preview offers the full body', (tester) async {
      expect(bigText.length, greaterThan(ResponseData.previewByteLimit));
      final needle = '$bigText\nthe-final-needle';
      await pump(
        tester,
        _res(utf8.encode(needle), type: 'text/plain'),
        const Size(1280, 800),
      );
      expect(find.textContaining('Preview limited'), findsOneWidget);
      expect(find.text('Show full body'), findsOneWidget);
      // The text itself is cut at 64 KB.
      await tester.tap(find.text('Raw'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('the-final-needle', findRichText: true),
        findsNothing,
      );

      await tester.tap(find.text('Show full body'));
      await tester.pumpAndSettle();
      expect(find.byType(LargeTextView), findsOneWidget);
      expect(find.textContaining('Showing the full body'), findsOneWidget);
      expect(find.text('Back to preview'), findsOneWidget);

      // Find reaches past the preview and scrolls there.
      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      await tester.enterText(fieldFinder, 'the-final-needle');
      await tester.pumpAndSettle();
      expect(find.text('1 of 1'), findsOneWidget);
      final inRows = find.descendant(
        of: find.byType(LargeTextView),
        matching: find.textContaining('the-final-needle', findRichText: true),
      );
      expect(inRows, findsOneWidget);
      final row = tester.widget<RichText>(
        find.byWidgetPredicate(
          (w) =>
              w is RichText &&
              w.text.toPlainText().contains('the-final-needle'),
        ),
      );
      final marked = <String>[];
      row.text.visitChildren((s) {
        if (s is TextSpan && s.style?.backgroundColor == findCurrentColor) {
          marked.add(s.text!);
        }
        return true;
      });
      expect(marked, ['the-final-needle']);
      expect(tester.takeException(), isNull);

      // The Pretty tab shows the same full text (not JSON, so un-indented).
      await tester.tap(find.text('Pretty'));
      await tester.pumpAndSettle();
      expect(find.byType(LargeTextView), findsOneWidget);
      expect(inRows, findsOneWidget);

      await tester.tap(find.text('Back to preview'));
      await tester.pumpAndSettle();
      expect(find.byType(LargeTextView), findsNothing);
      expect(find.text('No results'), findsOneWidget);
    });

    testWidgets('the full body view fits a phone', (tester) async {
      await pump(
        tester,
        _res(utf8.encode(bigText), type: 'text/plain'),
        const Size(320, 568),
      );
      expect(find.textContaining('Preview limited'), findsOneWidget);
      await tester.tap(find.text('Show full body'));
      await tester.pumpAndSettle();
      expect(find.byType(LargeTextView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('JSON in the full body is indented and coloured', (
      tester,
    ) async {
      final json = jsonEncode({
        'items': [
          for (var i = 0; i < 2500; i++) {'id': i, 'label': 'item number $i'},
        ],
        'last': 'the-end',
      });
      expect(json.length, greaterThan(ResponseData.previewByteLimit));
      await pump(
        tester,
        _res(utf8.encode(json), type: 'application/json'),
        const Size(1280, 800),
      );
      await tester.tap(find.text('Show full body'));
      await tester.pumpAndSettle();
      final view = tester.widget<LargeTextView>(find.byType(LargeTextView));
      expect(view.colourJson, isTrue);
      expect(view.index.rowCount, greaterThan(9000)); // one field per row
      expect(find.textContaining('"items": ['), findsOneWidget);
    });

    testWidgets('a body over 5 MB asks first', (tester) async {
      final big = Uint8List(5 * 1024 * 1024 + 10)
        ..fillRange(0, 5 * 1024 * 1024 + 10, 0x61);
      await pump(tester, _res(big, type: 'text/plain'), const Size(1280, 800));
      expect(
        find.textContaining('Showing all of it can be slow'),
        findsOneWidget,
      );
      await tester.tap(find.text('Show full body'));
      await tester.pumpAndSettle();
      expect(find.text('Show the full body?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(LargeTextView), findsNothing);
      expect(find.text('Show full body'), findsOneWidget);

      await tester.tap(find.text('Show full body'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Show anyway'));
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      for (
        var i = 0;
        i < 100 && find.byType(LargeTextView).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(find.byType(LargeTextView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'the status bar keeps its actions and folds the rest on phones',
      (tester) async {
        await pump(tester, jsonRes, const Size(1280, 800));
        for (final tip in [
          'Save response body to a file',
          'Save as example',
          'Copy body',
        ]) {
          expect(find.byTooltip(tip), findsOneWidget, reason: tip);
        }
        expect(find.byIcon(Icons.search), findsOneWidget);
        expect(find.byTooltip('More response actions'), findsNothing);
      },
    );

    testWidgets('on a phone the rarer actions move into a menu', (
      tester,
    ) async {
      await pump(tester, jsonRes, const Size(360, 640));
      expect(find.byTooltip('Save response body to a file'), findsOneWidget);
      expect(find.byTooltip('Copy body'), findsOneWidget);
      expect(find.byTooltip('Save as example'), findsNothing);
      await tester.tap(find.byTooltip('More response actions'));
      await tester.pumpAndSettle();
      expect(find.text('Save as example'), findsOneWidget);
      expect(find.text('Save as Markdown doc'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the Preview tab shows an HTML body inside the pane', (
      tester,
    ) async {
      await pump(
        tester,
        _res(utf8.encode('<h1>Hello preview</h1>'), type: 'text/html'),
        const Size(360, 640),
      );
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Hello preview', findRichText: true),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a 320 px pane with the find bar open has no overflow', (
      tester,
    ) async {
      await pump(tester, jsonRes, const Size(320, 568));
      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      await tester.enterText(fieldFinder, 'alpha');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Aa'), findsOneWidget);
    });
  });
}
