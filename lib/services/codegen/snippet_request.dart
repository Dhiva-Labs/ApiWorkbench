import 'dart:convert';

import '../../models/models.dart';
import '../auth/auth.dart';
import '../request_builder.dart';

/// One name/value pair of a form body. For a multipart file part [value] is
/// the local path of the file to upload.
class SnippetField {
  const SnippetField(this.name, this.value, {this.isFile = false});

  final String name;
  final String value;
  final bool isFile;

  /// Last path segment of a file part, used as the upload's file name.
  String get fileName {
    final i = value.lastIndexOf(RegExp(r'[/\\]'));
    return i < 0 ? value : value.substring(i + 1);
  }
}

/// The body of a snippet, in the shape each language wants it.
sealed class SnippetBody {
  const SnippetBody();
}

/// No body is sent.
final class NoBody extends SnippetBody {
  const NoBody();
}

/// A text body (JSON, XML, plain text or a GraphQL envelope), exactly as it
/// goes on the wire.
final class RawBody extends SnippetBody {
  const RawBody(this.text);
  final String text;
}

/// `application/x-www-form-urlencoded`: [fields] to build it from, and the
/// finished [encoded] string for languages without a form builder.
final class UrlEncodedBody extends SnippetBody {
  const UrlEncodedBody(this.fields, this.encoded);
  final List<SnippetField> fields;
  final String encoded;
}

/// `multipart/form-data` made of text and file parts. The boundary is left to
/// the target library.
final class MultipartBody extends SnippetBody {
  const MultipartBody(this.fields);
  final List<SnippetField> fields;
}

/// A binary body read from the file at [path].
final class FileBody extends SnippetBody {
  const FileBody(this.path);
  final String path;
}

/// The scheme, host, port and path of a snippet URL, split as text so that
/// an unresolved `{{host}}` placeholder is fine.
class SnippetUrl {
  const SnippetUrl({
    required this.scheme,
    required this.host,
    required this.port,
    required this.path,
  });

  factory SnippetUrl.parse(String url) {
    final m = RegExp(
      r'^(?:([A-Za-z][A-Za-z0-9+.-]*)://)?([^/?#]*)(.*)$',
    ).firstMatch(url);
    final scheme = (m?.group(1) ?? 'https').toLowerCase();
    var authority = m?.group(2) ?? '';
    var rest = m?.group(3) ?? '';
    final at = authority.lastIndexOf('@');
    if (at >= 0) authority = authority.substring(at + 1);
    var host = authority;
    int? port;
    final ipv6 = RegExp(r'^(\[[^\]]*\])(?::(\d+))?$').firstMatch(authority);
    final plain = RegExp(r'^(.*):(\d+)$').firstMatch(authority);
    if (ipv6 != null) {
      host = ipv6.group(1)!;
      port = int.tryParse(ipv6.group(2) ?? '');
    } else if (plain != null) {
      host = plain.group(1)!;
      port = int.tryParse(plain.group(2)!);
    }
    if (rest.isEmpty || !rest.startsWith('/')) rest = '/$rest';
    return SnippetUrl(scheme: scheme, host: host, port: port, path: rest);
  }

  /// `http` or `https` (anything else is shown as https).
  final String scheme;
  final String host;

  /// The explicit port, or null when the URL has none.
  final int? port;

  /// Path and query, always starting with `/`.
  final String path;

  bool get secure => scheme != 'http';

  /// The port the connection really uses.
  int get effectivePort => port ?? (secure ? 443 : 80);

  /// Host plus an explicit non-default port, as in a Host header.
  String get hostPort {
    final p = port;
    return p == null || p == (secure ? 443 : 80) ? host : '$host:$p';
  }
}

/// A request fully resolved for code generation: variables, path variables
/// and auth are applied, so what a generator prints is what would be sent.
///
/// Text is stored ready to print. In "unresolved" mode `{{name}}`
/// placeholders were swapped for stand-ins while building and are put back
/// here, so generators quote them like any other text.
class SnippetRequest {
  SnippetRequest({
    required this.prepared,
    required this.request,
    required this.method,
    required this.url,
    required this.headers,
    required this.body,
    this.warnings = const [],
  }) : parsedUrl = SnippetUrl.parse(url);

