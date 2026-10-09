import 'dart:convert';

import '../models/models.dart';
import 'workspace.dart';

/// What an import produced, plus everything worth telling the user about
/// what could not be carried over.
class ImportReport {
  final collections = <CollectionModel>[];
  final environments = <EnvironmentModel>[];

  /// Human-readable source formats seen, e.g. "Postman collection v2.1".
  final formats = <String>{};

  int requests = 0;
  int folders = 0;
  int assertionsFromScripts = 0;
  int capturesFromScripts = 0;

  /// Requests (or folders/collections) whose script text was kept but not
  /// fully converted.
  int scriptsKept = 0;
  int examplesSkipped = 0;
  int bodiesOnGetOrHead = 0;

  /// Postman auth type → requests that used it without an equivalent here.
  final unsupportedAuth = <String, int>{};
  final notes = <String>[];

  bool get isEmpty => collections.isEmpty && environments.isEmpty;

  /// One line per thing the user may need to act on.
  List<String> get warnings => [
    for (final e in unsupportedAuth.entries)
      '${e.value} request(s) use ${_authLabel(e.key)} auth, which '
          'ApiWorkbench does not support yet; their auth was left empty.',
    if (scriptsKept > 0)
      '$scriptsKept Postman script(s) were found. ApiWorkbench does not run '
          'JavaScript, so recognised checks became Tests '
          '($assertionsFromScripts) and saved values became Captures '
          '($capturesFromScripts); the scripts themselves are kept on each '
          'request under Docs for reference.',
    if (examplesSkipped > 0)
      '$examplesSkipped saved response example(s) were not imported.',
    if (bodiesOnGetOrHead > 0)
      '$bodiesOnGetOrHead GET/HEAD request(s) have a body, which '
          'ApiWorkbench does not send for those methods.',
    ...notes,
  ];
}

