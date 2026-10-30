import 'dart:convert';

import 'package:yaml/yaml.dart';

import '../models/models.dart';
import 'http_reason.dart';
import 'import_report.dart';
import 'schema_sample.dart';

/// Parses [raw] as JSON, or as YAML when it is not JSON, into plain Dart maps
/// and lists (YAML maps become `Map<String, dynamic>`, so a `200:` key reads
/// the same as `"200"`). Throws [FormatException] when it is neither.
Object? decodeJsonOrYaml(String raw) {
  final text = raw.startsWith('﻿') ? raw.substring(1) : raw;
  final head = text.trimLeft();
  if (head.startsWith('{') || head.startsWith('[')) {
    try {
      return jsonDecode(text);
    } on FormatException {
      // YAML flow style also starts with a brace; try that next.
    }
  }
  try {
    return _plain(loadYaml(text), _Budget());
  } on YamlException catch (e) {
    final line = e.span == null ? '' : ' (line ${e.span!.start.line + 1})';
    throw FormatException('The file is not valid YAML$line: ${e.message}.');
  }
}

/// Aliases can multiply a document ("billion laughs"); stop converting after
/// this many nodes.
class _Budget {
  int left = 2000000;
}

Object? _plain(Object? n, _Budget b) {
  if (--b.left < 0) {
    throw const FormatException('The YAML document is too large to import.');
  }
  if (n is Map) {
    final out = <String, dynamic>{};
    final merged = <String, dynamic>{};
    for (final e in n.entries) {
      final v = _plain(e.value, b);
      if ('${e.key}' == '<<') {
        // YAML merge key: `<<: *defaults` brings in another map's entries.
        for (final m in (v is List ? v : [v])) {
          if (m is Map<String, dynamic>) {
            for (final me in m.entries) {
              merged.putIfAbsent(me.key, () => me.value);
            }
          }
        }
      } else {
        out['${e.key}'] = v;
      }
    }
    merged.forEach((k, v) => out.putIfAbsent(k, () => v));
    return out;
  }
  if (n is List) return [for (final x in n) _plain(x, b)];
  return n;
}

/// Whether [doc] (a decoded JSON or YAML value) declares itself an OpenAPI 3
/// or Swagger 2 document.
bool looksLikeOpenApi(Object? doc) {
  if (doc is! Map) return false;
  final openapi = doc['openapi'];
  final swagger = doc['swagger'];
  return (openapi != null && '$openapi'.startsWith('3')) ||
      (swagger != null && '$swagger'.startsWith('2'));
}

/// Imports an OpenAPI 3.0/3.1 or Swagger 2.0 document given as JSON or YAML
/// text. Results accumulate into [into]. Throws [FormatException] when the
/// text is not such a document.
ImportReport importOpenApi(String raw, {ImportReport? into}) =>
    importOpenApiDocument(decodeJsonOrYaml(raw), into: into);

/// [importOpenApi] for a document that is already decoded.
ImportReport importOpenApiDocument(Object? doc, {ImportReport? into}) {
  final report = into ?? ImportReport();
  if (doc is! Map) {
    throw const FormatException(
      'The file is not an OpenAPI or Swagger document.',
    );
  }
  final _Converted result;
  try {
    result = _Importer(doc).convert();
  } on FormatException {
    rethrow;
  } catch (e) {
    // A malformed spec must not take the dialog down with a type error.
    throw FormatException('The OpenAPI document could not be converted ($e).');
  }
  // Nothing is added until the whole document converted.
  report.formats.add(result.format);
  report.collections.add(result.collection);
  report.requests += result.requests;
  report.folders += result.folders;
  result.unsupportedAuth.forEach(
    (k, v) => report.unsupportedAuth.update(k, (n) => n + v, ifAbsent: () => v),
  );
  report.notes.addAll(result.notes);
  return report;
}

class _Converted {
  _Converted(
    this.collection,
    this.format,
    this.requests,
    this.folders,
    this.unsupportedAuth,
    this.notes,
  );
  final CollectionModel collection;
  final String format;
  final int requests;
  final int folders;
  final Map<String, int> unsupportedAuth;
  final List<String> notes;
}

/// Methods that become requests, as written in a path item.
const _methods = {
  'get',
  'put',
  'post',
  'delete',
  'options',
  'head',
  'patch',
  'query',
};

