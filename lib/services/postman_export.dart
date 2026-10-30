import 'dart:convert';

import '../models/models.dart';

/// The schema URL Postman writes into `info.schema` of a v2.1 collection.
const postmanCollectionSchema =
    'https://schema.getpostman.com/json/collection/v2.1.0/collection.json';

/// A finished Postman export plus what could not be (or had to be changed
/// to be) written.
class PostmanExport {
  PostmanExport(
    this.json, {
    this.requests = 0,
    this.folders = 0,
    this.skipped = const [],
    this.notes = const [],
  });

  /// The file's text (pretty-printed JSON).
  final String json;

  /// Requests and folders written (collections only).
  final int requests;
  final int folders;

  /// One line per request left out, e.g. WebSocket requests, which the
  /// Postman collection format has no place for.
  final List<String> skipped;

  /// Things that were converted rather than copied, such as declarative
  /// tests turned into a script.
  final List<String> notes;
}

const _indent = JsonEncoder.withIndent('  ');

/// [c] as a Postman Collection v2.1 file: folders with their descriptions,
/// auth and scripts, requests with every body mode, auth, path variables,
/// scripts, examples and settings (`protocolProfileBehavior`), and the
/// collection's own auth, scripts, variables and description.
///
/// Variables carry their initial value; with [includeCurrentValues] the
/// local current value is written instead where there is one, the way
/// Postman does when asked to. Requests of other kinds than HTTP are left
/// out and listed in [PostmanExport.skipped].
PostmanExport buildPostmanCollection(
  CollectionModel c, {
  bool includeCurrentValues = false,
}) {
  final skipped = <String>[];
  final stats = _Stats();

  final root = _Folder('', '');
  _Folder folderAt(String path) {
    var node = root;
    var built = '';
    for (final seg in path.split('/')) {
      if (seg.isEmpty) continue;
      built = built.isEmpty ? seg : '$built/$seg';
      final parent = node;
      final path = built;
      node = parent.folders.putIfAbsent(path, () {
        final f = _Folder(seg, path);
        parent.entries.add(f);
        return f;
      });
    }
    return node;
  }

  for (final r in c.requests) {
    if (r.kind != RequestKind.http) {
      skipped.add(
        '${r.kind.label} request "${r.name}": the Postman collection format '
        'has no ${r.kind.label} requests.',
      );
      continue;
    }
    folderAt(r.folder).entries.add(r);
  }
  // Folders that exist only through their settings.
  for (final path in c.folders.keys) {
    folderAt(path);
  }

  Object item(Object e) {
    if (e is RequestModel) {
      stats.requests++;
      return _item(e, stats);
    }
    final f = e as _Folder;
    stats.folders++;
    final meta = c.folders[f.path];
    final auth = meta == null ? null : _auth(meta.auth);
    final events = meta == null
        ? const <Map<String, dynamic>>[]
        : _events(meta.preRequestScript, meta.testScript);
    return {
      'name': f.name.replaceAll('∕', '/'),
      if (meta != null && meta.description.isNotEmpty)
        'description': meta.description,
      'item': [for (final x in f.entries) item(x)],
      'auth': ?auth,
      if (events.isNotEmpty) 'event': events,
    };
  }

  // No auth on a collection is the same as an absent key.
  final auth = c.auth.type == AuthType.none ? null : _auth(c.auth);
  final events = _events(c.preRequestScript, c.testScript);
  final variables = [
    for (final v in c.variables)
      if (v.key.isNotEmpty) _collectionVariable(v, includeCurrentValues),
  ];
  final doc = <String, dynamic>{
    'info': {
      '_postman_id': c.id,
      'name': c.name,
      if (c.description.isNotEmpty) 'description': c.description,
      'schema': postmanCollectionSchema,
    },
    'item': [for (final e in root.entries) item(e)],
    'auth': ?auth,
    if (events.isNotEmpty) 'event': events,
    if (variables.isNotEmpty) 'variable': variables,
  };

  return PostmanExport(
    _indent.convert(doc),
    requests: stats.requests,
    folders: stats.folders,
    skipped: skipped,
    notes: [
      if (stats.assertions + stats.captures > 0)
        '${stats.assertions} test(s) and ${stats.captures} captured value(s) '
            'were written into the requests\' test scripts, since Postman '
            'only has scripts.',
    ],
  );
}

