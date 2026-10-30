import 'dart:convert';

import '../models/models.dart';
import 'import_report.dart';
import 'workspace.dart';

export 'import_report.dart';

/// Imports one file's text: a Postman collection (v1, v2.0, v2.1), a
/// Postman environment or globals file, a Postman "Export data" dump, or an
/// ApiWorkbench workspace. Results accumulate into [into] so several files
/// can share one report. Throws [FormatException] for anything else.
ImportReport importApiFile(String raw, {ImportReport? into}) {
  final report = into ?? ImportReport();
  final Object? json;
  try {
    json = jsonDecode(raw);
  } catch (_) {
    throw const FormatException('The file is not valid JSON.');
  }
  _importValue(json, report);
  return report;
}

bool _isItem(Object? x) =>
    x is Map && (x['request'] != null || x['item'] is List);

/// Wraps loose Postman items (a single request, a list of requests or
/// folders, or `{"item": [...]}` without collection info) in a collection.
Map<String, dynamic> _wrapItems(List<dynamic> items, String name) => {
  'info': {'name': name},
  'item': items,
};

void _importValue(Object? json, ImportReport r) {
  if (json is List && json.isNotEmpty && json.every(_isItem)) {
    r.formats.add('Postman requests');
    r.collections.add(_V2(r).collection(_wrapItems(json, 'Imported requests')));
    return;
  }
  if (json is List) {
    var any = false;
    for (final x in json) {
      if (x is Map<String, dynamic>) {
        _importValue(x, r);
        any = true;
      }
    }
    if (!any) throw const FormatException('The file has nothing to import.');
    return;
  }
  if (json is! Map<String, dynamic>) {
    throw const FormatException('The file has nothing to import.');
  }

  if (json['app'] == 'apiworkbench') {
    final ws = parseWorkspaceJson(jsonEncode(json));
    r.collections.addAll(ws.collections);
    r.environments.addAll(ws.environments);
    r.globals.addAll(ws.globals);
    r.requests += ws.collections.fold(0, (s, c) => s + c.requests.length);
    r.formats.add('ApiWorkbench workspace');
    return;
  }

  if (json['info'] == null && _isItem(json)) {
    // A request or a named folder is one item; a bare {"item": [...]} is a
    // list of them.
    r.formats.add('Postman requests');
    final single = json['request'] != null || json['name'] != null;
    final items = single ? [json] : json['item'] as List;
    r.collections.add(
      _V2(r).collection(_wrapItems(items, 'Imported requests')),
    );
    return;
  }

  final info = json['info'];
  if (info is Map &&
      (json['item'] is List || '${info['schema']}'.contains('collection'))) {
    final schema = '${info['schema'] ?? ''}';
    r.formats.add(
      schema.contains('v2.0')
          ? 'Postman collection v2.0'
          : 'Postman collection v2.1',
    );
    r.collections.add(_V2(r).collection(json));
    return;
  }

  // "Export data" dump: { version, collections: [...], environments: [...] }
  if (json['collections'] is List ||
      json['environments'] is List ||
      (json['globals'] is List && json['version'] != null)) {
    r.formats.add('Postman data export');
    for (final c in (json['collections'] as List? ?? [])) {
      if (c is Map<String, dynamic>) _importValue(c, r);
    }
    for (final e in (json['environments'] as List? ?? [])) {
      if (e is Map<String, dynamic>) r.environments.add(_environment(e));
    }
    r.globals.addAll(_dumpGlobals(json['globals']));
    return;
  }

  if (json['requests'] is List &&
      (json['order'] is List ||
          json['folders'] is List ||
          json['id'] != null)) {
    r.formats.add('Postman collection v1');
    r.collections.add(_V2(r).collection(_v1ToV2(json)));
    return;
  }

  final scope = json['_postman_variable_scope'];
  if (scope == 'globals') {
    r.formats.add('Postman globals');
    r.globals.addAll(_vars(json['values']));
    return;
  }
  if (json['values'] is List &&
      (scope == 'environment' || json['name'] != null)) {
    r.formats.add('Postman environment');
    r.environments.add(_environment(json));
    return;
  }

  throw const FormatException(
    'Not a Postman collection, environment or globals file, nor an '
    'ApiWorkbench workspace.',
  );
}