  /// The wire request (method, URL, headers, body bytes) after auth.
  final PreparedRequest prepared;

  /// The request as saved, for anything the wire form lost.
  final RequestModel request;

  /// Upper-case HTTP method.
  final String method;
  final String url;
  final SnippetUrl parsedUrl;

  /// All headers in send order. A multipart Content-Type is left out: its
  /// boundary belongs to the library that builds the body.
  final List<MapEntry<String, String>> headers;
  final SnippetBody body;

  /// Things the user should know about, such as auth that could not be
  /// applied. Shown above the code.
  final List<String> warnings;

  bool get hasBody => body is! NoBody;
  bool get verifySsl => prepared.settings.verifySsl;

  /// First value of header [name] (case-insensitive), or null.
  String? header(String name) {
    final lower = name.toLowerCase();
    for (final h in headers) {
      if (h.key.toLowerCase() == lower) return h.value;
    }
    return null;
  }

  String? get contentType => header('content-type');

  /// The media type without parameters, lower case.
  String? get mediaType => contentType?.split(';').first.trim().toLowerCase();

  /// Headers minus the named ones. With [formType] the default
  /// `application/x-www-form-urlencoded` Content-Type is dropped too, for
  /// libraries that set it themselves.
  List<MapEntry<String, String>> headersWithout({
    Iterable<String> names = const [],
    bool formType = false,
  }) {
    final skip = {for (final n in names) n.toLowerCase()};
    return [
      for (final h in headers)
        if (!skip.contains(h.key.toLowerCase()) &&
            !(formType &&
                h.key.toLowerCase() == 'content-type' &&
                h.value.trim().toLowerCase() ==
                    'application/x-www-form-urlencoded'))
          h,
    ];
  }

  /// One value per header name, repeats joined like an HTTP client would.
  Map<String, String> headerMap({
    Iterable<String> names = const [],
    bool formType = false,
  }) => HeaderList(headersWithout(names: names, formType: formType)).toMap();
}

/// Builds the [SnippetRequest] for [request].
///
/// It mirrors a real send: [buildRequest] with [vars] and [app], then
/// [applyAuth] with the auth [resolveAuth] picks (the request's own, or the
/// folder's or [collection]'s). Nothing touches the network or the disk, so
/// a form file or binary body that does not exist here still produces a
/// snippet.
///
/// With [unresolved] the variables are not substituted: `{{name}}` stays in
/// the output wherever it was written. Each placeholder is swapped for a
/// stand-in word while the request is built (so a host or query value is
/// not percent-encoded) and swapped back afterwards.
///
/// Throws [RequestBuildException] when the request cannot be built, for
/// example when its URL is empty.
Future<SnippetRequest> resolveSnippetRequest(
  RequestModel request,
  Map<String, String> vars, {
  CollectionModel? collection,
  AppSettings? app,
  bool unresolved = false,
}) async {
  final auth = resolveAuth(request, collection);
  final stand = unresolved ? _StandIns.scan(request, auth) : null;
  final use = stand?.vars ?? vars;
  String back(String s) => stand == null ? s : stand.restore(s);

  // Build from a copy without files: a form file or binary body from another
  // machine must not stop the snippet, and the generators take file parts
  // from the model rather than from the encoded bytes.
  final copy = request.clone(sameId: true);
  final method = request.method.toUpperCase();
  final bodyType = request.bodyType;
  String binaryPath = '';
  if (bodyType == BodyType.formData) {
    copy.formFields.removeWhere((f) => f.isFile);
  } else if (bodyType == BodyType.binary) {
    binaryPath = substituteVars(request.body, use).trim();
    copy.bodyType = BodyType.none;
  }

  final p = await buildRequest(copy, use, app: app);
  if (bodyType == BodyType.binary &&
      binaryPath.isNotEmpty &&
      method != 'HEAD' &&
      !p.headers.has('content-type')) {
    p.headers.add('Content-Type', BodyType.binary.contentType!);
  }

  final warnings = <String>[];
  try {
    await applyAuth(
      p,
      auth,
      AuthContext(vars: use, request: request, offline: true),
    );
  } on AuthException catch (e) {
    warnings.add('Auth was not applied: ${e.message}');
  }

  var url = p.url.toString();
  if (stand != null) {
    // buildUrl assumes https:// for a URL without a scheme. For
    // `{{baseUrl}}/users` the scheme is part of the variable, so drop it.
    final written = request.url.trim();
    if (written.startsWith('{{') &&
        !substituteVars(written, use).contains('://') &&
        url.startsWith('https://')) {
      url = url.substring('https://'.length);
    }
  }
  url = back(url);

  final headers = <MapEntry<String, String>>[];
  for (final h in p.headers) {
    if (bodyType == BodyType.formData &&
        h.key.toLowerCase() == 'content-type') {
      continue;
    }
    headers.add(MapEntry(back(h.key), _restoreHeader(h, stand)));
  }

  final SnippetBody body;
  if (method == 'HEAD' || bodyType == BodyType.none) {
    body = const NoBody();
  } else if (bodyType == BodyType.binary) {
    body = binaryPath.isEmpty ? const NoBody() : FileBody(back(binaryPath));
  } else if (bodyType == BodyType.formData) {
    body = MultipartBody(_fields(request, use, back, files: true));
  } else if (bodyType == BodyType.formUrlEncoded) {
    final fields = _fields(request, use, back, files: false);
    body = fields.isEmpty
        ? const NoBody()
        : UrlEncodedBody(fields, back(p.bodyText));
  } else {
    final text = back(p.bodyText);
    body = text.isEmpty ? const NoBody() : RawBody(text);
  }

  return SnippetRequest(
    prepared: p,
    request: request,
    method: method,
    url: url,
    headers: headers,
    body: body,
    warnings: warnings,
  );
}