enum _Media { json, urlEncoded, multipart, xml, text, binary }

Map _map(Object? v) => v is Map ? v : const {};

List _list(Object? v) => v is List ? v : const [];

String _text(Object? v) => v == null ? '' : '$v'.trim();

const _pretty = JsonEncoder.withIndent('  ');

class _Importer {
  _Importer(this.doc);

  final Map doc;
  late final bool v2;
  late final CollectionModel col;
  final notes = <String>{};
  final unsupportedAuth = <String, int>{};
  final externalRefs = <String>{};
  int brokenRefs = 0;

  late final SchemaSampler requestSampler = SchemaSampler(
    resolve: _resolve,
    forRequest: true,
  );
  late final SchemaSampler anySampler = SchemaSampler(resolve: _resolve);

  // Security.
  String? globalUnsupported;
  String globalSecurityKey = '[]';
  int inheritingRequests = 0;

  final folderNames = <String>{};
  int requests = 0;
  int skippedTrace = 0;

  _Converted convert() {
    final String format;
    final openapi = doc['openapi'];
    final swagger = doc['swagger'];
    if (openapi != null) {
      final version = '$openapi';
      if (!version.startsWith('3')) {
        throw FormatException('OpenAPI $version is not supported (3.x only).');
      }
      v2 = false;
      final parts = version.split('.');
      format = 'OpenAPI ${parts.take(2).join('.')}';
    } else if (swagger != null) {
      final version = '$swagger';
      if (!version.startsWith('2')) {
        throw FormatException('Swagger $version is not supported (2.0 only).');
      }
      v2 = true;
      format = 'Swagger 2.0';
    } else {
      throw const FormatException(
        'Not an OpenAPI or Swagger document: it has no "openapi" or '
        '"swagger" version.',
      );
    }

    final info = _map(doc['info']);
    final title = _text(info['title']);
    col = CollectionModel(
      name: title.isEmpty ? 'Imported API' : title,
      description: _text(info['description']).isNotEmpty
          ? _text(info['description'])
          : _text(info['summary']),
    );

    _baseUrl();
    _globalSecurity();

    final tagInfo = <String, String>{
      for (final t in _list(doc['tags']))
        if (t is Map && _text(t['name']).isNotEmpty)
          _text(t['name']): _text(t['description']),
    };

    final paths = _map(doc['paths']);
    paths.forEach((path, rawItem) {
      if ('$path'.startsWith('x-')) return;
      final item = _deref(rawItem);
      if (item == null) return;
      item.forEach((key, op) {
        final k = '$key'.toLowerCase();
        if (k == 'trace') {
          skippedTrace++;
          return;
        }
        // `query` is OpenAPI 3.2's method; 3.0 documents carry it as x-query.
        final method = k == 'x-query' ? 'query' : k;
        if (!_methods.contains(method) || op is! Map) return;
        col.requests.add(_operation('$path', method, item, op, tagInfo));
        requests++;
      });
    });

    if (requests == 0) {
      throw const FormatException(
        'The document has no operations under "paths" to import.',
      );
    }

    if (globalUnsupported != null && inheritingRequests > 0) {
      unsupportedAuth.update(
        globalUnsupported!,
        (n) => n + inheritingRequests,
        ifAbsent: () => inheritingRequests,
      );
    }
    if (skippedTrace > 0) {
      notes.add(
        '$skippedTrace TRACE ${skippedTrace == 1 ? 'operation was' : 'operations were'} '
        'skipped.',
      );
    }
    if (_map(doc['webhooks']).isNotEmpty) {
      notes.add('Webhooks in the document are not imported.');
    }
    if (externalRefs.isNotEmpty) {
      final sample = externalRefs.take(2).join(', ');
      notes.add(
        '${externalRefs.length} '
        '${externalRefs.length == 1 ? 'reference' : 'references'} to other '
        'files or URLs (for example $sample) ${externalRefs.length == 1 ? 'is' : 'are'} '
        'not followed; the parts they describe were left out of bodies and '
        'parameters.',
      );
    }
    if (brokenRefs > 0) {
      notes.add(
        '$brokenRefs ${brokenRefs == 1 ? 'reference points' : 'references point'} '
        'to something missing.',
      );
    }

    return _Converted(
      col,
      format,
      requests,
      folderNames.length,
      unsupportedAuth,
      notes.toList(),
    );
  }

  // -- $ref --

