import 'dart:convert';

import '../models/models.dart';
import 'http_reason.dart';
import 'import_report.dart';

/// Whether [doc] (decoded JSON) is an HTTP Archive: `{"log": {"entries": []}}`.
bool looksLikeHar(Object? doc) =>
    doc is Map && doc['log'] is Map && (doc['log'] as Map)['entries'] is List;

/// Imports an HTTP Archive (`.har`, exported from a browser's network tab)
/// given as JSON text. One collection, named "HAR import" and the date, holds a request
/// per entry, with the captured response saved as an example on it.
///
/// - [skipStaticAssets] leaves out images, fonts, stylesheets, scripts and
///   media, judged by the browser's resource type, the response MIME type and
///   the file extension.
/// - [dedupe] merges entries that repeat the same request (method, URL, query
///   and body); a repeat whose response differs adds another example to the
///   first.
///
/// Results accumulate into [into]. Throws [FormatException] when the text is
/// not a HAR file or nothing is left to import.
ImportReport importHar(
  String raw, {
  ImportReport? into,
  bool skipStaticAssets = true,
  bool dedupe = true,
  DateTime? now,
}) {
  final Object? json;
  try {
    json = jsonDecode(raw.startsWith('﻿') ? raw.substring(1) : raw);
  } on FormatException {
    throw const FormatException('The file is not valid JSON.');
  }
  return importHarDocument(
    json,
    into: into,
    skipStaticAssets: skipStaticAssets,
    dedupe: dedupe,
    now: now,
  );
}

/// [importHar] for a document that is already decoded.
ImportReport importHarDocument(
  Object? json, {
  ImportReport? into,
  bool skipStaticAssets = true,
  bool dedupe = true,
  DateTime? now,
}) {
  if (!looksLikeHar(json)) {
    throw const FormatException(
      'Not a HAR file: it has no "log" with "entries".',
    );
  }
  final log = (json as Map)['log'] as Map;
  final entries = (log['entries'] as List).whereType<Map>().toList();
  if (entries.isEmpty) {
    throw const FormatException('The HAR file has no entries.');
  }

  final importer = _HarImporter(
    skipStaticAssets: skipStaticAssets,
    dedupe: dedupe,
  );
  try {
    for (final e in entries) {
      importer.add(e);
    }
  } catch (e) {
    // A strange capture must not take the dialog down with a type error.
    throw FormatException('The HAR file could not be read ($e).');
  }
  if (importer.requests.isEmpty) {
    throw FormatException(
      importer.skippedStatic > 0
          ? 'Nothing to import: everything in the capture was a static asset '
                '(images, fonts, CSS, JS). Turn off "Skip static assets" to '
                'import them.'
          : 'The HAR file has no HTTP requests to import.',
    );
  }

  final date = now ?? DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final report = into ?? ImportReport();
  report.formats.add(
    'HAR${'${log['version'] ?? ''}'.isEmpty ? '' : ' ${log['version']}'}',
  );
  report.collections.add(
    CollectionModel(
      name: 'HAR import ${date.year}-${two(date.month)}-${two(date.day)}',
      requests: importer.requests,
    ),
  );
  report.requests += importer.requests.length;
  report.notes.addAll(importer.notes());
  return report;
}

// ---- conversion ---------------------------------------------------------------

/// Headers a client computes itself or that would change how the request
/// is sent (a recorded `Accept-Encoding: br` could make the server answer in
/// a format this app cannot read).
const _computedHeaders = {
  'content-length',
  'host',
  'connection',
  'keep-alive',
  'proxy-connection',
  'transfer-encoding',
  'upgrade',
  'te',
  'accept-encoding',
};

/// Response headers that describe the transfer, not the content.
const _transferHeaders = {
  'content-length',
  'content-encoding',
  'transfer-encoding',
  'connection',
  'keep-alive',
};

const _staticResourceTypes = {
  'image',
  'font',
  'stylesheet',
  'script',
  'media',
  'texttrack',
};

const _staticExtensions = {
  'png', 'jpg', 'jpeg', 'gif', 'webp', 'avif', 'svg', 'ico', 'bmp', 'cur', //
  'tif', 'tiff', 'apng', 'css', 'js', 'mjs', 'cjs', 'map', 'woff', 'woff2',
  'ttf', 'otf', 'eot', 'mp3', 'mp4', 'webm', 'ogg', 'ogv', 'oga', 'wav',
  'm4a', 'm4v', 'mov', 'avi', 'flac', 'aac',
};

