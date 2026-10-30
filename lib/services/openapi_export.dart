import 'dart:convert';

import '../models/models.dart';
import 'http_reason.dart';

/// [c] as an OpenAPI 3.0 document: JSON, or YAML when [yaml] (issue #30).
///
/// What carries over:
/// - `info` from the collection, `servers` from its `baseUrl` variable (or the
///   origin most requests share), folders as tags.
/// - One operation per HTTP request: path variables, params and headers as
///   parameters (rows that are on are `required`, disabled rows are not, so
///   an import gets the same on/off state back), the body as `requestBody`
///   with an example, and saved examples as `responses`.
/// - Bearer, Basic, Digest, API key and OAuth 2.0 auth as `securitySchemes`,
///   with an operation-level `security` where a request differs from the
///   collection.
///
/// Requests that share a method and path become one operation, whose
/// responses collect all their examples. Streaming requests (WebSocket, MQTT,
/// gRPC, ...) have no place in OpenAPI and are skipped.
String buildOpenApiDocument(CollectionModel c, {bool yaml = false}) {
  final doc = openApiDocumentMap(c);
  return yaml
      ? emitYaml(doc)
      : '${const JsonEncoder.withIndent('  ').convert(doc)}\n';
}

/// The document [buildOpenApiDocument] writes, as plain maps and lists.
Map<String, dynamic> openApiDocumentMap(CollectionModel c) =>
    _Exporter(c).build();

// ---- document ---------------------------------------------------------------

/// Methods OpenAPI 3.0 defines; the others go under an `x-` key.
const _oasMethods = {
  'get',
  'put',
  'post',
  'delete',
  'options',
  'head',
  'patch',
  'trace',
};

/// Headers OpenAPI says must not be described as parameters.
const _reservedHeaders = {'authorization', 'content-type', 'accept'};

/// Response headers the transport adds; not worth documenting.
const _transportHeaders = {
  'content-type',
  'content-length',
  'content-encoding',
  'transfer-encoding',
  'connection',
  'date',
  'server',
};

typedef _Requirement = ({String name, List<String> scopes});