  /// The value at a local reference such as `#/components/schemas/Pet`.
  Object? _resolve(String ref) {
    if (!ref.startsWith('#')) {
      externalRefs.add(ref);
      return null;
    }
    final pointer = ref.substring(1);
    if (pointer.isEmpty) return doc;
    if (!pointer.startsWith('/')) {
      brokenRefs++;
      return null;
    }
    Object? node = doc;
    for (final raw in pointer.substring(1).split('/')) {
      String seg;
      try {
        seg = Uri.decodeComponent(raw);
      } catch (_) {
        seg = raw;
      }
      seg = seg.replaceAll('~1', '/').replaceAll('~0', '~');
      if (node is Map && node.containsKey(seg)) {
        node = node[seg];
      } else if (node is List) {
        final i = int.tryParse(seg);
        if (i == null || i < 0 || i >= node.length) {
          brokenRefs++;
          return null;
        }
        node = node[i];
      } else {
        brokenRefs++;
        return null;
      }
    }
    return node;
  }

  /// [node] with `$ref`s followed (and a 3.1 sibling such as `description`
  /// laid over the target), or null when it is not a map or the chain loops.
  Map? _deref(Object? node) {
    final seen = <String>{};
    var cur = node;
    for (var i = 0; i < 24; i++) {
      if (cur is! Map) return null;
      final ref = cur[r'$ref'];
      if (ref is! String) return cur;
      if (!seen.add(ref)) return null;
      final target = _resolve(ref);
      if (target is! Map) return null;
      cur = {
        ...target,
        for (final e in cur.entries)
          if (e.key != r'$ref') e.key: e.value,
      };
    }
    return null;
  }

  // -- servers --

  void _baseUrl() {
    String url;
    final others = <String>[];
    if (v2) {
      final host = _text(doc['host']);
      var basePath = _text(doc['basePath']);
      final schemes = _list(doc['schemes']).map((s) => '$s').toList();
      final scheme = schemes.contains('https')
          ? 'https'
          : (schemes.isNotEmpty ? schemes.first : 'https');
      if (basePath == '/') basePath = '';
      url = host.isEmpty ? basePath : '$scheme://$host$basePath';
    } else {
      final servers = _list(doc['servers']).whereType<Map>().toList();
      url = servers.isEmpty ? '' : _serverUrl(servers.first);
      others.addAll(servers.skip(1).map(_serverUrl));
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.isEmpty) {
      notes.add(
        'The document does not say where the API runs. Set the baseUrl '
        'variable (for example https://api.example.com).',
      );
    } else if (!RegExp(r'^(https?://|\{\{)').hasMatch(url)) {
      notes.add(
        'The server address "$url" is relative. Set the baseUrl variable to '
        'the full address (for example https://api.example.com$url).',
      );
    }
    if (others.isNotEmpty) {
      notes.add(
        'The document lists more servers (${others.take(4).join(', ')}'
        '${others.length > 4 ? ', …' : ''}); change baseUrl to use one.',
      );
    }
    col.variables.add(
      KV(
        key: 'baseUrl',
        value: url,
        description: 'Server address from the OpenAPI document.',
      ),
    );
  }

  /// A server's URL with its variables replaced by their defaults.
  String _serverUrl(Map server) {
    final vars = _map(server['variables']);
    return _text(server['url']).replaceAllMapped(RegExp(r'\{([^{}]+)\}'), (m) {
      final def = _map(vars[m.group(1)])['default'];
      return def != null ? '$def' : '{{${m.group(1)}}}';
    });
  }

  // -- security --

  Map get _schemes => v2
      ? _map(doc['securityDefinitions'])
      : _map(_map(doc['components'])['securitySchemes']);

  void _globalSecurity() {
    final security = doc['security'];
    final r = _authFor(security);
    globalUnsupported = r.unsupported;
    globalSecurityKey = jsonEncode(security is List ? security : const []);
    col.auth = r.auth ?? AuthConfig();
  }