// ---- environments and variables --------------------------------------------

EnvironmentModel _environment(Map<String, dynamic> j) => EnvironmentModel(
  name: '${j['name'] ?? 'Postman environment'}',
  variables: _vars(j['values']),
);

/// Variables of a Postman environment, globals or collection. Postman marks
/// secrets with `type: secret`; disabled rows and descriptions are kept.
List<KV> _vars(Object? list) => [
  for (final v in (list is List ? list : const []))
    if (v is Map && (v['key'] ?? '').toString().isNotEmpty) _variable(v),
];

KV _variable(Map v) {
  final value = _str(v['value']);
  // Some exports carry the local value next to the initial one.
  final current = v['currentValue'] == null ? null : _str(v['currentValue']);
  return KV(
    key: '${v['key']}',
    value: value,
    enabled: v['enabled'] != false && v['disabled'] != true,
    secret: v['type'] == 'secret',
    current: current == value ? null : current,
    description: _description(v['description']),
  );
}

/// Globals from a data dump: a list of variables, or of `{values: [...]}`
/// scopes.
List<KV> _dumpGlobals(Object? globals) {
  if (globals is Map) return _vars(globals['values']);
  if (globals is! List) return const [];
  return [
    for (final g in globals)
      if (g is Map) ...(g['values'] is List ? _vars(g['values']) : _vars([g])),
  ];
}

String _str(Object? v) => switch (v) {
  null => '',
  String s => s,
  Map() || List() => jsonEncode(v),
  _ => '$v',
};

String _description(Object? d) => switch (d) {
  String s => s,
  Map m => _str(m['content']),
  _ => '',
};

// ---- collection v2.x -------------------------------------------------------

class _V2 {
  _V2(this.r);
  final ImportReport r;

  CollectionModel collection(Map<String, dynamic> j) {
    final info = j['info'] as Map? ?? {};
    final events = _scripts(j['event']);
    final col = CollectionModel(
      name: '${info['name'] ?? 'Imported collection'}',
      variables: _vars(j['variable']),
      description: _description(info['description']),
      // An absent collection auth means no auth; requests that inherit
      // then send nothing.
      auth: _collectionAuth(j['auth']),
      preRequestScript: events.pre,
      testScript: events.tests,
    );
    _countScripts(events);
    _items(j['item'], col, const []);
    return col;
  }

  AuthConfig _collectionAuth(Object? a) {
    final auth = _auth(a);
    return auth == null || auth.type == AuthType.inherit ? AuthConfig() : auth;
  }

  void _countScripts(({String tests, String pre}) s) {
    if (s.pre.isNotEmpty) r.scriptsKept++;
    if (s.tests.isNotEmpty) r.scriptsKept++;
  }

  void _items(Object? items, CollectionModel col, List<String> path) {
    if (items is! List) return;
    for (final it in items) {
      if (it is! Map<String, dynamic>) continue;
      if (it['item'] is List) {
        r.folders++;
        final name = '${it['name'] ?? ''}'.trim().isEmpty
            ? 'Folder'
            : '${it['name']}'.replaceAll('/', '∕');
        final here = [...path, name];
        final ev = _scripts(it['event']);
        _countScripts(ev);
        _folderMeta(
          col,
          here.join('/'),
          FolderMeta(
            description: _description(it['description']),
            auth: _auth(it['auth']),
            preRequestScript: ev.pre,
            testScript: ev.tests,
          ),
        );
        _items(it['item'], col, here);
      } else {
        col.requests.add(_request(it, path.join('/')));
      }
    }
  }

  /// Two folders with the same name share one path; the later one only
  /// fills in what the earlier one left empty.
  static void _folderMeta(CollectionModel col, String key, FolderMeta meta) {
    if (meta.isEmpty) return;
    final old = col.folders[key];
    if (old == null) {
      col.folders[key] = meta;
      return;
    }
    if (old.description.isEmpty) old.description = meta.description;
    if (old.auth.type == AuthType.inherit) old.auth = meta.auth;
    if (old.preRequestScript.isEmpty) {
      old.preRequestScript = meta.preRequestScript;
    }
    if (old.testScript.isEmpty) old.testScript = meta.testScript;
  }

