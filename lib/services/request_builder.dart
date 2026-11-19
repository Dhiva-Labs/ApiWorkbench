import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart' show FormData, MultipartFile;
import 'package:path/path.dart' as p;

import '../models/models.dart';
import 'dynamic_vars.dart';
import 'prepared_request.dart';

export 'prepared_request.dart';

/// Replaces {{variable}} placeholders using [vars], then Postman-style
/// dynamic variables such as {{$guid}}. Unknown names are left as-is.
String substituteVars(String input, Map<String, String> vars) {
  if (!input.contains('{{')) return input;
  return input.replaceAllMapped(RegExp(r'\{\{([^{}]+)\}\}'), (m) {
    final name = m.group(1)!.trim();
    return vars[name] ??
        (name.startsWith(r'$') ? dynamicVariable(name) : null) ??
        m.group(0)!;
  });
}

/// Builds the wire request for [r]: variables, path variables, params,
/// headers and the serialized body. Auth is applied separately (see
/// `applyAuth`), cookies and redirects by the HTTP service.
///
/// Throws [RequestBuildException] with a readable message.
Future<PreparedRequest> buildRequest(
  RequestModel r,
  Map<String, String> vars, {
  AppSettings? app,
}) async {
  final settings = ResolvedSettings.of(r.settings, app ?? AppSettings());
  final url = buildUrl(r, vars, encode: settings.encodeUrl);

  final headers = HeaderList();
  for (final h in r.headers.where((h) => h.enabled && h.key.isNotEmpty)) {
    headers.add(substituteVars(h.key, vars), substituteVars(h.value, vars));
  }

  final method = r.method.toUpperCase();
  Uint8List? body;
  // Like Postman, GET sends a body when one is set; HEAD never does.
  if (r.bodyType != BodyType.none && method != 'HEAD') {
    final ct = r.bodyType.contentType;
    if (ct != null && !headers.has('content-type')) {
      headers.add('Content-Type', ct);
    }
    switch (r.bodyType) {
      case BodyType.formData:
        // The boundary is generated here; a hand-set multipart Content-Type
        // (common in Postman exports) would not match it.
        headers.remove('content-type');
        final form = FormData();
        for (final f in r.formFields.where(
          (f) => f.enabled && f.key.isNotEmpty,
        )) {
          final key = substituteVars(f.key, vars);
          final value = substituteVars(f.value, vars);
          if (f.isFile) {
            if (value.isEmpty) continue;
            final path = _readablePath(value, 'Form file');
            if (!File(path).existsSync()) {
              throw RequestBuildException('Form file not found: $value');
            }
            form.files.add(MapEntry(key, await MultipartFile.fromFile(path)));
          } else {
            form.fields.add(MapEntry(key, value));
          }
        }
        headers.add(
          'Content-Type',
          'multipart/form-data; boundary=${form.boundary}',
        );
        body = await form.readAsBytes();
      case BodyType.binary:
        final path = substituteVars(r.body, vars).trim();
        if (path.isNotEmpty) {
          final file = File(_readablePath(path, 'Body file'));
          if (!file.existsSync()) {
            throw RequestBuildException('Body file not found: $path');
          }
          body = await file.readAsBytes();
        }
      case BodyType.formUrlEncoded:
        body = utf8.encode(
          r.formFields
              .where((f) => f.enabled && f.key.isNotEmpty)
              .map(
                (f) =>
                    '${Uri.encodeQueryComponent(substituteVars(f.key, vars))}='
                    '${Uri.encodeQueryComponent(substituteVars(f.value, vars))}',
              )
              .join('&'),
        );
      case BodyType.graphql:
        Object? gqlVars;
        final rawVars = substituteVars(r.graphqlVariables, vars).trim();
        if (rawVars.isNotEmpty) {
          try {
            gqlVars = jsonDecode(rawVars);
          } catch (e) {
            throw RequestBuildException(
              'GraphQL variables are not valid JSON: $e',
            );
          }
        }
        body = utf8.encode(
          jsonEncode({
            'query': substituteVars(r.body, vars),
            'variables': ?gqlVars,
          }),
        );
      case BodyType.json || BodyType.text || BodyType.xml:
        body = utf8.encode(substituteVars(r.body, vars));
      case BodyType.none:
        break;
    }
  }

  return PreparedRequest(
    method: method,
    url: url,
    headers: headers,
    body: body,
    settings: settings,
  );
}

/// Which local files request bodies (form files, binary bodies) may read.
///
/// The app runs without one: its file fields hold files the user picked,
/// and imports never bring file paths along. The command line runs a
/// collection from a file under a policy (see [run]): relative paths
/// resolve against [workingDir], and files outside it are refused unless
/// [allowOutside] is set.
class FileReadPolicy {
  FileReadPolicy(String workingDir, {this.allowOutside = false})
    : workingDir = p.normalize(p.absolute(workingDir));

  final String workingDir;
  final bool allowOutside;

  static final _zoneKey = Object();