  /// The first requirement whose scheme ApiWorkbench can send. [unsupported]
  /// names the kind of auth that could not be converted, when that was all
  /// there was.
  ({AuthConfig? auth, String? unsupported}) _authFor(Object? security) {
    if (security is! List) return (auth: null, unsupported: null);
    var options = 0;
    AuthConfig? chosen;
    String? chosenName;
    String? unsupported;
    for (final req in security) {
      if (req is! Map || req.isEmpty) continue;
      options++;
      if (chosen != null) continue;
      for (final e in req.entries) {
        final r = _scheme('${e.key}', _list(e.value).map((s) => '$s').toList());
        if (r.auth != null) {
          chosen = r.auth;
          chosenName = '${e.key}';
          break;
        }
        unsupported ??= r.unsupported;
      }
    }
    if (options > 1 && chosenName != null) {
      notes.add(
        'Several security options are listed; only "$chosenName" is set up '
        'as the auth.',
      );
    }
    return (auth: chosen, unsupported: chosen == null ? unsupported : null);
  }

  ({AuthConfig? auth, String? unsupported}) _scheme(
    String name,
    List<String> scopes,
  ) {
    final def = _deref(_schemes[name]);
    if (def == null) {
      notes.add('Security scheme "$name" is used but not defined.');
      return (auth: null, unsupported: null);
    }
    switch ('${def['type']}') {
      case 'http':
        final scheme = _text(def['scheme']).toLowerCase();
        return switch (scheme) {
          'bearer' => (
            auth: AuthConfig(type: AuthType.bearer),
            unsupported: null,
          ),
          'basic' => (
            auth: AuthConfig(type: AuthType.basic),
            unsupported: null,
          ),
          'digest' => (
            auth: AuthConfig(type: AuthType.digest),
            unsupported: null,
          ),
          _ => (auth: null, unsupported: 'HTTP $scheme'),
        };
      case 'basic':
        return (auth: AuthConfig(type: AuthType.basic), unsupported: null);
      case 'apiKey':
        final where = _text(def['in']);
        if (where == 'cookie') {
          return (auth: null, unsupported: 'API key in a cookie');
        }
        return (
          auth: AuthConfig(
            type: AuthType.apiKey,
            apiKeyName: _text(def['name']),
            apiKeyInHeader: where != 'query',
          ),
          unsupported: null,
        );
      case 'oauth2':
        return (auth: _oauth2(def, scopes), unsupported: null);
      case 'openIdConnect':
        return (auth: null, unsupported: 'OpenID Connect');
      case 'mutualTLS':
        return (auth: null, unsupported: 'mutual TLS');
      default:
        return (auth: null, unsupported: _text(def['type']));
    }
  }

  AuthConfig _oauth2(Map def, List<String> scopes) {
    String grant;
    Map flow;
    if (v2) {
      grant = switch (_text(def['flow'])) {
        'implicit' => 'implicit',
        'password' => 'password_credentials',
        'application' => 'client_credentials',
        _ => 'authorization_code',
      };
      flow = def;
    } else {
      final flows = _map(def['flows']);
      const order = [
        ('authorizationCode', 'authorization_code'),
        ('clientCredentials', 'client_credentials'),
        ('password', 'password_credentials'),
        ('implicit', 'implicit'),
      ];
      var picked = order.first;
      for (final o in order) {
        if (flows[o.$1] is Map) {
          picked = o;
          break;
        }
      }
      grant = picked.$2;
      flow = _map(flows[picked.$1]);
    }
    return AuthConfig(
      type: AuthType.oauth2,
      params: {
        'grant_type': grant,
        if (_text(flow['authorizationUrl']).isNotEmpty)
          'authUrl': _text(flow['authorizationUrl']),
        if (_text(flow['tokenUrl']).isNotEmpty)
          'accessTokenUrl': _text(flow['tokenUrl']),
        if (_text(flow['refreshUrl']).isNotEmpty)
          'refreshTokenUrl': _text(flow['refreshUrl']),
        if (scopes.isNotEmpty) 'scope': scopes.join(' '),
        'addTokenTo': 'header',
        'headerPrefix': 'Bearer',
      },
    );
  }

  void _operationAuth(Map op, RequestModel m) {
    final security = op['security'];
    if (security is! List || jsonEncode(security) == globalSecurityKey) {
      m.auth = AuthConfig(type: AuthType.inherit);
      if (globalUnsupported != null) inheritingRequests++;
      return;
    }
    final r = _authFor(security);
    if (r.auth != null) {
      m.auth = r.auth!;
    } else {
      // Empty security, or only schemes ApiWorkbench cannot send: do not
      // fall back on the collection's auth, the operation said otherwise.
      m.auth = AuthConfig(type: AuthType.none);
      if (r.unsupported != null) {
        unsupportedAuth.update(r.unsupported!, (n) => n + 1, ifAbsent: () => 1);
      }
    }
  }