/// [e] as a Postman environment file. Secret variables get
/// `"type": "secret"`; disabled variables stay, flagged `"enabled": false`.
PostmanExport buildPostmanEnvironment(
  EnvironmentModel e, {
  bool includeCurrentValues = false,
}) => PostmanExport(
  _indent.convert(
    _variableScope(
      e.id,
      e.name,
      'environment',
      e.variables,
      includeCurrentValues,
    ),
  ),
);

/// [globals] as a Postman globals file.
PostmanExport buildPostmanGlobals(
  List<KV> globals, {
  bool includeCurrentValues = false,
  String name = 'Globals',
}) => PostmanExport(
  _indent.convert(
    _variableScope(newId(), name, 'globals', globals, includeCurrentValues),
  ),
);

Map<String, dynamic> _variableScope(
  String id,
  String name,
  String scope,
  List<KV> vars,
  bool current,
) => {
  'id': id,
  'name': name,
  'values': [
    for (final v in vars)
      if (v.key.isNotEmpty)
        {
          'key': v.key,
          'value': current ? v.effective : v.value,
          'type': v.secret ? 'secret' : 'default',
          'enabled': v.enabled,
          if (v.description.isNotEmpty) 'description': v.description,
        },
  ],
  '_postman_variable_scope': scope,
  '_postman_exported_at': DateTime.now().toUtc().toIso8601String(),
  '_postman_exported_using': 'ApiWorkbench',
};

Map<String, dynamic> _collectionVariable(KV v, bool current) => {
  'key': v.key,
  'value': current ? v.effective : v.value,
  'type': v.secret ? 'secret' : 'string',
  if (!v.enabled) 'disabled': true,
  if (v.description.isNotEmpty) 'description': v.description,
};

class _Stats {
  int requests = 0;
  int folders = 0;
  int assertions = 0;
  int captures = 0;
}

/// A folder in the tree being built; [entries] keeps requests and
/// sub-folders in the order they first appear.
class _Folder {
  _Folder(this.name, this.path);

  /// The path segment; the app swaps a '/' in a folder's name for '∕'.
  final String name;
  final String path;
  final entries = <Object>[];
  final folders = <String, _Folder>{};
}

// ---- requests ------------------------------------------------------------

Map<String, dynamic> _item(RequestModel r, _Stats stats) {
  final settings = _profileBehavior(r.settings);
  final tests = _testScript(r, stats);
  final events = _events(r.preRequestScript, tests);
  return {
    'name': r.name,
    if (settings.isNotEmpty) 'protocolProfileBehavior': settings,
    if (events.isNotEmpty) 'event': events,
    'request': _request(r),
    'response': [for (final e in r.examples) _example(e)],
  };
}

Map<String, dynamic> _request(RequestModel r) {
  final auth = _auth(r.auth);
  final body = _body(r);
  return {
    'auth': ?auth,
    'method': r.method,
    'header': _rows(r.headers),
    'body': ?body,
    'url': _url(r),
    if (r.description.isNotEmpty) 'description': r.description,
  };
}

/// Header, query and form rows. Rows without a name are not representable.
List<Map<String, dynamic>> _rows(List<KV> rows, {bool text = false}) => [
  for (final k in rows)
    if (k.key.isNotEmpty)
      {
        'key': k.key,
        'value': k.value,
        if (text) 'type': 'text',
        if (!k.enabled) 'disabled': true,
        if (k.description.isNotEmpty) 'description': k.description,
      },
];