  /// The policy [run] set for the code running now, or null.
  static FileReadPolicy? get current =>
      Zone.current[_zoneKey] as FileReadPolicy?;

  /// Runs [body] with this policy applied to every request it builds,
  /// including in what it awaits.
  R run<R>(R Function() body) => runZoned(body, zoneValues: {_zoneKey: this});

  /// [path] resolved against [workingDir]. Throws [RequestBuildException]
  /// when it lies outside it (after following symbolic links) and that is
  /// not allowed.
  String resolve(String path, String what) {
    final full = p.normalize(p.join(workingDir, path));
    if (allowOutside) return full;
    if (p.isWithin(workingDir, full)) {
      // A link inside the folder may still point outside it.
      final real = _real(full);
      if (real == null || p.isWithin(_real(workingDir) ?? workingDir, real)) {
        return full;
      }
    }
    throw RequestBuildException(
      '$what $path is outside the working directory $workingDir. Move it '
      'there, choose another --working-dir, or allow it with '
      '--insecure-file-read.',
    );
  }

  /// [path] with symbolic links resolved, or null when it does not exist.
  static String? _real(String path) {
    try {
      return File(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      return null;
    }
  }
}

/// [path] as it may be read under the current [FileReadPolicy].
String _readablePath(String path, String what) =>
    FileReadPolicy.current?.resolve(path, what) ?? path;

/// The request URL with variables, path variables and enabled param rows
/// applied. A missing scheme means https.
Uri buildUrl(RequestModel r, Map<String, String> vars, {bool encode = true}) {
  var raw = substituteVars(r.url.trim(), vars);
  if (raw.isEmpty) throw RequestBuildException('Request URL is empty.');
  if (!raw.contains('://')) raw = 'https://$raw';

  var fragment = '';
  final hash = raw.indexOf('#');
  if (hash >= 0) {
    fragment = raw.substring(hash);
    raw = raw.substring(0, hash);
  }

  raw = applyPathVariables(raw, r.pathVariables, vars, encode: encode);

  final rows = [
    for (final p in r.params.where((p) => p.enabled && p.key.isNotEmpty))
      '${_param(substituteVars(p.key, vars), encode)}='
          '${_param(substituteVars(p.value, vars), encode)}',
  ];
  if (rows.isNotEmpty) {
    final q = raw.indexOf('?');
    final sep = q < 0
        ? '?'
        : (raw.endsWith('?') || raw.endsWith('&') ? '' : '&');
    raw = '$raw$sep${rows.join('&')}';
  }

  try {
    final uri = Uri.parse('$raw$fragment');
    if (uri.host.isEmpty) throw const FormatException('no host');
    return uri;
  } on FormatException catch (e) {
    throw RequestBuildException('Invalid URL: ${e.message}');
  }
}

/// Replaces `:name` segments of [url] with their values. Empty values leave
/// the segment as typed, like Postman.
String applyPathVariables(
  String url,
  List<KV> pathVariables,
  Map<String, String> vars, {
  bool encode = true,
}) {
  if (pathVariables.isEmpty) return url;
  final values = {
    for (final v in pathVariables)
      if (v.enabled && v.key.isNotEmpty) v.key: substituteVars(v.value, vars),
  };
  final scheme = url.indexOf('://');
  final pathStart = url.indexOf('/', scheme < 0 ? 0 : scheme + 3);
  if (pathStart < 0) return url;
  final q = url.indexOf('?', pathStart);
  final end = q < 0 ? url.length : q;
  final path = url
      .substring(pathStart, end)
      .split('/')
      .map((seg) {
        if (seg.length < 2 || !seg.startsWith(':')) return seg;
        final v = values[seg.substring(1)];
        if (v == null || v.isEmpty) return seg;
        return encode ? _segment(v) : v;
      })
      .join('/');
  return url.substring(0, pathStart) + path + url.substring(end);
}

final _pctTriplet = RegExp(r'^%[0-9A-Fa-f]{2}');

/// Percent-encodes what a query key or value must not contain raw, keeping
/// `%XX` sequences that are already encoded.
String _param(String s, bool encode) =>
    encode ? _encode(s, "-._~!\$'()*,;:@/?") : s;

String _segment(String s) => _encode(s, "-._~!\$&'()*+,;=:@");

String _encode(String s, String keep) {
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == '%' && _pctTriplet.hasMatch(s.substring(i))) {
      out.write(c);
      continue;
    }
    final code = c.codeUnitAt(0);
    final alnum =
        (code >= 0x30 && code <= 0x39) ||
        (code >= 0x41 && code <= 0x5A) ||
        (code >= 0x61 && code <= 0x7A);
    if (alnum || keep.contains(c)) {
      out.write(c);
    } else {
      // Surrogate pairs are encoded together.
      final isHigh = code >= 0xD800 && code <= 0xDBFF && i + 1 < s.length;
      final chunk = isHigh ? s.substring(i, ++i + 1) : c;
      for (final b in utf8.encode(chunk)) {
        out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
  }
  return out.toString();
}