  // -- operations --

  RequestModel _operation(
    String path,
    String method,
    Map item,
    Map op,
    Map<String, String> tagInfo,
  ) {
    final summary = _text(op['summary']);
    final opId = _text(op['operationId']);
    final m = RequestModel(
      name: summary.isNotEmpty
          ? summary
          : (opId.isNotEmpty ? opId : '${method.toUpperCase()} $path'),
      method: method.toUpperCase(),
      description: _text(op['description']),
    );

    final tags = _list(op['tags']).map(_text).where((t) => t.isNotEmpty);
    if (tags.isNotEmpty) {
      final tag = tags.first;
      m.folder = tag.replaceAll('/', '∕');
      if (folderNames.add(m.folder)) {
        final d = tagInfo[tag] ?? '';
        if (d.isNotEmpty) col.folders[m.folder] = FolderMeta(description: d);
      }
    }

    final params = _parameters(item, op);

    // Operation- or path-level servers replace the collection's baseUrl.
    final own = _list(op['servers']).isNotEmpty
        ? op['servers']
        : item['servers'];
    final servers = _list(own).whereType<Map>();
    var base = '{{baseUrl}}';
    if (!v2 && servers.isNotEmpty) {
      base = _serverUrl(servers.first);
      while (base.endsWith('/')) {
        base = base.substring(0, base.length - 1);
      }
    }
    m.url = '$base${_urlPath(path)}';

    _applyParameters(m, params);
    if (v2) {
      _bodyV2(m, op, params);
    } else {
      _bodyV3(m, op);
    }
    _operationAuth(op, m);
    _responses(m, op);
    return m;
  }

  /// `/pets/{id}` → `/pets/:id`. A segment mixing text and a parameter
  /// (`/files/{name}.{ext}`) cannot be a path variable, so its placeholders
  /// become `{{variables}}` of the collection.
  String _urlPath(String path) {
    final segments = path.startsWith('/') ? path : '/$path';
    return segments
        .split('/')
        .map((s) {
          final whole = RegExp(r'^\{([^{}]+)\}$').firstMatch(s);
          if (whole != null) return ':${whole.group(1)}';
          return s.replaceAllMapped(RegExp(r'(?<!\{)\{([^{}]+)\}(?!\})'), (m) {
            final name = m.group(1)!;
            if (!col.variables.any((v) => v.key == name)) {
              col.variables.add(KV(key: name));
            }
            notes.add(
              'Some paths mix text and a parameter in one segment (for '
              'example /files/{name}.{ext}); those parts became collection '
              'variables to fill in.',
            );
            return '{{$name}}';
          });
        })
        .join('/');
  }

  /// Path-item and operation parameters; an operation's replaces a
  /// path-level one with the same name and location.
  List<Map> _parameters(Map item, Map op) {
    final byKey = <String, Map>{};
    for (final list in [item['parameters'], op['parameters']]) {
      for (final raw in _list(list)) {
        final p = _deref(raw);
        if (p == null || _text(p['name']).isEmpty) continue;
        byKey['${p['in']}:${p['name']}'] = p;
      }
    }
    return byKey.values.toList();
  }

  /// The schema a parameter is described by: `schema`, the first `content`
  /// entry, or (Swagger 2) the parameter itself.
  Object? _paramSchema(Map p) {
    if (p['schema'] != null) return p['schema'];
    final content = _map(p['content']);
    if (content.isNotEmpty) return _map(content.values.first)['schema'];
    return v2 ? p : null;
  }

  /// The example values of a parameter: one, or several for an array that
  /// is sent as repeated query keys.
  List<String> _paramValues(Map p) {
    Object? v = p['example'];
    if (v == null && p['examples'] is Map) {
      for (final e in (p['examples'] as Map).values) {
        final ex = _deref(e);
        if (ex != null && ex.containsKey('value')) {
          v = ex['value'];
          break;
        }
      }
    }
    v ??= p['x-example'];
    v ??= anySampler.sample(_paramSchema(p));
    if (v is List) {
      final style = p['style'];
      final explode =
          p['explode'] ??
          (v2
              ? p['collectionFormat'] == 'multi'
              : style == null || style == 'form');
      final items = v.map(_str).toList();
      if (p['in'] == 'query' && explode == true && items.isNotEmpty) {
        return items;
      }
      return [items.join(',')];
    }
    return [_str(v)];
  }