Map<String, dynamic> _url(RequestModel r) {
  var base = r.url;
  var fragment = '';
  final hash = base.indexOf('#');
  if (hash >= 0) {
    fragment = base.substring(hash);
    base = base.substring(0, hash);
  }
  // A query typed straight into the URL joins the Params rows.
  final query = <KV>[];
  final q = base.indexOf('?');
  if (q >= 0) {
    for (final part in base.substring(q + 1).split('&')) {
      if (part.isEmpty) continue;
      final eq = part.indexOf('=');
      query.add(
        eq < 0
            ? KV(key: part)
            : KV(key: part.substring(0, eq), value: part.substring(eq + 1)),
      );
    }
    base = base.substring(0, q);
  }
  query.addAll(r.params.where((p) => p.key.isNotEmpty));
  final live = query.where((p) => p.enabled);
  final raw =
      '$base${live.isEmpty ? '' : '?${live.map((p) => '${p.key}=${p.value}').join('&')}'}'
      '$fragment';

  // Pieces, as Postman's url object has them. `raw` is what is imported;
  // the rest is for tools that read the parts.
  var rest = base;
  String? protocol;
  final scheme = RegExp(r'^([A-Za-z][A-Za-z0-9+.\-]*)://').firstMatch(rest);
  if (scheme != null) {
    protocol = scheme.group(1);
    rest = rest.substring(scheme.end);
  }
  final slash = rest.indexOf('/');
  var authority = slash < 0 ? rest : rest.substring(0, slash);
  final path = slash < 0 ? null : rest.substring(slash + 1).split('/');
  String? port;
  if (!authority.contains('@')) {
    final p = RegExp(r'^(.+):(\d+|\{\{[^}]*\}\})$').firstMatch(authority);
    if (p != null) {
      authority = p.group(1)!;
      port = p.group(2);
    }
  }
  final host = authority.contains('@')
      ? [authority]
      : _splitOutsideBraces(authority);

  return {
    'raw': raw,
    'protocol': ?protocol,
    if (host.isNotEmpty) 'host': host,
    'port': ?port,
    'path': ?path,
    if (query.isNotEmpty)
      'query': [
        for (final p in query)
          {
            'key': p.key,
            'value': p.value,
            if (!p.enabled) 'disabled': true,
            if (p.description.isNotEmpty) 'description': p.description,
          },
      ],
    if (r.pathVariables.any((v) => v.key.isNotEmpty))
      'variable': [
        for (final v in r.pathVariables)
          if (v.key.isNotEmpty)
            {
              'key': v.key,
              'value': v.value,
              if (!v.enabled) 'disabled': true,
              if (v.description.isNotEmpty) 'description': v.description,
            },
      ],
    if (fragment.length > 1) 'hash': fragment.substring(1),
  };
}

/// Splits a host on '.', except inside `{{ }}`.
List<String> _splitOutsideBraces(String host) {
  if (host.isEmpty) return const [];
  final parts = <String>[];
  var depth = 0;
  var start = 0;
  for (var i = 0; i < host.length; i++) {
    if (host.startsWith('{{', i)) {
      depth++;
      i++;
    } else if (host.startsWith('}}', i) && depth > 0) {
      depth--;
      i++;
    } else if (host[i] == '.' && depth == 0) {
      parts.add(host.substring(start, i));
      start = i + 1;
    }
  }
  parts.add(host.substring(start));
  return parts;
}

Map<String, dynamic>? _body(RequestModel r) {
  switch (r.bodyType) {
    case BodyType.none:
      return null;
    case BodyType.json || BodyType.text || BodyType.xml:
      // An empty raw body is the same as no body.
      if (r.body.isEmpty) return null;
      return {
        'mode': 'raw',
        'raw': r.body,
        'options': {
          'raw': {
            'language': switch (r.bodyType) {
              BodyType.json => 'json',
              BodyType.xml => 'xml',
              _ => 'text',
            },
          },
        },
      };
    case BodyType.formUrlEncoded:
      return {
        'mode': 'urlencoded',
        'urlencoded': _rows(r.formFields, text: true),
      };
    case BodyType.formData:
      return {
        'mode': 'formdata',
        'formdata': [
          for (final f in r.formFields)
            if (f.key.isNotEmpty)
              {
                'key': f.key,
                if (f.isFile) 'type': 'file' else 'type': 'text',
                if (f.isFile) 'src': f.value else 'value': f.value,
                if (!f.enabled) 'disabled': true,
                if (f.description.isNotEmpty) 'description': f.description,
              },
        ],
      };
    case BodyType.graphql:
      return {
        'mode': 'graphql',
        'graphql': {'query': r.body, 'variables': r.graphqlVariables},
      };
    case BodyType.binary:
      return {
        'mode': 'file',
        'file': {if (r.body.isNotEmpty) 'src': r.body},
      };
  }
}