  RequestModel _request(Map<String, dynamic> it, String folder) {
    r.requests++;
    final name = '${it['name'] ?? 'Request'}';
    final m = _requestObject(it['request'], name, it['description']);
    m.folder = folder;

    final own = _scripts(it['event']);
    m.preRequestScript = own.pre;
    m.testScript = own.tests;
    _countScripts(own);
    m.settings = _settings(it['protocolProfileBehavior']);
    m.examples = _examples(it['response'], name);
    r.examples += m.examples.length;
    if (m.bodyType != BodyType.none && m.method == 'HEAD') {
      r.bodiesOnGetOrHead++;
    }
    return m;
  }

  /// A Postman request object (also an example's `originalRequest`) as a
  /// model. No `auth` key means "inherit from the folder or collection".
  RequestModel _requestObject(Object? req, String name, Object? fallbackDesc) {
    final rq = req is String
        ? {'url': req, 'method': 'GET'}
        : (req as Map? ?? {});
    final m = RequestModel(
      name: name,
      method: '${rq['method'] ?? 'GET'}'.toUpperCase(),
      description: _description(rq['description'] ?? fallbackDesc),
    );
    _url(rq['url'], m);
    m.headers = _headers(rq['header']);
    _body(rq['body'], m);
    m.auth = _auth(rq['auth']) ?? AuthConfig(type: AuthType.inherit);
    return m;
  }

  // -- url --

  void _url(Object? url, RequestModel m) {
    String raw;
    List<KV>? query;
    final pathVars = <KV>[];
    if (url is Map) {
      raw = _str(url['raw']);
      if (raw.isEmpty) {
        final host = url['host'] is List
            ? (url['host'] as List).join('.')
            : _str(url['host']);
        final path = url['path'] is List
            ? (url['path'] as List).map(_str).join('/')
            : _str(url['path']);
        final proto = _str(url['protocol']);
        final port = _str(url['port']);
        final hash = _str(url['hash']);
        raw =
            '${proto.isEmpty ? '' : '$proto://'}$host${port.isEmpty ? '' : ':$port'}'
            '${path.isEmpty ? '' : '/$path'}${hash.isEmpty ? '' : '#$hash'}';
      }
      if (url['query'] is List) {
        query = [
          for (final q in url['query'] as List)
            if (q is Map && q['key'] != null)
              KV(
                key: _str(q['key']),
                value: _str(q['value']),
                enabled: q['disabled'] != true,
                description: _description(q['description']),
              ),
        ];
      }
      if (url['variable'] is List) {
        for (final v in url['variable'] as List) {
          if (v is Map && _str(v['key']).isNotEmpty) {
            pathVars.add(
              KV(
                key: _str(v['key']),
                value: _str(v['value']),
                enabled: v['disabled'] != true,
                description: _description(v['description']),
              ),
            );
          }
        }
      }
    } else {
      raw = _str(url);
    }

    // The query lives in the Params table; the URL keeps only the base.
    var base = raw;
    var fragment = '';
    final hash = base.indexOf('#');
    if (hash >= 0) {
      fragment = base.substring(hash);
      base = base.substring(0, hash);
    }
    final q = base.indexOf('?');
    if (q >= 0) {
      query ??= _parseQuery(base.substring(q + 1));
      base = base.substring(0, q);
    }
    // `:name` segments stay in the URL; the values live in pathVariables.
    m.url = '$base$fragment';
    m.params = query ?? [];
    m.pathVariables = pathVars;
  }

  static List<KV> _parseQuery(String q) => [
    for (final part in q.split('&'))
      if (part.isNotEmpty)
        part.contains('=')
            ? KV(
                key: part.substring(0, part.indexOf('=')),
                value: part.substring(part.indexOf('=') + 1),
              )
            : KV(key: part),
  ];

  // -- headers --