  void _applyParameters(RequestModel m, List<Map> params) {
    final cookies = <String>[];
    var cookiesRequired = false;
    for (final p in params) {
      final name = _text(p['name']);
      final required = p['required'] == true;
      final description = _text(p['description']);
      switch ('${p['in']}') {
        case 'path':
          break; // handled below, in URL order
        case 'query':
          for (final value in _paramValues(p)) {
            m.params.add(
              KV(
                key: name,
                value: value,
                enabled: required,
                description: description,
              ),
            );
          }
        case 'header':
          // These three are described by auth and the body instead.
          if (const {
            'authorization',
            'content-type',
            'accept',
          }.contains(name.toLowerCase())) {
            break;
          }
          m.headers.add(
            KV(
              key: name,
              value: _paramValues(p).join(','),
              enabled: required,
              description: description,
            ),
          );
        case 'cookie':
          cookies.add('$name=${_paramValues(p).join(',')}');
          cookiesRequired |= required;
      }
    }
    if (cookies.isNotEmpty) {
      m.headers.add(
        KV(key: 'Cookie', value: cookies.join('; '), enabled: cookiesRequired),
      );
    }
    final byName = {
      for (final p in params)
        if (p['in'] == 'path') _text(p['name']): p,
    };
    for (final name in pathVariableNames(m.url)) {
      final p = byName[name];
      m.pathVariables.add(
        KV(
          key: name,
          value: p == null ? '' : _paramValues(p).join(','),
          description: p == null ? '' : _text(p['description']),
        ),
      );
    }
  }

  // -- bodies --

  /// OpenAPI 3: the media type of `requestBody.content` that suits a request
  /// best (JSON, forms, XML, text, anything else).
  void _bodyV3(RequestModel m, Map op) {
    final rb = _deref(op['requestBody']);
    if (rb == null) return;
    final content = _map(rb['content']);
    if (content.isEmpty) return;
    final key = _pickMedia(content);
    final media = _map(content[key]);
    _fillBody(
      m,
      key,
      schema: media['schema'],
      example: _mediaExample(media),
      hasExample: _hasMediaExample(media),
    );
  }

  /// Swagger 2: a `body` parameter, or `formData` parameters.
  void _bodyV2(RequestModel m, Map op, List<Map> params) {
    final declared = op['consumes'] is List ? op['consumes'] : doc['consumes'];
    final types = _list(declared).map((s) => '$s').toList();
    final body = params.where((p) => p['in'] == 'body').firstOrNull;
    final forms = params.where((p) => p['in'] == 'formData').toList();
    if (body != null) {
      final key = types.isEmpty
          ? 'application/json'
          : _pickMedia({for (final t in types) t: null});
      _fillBody(
        m,
        key,
        schema: body['schema'],
        example: body['x-example'],
        hasExample: body.containsKey('x-example'),
      );
    } else if (forms.isNotEmpty) {
      final hasFile = forms.any((p) => p['type'] == 'file');
      final multipart =
          hasFile ||
          (types.contains('multipart/form-data') &&
              !types.contains('application/x-www-form-urlencoded'));
      m.bodyType = multipart ? BodyType.formData : BodyType.formUrlEncoded;
      for (final p in forms) {
        final isFile = p['type'] == 'file';
        m.formFields.add(
          KV(
            key: _text(p['name']),
            value: isFile ? '' : _paramValues(p).join(','),
            isFile: isFile,
            description: _text(p['description']),
          ),
        );
      }
    }
  }

  /// The best of several media types for a request body.
  String _pickMedia(Map content) {
    final keys = content.keys.map((k) => '$k').toList();
    String base(String k) => k.split(';').first.trim().toLowerCase();
    final rules = <bool Function(String)>[
      (k) => k == 'application/json',
      (k) => k.contains('json'),
      (k) => k == 'application/x-www-form-urlencoded',
      (k) => k.startsWith('multipart/'),
      (k) => k.contains('xml'),
      (k) => k.startsWith('text/'),
    ];
    for (final rule in rules) {
      for (final k in keys) {
        if (rule(base(k))) return k;
      }
    }
    return keys.first;
  }