// ---- auth ----------------------------------------------------------------

/// Attributes Postman stores as booleans; the app keeps every attribute as
/// text, so "true"/"false" in these goes back out as real booleans.
const _booleanAttrs = {
  'useBrowser',
  'addParamsToHeader',
  'addEmptyParamsToSign',
  'includeBodyHash',
  'disableRetryRequest',
  'includePayloadHash',
  'isSecretBase64Encoded',
  'addAuthDataToQuery',
  'showPassword',
};

/// Attributes that hold JSON arrays in Postman's OAuth 2.0 settings.
const _jsonAttrs = {
  'tokenRequestParams',
  'refreshRequestParams',
  'authRequestParams',
};

/// Postman's auth object, or null for "inherit" (an absent `auth` key means
/// exactly that in Postman) and for a collection with no auth.
Map<String, dynamic>? _auth(AuthConfig a) {
  final String type;
  final attrs = <String, String>{};
  switch (a.type) {
    case AuthType.inherit:
      return null;
    case AuthType.none:
      return {'type': 'noauth'};
    case AuthType.bearer:
      type = 'bearer';
      attrs['token'] = a.bearerToken;
    case AuthType.basic:
      type = 'basic';
      attrs['username'] = a.basicUser;
      attrs['password'] = a.basicPassword;
    case AuthType.apiKey:
      type = 'apikey';
      attrs['key'] = a.apiKeyName;
      attrs['value'] = a.apiKeyValue;
      attrs['in'] = a.apiKeyInHeader ? 'header' : 'query';
    default:
      type = a.type.postmanName;
  }
  attrs.addAll(a.params);
  return {
    'type': type,
    type: [for (final e in attrs.entries) _attribute(e.key, e.value)],
  };
}

Map<String, dynamic> _attribute(String key, String value) {
  if (_booleanAttrs.contains(key) && (value == 'true' || value == 'false')) {
    return {'key': key, 'value': value == 'true', 'type': 'boolean'};
  }
  if (_jsonAttrs.contains(key)) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is List || decoded is Map) {
        return {'key': key, 'value': decoded, 'type': 'any'};
      }
    } catch (_) {}
  }
  return {'key': key, 'value': value, 'type': 'string'};
}

// ---- scripts, settings, examples -----------------------------------------

List<Map<String, dynamic>> _events(String pre, String tests) => [
  if (pre.trim().isNotEmpty) _event('prerequest', pre),
  if (tests.trim().isNotEmpty) _event('test', tests),
];

Map<String, dynamic> _event(String listen, String script) => {
  'listen': listen,
  'script': {
    'type': 'text/javascript',
    'exec': script.replaceAll('\r\n', '\n').split('\n'),
  },
};

Map<String, dynamic> _profileBehavior(RequestSettings s) => {
  'followRedirects': ?s.followRedirects,
  'maxRedirects': ?s.maxRedirects,
  'strictSSL': ?s.verifySsl,
  if (!s.encodeUrl) 'disableUrlEncoding': true,
  if (!s.useCookies) 'disableCookies': true,
  'timeout': ?s.timeoutMs,
  if (s.followOriginalMethod) 'followOriginalHttpMethod': true,
  if (s.followAuthorizationHeader) 'followAuthorizationHeader': true,
  if (s.removeRefererOnRedirect) 'removeRefererHeaderOnRedirect': true,
};

Map<String, dynamic> _example(ResponseExample e) => {
  'name': e.name,
  if (e.originalRequest != null)
    'originalRequest': _request(e.originalRequest!),
  'status': e.statusText,
  'code': e.statusCode,
  '_postman_previewlanguage': _previewLanguage(e.contentType),
  'header': _rows(e.headers),
  'cookie': <Object>[],
  'body': e.body,
};