const _scriptTypes = {
  'text/javascript',
  'application/javascript',
  'application/x-javascript',
  'application/ecmascript',
  'text/ecmascript',
  'application/wasm',
  'text/css',
};

/// Largest response body kept as an example; bigger ones would slow the
/// workspace down for little use.
const _maxBody = 512 * 1024;

/// Examples kept per request when repeats are merged.
const _maxExamples = 5;

Map _map(Object? v) => v is Map ? v : const {};

class _HarImporter {
  _HarImporter({required this.skipStaticAssets, required this.dedupe});

  final bool skipStaticAssets;
  final bool dedupe;
  final requests = <RequestModel>[];
  final _byKey = <String, RequestModel>{};

  int skippedStatic = 0;
  int skippedOther = 0;
  int duplicates = 0;
  int oversized = 0;

  List<String> notes() => [
    if (skippedStatic > 0)
      'Skipped ${_n(skippedStatic, 'static asset')} (images, fonts, CSS, JS, '
          'media).',
    if (skippedOther > 0)
      'Skipped ${_n(skippedOther, 'non-HTTP entry', 'non-HTTP entries')} '
          '(WebSocket, data: and similar).',
    if (duplicates > 0) 'Merged ${_n(duplicates, 'repeated request')}.',
    if (oversized > 0)
      '${_n(oversized, 'response body', 'response bodies')} over '
          '${_maxBody ~/ 1024} KB ${oversized == 1 ? 'was' : 'were'} not kept.',
    if (requests.any(_carriesCredentials))
      'The capture includes Authorization headers or cookies; they were '
          'imported as recorded.',
  ];

  static String _n(int n, String one, [String? many]) =>
      '$n ${n == 1 ? one : (many ?? '${one}s')}';

  static bool _carriesCredentials(RequestModel m) => m.headers.any(
    (h) =>
        h.key.toLowerCase() == 'authorization' ||
        h.key.toLowerCase() == 'cookie',
  );

  void add(Map entry) {
    final req = _map(entry['request']);
    final resp = _map(entry['response']);
    final url = '${req['url'] ?? ''}';
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) {
      skippedOther++;
      return;
    }
    final method = '${req['method'] ?? 'GET'}'.toUpperCase();
    if (skipStaticAssets && _isStatic(entry, method, url, resp)) {
      skippedStatic++;
      return;
    }

    final m = _request(method, url, req);
    final example = _example(resp);