  static List<KV> _headers(Object? h) {
    if (h is String) {
      return [
        for (final line in h.split('\n'))
          if (line.contains(':'))
            KV(
              key: line
                  .substring(0, line.indexOf(':'))
                  .replaceFirst(RegExp(r'^\s*//\s*'), '')
                  .trim(),
              value: line.substring(line.indexOf(':') + 1).trim(),
              enabled: !line.trimLeft().startsWith('//'),
            ),
      ];
    }
    return [
      for (final x in (h is List ? h : const []))
        if (x is Map && _str(x['key']).isNotEmpty)
          KV(
            key: _str(x['key']),
            value: _str(x['value']),
            enabled: x['disabled'] != true,
            description: _description(x['description']),
          ),
    ];
  }

  // -- body --

  void _body(Object? body, RequestModel m) {
    if (body is! Map || body['disabled'] == true) return;
    switch ('${body['mode'] ?? ''}') {
      case 'raw':
        final raw = _str(body['raw']);
        if (raw.isEmpty) return;
        final lang = '${(body['options'] as Map?)?['raw']?['language'] ?? ''}';
        m.body = raw;
        m.bodyType = switch (lang) {
          'json' => BodyType.json,
          'xml' => BodyType.xml,
          'text' || 'javascript' || 'html' => BodyType.text,
          _ => _guessRaw(raw, m.headers),
        };
      case 'urlencoded':
        m.bodyType = BodyType.formUrlEncoded;
        m.formFields = _fields(body['urlencoded'], files: false);
      case 'formdata':
        m.bodyType = BodyType.formData;
        m.formFields = _fields(body['formdata'], files: true);
      case 'file':
        m.bodyType = BodyType.binary;
        m.body = _str((body['file'] as Map?)?['src']);
      case 'graphql':
        final g = body['graphql'] as Map? ?? {};
        m.bodyType = BodyType.graphql;
        m.body = _str(g['query']);
        m.graphqlVariables = _str(g['variables']);
    }
  }

  static BodyType _guessRaw(String raw, List<KV> headers) {
    final ct = headers
        .where((h) => h.key.toLowerCase() == 'content-type')
        .map((h) => h.value.toLowerCase())
        .firstOrNull;
    if (ct != null) {
      if (ct.contains('json')) return BodyType.json;
      if (ct.contains('xml')) return BodyType.xml;
      return BodyType.text;
    }
    final t = raw.trimLeft();
    if (t.startsWith('{') || t.startsWith('[')) return BodyType.json;
    if (t.startsWith('<')) return BodyType.xml;
    return BodyType.text;
  }

  static List<KV> _fields(Object? list, {required bool files}) {
    final out = <KV>[];
    for (final f in (list is List ? list : const [])) {
      if (f is! Map || _str(f['key']).isEmpty) continue;
      final enabled = f['disabled'] != true;
      final description = _description(f['description']);
      if (files && f['type'] == 'file') {
        final src = f['src'];
        final paths = src is List ? src.map(_str).toList() : [_str(src)];
        for (final p in paths) {
          out.add(
            KV(
              key: _str(f['key']),
              value: p,
              enabled: enabled,
              isFile: true,
              description: description,
            ),
          );
        }
      } else {
        out.add(
          KV(
            key: _str(f['key']),
            value: _str(f['value']),
            enabled: enabled,
            description: description,
          ),
        );
      }
    }
    return out;
  }

  // -- auth --

  /// Postman's auth object as a config; null when there is no `auth` key,
  /// which means "inherit from the parent".
  ///
  /// Bearer, Basic and API key fill their dedicated fields; every other
  /// type keeps its attributes verbatim in [AuthConfig.params], values that
  /// are not strings (booleans, objects, arrays) as JSON text. Attributes
  /// a dedicated type has no field for ride along in params too.
  AuthConfig? _auth(Object? a) {
    if (a is! Map) return null;
    final name = '${a['type'] ?? ''}';
    if (name.isEmpty) return null;
    final type = authTypeFromPostman(name);
    if (type == null) {
      r.unsupportedAuth.update(name, (n) => n + 1, ifAbsent: () => 1);
      return AuthConfig();
    }
    if (type == AuthType.none || type == AuthType.inherit) {
      return AuthConfig(type: type);
    }
    final attrs = <String, String>{};
    final raw = a[name];
    if (raw is List) {
      for (final x in raw) {
        if (x is Map && x['key'] != null) {
          attrs['${x['key']}'] = _str(x['value']);
        }
      }
    } else if (raw is Map) {
      raw.forEach((k, v) => attrs['$k'] = _str(v));
    }
    final auth = AuthConfig(type: type);
    switch (type) {
      case AuthType.bearer:
        auth.bearerToken = attrs.remove('token') ?? '';
      case AuthType.basic:
        auth.basicUser = attrs.remove('username') ?? '';
        auth.basicPassword = attrs.remove('password') ?? '';
      case AuthType.apiKey:
        auth.apiKeyName = attrs.remove('key') ?? '';
        auth.apiKeyValue = attrs.remove('value') ?? '';
        auth.apiKeyInHeader = (attrs.remove('in') ?? 'header') != 'query';
      default:
        break;
    }
    auth.params = attrs;
    return auth;
  }