String _normName(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[_\-\s]'), '');

class _Exporter {
  _Exporter(this.c) {
    final base = c.variables
        .where((v) => v.key.isNotEmpty && _normName(v.key) == 'baseurl')
        .firstOrNull;
    var value = (base?.value ?? '').trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    baseValue = value;
    serverUrl = value.isNotEmpty ? value : _commonOrigin();
  }

  final CollectionModel c;
  String baseValue = '';
  String serverUrl = '';

  final paths = <String, Map<String, dynamic>>{};
  final tags = <String, Map<String, dynamic>>{};
  final schemes = <String, Map<String, dynamic>>{};
  final _usedIds = <String>{};
  final _accs = <String, _Responses>{};

  Map<String, dynamic> build() {
    // Register the collection's scheme first so it leads the list.
    final globalReq = _requirement(_collectionAuth());
    for (final r in c.requests) {
      if (r.kind == RequestKind.http) _operation(r, globalReq);
    }
    for (final acc in _accs.values) {
      acc.finish();
    }

    return {
      'openapi': '3.0.3',
      'info': {
        'title': c.name.isEmpty ? 'API' : c.name,
        if (c.description.isNotEmpty) 'description': c.description,
        'version': '1.0.0',
      },
      if (serverUrl.isNotEmpty)
        'servers': [
          {'url': serverUrl},
        ],
      if (globalReq != null)
        'security': [
          {globalReq.name: globalReq.scopes},
        ],
      if (tags.isNotEmpty) 'tags': tags.values.toList(),
      'paths': paths,
      if (schemes.isNotEmpty) 'components': {'securitySchemes': schemes},
    };
  }

  /// With no `baseUrl` variable, the origin most absolute URLs start with.
  String _commonOrigin() {
    final counts = <String, int>{};
    for (final r in c.requests) {
      final m = _origin.firstMatch(r.url.trim());
      if (m != null) {
        counts.update(m.group(1)!, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    if (counts.isEmpty) return '';
    return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }

  static final _origin = RegExp(r'^(https?://[^/?#{]+)');

  // -- url --

  /// Splits a request URL into the part after the server (the path), a
  /// different origin when it is not the document's server, and any query
  /// typed into the URL itself.
  ({String? origin, String path, List<KV> query}) _split(String url) {
    var u = url.trim();
    String? origin;
    final lead = RegExp(r'^\{\{\s*([^{}]+?)\s*\}\}').firstMatch(u);
    if (lead != null && _normName(lead.group(1)!) == 'baseurl') {
      u = u.substring(lead.end);
    } else if (baseValue.isNotEmpty && _startsWithBase(u)) {
      u = u.substring(baseValue.length);
    } else {
      final m = _origin.firstMatch(u);
      if (m != null) {
        if (m.group(1) != serverUrl) origin = m.group(1);
        u = u.substring(m.end);
      }
    }
    final hash = u.indexOf('#');
    if (hash >= 0) u = u.substring(0, hash);
    final query = <KV>[];
    final q = u.indexOf('?');
    if (q >= 0) {
      for (final part in u.substring(q + 1).split('&')) {
        if (part.isEmpty) continue;
        final eq = part.indexOf('=');
        query.add(
          eq < 0
              ? KV(key: _decode(part))
              : KV(
                  key: _decode(part.substring(0, eq)),
                  value: _decode(part.substring(eq + 1)),
                ),
        );
      }
      u = u.substring(0, q);
    }
    if (!u.startsWith('/')) u = '/$u';
    return (origin: origin, path: u, query: query);
  }

  bool _startsWithBase(String u) {
    if (!u.startsWith(baseValue)) return false;
    if (u.length == baseValue.length) return true;
    return '/?#'.contains(u[baseValue.length]);
  }

  static String _decode(String s) {
    try {
      return Uri.decodeQueryComponent(s);
    } catch (_) {
      return s;
    }
  }

  // -- operations --

  void _operation(RequestModel r, _Requirement? global) {
    final target = _split(r.url);
    final method = r.method.toLowerCase();
    final segments = target.path.split('/');
    bool isParam(String s) => s.length > 1 && s.startsWith(':');
    final names = [
      for (final s in segments)
        if (isParam(s)) s.substring(1),
    ];
    final path = segments
        .map((s) => isParam(s) ? '{${s.substring(1)}}' : s)
        .join('/');
    final key = _oasMethods.contains(method) ? method : 'x-$method';
    final item = paths.putIfAbsent(path, () => {});

    final acc = _accs.putIfAbsent('$path $key', () => _Responses());
    if (item.containsKey(key)) {
      // Same method and path as an earlier request: keep that operation
      // and add this request's examples to it.
      acc.add(r.examples);
      return;
    }

    final tag = r.folder;
    if (tag.isNotEmpty) {
      tags.putIfAbsent(tag, () {
        final d = c.folders[tag]?.description ?? '';
        return {'name': tag, if (d.isNotEmpty) 'description': d};
      });
    }

    final req = _requirement(_effectiveAuth(r));
    final params = _parameters(r, names, target.query);
    final body = (method == 'get' || method == 'head' || method == 'options')
        ? null
        : _requestBody(r);

    item[key] = {
      if (tag.isNotEmpty) 'tags': [tag],
      'summary': r.name,
      if (r.description.isNotEmpty) 'description': r.description,
      'operationId': _operationId(r, method, path),
      if (params.isNotEmpty) 'parameters': params,
      'requestBody': ?body,
      'responses': acc.responses,
      if (!_sameRequirement(req, global))
        'security': req == null
            ? <Object?>[]
            : [
                {req.name: req.scopes},
              ],
      if (target.origin != null)
        'servers': [
          {'url': target.origin},
        ],
    };
    acc.add(r.examples);
  }

  String _operationId(RequestModel r, String method, String path) {
    List<String> words(String s) =>
        RegExp(r'[A-Za-z0-9]+').allMatches(s).map((m) => m.group(0)!).toList();
    var parts = words(r.name == 'Untitled request' ? '' : r.name);
    if (parts.isEmpty) parts = words('$method $path');
    var id = parts.isEmpty
        ? method
        : parts.first.toLowerCase() +
              parts
                  .skip(1)
                  .map((w) => w[0].toUpperCase() + w.substring(1))
                  .join();
    if (RegExp(r'^[0-9]').hasMatch(id)) id = 'op$id';
    var unique = id;
    for (var n = 2; !_usedIds.add(unique); n++) {
      unique = '$id$n';
    }
    return unique;
  }

  // -- parameters --

  List<Map<String, dynamic>> _parameters(
    RequestModel r,
    List<String> pathNames,
    List<KV> urlQuery,
  ) {
    final out = <Map<String, dynamic>>[];
    final values = {for (final v in r.pathVariables) v.key: v};
    for (final n in pathNames) {
      final v = values[n];
      out.add({
        'name': n,
        'in': 'path',
        'required': true,
        if (v != null && v.description.isNotEmpty) 'description': v.description,
        'schema': _schemaFor(v?.value ?? ''),
        if (v != null && v.value.isNotEmpty) 'example': _exampleFor(v.value),
      });
    }

    final queryRows = [
      ...r.params,
      ...urlQuery.where((q) => !r.params.any((p) => p.key == q.key)),
    ];
    out.addAll(_grouped('query', queryRows, (name) => name));

    final headers = <KV>[];
    final cookies = <KV>[];
    for (final h in r.headers) {
      final name = h.key.trim();
      if (name.isEmpty) continue;
      final lower = name.toLowerCase();
      if (lower == 'cookie') {
        for (final part in h.value.split(';')) {
          final eq = part.indexOf('=');
          if (eq <= 0) continue;
          cookies.add(
            KV(
              key: part.substring(0, eq).trim(),
              value: part.substring(eq + 1).trim(),
              enabled: h.enabled,
            ),
          );
        }
      } else if (!_reservedHeaders.contains(lower)) {
        headers.add(h);
      }
    }
    out.addAll(_grouped('header', headers, (name) => name.toLowerCase()));
    out.addAll(_grouped('cookie', cookies, (name) => name));
    return out;
  }

  /// One parameter per distinct name; a name used more than once becomes an
  /// array with all its values.
  List<Map<String, dynamic>> _grouped(
    String where,
    List<KV> rows,
    String Function(String) identity,
  ) {
    final groups = <String, List<KV>>{};
    for (final p in rows) {
      if (p.key.trim().isEmpty) continue;
      groups.putIfAbsent(identity(p.key.trim()), () => []).add(p);
    }
    return [
      for (final g in groups.values)
        {
          'name': g.first.key.trim(),
          'in': where,
          'required': g.any((p) => p.enabled),
          if (g.any((p) => p.description.isNotEmpty))
            'description': g
                .firstWhere((p) => p.description.isNotEmpty)
                .description,
          if (g.length > 1) ...{
            'schema': {'type': 'array', 'items': _schemaFor(g.first.value)},
            'example': [for (final p in g) _exampleFor(p.value)],
          } else ...{
            'schema': _schemaFor(g.first.value),
            if (g.first.value.isNotEmpty) 'example': _exampleFor(g.first.value),
          },
        },
    ];
  }

  /// [v] as a number or boolean when writing it back gives exactly [v];
  /// null otherwise (so `1.50`, `007` and `{{id}}` stay strings).
  static Object? _typed(String v) {
    final i = int.tryParse(v);
    if (i != null && '$i' == v && v.length <= 15) return i;
    final d = double.tryParse(v);
    if (d != null && '$d' == v && RegExp(r'^-?\d+\.\d+$').hasMatch(v)) {
      return d;
    }
    if (v == 'true') return true;
    if (v == 'false') return false;
    return null;
  }

  static Map<String, dynamic> _schemaFor(String v) => {
    'type': switch (_typed(v)) {
      int() => 'integer',
      double() => 'number',
      bool() => 'boolean',
      _ => 'string',
    },
  };

  static Object _exampleFor(String v) => _typed(v) ?? v;

  // -- body --

  Map<String, dynamic>? _requestBody(RequestModel r) {
    final ct = _headerContentType(r);
    Map<String, dynamic> media(String key, Map<String, dynamic> body) => {
      'required': true,
      'content': {key: body},
    };
    switch (r.bodyType) {
      case BodyType.none:
        return null;
      case BodyType.json:
        final text = r.body.trim();
        final key = ct != null && ct.contains('json') ? ct : 'application/json';
        if (text.isEmpty) return media(key, {});
        try {
          final value = jsonDecode(text);
          return media(key, {
            'schema': schemaFromValue(value),
            'example': value,
          });
        } on FormatException {
          // Not JSON yet (placeholders such as {{id}}): keep the text as is.
          return media(key, {
            if (text.startsWith('{')) 'schema': {'type': 'object'},
            if (text.startsWith('[')) 'schema': {'type': 'array'},
            'example': r.body,
          });
        }
      case BodyType.graphql:
        Object? vars;
        try {
          vars = r.graphqlVariables.trim().isEmpty
              ? null
              : jsonDecode(r.graphqlVariables);
        } on FormatException {
          vars = null;
        }
        return media('application/json', {
          'schema': {
            'type': 'object',
            'properties': {
              'query': {'type': 'string'},
              'variables': {'type': 'object'},
            },
          },
          'example': {'query': r.body, 'variables': vars ?? {}},
        });
      case BodyType.text:
        if (r.body.isEmpty) return null;
        final key = ct != null && ct.startsWith('text/') ? ct : 'text/plain';
        return media(key, {
          'schema': {'type': 'string'},
          'example': r.body,
        });
      case BodyType.xml:
        if (r.body.isEmpty) return null;
        final key = ct != null && ct.contains('xml') ? ct : 'application/xml';
        return media(key, {
          'schema': {'type': 'string'},
          'example': r.body,
        });
      case BodyType.formUrlEncoded || BodyType.formData:
        final multipart = r.bodyType == BodyType.formData;
        final props = <String, dynamic>{};
        for (final f in r.formFields) {
          if (f.key.isEmpty) continue;
          props[f.key] = f.isFile
              ? {'type': 'string', 'format': 'binary'}
              : {
                  ..._schemaFor(f.value),
                  if (f.value.isNotEmpty) 'example': _exampleFor(f.value),
                  if (f.description.isNotEmpty) 'description': f.description,
                };
        }
        if (props.isEmpty) return null;
        return media(
          multipart
              ? 'multipart/form-data'
              : 'application/x-www-form-urlencoded',
          {
            'schema': {'type': 'object', 'properties': props},
          },
        );
      case BodyType.binary:
        return media('application/octet-stream', {
          'schema': {'type': 'string', 'format': 'binary'},
        });
    }
  }

  static String? _headerContentType(RequestModel r) {
    for (final h in r.headers) {
      if (h.enabled && h.key.toLowerCase() == 'content-type') {
        return h.value.split(';').first.trim().toLowerCase();
      }
    }
    return null;
  }

  // -- auth --

  /// The auth a request actually uses: its own, else the nearest folder's,
  /// else the collection's.
  AuthConfig _effectiveAuth(RequestModel r) {
    if (r.auth.type != AuthType.inherit) return r.auth;
    for (final f in CollectionModel.folderChain(r.folder).reversed) {
      final a = c.folders[f]?.auth;
      if (a != null && a.type != AuthType.inherit) return a;
    }
    return _collectionAuth();
  }

  AuthConfig _collectionAuth() =>
      c.auth.type == AuthType.inherit ? AuthConfig() : c.auth;

  static bool _sameRequirement(_Requirement? a, _Requirement? b) {
    if (a == null || b == null) return a == null && b == null;
    return a.name == b.name && a.scopes.join(' ') == b.scopes.join(' ');
  }

  /// Registers the security scheme for [a] and returns the requirement that
  /// uses it, or null for no auth and for types OpenAPI cannot describe.
  _Requirement? _requirement(AuthConfig a) {
    switch (a.type) {
      case AuthType.bearer:
        return (
          name: _register('bearerAuth', {'type': 'http', 'scheme': 'bearer'}),
          scopes: const [],
        );
      case AuthType.basic:
        return (
          name: _register('basicAuth', {'type': 'http', 'scheme': 'basic'}),
          scopes: const [],
        );
      case AuthType.digest:
        return (
          name: _register('digestAuth', {'type': 'http', 'scheme': 'digest'}),
          scopes: const [],
        );
      case AuthType.apiKey:
        if (a.apiKeyName.isEmpty) return null;
        final scheme = {
          'type': 'apiKey',
          'in': a.apiKeyInHeader ? 'header' : 'query',
          'name': a.apiKeyName,
        };
        return (name: _register('apiKeyAuth', scheme), scopes: const []);
      case AuthType.oauth2:
        return _oauth2(a);
      default:
        return null;
    }
  }

  /// The scheme name for [scheme]: an identical one already registered, else
  /// [base] (numbered when a different scheme took it).
  String _register(String base, Map<String, dynamic> scheme) {
    final wanted = jsonEncode(scheme);
    var name = base;
    for (var n = 2; ; n++) {
      final existing = schemes[name];
      if (existing == null) {
        schemes[name] = scheme;
        return name;
      }
      if (jsonEncode(existing) == wanted) return name;
      name = '${base}_$n';
    }
  }

  _Requirement _oauth2(AuthConfig a) {
    final flow = switch (a.param('grant_type', 'authorization_code')) {
      'implicit' => 'implicit',
      'password_credentials' => 'password',
      'client_credentials' => 'clientCredentials',
      _ => 'authorizationCode',
    };
    final scopes = a
        .param('scope')
        .split(RegExp(r'[\s,]+'))
        .where((s) => s.isNotEmpty)
        .toList();
    final refresh = a.param('refreshTokenUrl');
    final urls = <String, String>{
      if (flow == 'authorizationCode' || flow == 'implicit')
        'authorizationUrl': a.param('authUrl'),
      if (flow != 'implicit') 'tokenUrl': a.param('accessTokenUrl'),
      if (refresh.isNotEmpty) 'refreshUrl': refresh,
    };
    // One scheme per flow and URL set; requests asking for other scopes add
    // them to it.
    var name = 'oauth2Auth';
    for (var n = 2; ; n++) {
      final existing = schemes[name];
      if (existing == null) {
        schemes[name] = {
          'type': 'oauth2',
          'flows': {
            flow: {
              ...urls,
              'scopes': {for (final s in scopes) s: ''},
            },
          },
        };
        break;
      }
      final flows = existing['flows'] as Map<String, dynamic>;
      final current = flows[flow] as Map<String, dynamic>?;
      if (existing['type'] == 'oauth2' &&
          flows.length == 1 &&
          current != null &&
          urls.entries.every((e) => current[e.key] == e.value) &&
          current.length == urls.length + 1) {
        final known = current['scopes'] as Map<String, dynamic>;
        for (final s in scopes) {
          known.putIfAbsent(s, () => '');
        }
        break;
      }
      name = 'oauth2Auth_$n';
    }
    return (name: name, scopes: scopes);
  }
}

// ---- responses --------------------------------------------------------------

/// Collects the saved examples of every request that maps to one operation
/// and writes them into the operation's `responses` map.
class _Responses {
  final responses = <String, dynamic>{};
  final _byStatus = <int, _Status>{};

  void add(List<ResponseExample> examples) {
    for (final e in examples) {
      _byStatus.putIfAbsent(e.statusCode, () => _Status(e)).add(e);
    }
  }

  void finish() {
    if (_byStatus.isEmpty) {
      responses['200'] = {'description': 'OK'};
      return;
    }
    final codes = _byStatus.keys.toList()..sort();
    for (final code in codes) {
      responses['$code'] = _byStatus[code]!.toJson();
    }
  }
}

class _Status {
  _Status(ResponseExample first)
    : description = first.statusText.isNotEmpty
          ? first.statusText
          : (httpReason(first.statusCode).isNotEmpty
                ? httpReason(first.statusCode)
                : 'Response');

  final String description;
  final headers = <String, Map<String, dynamic>>{};

  /// Media type → (example name, parsed value).
  final media = <String, List<(String, Object?)>>{};

  void add(ResponseExample e) {
    for (final h in e.headers) {
      final name = h.key.trim();
      if (!h.enabled ||
          name.isEmpty ||
          _transportHeaders.contains(name.toLowerCase())) {
        continue;
      }
      headers.putIfAbsent(
        name,
        () => {
          'schema': {'type': 'string'},
          if (h.value.isNotEmpty) 'example': h.value,
        },
      );
    }
    if (e.body.isEmpty) return;
    final given = e.contentType?.split(';').first.trim().toLowerCase();
    Object? value;
    String type;
    if (given != null && given.isNotEmpty) {
      type = given;
      value = given.contains('json') ? _tryJson(e.body) : e.body;
    } else {
      final parsed = _tryJson(e.body);
      type = identical(parsed, e.body) ? 'text/plain' : 'application/json';
      value = parsed;
    }
    media.putIfAbsent(type, () => []).add((e.name, value));
  }

  /// The parsed JSON, or [s] itself (the same object) when it is not JSON.
  static Object? _tryJson(String s) {
    try {
      return jsonDecode(s);
    } on FormatException {
      return s;
    }
  }

  Map<String, dynamic> toJson() => {
    'description': description,
    if (headers.isNotEmpty) 'headers': headers,
    if (media.isNotEmpty)
      'content': {
        for (final m in media.entries)
          m.key: {
            if (m.key.contains('json') && m.value.first.$2 is! String)
              'schema': schemaFromValue(m.value.first.$2),
            if (m.value.length == 1)
              'example': m.value.first.$2
            else
              'examples': _named(m.value),
          },
      },
  };

  static Map<String, dynamic> _named(List<(String, Object?)> items) {
    final out = <String, dynamic>{};
    for (final (name, value) in items) {
      final base = name.trim().isEmpty ? 'example' : name.trim();
      var key = base;
      for (var n = 2; out.containsKey(key); n++) {
        key = '$base $n';
      }
      out[key] = {'summary': base, 'value': value};
    }
    return out;
  }
}

/// A JSON Schema describing [v], for documentation next to its example.
Map<String, dynamic> schemaFromValue(Object? v, [int depth = 0]) {
  if (depth > 8) return {};
  return switch (v) {
    Map() => {
      'type': 'object',
      if (v.isNotEmpty)
        'properties': {
          for (final e in v.entries)
            '${e.key}': schemaFromValue(e.value, depth + 1),
        },
    },
    List() => {
      'type': 'array',
      'items': v.isEmpty
          ? <String, dynamic>{}
          : schemaFromValue(v.first, depth + 1),
    },
    String() => {'type': 'string'},
    int() => {'type': 'integer'},
    num() => {'type': 'number'},
    bool() => {'type': 'boolean'},
    _ => {'nullable': true},
  };
}

// ---- YAML -------------------------------------------------------------------

/// Writes [value] (maps, lists, strings, numbers, booleans, null) as block
/// style YAML. Strings that a YAML reader would take for something else
/// (`true`, `123`, `1.0.0`, `#/components/...`, `a: b`) are double-quoted, as
/// are keys such as `'200'`; multi-line text becomes a literal block.
String emitYaml(Object? value) {
  final b = StringBuffer();
  if (value is Map && value.isNotEmpty) {
    _yamlMap(b, value, 0);
  } else if (value is List && value.isNotEmpty) {
    _yamlList(b, value, 0);
  } else {
    b.writeln(_inline(value));
  }
  return b.toString();
}

/// A scalar or an empty collection on one line.
String _inline(Object? v) => switch (v) {
  null => 'null',
  bool() => '$v',
  int() => '$v',
  double() =>
    v.isNaN
        ? '.nan'
        : v.isInfinite
        ? (v.isNegative ? '-.inf' : '.inf')
        : '$v',
  Map() => '{}',
  List() => '[]',
  _ => _yamlString('$v'),
};

void _yamlMap(StringBuffer b, Map m, int indent, {String? lead}) {
  var first = true;
  for (final e in m.entries) {
    final pad = first && lead != null ? lead : ' ' * indent;
    first = false;
    final key = _yamlKey('${e.key}');
    final v = e.value;
    if (v is Map && v.isNotEmpty) {
      b.writeln('$pad$key:');
      _yamlMap(b, v, indent + 2);
    } else if (v is List && v.isNotEmpty) {
      b.writeln('$pad$key:');
      _yamlList(b, v, indent + 2);
    } else if (v is String && _literal(v)) {
      b.writeln('$pad$key: ${_literalHeader(v)}');
      _literalBody(b, v, indent + 2);
    } else {
      b.writeln('$pad$key: ${_inline(v)}');
    }
  }
}

void _yamlList(StringBuffer b, List l, int indent) {
  final pad = ' ' * indent;
  for (final v in l) {
    if (v is Map && v.isNotEmpty) {
      _yamlMap(b, v, indent + 2, lead: '$pad- ');
    } else if (v is List && v.isNotEmpty) {
      b.writeln('$pad-');
      _yamlList(b, v, indent + 2);
    } else if (v is String && _literal(v)) {
      b.writeln('$pad- ${_literalHeader(v)}');
      _literalBody(b, v, indent + 2);
    } else {
      b.writeln('$pad- ${_inline(v)}');
    }
  }
}

final _plainChars = RegExp(
  r"^[A-Za-z_/][A-Za-z0-9_\-./ ()+=@,;$%'*&!?|<>^~\[\]{}:#]*$",
);
const _reserved = {'true', 'false', 'yes', 'no', 'on', 'off', 'null', 'y', 'n'};

/// Whether [s] can be written without quotes and read back as the same
/// string. Deliberately narrow: anything unusual gets quoted.
bool _plainSafe(String s) {
  if (s.isEmpty || s != s.trim() || !_plainChars.hasMatch(s)) return false;
  if (_reserved.contains(s.toLowerCase())) return false;
  // ': ' and ' #' would start a mapping value or a comment; a trailing ':'
  // makes a mapping key.
  if (s.contains(': ') || s.contains(' #') || s.endsWith(':')) return false;
  return true;
}

String _yamlKey(String k) => _plainSafe(k) ? k : _doubleQuoted(k);

String _yamlString(String s) => _plainSafe(s) ? s : _doubleQuoted(s);

String _doubleQuoted(String s) {
  final b = StringBuffer('"');
  for (final r in s.runes) {
    switch (r) {
      case 0x22:
        b.write(r'\"');
      case 0x5C:
        b.write(r'\\');
      case 0x0A:
        b.write(r'\n');
      case 0x0D:
        b.write(r'\r');
      case 0x09:
        b.write(r'\t');
      default:
        if (_unprintable(r)) {
          b.write('\\u${r.toRadixString(16).toUpperCase().padLeft(4, '0')}');
        } else if (r >= 0xD800 && r <= 0xDFFF) {
          b.write('�'); // a lone surrogate cannot be written
        } else {
          b.writeCharCode(r);
        }
    }
  }
  return (b..write('"')).toString();
}

bool _unprintable(int r) =>
    r < 0x20 ||
    (r >= 0x7F && r <= 0x9F) ||
    r == 0x2028 ||
    r == 0x2029 ||
    r == 0xFEFF ||
    r == 0xFFFE ||
    r == 0xFFFF;

/// Whether [s] can be written as a literal block (`|`) and read back
/// unchanged.
bool _literal(String s) {
  if (!s.contains('\n') || s.contains('\r')) return false;
  if (s.startsWith(' ') || s.startsWith('\n') || s.startsWith('\t')) {
    return false;
  }
  if (s.endsWith('\n\n')) return false;
  for (final r in s.runes) {
    if (r == 0x0A || r == 0x09) continue;
    if (_unprintable(r) || (r >= 0xD800 && r <= 0xDFFF)) return false;
  }
  return true;
}

String _literalHeader(String s) => s.endsWith('\n') ? '|' : '|-';

void _literalBody(StringBuffer b, String s, int indent) {
  final pad = ' ' * indent;
  final body = s.endsWith('\n') ? s.substring(0, s.length - 1) : s;
  for (final line in body.split('\n')) {
    b.writeln(line.isEmpty ? '' : '$pad$line');
  }
}