String _previewLanguage(String? contentType) {
  final ct = (contentType ?? '').toLowerCase();
  if (ct.contains('json')) return 'json';
  if (ct.contains('xml')) return 'xml';
  if (ct.contains('html')) return 'html';
  return 'text';
}

// ---- declarative tests ---------------------------------------------------

/// The request's test script, with its assertions and captures appended as
/// script code. Postman has no declarative tests, and leaving them out
/// would silently drop checks the user relies on.
String _testScript(RequestModel r, _Stats stats) {
  final blocks = <String>[];
  for (final a in r.assertions.where((a) => a.enabled)) {
    final block = _assertion(a);
    if (block != null) {
      blocks.add(block);
      stats.assertions++;
    }
  }
  for (final e in r.captures.entries) {
    final block = _capture(e.key.trim(), e.value.trim());
    if (block != null) {
      blocks.add(block);
      stats.captures++;
    }
  }
  if (blocks.isEmpty) return r.testScript;
  final generated = ['// Tests and captures from ApiWorkbench', ...blocks];
  return [
    if (r.testScript.trim().isNotEmpty) r.testScript,
    generated.join('\n'),
  ].join('\n\n');
}

String _js(String s) => jsonEncode(s);

String? _assertion(AssertionModel a) {
  final want = a.expected;
  String test(String title, String check) =>
      'pm.test(${_js(title)}, function () {\n  $check\n});';
  switch (a.kind) {
    case AssertKind.statusEquals:
      final cls = RegExp(
        r'^([1-5])xx$',
        caseSensitive: false,
      ).firstMatch(want.trim());
      if (cls != null) {
        return test(
          'Status is ${want.trim()}',
          'pm.expect(Math.floor(pm.response.code / 100)).to.eql(${cls.group(1)});',
        );
      }
      final code = int.tryParse(want.trim());
      return code == null
          ? null
          : test('Status is $code', 'pm.response.to.have.status($code);');
    case AssertKind.bodyContains:
      return test(
        'Body contains ${_js(want)}',
        'pm.expect(pm.response.text()).to.include(${_js(want)});',
      );
    case AssertKind.jsonEquals:
      return test(
        '${a.target} equals ${_js(want)}',
        'pm.expect(String(${_jsonAccess(a.target.trim())})).to.eql(${_js(want)});',
      );
    case AssertKind.headerContains:
      final name = a.target.trim();
      if (name.isEmpty) return null;
      return want.isEmpty
          ? test(
              'Header $name is present',
              'pm.response.to.have.header(${_js(name)});',
            )
          : test(
              'Header $name contains ${_js(want)}',
              'pm.expect(String(pm.response.headers.get(${_js(name)}))).to.include(${_js(want)});',
            );
    case AssertKind.timeBelow:
      final ms = int.tryParse(want.trim());
      return ms == null
          ? null
          : test(
              'Response time is below $ms ms',
              'pm.expect(pm.response.responseTime).to.be.below($ms);',
            );
  }
}

String? _capture(String name, String source) {
  if (name.isEmpty || source.isEmpty) return null;
  final String value;
  if (source == 'status') {
    value = 'pm.response.code';
  } else if (source.startsWith('header.')) {
    value = 'pm.response.headers.get(${_js(source.substring(7))})';
  } else {
    value = _jsonAccess(
      source.startsWith('body.') ? source.substring(5) : source,
    );
  }
  return 'try {\n'
      '  const value = $value;\n'
      '  if (value !== undefined && value !== null) {\n'
      '    pm.environment.set(${_js(name)}, '
      'typeof value === "string" ? value : JSON.stringify(value));\n'
      '  }\n'
      '} catch (e) {}';
}

/// `data.items[0].id` as JavaScript reading from the parsed response body.
String _jsonAccess(String path) {
  final out = StringBuffer('pm.response.json()');
  for (final m in RegExp(r'([^.\[\]]+)|\[(\d+)\]').allMatches(path)) {
    final key = m.group(1);
    if (key == null) {
      out.write('[${m.group(2)}]');
    } else if (RegExp(r'^[A-Za-z_$][\w$]*$').hasMatch(key)) {
      out.write('.$key');
    } else {
      out.write('[${_js(key)}]');
    }
  }
  return out.toString();
}