  // -- settings --

  /// `protocolProfileBehavior` → the request's Settings tab.
  /// `disableBodyPruning` needs nothing: bodies are sent on every method.
  static RequestSettings _settings(Object? ppb) {
    final s = RequestSettings();
    if (ppb is! Map) return s;
    bool? flag(String k) => ppb[k] is bool ? ppb[k] as bool : null;
    int? whole(String k) => ppb[k] is num ? (ppb[k] as num).toInt() : null;
    s.followRedirects = flag('followRedirects');
    s.maxRedirects = whole('maxRedirects');
    s.verifySsl = flag('strictSSL');
    s.encodeUrl = flag('disableUrlEncoding') != true;
    s.useCookies = flag('disableCookies') != true;
    s.timeoutMs = whole('timeout');
    s.followOriginalMethod = flag('followOriginalHttpMethod') ?? false;
    s.followAuthorizationHeader = flag('followAuthorizationHeader') ?? false;
    s.removeRefererOnRedirect = flag('removeRefererHeaderOnRedirect') ?? false;
    return s;
  }

  // -- examples --

  List<ResponseExample> _examples(Object? list, String requestName) => [
    for (final e in (list is List ? list : const []))
      if (e is Map)
        ResponseExample(
          name: '${e['name'] ?? 'Example'}',
          statusCode: int.tryParse(_str(e['code'])) ?? 200,
          statusText: _str(e['status']),
          headers: _headers(e['header']),
          body: _str(e['body']),
          originalRequest: e['originalRequest'] == null
              ? null
              : _requestObject(e['originalRequest'], requestName, null),
        ),
  ];

  // -- scripts --

  static ({String tests, String pre}) _scripts(Object? events) {
    var tests = '';
    var pre = '';
    for (final e in (events is List ? events : const [])) {
      if (e is! Map || e['disabled'] == true) continue;
      final script = e['script'];
      final exec = script is Map ? script['exec'] : null;
      final text = exec is List ? exec.map(_str).join('\n') : _str(exec);
      if (text.trim().isEmpty) continue;
      if (e['listen'] == 'test') tests = _join(tests, text);
      if (e['listen'] == 'prerequest') pre = _join(pre, text);
    }
    return (tests: tests, pre: pre);
  }
}

String _join(String a, String b) =>
    a.isEmpty ? b : (b.isEmpty ? a : '$a\n\n$b');

// ---- collection v1 → v2 ------------------------------------------------------