  _Media _category(String mediaType, Object? schema) {
    final t = mediaType.split(';').first.trim().toLowerCase();
    if (t.contains('json')) return _Media.json;
    if (t == 'application/x-www-form-urlencoded') return _Media.urlEncoded;
    if (t.startsWith('multipart/')) return _Media.multipart;
    if (t.contains('xml')) return _Media.xml;
    if (t.startsWith('text/')) return _Media.text;
    final s = _schemaOf(schema);
    if (t == '*/*' || t == 'application/*') {
      final type = s['type'];
      if (type == 'object' || type == 'array' || s.containsKey('properties')) {
        return _Media.json;
      }
      return _Media.text;
    }
    return _Media.binary;
  }

  bool _hasMediaExample(Map media) {
    if (media.containsKey('example')) return true;
    return _firstExample(media['examples']).$1;
  }

  Object? _mediaExample(Map media) {
    if (media.containsKey('example')) return media['example'];
    return _firstExample(media['examples']).$2;
  }

  /// The first `value` in an `examples` map (or null, false).
  (bool, Object?) _firstExample(Object? examples) {
    for (final e in _map(examples).values) {
      final ex = _deref(e);
      if (ex != null && ex.containsKey('value')) return (true, ex['value']);
    }
    return (false, null);
  }

  void _fillBody(
    RequestModel m,
    String mediaType, {
    Object? schema,
    Object? example,
    bool hasExample = false,
  }) {
    final cat = _category(mediaType, schema);
    final base = mediaType.split(';').first.trim().toLowerCase();
    // The type a body type sends by default; others are set explicitly.
    void contentType(BodyType t) {
      m.bodyType = t;
      final wanted = t.contentType;
      if (wanted != null && base != wanted && !base.contains('*')) {
        m.headers.add(KV(key: 'Content-Type', value: mediaType));
      }
    }

    switch (cat) {
      case _Media.json:
        contentType(BodyType.json);
        final value = hasExample ? example : requestSampler.sample(schema);
        m.body = value == null && !hasExample ? '' : _jsonText(value, schema);
      case _Media.xml:
        contentType(BodyType.xml);
        final value = hasExample ? example : requestSampler.sample(schema);
        m.body = value is String
            ? value
            : (value == null ? '' : _xml(_rootName(schema), value));
      case _Media.text:
        contentType(BodyType.text);
        final value = hasExample ? example : requestSampler.sample(schema);
        m.body = value is String ? value : _str(value);
      case _Media.urlEncoded || _Media.multipart:
        final multipart = cat == _Media.multipart;
        m.bodyType = multipart ? BodyType.formData : BodyType.formUrlEncoded;
        m.formFields = _formFields(schema, example, multipart: multipart);
      case _Media.binary:
        contentType(BodyType.binary);
    }
  }

  /// Pretty JSON for a body. A string example may already be JSON text (YAML
  /// authors often write `example: '{"a": 1}'`) or contain placeholders; it
  /// is kept as written unless the schema says the value itself is a string.
  String _jsonText(Object? value, Object? schema) {
    if (value is String) {
      if (_schemaOf(schema)['type'] == 'string') return jsonEncode(value);
      try {
        return _pretty.convert(jsonDecode(value));
      } on FormatException {
        return value;
      }
    }
    return _pretty.convert(value);
  }

  /// [schema] with its `$ref` followed, as a map ({} when there is none).
  Map _schemaOf(Object? schema) => _deref(schema) ?? const {};

  /// All properties of an object schema, including those from `allOf`.
  Map<String, dynamic> _properties(Object? schema, [int depth = 0]) {
    final out = <String, dynamic>{};
    if (depth > 8) return out;
    final s = _schemaOf(schema);
    for (final part in _list(s['allOf'])) {
      out.addAll(_properties(part, depth + 1));
    }
    _map(s['properties']).forEach((k, v) => out['$k'] = v);
    return out;
  }

  List<KV> _formFields(
    Object? schema,
    Object? example, {
    required bool multipart,
  }) {
    final fields = <KV>[];
    _properties(schema).forEach((name, prop) {
      final s = _schemaOf(prop);
      final items = _schemaOf(s['items']);
      final isFile =
          s['type'] == 'file' ||
          (s['type'] == 'string' && s['format'] == 'binary') ||
          (s['type'] == 'array' && items['format'] == 'binary');
      Object? value = example is Map && example.containsKey(name)
          ? example[name]
          : requestSampler.sample(prop);
      if (value is List && value.isNotEmpty) value = value.first;
      fields.add(
        KV(
          key: name,
          value: isFile ? '' : _str(value),
          isFile: isFile && multipart,
          description: _text(s['description']),
        ),
      );
    });
    return fields;
  }