List<SnippetField> _fields(
  RequestModel r,
  Map<String, String> vars,
  String Function(String) back, {
  required bool files,
}) => [
  for (final f in r.formFields.where((f) => f.enabled && f.key.isNotEmpty))
    if (!(f.isFile && substituteVars(f.value, vars).isEmpty))
      SnippetField(
        back(substituteVars(f.key, vars)),
        back(substituteVars(f.value, vars)),
        isFile: files && f.isFile,
      ),
];

/// A Basic header holds base64 of `user:pass`; with stand-ins in it the
/// placeholders would be unreadable, so show what it is built from.
String _restoreHeader(MapEntry<String, String> h, _StandIns? stand) {
  if (stand == null) return h.value;
  if (h.key.toLowerCase() == 'authorization' && h.value.startsWith('Basic ')) {
    try {
      final plain = utf8.decode(base64Decode(h.value.substring(6).trim()));
      final shown = stand.restore(plain);
      if (shown != plain) return 'Basic base64($shown)';
    } on FormatException {
      // Not base64: fall through.
    }
  }
  return stand.restore(h.value);
}

/// Stand-in words for `{{placeholders}}` while a request is built unresolved.
/// They are plain lower-case letters and digits, so URL building and
/// percent-encoding leave them alone and they are easy to find again.
class _StandIns {
  _StandIns._(this.vars, this._back);

  factory _StandIns.scan(RequestModel r, AuthConfig auth) {
    final text = jsonEncode(r.toJson()) + jsonEncode(auth.toJson());
    final names = <String>[];
    for (final m in RegExp(r'\{\{([^{}]+)\}\}').allMatches(text)) {
      final name = m.group(1)!.trim();
      if (!names.contains(name)) names.add(name);
    }
    final vars = <String, String>{};
    final back = <String, String>{};
    for (var i = 0; i < names.length; i++) {
      final word = 'zzawvar${i}zz';
      vars[names[i]] = word;
      back[word] = '{{${names[i]}}}';
    }
    return _StandIns._(vars, back);
  }

  final Map<String, String> vars;
  final Map<String, String> _back;

  String restore(String s) {
    var out = s;
    _back.forEach((word, placeholder) {
      out = out.replaceAll(word, placeholder);
    });
    return out;
  }
}