Map<String, dynamic> _v1ToV2(Map<String, dynamic> j) {
  final reqs = <String, Map<String, dynamic>>{
    for (final q in (j['requests'] as List))
      if (q is Map<String, dynamic>) '${q['id']}': q,
  };
  final folders = <String, Map<String, dynamic>>{
    for (final f in (j['folders'] as List? ?? []))
      if (f is Map<String, dynamic>) '${f['id']}': f,
  };
  final used = <String>{};

  // v1 saved responses: `responseCode` and `text` become v2's `code` and
  // `body`.
  Map<String, dynamic> example(Map x) {
    final code = x['responseCode'] as Map? ?? {};
    return {
      'name': x['name'] ?? 'Example',
      'code': code['code'] ?? x['code'],
      'status': code['name'] ?? x['status'],
      'header': x['headers'] ?? x['header'],
      'body': x['text'] ?? x['body'],
    };
  }

  Map<String, dynamic> request(Map<String, dynamic> q) {
    used.add('${q['id']}');
    final mode = '${q['dataMode'] ?? ''}';
    Map<String, dynamic>? body;
    List<Map<String, dynamic>> rows() => [
      for (final d in (q['data'] as List? ?? []))
        if (d is Map)
          {
            'key': d['key'],
            'value': d['value'],
            'type': d['type'] == 'file' ? 'file' : 'text',
            if (d['type'] == 'file') 'src': d['value'],
            'disabled': d['enabled'] == false,
          },
    ];
    switch (mode) {
      case 'raw':
        body = {'mode': 'raw', 'raw': q['rawModeData'] ?? ''};
      case 'urlencoded':
        body = {'mode': 'urlencoded', 'urlencoded': rows()};
      case 'params':
        body = {'mode': 'formdata', 'formdata': rows()};
      case 'binary':
        body = {
          'mode': 'file',
          'file': {'src': ''},
        };
      case 'graphql':
        final g = q['graphqlModeData'] as Map? ?? {};
        body = {'mode': 'graphql', 'graphql': g};
    }
    final headerData = q['headerData'];
    final events = [
      if ('${q['tests'] ?? ''}'.isNotEmpty)
        {
          'listen': 'test',
          'script': {'exec': '${q['tests']}'},
        },
      if ('${q['preRequestScript'] ?? ''}'.isNotEmpty)
        {
          'listen': 'prerequest',
          'script': {'exec': '${q['preRequestScript']}'},
        },
      ...(q['events'] as List? ?? []),
    ];
    Object? auth = q['auth'];
    if (auth == null && q['currentHelper'] == 'basicAuth') {
      final h = q['helperAttributes'] as Map? ?? {};
      auth = {
        'type': 'basic',
        'basic': {'username': h['username'], 'password': h['password']},
      };
    } else if (auth == null && q['currentHelper'] == 'bearerAuth') {
      final h = q['helperAttributes'] as Map? ?? {};
      auth = {
        'type': 'bearer',
        'bearer': {'token': h['token']},
      };
    }
    return {
      'name': q['name'] ?? q['url'],
      'request': {
        'method': q['method'] ?? 'GET',
        'url': {
          'raw': q['url'] ?? '',
          if (q['queryParams'] is List && (q['queryParams'] as List).isNotEmpty)
            'query': q['queryParams'],
          if (q['pathVariableData'] is List) 'variable': q['pathVariableData'],
        },
        'header': headerData is List
            ? headerData
                  .map(
                    (h) => h is Map
                        ? {...h, 'disabled': h['enabled'] == false}
                        : h,
                  )
                  .toList()
            : q['headers'],
        'body': ?body,
        'auth': ?auth,
        'description': q['description'],
      },
      'event': events,
      if (q['responses'] is List)
        'response': [
          for (final x in (q['responses'] as List))
            if (x is Map) example(x),
        ],
    };
  }

  Map<String, dynamic> folder(Map<String, dynamic> f) => {
    'name': f['name'] ?? 'Folder',
    'item': [
      for (final id in (f['folders_order'] as List? ?? []))
        if (folders['$id'] != null) folder(folders['$id']!),
      for (final id in (f['order'] as List? ?? []))
        if (reqs['$id'] != null) request(reqs['$id']!),
    ],
    if (f['auth'] != null) 'auth': f['auth'],
  };

  final nested = <String>{
    for (final f in folders.values)
      for (final id in (f['folders_order'] as List? ?? [])) '$id',
  };
  final items = <Map<String, dynamic>>[
    for (final id
        in (j['folders_order'] as List? ??
            folders.keys.where((k) => !nested.contains(k)).toList()))
      if (folders['$id'] != null) folder(folders['$id']!),
    for (final id in (j['order'] as List? ?? []))
      if (reqs['$id'] != null) request(reqs['$id']!),
  ];
  // Anything not referenced by an order list still gets imported.
  for (final q in reqs.values) {
    if (!used.contains('${q['id']}')) items.add(request(q));
  }
  return {
    'info': {
      'name': j['name'] ?? 'Imported collection',
      'description': j['description'],
    },
    'item': items,
    'variable': j['variables'],
    'auth': j['auth'],
    'event': j['events'],
  };
}

// ---- test script conversion --------------------------------------------------