    if (dedupe) {
      final key = _key(m);
      final first = _byKey[key];
      if (first != null) {
        duplicates++;
        if (example != null &&
            first.examples.length < _maxExamples &&
            !first.examples.any(
              (e) =>
                  e.statusCode == example.statusCode && e.body == example.body,
            )) {
          first.examples.add(example);
        }
        return;
      }
      _byKey[key] = m;
    }
    if (example != null) m.examples.add(example);
    requests.add(m);
  }

  static String _key(RequestModel m) => [
    m.method,
    m.url,
    for (final p in m.params) '${p.key}=${p.value}',
    m.bodyType.name,
    m.body,
    for (final f in m.formFields) '${f.key}=${f.value}',
  ].join('\u0000');

  // -- request --

  RequestModel _request(String method, String url, Map req) {
    var base = url;
    final hash = base.indexOf('#');
    if (hash >= 0) base = base.substring(0, hash);
    final q = base.indexOf('?');
    final rawQuery = q >= 0 ? base.substring(q + 1) : '';
    if (q >= 0) base = base.substring(0, q);

    final m = RequestModel(
      name: '$method ${_pathOf(base)}',
      method: method,
      url: base,
    );

    // queryString holds decoded pairs; the URL is only the fallback.
    final recorded = _list(req['queryString']);
    m.params = recorded.isNotEmpty
        ? [
            for (final p in recorded.whereType<Map>())
              KV(key: '${p['name'] ?? ''}', value: '${p['value'] ?? ''}'),
          ]
        : _parseQuery(rawQuery);

    final cookies = [
      for (final c in _list(req['cookies']).whereType<Map>())
        if ('${c['name'] ?? ''}'.isNotEmpty) '${c['name']}=${c['value'] ?? ''}',
    ];
    for (final h in _list(req['headers']).whereType<Map>()) {
      final name = '${h['name'] ?? ''}'.trim();
      final lower = name.toLowerCase();
      if (name.isEmpty ||
          name.startsWith(':') ||
          _computedHeaders.contains(lower) ||
          (lower == 'cookie' && cookies.isNotEmpty)) {
        continue;
      }
      m.headers.add(KV(key: name, value: '${h['value'] ?? ''}'));
    }
    if (cookies.isNotEmpty) {
      m.headers.add(KV(key: 'Cookie', value: cookies.join('; ')));
    }

    final post = req['postData'];
    if (post is Map) _body(m, post);
    return m;
  }

  static List _list(Object? v) => v is List ? v : const [];

  static String _pathOf(String base) {
    final m = RegExp(
      r'^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]*(/.*)?$',
    ).firstMatch(base);
    final path = m?.group(1) ?? '';
    return path.isEmpty ? '/' : path;
  }

  static List<KV> _parseQuery(String q) => [
    for (final part in q.split('&'))
      if (part.isNotEmpty)
        part.contains('=')
            ? KV(
                key: _decode(part.substring(0, part.indexOf('='))),
                value: _decode(part.substring(part.indexOf('=') + 1)),
              )
            : KV(key: _decode(part)),
  ];

  static String _decode(String s) {
    try {
      return Uri.decodeQueryComponent(s);
    } catch (_) {
      return s;
    }
  }

  // -- body --

  void _body(RequestModel m, Map post) {
    final mime = '${post['mimeType'] ?? ''}';
    final base = mime.split(';').first.trim().toLowerCase();
    final text = post['text'] is String ? post['text'] as String : '';
    final params = _list(post['params']).whereType<Map>().toList();

    if (base == 'application/x-www-form-urlencoded') {
      m.bodyType = BodyType.formUrlEncoded;
      m.formFields = params.isNotEmpty
          ? [
              for (final p in params)
                KV(key: '${p['name'] ?? ''}', value: '${p['value'] ?? ''}'),
            ]
          : _parseQuery(text);
      return;
    }
    if (base.startsWith('multipart/')) {
      m.bodyType = BodyType.formData;
      m.formFields = params.isNotEmpty
          ? [for (final p in params) _formPart(p)]
          : _parseMultipart(text, mime);
      // The boundary is made per request, the recorded one would be wrong.
      m.headers.removeWhere((h) => h.key.toLowerCase() == 'content-type');
      return;
    }
    if (text.isEmpty) {
      if (params.isNotEmpty) {
        m.bodyType = BodyType.formUrlEncoded;
        m.formFields = [
          for (final p in params)
            KV(key: '${p['name'] ?? ''}', value: '${p['value'] ?? ''}'),
        ];
      }
      return;
    }
    m.body = text;
    m.bodyType = base.contains('json')
        ? BodyType.json
        : (base.contains('xml') && !base.contains('html')
              ? BodyType.xml
              : BodyType.text);
    final hasType = m.headers.any((h) => h.key.toLowerCase() == 'content-type');
    final wanted = m.bodyType.contentType;
    if (!hasType && mime.isNotEmpty && base != wanted) {
      m.headers.add(KV(key: 'Content-Type', value: mime));
    }
  }

  static KV _formPart(Map p) {
    final file = '${p['fileName'] ?? ''}';
    return file.isEmpty
        ? KV(key: '${p['name'] ?? ''}', value: '${p['value'] ?? ''}')
        : KV(
            key: '${p['name'] ?? ''}',
            isFile: true,
            description: 'The capture uploaded "$file"; choose a file to send.',
          );
  }

  /// The fields of a recorded `multipart/form-data` body (Chrome stores the
  /// raw text and no parsed params).
  static List<KV> _parseMultipart(String text, String mime) {
    var boundary = RegExp(
      r'boundary="?([^";]+)"?',
      caseSensitive: false,
    ).firstMatch(mime)?.group(1);
    if (boundary == null) {
      final first = text.split(RegExp(r'\r?\n')).first;
      if (first.startsWith('--') && first.length > 2) {
        boundary = first.substring(2).trim();
      }
    }
    if (boundary == null) return [];
    final fields = <KV>[];
    final parts = text.split('--$boundary');
    for (final part in parts.skip(1)) {
      if (part.startsWith('--')) break; // closing delimiter
      final body = part.replaceFirst(RegExp(r'^\r?\n'), '');
      final split = RegExp(r'\r?\n\r?\n').firstMatch(body);
      if (split == null) continue;
      final head = body.substring(0, split.start);
      var value = body.substring(split.end);
      value = value.replaceFirst(RegExp(r'\r?\n$'), '');
      final name = RegExp(r'name="([^"]*)"').firstMatch(head)?.group(1);
      if (name == null) continue;
      final file = RegExp(r'filename="([^"]*)"').firstMatch(head)?.group(1);
      fields.add(
        file == null
            ? KV(key: name, value: value)
            : KV(
                key: name,
                isFile: true,
                description:
                    'The capture uploaded "$file"; choose a file to send.',
              ),
      );
    }
    return fields;
  }

  // -- static assets --

  static bool _isStatic(Map entry, String method, String url, Map resp) {
    final type = '${entry['_resourceType'] ?? ''}'.toLowerCase();
    if (_staticResourceTypes.contains(type)) return true;
    if (_staticMime(_mimeOf(resp))) return true;
    if (method == 'GET') {
      final path = _pathOf(url.split(RegExp(r'[?#]')).first);
      final name = path.split('/').last;
      final dot = name.lastIndexOf('.');
      if (dot >= 0 &&
          _staticExtensions.contains(name.substring(dot + 1).toLowerCase())) {
        return true;
      }
    }
    return false;
  }

  static String _mimeOf(Map resp) =>
      '${_map(resp['content'])['mimeType'] ?? ''}'
          .toLowerCase()
          .split(';')
          .first
          .trim();

  static bool _staticMime(String mime) =>
      mime.startsWith('image/') ||
      mime.startsWith('font/') ||
      mime.startsWith('audio/') ||
      mime.startsWith('video/') ||
      (mime.startsWith('application/') && mime.contains('font')) ||
      _scriptTypes.contains(mime);

  /// Content that is not text, so an example cannot hold it.
  static bool _binaryMime(String mime) =>
      (_staticMime(mime) &&
          !_scriptTypes.contains(mime) &&
          mime != 'image/svg+xml') ||
      mime == 'application/wasm' ||
      mime == 'application/octet-stream' ||
      mime == 'application/pdf' ||
      mime == 'application/zip' ||
      mime == 'application/gzip';

  // -- response --

  ResponseExample? _example(Map resp) {
    final raw = resp['status'];
    final status = raw is num ? raw.toInt() : (int.tryParse('$raw') ?? 0);
    if (status <= 0) return null; // blocked or failed: nothing came back
    final reason = '${resp['statusText'] ?? ''}'.trim();
    final statusText = reason.isNotEmpty ? reason : httpReason(status);

    final headers = <KV>[];
    for (final h in _list(resp['headers']).whereType<Map>()) {
      final name = '${h['name'] ?? ''}'.trim();
      if (name.isEmpty ||
          name.startsWith(':') ||
          _transferHeaders.contains(name.toLowerCase())) {
        continue;
      }
      headers.add(KV(key: name, value: '${h['value'] ?? ''}'));
    }
    final content = _map(resp['content']);
    final mime = '${content['mimeType'] ?? ''}';
    // Chrome writes x-unknown when the response did not say.
    if (mime.isNotEmpty &&
        mime != 'x-unknown' &&
        !headers.any((h) => h.key.toLowerCase() == 'content-type')) {
      headers.insert(0, KV(key: 'Content-Type', value: mime));
    }

    return ResponseExample(
      name: '$status${statusText.isEmpty ? '' : ' $statusText'}',
      statusCode: status,
      statusText: statusText,
      headers: headers,
      body: _responseBody(content),
    );
  }

  /// The body as text; '' for binary content, which examples do not keep.
  String _responseBody(Map content) {
    final text = content['text'];
    if (text is! String || text.isEmpty) return '';
    if (_binaryMime(_mimeOf({'content': content}))) return '';
    var body = text;
    if ('${content['encoding'] ?? ''}'.toLowerCase() == 'base64') {
      try {
        body = utf8.decode(base64.decode(base64.normalize(text)));
      } on FormatException {
        return ''; // not valid UTF-8 text: binary after all
      }
      if (body.contains('\u0000')) return '';
    }
    if (body.length > _maxBody) {
      oversized++;
      return '';
    }
    return body;
  }
}