String _authLabel(String t) => switch (t) {
  'digest' => 'Digest',
  'oauth1' => 'OAuth 1.0',
  'oauth2' => 'OAuth 2.0 (no saved token)',
  'hawk' => 'Hawk',
  'awsv4' => 'AWS Signature',
  'ntlm' => 'NTLM',
  'edgegrid' => 'Akamai EdgeGrid',
  'jwt' => 'JWT Bearer',
  'asap' => 'ASAP (Atlassian)',
  _ => t,
};

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
  if (json['collections'] is List || json['environments'] is List) {
    r.formats.add('Postman data export');
    for (final c in (json['collections'] as List? ?? [])) {
      if (c is Map<String, dynamic>) _importValue(c, r);
    }
    for (final e in (json['environments'] as List? ?? [])) {
      if (e is Map<String, dynamic>) r.environments.add(_environment(e));
    }
    final globals = json['globals'];
    if (globals is List && globals.isNotEmpty) {
      r.environments.add(_globals(globals));
    }
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
    r.environments.add(_globals(json['values'] as List? ?? []));
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

// ---- environments ----------------------------------------------------------

EnvironmentModel _environment(Map<String, dynamic> j) => EnvironmentModel(
  name: '${j['name'] ?? 'Postman environment'}',
  variables: _vars(j['values']),
);

EnvironmentModel _globals(List<dynamic> values) =>
    EnvironmentModel(name: 'Postman globals', variables: _vars(values));

List<KV> _vars(Object? list) => [
  for (final v in (list is List ? list : const []))
    if (v is Map && (v['key'] ?? '').toString().isNotEmpty)
      KV(
        key: '${v['key']}',
        value: _str(v['value']),
        enabled: v['enabled'] != false && v['disabled'] != true,
      ),
];

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

/// Auth plus scripts inherited from the collection and enclosing folders.
class _Scope {
  const _Scope({
    this.auth,
    this.path = const [],
    this.tests = '',
    this.pre = '',
  });
  final Map<String, dynamic>? auth;
  final List<String> path;
  final String tests;
  final String pre;
}

class _V2 {
  _V2(this.r);
  final ImportReport r;

  CollectionModel collection(Map<String, dynamic> j) {
    final info = j['info'] as Map? ?? {};
    final col = CollectionModel(
      name: '${info['name'] ?? 'Imported collection'}',
      variables: _vars(j['variable']),
      description: _description(info['description']),
    );
    final events = _scripts(j['event']);
    if (events.tests.isNotEmpty || events.pre.isNotEmpty) r.scriptsKept++;
    _items(
      j['item'],
      col,
      _Scope(auth: _auth(j['auth']), tests: events.tests, pre: events.pre),
    );
    return col;
  }

  void _items(Object? items, CollectionModel col, _Scope scope) {
    if (items is! List) return;
    for (final it in items) {
      if (it is! Map<String, dynamic>) continue;
      if (it['item'] is List) {
        // Folder.
        r.folders++;
        final ev = _scripts(it['event']);
        if (ev.tests.isNotEmpty || ev.pre.isNotEmpty) r.scriptsKept++;
        _items(
          it['item'],
          col,
          _Scope(
            auth: _auth(it['auth']) ?? scope.auth,
            path: [
              ...scope.path,
              '${it['name'] ?? 'Folder'}'.replaceAll('/', '∕'),
            ],
            tests: _join(scope.tests, ev.tests),
            pre: _join(scope.pre, ev.pre),
          ),
        );
      } else {
        col.requests.add(_request(it, scope));
      }
    }
  }

  RequestModel _request(Map<String, dynamic> it, _Scope scope) {
    r.requests++;
    final req = it['request'];
    final rq = req is String
        ? {'url': req, 'method': 'GET'}
        : (req as Map? ?? {});
    final m = RequestModel(
      name: '${it['name'] ?? 'Request'}',
      method: '${rq['method'] ?? 'GET'}'.toUpperCase(),
      folder: scope.path.join('/'),
      description: _description(rq['description'] ?? it['description']),
    );

    _url(rq['url'], m);
    m.headers = _headers(rq['header']);
    _body(rq['body'], m);
    _applyAuth(_auth(rq['auth']) ?? scope.auth, m);

    final responses = it['response'];
    if (responses is List) r.examplesSkipped += responses.length;

    final own = _scripts(it['event']);
    final tests = _join(scope.tests, own.tests);
    final pre = _join(scope.pre, own.pre);
    m.testScript = tests;
    m.preRequestScript = pre;
    if (own.tests.isNotEmpty || own.pre.isNotEmpty) r.scriptsKept++;
    if (tests.isNotEmpty) {
      final conv = convertTestScript(tests);
      m.assertions.addAll(conv.assertions);
      m.captures.addAll(conv.captures);
      r.assertionsFromScripts += conv.assertions.length;
      r.capturesFromScripts += conv.captures.length;
    }
    if (m.bodyType != BodyType.none &&
        (m.method == 'GET' || m.method == 'HEAD')) {
      r.bodiesOnGetOrHead++;
    }
    return m;
  }

  // -- url --

  void _url(Object? url, RequestModel m) {
    String raw;
    List<KV>? query;
    var pathVars = <String, String>{};
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
        raw =
            '${proto.isEmpty ? '' : '$proto://'}$host${port.isEmpty ? '' : ':$port'}'
            '${path.isEmpty ? '' : '/$path'}';
      }
      if (url['query'] is List) {
        query = [
          for (final q in url['query'] as List)
            if (q is Map && q['key'] != null)
              KV(
                key: _str(q['key']),
                value: _str(q['value']),
                enabled: q['disabled'] != true,
              ),
        ];
      }
      if (url['variable'] is List) {
        pathVars = {
          for (final v in url['variable'] as List)
            if (v is Map && v['key'] != null) _str(v['key']): _str(v['value']),
        };
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
    pathVars.forEach((k, v) {
      base = base.replaceAll(
        RegExp('(?<=/):${RegExp.escape(k)}(?=/|\$)'),
        v.isEmpty ? '{{$k}}' : v,
      );
    });
    m.url = '$base$fragment';
    m.params = query ?? [];
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
      if (files && f['type'] == 'file') {
        final src = f['src'];
        final paths = src is List ? src.map(_str).toList() : [_str(src)];
        for (final p in paths) {
          out.add(
            KV(key: _str(f['key']), value: p, enabled: enabled, isFile: true),
          );
        }
      } else {
        out.add(
          KV(key: _str(f['key']), value: _str(f['value']), enabled: enabled),
        );
      }
    }
    return out;
  }

  // -- auth --

  /// Normalises Postman's auth object; null means "inherit from parent".
  static Map<String, dynamic>? _auth(Object? a) {
    if (a is! Map) return null;
    final type = '${a['type'] ?? ''}';
    if (type.isEmpty || type == 'inherit') return null;
    final attrs = a[type];
    final map = <String, String>{};
    if (attrs is List) {
      for (final x in attrs) {
        if (x is Map && x['key'] != null) map['${x['key']}'] = _str(x['value']);
      }
    } else if (attrs is Map) {
      attrs.forEach((k, v) => map['$k'] = _str(v));
    }
    return {'type': type, 'attrs': map};
  }

  void _applyAuth(Map<String, dynamic>? auth, RequestModel m) {
    if (auth == null) return;
    final type = auth['type'] as String;
    final a = auth['attrs'] as Map<String, String>;
    switch (type) {
      case 'noauth':
        m.authType = AuthType.none;
      case 'bearer':
        m.authType = AuthType.bearer;
        m.bearerToken = a['token'] ?? '';
      case 'basic':
        m.authType = AuthType.basic;
        m.basicUser = a['username'] ?? '';
        m.basicPassword = a['password'] ?? '';
      case 'apikey':
        m.authType = AuthType.apiKey;
        m.apiKeyName = a['key'] ?? '';
        m.apiKeyValue = a['value'] ?? '';
        m.apiKeyInHeader = (a['in'] ?? 'header') != 'query';
      case 'oauth2':
        final token = a['accessToken'] ?? '';
        if (token.isEmpty) {
          r.unsupportedAuth.update(type, (n) => n + 1, ifAbsent: () => 1);
          return;
        }
        final prefix = a['headerPrefix'] ?? 'Bearer';
        if (a['addTokenTo'] == 'queryParams') {
          m.authType = AuthType.apiKey;
          m.apiKeyName = 'access_token';
          m.apiKeyValue = token;
          m.apiKeyInHeader = false;
        } else if (prefix.trim().isEmpty || prefix.trim() == 'Bearer') {
          m.authType = AuthType.bearer;
          m.bearerToken = token;
        } else {
          m.headers.add(
            KV(key: 'Authorization', value: '${prefix.trim()} $token'),
          );
        }
      default:
        r.unsupportedAuth.update(type, (n) => n + 1, ifAbsent: () => 1);
    }
  }

  // -- scripts --

  static ({String tests, String pre}) _scripts(Object? events) {
    var tests = '';
    var pre = '';
    for (final e in (events is List ? events : const [])) {
      if (e is! Map || e['disabled'] == true) continue;
      final script = e['script'];
      final exec = script is Map ? script['exec'] : null;
      final text = (exec is List ? exec.map(_str).join('\n') : _str(exec))
          .trim();
      if (text.isEmpty) continue;
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
      if (q['responses'] is List) 'response': q['responses'],
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
/// ignored (the caller keeps the script text).
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