  String _rootName(Object? schema) {
    if (schema is Map) {
      final ref = schema[r'$ref'];
      final xml = _map(_schemaOf(schema)['xml'])['name'];
      if (xml != null) return '$xml';
      if (ref is String) return ref.split('/').last;
    }
    return 'root';
  }

  /// A small XML rendering of a sample value: maps become child elements,
  /// lists repeat their element.
  String _xml(String root, Object? value) {
    final b = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n');
    void write(String name, Object? v, int depth) {
      final pad = '  ' * depth;
      if (v is List) {
        for (final x in v) {
          write(name, x, depth);
        }
      } else if (v is Map) {
        b.writeln('$pad<$name>');
        v.forEach((k, x) => write('$k', x, depth + 1));
        b.writeln('$pad</$name>');
      } else {
        b.writeln('$pad<$name>${_escapeXml(_str(v))}</$name>');
      }
    }

    write(root, value, 0);
    return b.toString().trimRight();
  }

  static String _escapeXml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  String _str(Object? v) => switch (v) {
    null => '',
    String() => v,
    Map() || List() => jsonEncode(v),
    _ => '$v',
  };

  // -- responses --

  void _responses(RequestModel m, Map op) {
    _map(op['responses']).forEach((code, raw) {
      final status = int.tryParse('$code');
      if (status == null) return; // "default" and "2XX" have no one status
      final resp = _deref(raw);
      if (resp == null) return;
      final reason = httpReason(status);
      final base = '$status${reason.isEmpty ? '' : ' $reason'}';

      // (media type, example name, value) for every example given.
      final found = <(String, String?, Object?)>[];
      if (v2) {
        _map(resp['examples']).forEach((mt, v) => found.add(('$mt', null, v)));
        final schema = _schemaOf(resp['schema']);
        if (found.isEmpty && schema.containsKey('example')) {
          final produces = _list(
            _list(op['produces']).isNotEmpty ? op['produces'] : doc['produces'],
          );
          found.add((
            produces.isEmpty ? 'application/json' : '${produces.first}',
            null,
            schema['example'],
          ));
        }
      } else {
        _map(resp['content']).forEach((mt, rawMedia) {
          final media = _map(rawMedia);
          if (media.containsKey('example')) {
            found.add(('$mt', null, media['example']));
          }
          _map(media['examples']).forEach((name, e) {
            final ex = _deref(e);
            if (ex == null || !ex.containsKey('value')) return;
            final summary = _text(ex['summary']);
            found.add((
              '$mt',
              summary.isNotEmpty ? summary : '$name',
              ex['value'],
            ));
          });
          if (!media.containsKey('example') && media['examples'] == null) {
            final schema = _schemaOf(media['schema']);
            if (schema.containsKey('example')) {
              found.add(('$mt', null, schema['example']));
            }
          }
        });
      }
      if (found.isEmpty) return;

      final extra = <KV>[
        for (final e in _map(resp['headers']).entries)
          if (_deref(e.value) case final h?)
            KV(
              key: '${e.key}',
              value: _headerSample(h),
              description: _text(h['description']),
            ),
      ];
      final types = found.map((f) => f.$1).toSet();
      for (final (mt, name, value) in found) {
        final json = mt.toLowerCase().contains('json');
        final body = value is String && !json
            ? value
            : (json
                  ? _jsonText(value, null)
                  : (value == null ? '' : _str(value)));
        m.examples.add(
          ResponseExample(
            name:
                (name == null
                    ? base
                    : (name.startsWith(base) ? name : '$base - $name')) +
                (types.length > 1 ? ' ($mt)' : ''),
            statusCode: status,
            statusText: reason,
            headers: [
              KV(key: 'Content-Type', value: mt),
              ...extra,
            ],
            body: body,
          ),
        );
      }
    });
  }

  String _headerSample(Map h) {
    Object? v = h['example'] ?? h['x-example'];
    v ??= anySampler.sample(h['schema'] ?? (v2 ? h : null));
    return _str(v is List ? v.join(',') : v);
  }
}