class ScriptConversion {
  final assertions = <AssertionModel>[];
  final captures = <String, String>{};
}

final _status = <String, String>{
  'ok': '200', 'success': '2xx', 'created': '201', 'accepted': '202', //
  'withoutContent': '204', 'badRequest': '400', 'unauthorized': '401',
  'unauthorised': '401', 'forbidden': '403', 'notFound': '404',
  'rateLimited': '429', 'clientError': '4xx', 'serverError': '5xx',
  'info': '1xx', 'redirection': '3xx',
};

/// Turns the common Postman/Chai checks in a test script into declarative
/// assertions and `pm.*.set(...)` calls into captures. Anything else is
/// ignored.
///
/// The importer no longer calls this: imported scripts run as they are, and
/// converting them as well would run every check twice. It stays for tools
/// that want to offer a one-click conversion.
ScriptConversion convertTestScript(String script) {
  final out = ScriptConversion();
  final seen = <String>{};
  void add(AssertKind kind, String expected, [String target = '']) {
    if (seen.add('${kind.name}|$target|$expected')) {
      out.assertions.add(
        AssertionModel(kind: kind, target: target, expected: expected),
      );
    }
  }

  // Variables holding the parsed JSON body: `var jsonData = pm.response.json();`
  final jsonVars = <String>{
    for (final m in RegExp(
      r'(?:var|let|const)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:pm\.response\.json\(\)|JSON\.parse\(\s*(?:responseBody|pm\.response\.text\(\))\s*\))',
    ).allMatches(script))
      m.group(1)!,
  };
  const pathTail =
      r'((?:\.[A-Za-z_$][\w$]*|\[\s*\d+\s*\]|\[\s*["'
      "'"
      r'][^"'
      "'"
      r'\]]+["'
      "'"
      r']\s*\])*)';
  final jsonHead = [
    r'pm\.response\.json\(\)',
    for (final v in jsonVars) RegExp.escape(v),
  ].join('|');
  String path(String tail) => tail
      .replaceAllMapped(
        RegExp(r'''\[\s*["']([^"'\]]+)["']\s*\]'''),
        (m) => '.${m.group(1)}',
      )
      .replaceAll(RegExp(r'\s'), '')
      .replaceFirst(RegExp(r'^\.'), '');
  const lit =
      r'''("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|-?\d+(?:\.\d+)?|true|false|null)''';
  String unquote(String v) => (v.startsWith('"') || v.startsWith("'"))
      ? v.substring(1, v.length - 1)
      : v;

  // Status
  for (final m in RegExp(
    r'pm\.response\.to\.have\.status\(\s*(\d{3})\s*\)',
  ).allMatches(script)) {
    add(AssertKind.statusEquals, m.group(1)!);
  }
  for (final m in RegExp(
    r'pm\.response\.to\.(?:be|have)\.(\w+)\b(?!\s*\()',
  ).allMatches(script)) {
    final code = _status[m.group(1)];
    if (code != null) add(AssertKind.statusEquals, code);
  }
  for (final m in RegExp(
    r'pm\.expect\(\s*pm\.response\.(?:code|status)\s*\)\.to\.(?:eql|equal|eq|be\.equal|deep\.equal)\(\s*(\d{3})',
  ).allMatches(script)) {
    add(AssertKind.statusEquals, m.group(1)!);
  }
  for (final m in RegExp(
    r'responseCode\.code\s*===?\s*(\d{3})',
  ).allMatches(script)) {
    add(AssertKind.statusEquals, m.group(1)!);
  }

  // Response time
  for (final m in RegExp(
    r'pm\.expect\(\s*pm\.response\.responseTime\s*\)\.to\.be\.(?:below|lessThan|lt|under)\(\s*(\d+)',
  ).allMatches(script)) {
    add(AssertKind.timeBelow, m.group(1)!);
  }
  for (final m in RegExp(r'\bresponseTime\s*<\s*(\d+)').allMatches(script)) {
    add(AssertKind.timeBelow, m.group(1)!);
  }

  // Headers
  for (final m in RegExp(
    r'''pm\.response\.to\.have\.header\(\s*(["'])(.+?)\1\s*(?:,\s*(["'])(.*?)\3\s*)?\)''',
  ).allMatches(script)) {
    add(AssertKind.headerContains, m.group(4) ?? '', m.group(2)!);
  }
  for (final m in RegExp(
    r'''pm\.expect\(\s*pm\.response\.headers\.get\(\s*(["'])(.+?)\1\s*\)\s*\)\.to\.(?:eql|equal|eq|include|contain|have\.string)\(\s*(["'])(.*?)\3''',
  ).allMatches(script)) {
    add(AssertKind.headerContains, m.group(4)!, m.group(2)!);
  }
  for (final m in RegExp(
    r'''pm\.response\.headers\.has\(\s*(["'])(.+?)\1|postman\.getResponseHeader\(\s*(["'])(.+?)\3\s*\)''',
  ).allMatches(script)) {
    add(AssertKind.headerContains, '', m.group(2) ?? m.group(4)!);
  }

  // Body text
  for (final m in RegExp(
    r'''pm\.expect\(\s*pm\.response\.text\(\)\s*\)\.to\.(?:include|contain|have\.string)\(\s*(["'])(.*?)\1''',
  ).allMatches(script)) {
    add(AssertKind.bodyContains, m.group(2)!);
  }
  for (final m in RegExp(
    r'''pm\.response\.to\.have\.body\(\s*(["'])(.*?)\1|responseBody\.has\(\s*(["'])(.*?)\3|responseBody\.indexOf\(\s*(["'])(.*?)\5\s*\)\s*(?:!==?\s*-1|>\s*-1|>=\s*0)''',
  ).allMatches(script)) {
    add(AssertKind.bodyContains, m.group(2) ?? m.group(4) ?? m.group(6)!);
  }

  // JSON values: pm.expect(jsonData.a.b).to.eql(1) / tests[..] = jsonData.a === 1
  for (final m in RegExp(
    'pm\\.expect\\(\\s*(?:$jsonHead)$pathTail\\s*\\)\\.to\\.(?:eql|equal|eq|be\\.equal|deep\\.equal|be)\\(\\s*$lit\\s*\\)',
  ).allMatches(script)) {
    final p = path(m.group(1)!);
    if (p.isNotEmpty) add(AssertKind.jsonEquals, unquote(m.group(2)!), p);
  }
  for (final m in RegExp(
    'pm\\.expect\\(\\s*(?:$jsonHead)$pathTail\\s*\\)\\.to\\.be\\.(true|false|null)\\b',
  ).allMatches(script)) {
    final p = path(m.group(1)!);
    if (p.isNotEmpty) add(AssertKind.jsonEquals, m.group(2)!, p);
  }
  for (final m in RegExp(
    '(?:$jsonHead)$pathTail\\s*===?\\s*$lit',
  ).allMatches(script)) {
    final p = path(m.group(1)!);
    if (p.isNotEmpty) add(AssertKind.jsonEquals, unquote(m.group(2)!), p);
  }

  // Captures: pm.environment.set("token", jsonData.token) and friends.
  final setCall = RegExp(
    r'''(?:pm\.(?:environment|collectionVariables|globals|variables)\.set|postman\.set(?:Environment|Global)Variable)\(\s*(["'])(.+?)\1\s*,\s*([^;\n]+?)\s*\)\s*;?\s*$''',
    multiLine: true,
  );
  for (final m in setCall.allMatches(script)) {
    final name = m.group(2)!;
    final expr = m.group(3)!.trim();
    String? source;
    final jm = RegExp('^(?:$jsonHead)$pathTail\$').firstMatch(expr);
    final hm = RegExp(
      r'''^(?:pm\.response\.headers\.get|postman\.getResponseHeader)\(\s*(["'])(.+?)\1\s*\)$''',
    ).firstMatch(expr);
    if (jm != null && path(jm.group(1)!).isNotEmpty) {
      source = 'body.${path(jm.group(1)!)}';
    } else if (hm != null) {
      source = 'header.${hm.group(2)}';
    } else if (RegExp(
      r'^(?:pm\.response\.code|responseCode\.code)$',
    ).hasMatch(expr)) {
      source = 'status';
    }
    if (source != null) out.captures[name] = source;
  }
  return out;
}
