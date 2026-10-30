import 'dart:convert';
import 'dart:io' show Cookie;
import 'dart:math';

import '../../models/models.dart';
import '../console_events.dart';
import '../dynamic_vars.dart';
import '../request_builder.dart' show substituteVars;
import '../var_scopes.dart';
import 'js_session.dart';
import 'script_engine.dart';

/// Response bodies larger than this reach scripts truncated.
const scriptBodyLimit = 64 << 20;

final _secure = Random.secure();

/// Translates between a [ScriptContext] and the sandbox's JSON: the
/// context going in, variable writes and `pm.sendRequest` calls during the
/// run, and the outcome (with pre-request edits to the request) coming out.
class ScriptCodec implements JsHost {
  ScriptCodec(this.ctx);

  final ScriptContext ctx;

  /// Notices about edits the sandbox refused (files, unknown auth types).
  final List<ConsoleLine> notices = [];

  bool get _pre => ctx.phase == ScriptPhase.preRequest;

  String get _phaseLabel => _pre ? 'Pre-request' : 'Post-response';

  // ---------------------------------------------------------------- in

  Map<String, Object?> encodeContext() {
    final scopes = ctx.scopes;
    final resolved = _pre ? null : scopes.resolve();
    return {
      'phase': _pre ? 'prerequest' : 'test',
      'info': {
        'requestName': ctx.info.requestName,
        'requestId': ctx.info.requestId,
        'iteration': ctx.info.iteration,
        'iterationCount': ctx.info.iterationCount,
        'collectionName': ctx.info.collectionName,
      },
      'vars': {
        'globals': kvMap(scopes.globals),
        'collection': kvMap(scopes.collection),
        'session': Map.of(scopes.session),
        'environment': scopes.environment == null
            ? null
            : kvMap(scopes.environment),
        'data': Map.of(scopes.data),
        'local': Map.of(scopes.local),
      },
      // Test scripts see the request as sent: variables resolved.
      'request': encodeRequest(ctx.request, vars: resolved),
      'response': ctx.response == null ? null : encodeResponse(ctx.response!),
      'cookies': [for (final c in ctx.responseCookies) _cookie(c)],
      'seed': [for (var i = 0; i < 44; i++) _secure.nextInt(256)],
      'dynamic': {
        for (final n in dynamicVariableNames) n: dynamicVariable(n) ?? '',
      },
    };
  }

  static Map<String, Object?> _cookie(Cookie c) => {
    'name': c.name,
    'value': c.value,
    'domain': ?c.domain,
    'path': ?c.path,
    if (c.expires != null) 'expires': c.expires!.toUtc().toIso8601String(),
    if (c.maxAge != null) 'maxAge': c.maxAge,
    'secure': c.secure,
    'httpOnly': c.httpOnly,
  };

  // ------------------------------------------------------------ during

  @override
  void applyOps(List<Object?> ops) {
    for (final raw in ops) {
      if (raw is! List || raw.length < 2) continue;
      final scope = switch (raw[0]) {
        'globals' => VarScope.globals,
        'collection' => VarScope.collection,
        'environment' => VarScope.environment,
        'local' => VarScope.local,
        _ => null,
      };
      if (scope == null) continue;
      final key = raw.length > 2 ? '${raw[2]}' : '';
      switch (raw[1]) {
        case 's':
          ctx.scopes.set(scope, key, raw.length > 3 ? '${raw[3]}' : '');
        case 'u':
          ctx.scopes.unset(scope, key);
        case 'c':
          ctx.scopes.clear(scope);
      }
    }
  }

  @override
  Future<Map<String, Object?>> send(Map<String, Object?> spec) async {
    final sender = ctx.sendRequest;
    if (sender == null) {
      return {'error': 'pm.sendRequest is not available here'};
    }
    try {
      final res = await sender(requestFromSpec(spec));
      if (res.error != null) return {'error': res.error};
      return {'response': encodeResponse(res)};
    } on ScriptRequestError catch (e) {
      return {'error': e.message};
    } catch (e) {
      return {'error': '$e'};
    }
  }

  // --------------------------------------------------------------- out

  /// The [ScriptOutcome] for a `runJsJob` result. Pre-request edits to
  /// `pm.request` are applied to [ScriptContext.request] here.
  ScriptOutcome outcome(Map<String, Object?> r) {
    final out = ScriptOutcome(error: r['error'] as String?);
    for (final t in (r['tests'] as List? ?? const [])) {
      final m = t as Map;
      out.tests.add(
        ScriptTestResult(
          '${m['name']}',
          m['pass'] == true,
          error: m['error'] as String?,
          origin: '${m['origin'] ?? ''}',
          skipped: m['skipped'] == true,
        ),
      );
    }
    for (final l in (r['logs'] as List? ?? const [])) {
      final m = l as Map;
      out.logs.add(
        ConsoleLine(
          switch (m['l']) {
            'info' => ConsoleLevel.info,
            'warn' => ConsoleLevel.warn,
            'error' => ConsoleLevel.error,
            'debug' => ConsoleLevel.debug,
            _ => ConsoleLevel.log,
          },
          '${m['m']}',
          at: m['t'] is num
              ? DateTime.fromMillisecondsSinceEpoch((m['t'] as num).toInt())
              : null,
          source: '$_phaseLabel: ${m['o'] ?? ''}',
        ),
      );
    }
    final dropped = (r['dropped'] as num?)?.toInt() ?? 0;
    if (dropped > 0) {
      out.logs.add(
        ConsoleLine(
          ConsoleLevel.warn,
          '$dropped more console lines were dropped.',
          source: _phaseLabel,
        ),
      );
    }
    final next = r['next'];
    if (next is Map) {
      out.next = next['stop'] == true
          ? const NextRequest.stop()
          : NextRequest.named('${next['name']}');
    }
    final vis = r['visualizer'];
    if (vis is Map && vis['html'] is String) {
      out.visualizer = VisualizerOutput(vis['html'] as String);
    }
    out.skipRequest = _pre && r['skip'] == true;
    final changes = r['request'];
    if (_pre && changes is Map && changes.isNotEmpty) {
      applyRequestChanges(ctx.request, changes.cast<String, Object?>());
    }
    out.logs.addAll(notices);
    return out;
  }

  void _notice(String message) =>
      notices.add(ConsoleLine(ConsoleLevel.warn, message, source: _phaseLabel));

  /// Copies what a pre-request script changed in `pm.request` onto [r].
  /// Scripts can't attach local files: new file fields or a new file body
  /// are dropped with a console notice.
  void applyRequestChanges(RequestModel r, Map<String, Object?> c) {
    if (c['method'] is String) r.method = (c['method'] as String).toUpperCase();
    if (c['url'] is String) r.url = c['url'] as String;
    if (c['params'] is List) r.params = _kvs(c['params'] as List);
    if (c['pathVariables'] is List) {
      r.pathVariables = _kvs(c['pathVariables'] as List);
    }
    if (c['headers'] is List) r.headers = _kvs(c['headers'] as List);
    if (c.containsKey('body')) _applyBody(r, c['body']);
    if (c['auth'] is Map) {
      final a = authFromJson(
        (c['auth'] as Map).cast<String, Object?>(),
        r.auth,
      );
      if (a != null) r.auth = a;
    }
  }

  void _applyBody(RequestModel r, Object? body) {
    final j = body is Map
        ? body.cast<String, Object?>()
        : const <String, Object?>{};
    final mode = j['mode'];
    if (mode == null || j['disabled'] == true) {
      r
        ..bodyType = BodyType.none
        ..body = '';
      return;
    }
    switch (mode) {
      case 'raw':
        final options = j['options'];
        final raw = options is Map ? options['raw'] : null;
        final lang = raw is Map ? '${raw['language'] ?? ''}'.toLowerCase() : '';
        r.bodyType = switch (lang) {
          'json' => BodyType.json,
          'xml' => BodyType.xml,
          'text' || 'javascript' || 'html' => BodyType.text,
          _ =>
            const {
                  BodyType.json,
                  BodyType.xml,
                  BodyType.text,
                }.contains(r.bodyType)
                ? r.bodyType
                : BodyType.text,
        };
        r.body = _str(j['raw']);
      case 'urlencoded':
        r
          ..bodyType = BodyType.formUrlEncoded
          ..formFields = _kvs(j['urlencoded'] as List? ?? const []);
      case 'formdata':
        final known = {
          for (final f in r.formFields)
            if (f.isFile) '${f.key}\u0000${f.value}',
        };
        final fields = <KV>[];
        for (final p in (j['formdata'] as List? ?? const [])) {
          if (p is! Map) continue;
          final key = _str(p['key']);
          final enabled = p['disabled'] != true;
          if (p['type'] == 'file') {
            final src = p['src'] is List
                ? _str((p['src'] as List).firstOrNull)
                : _str(p['src']);
            if (known.contains('$key\u0000$src')) {
              fields.add(
                KV(key: key, value: src, isFile: true, enabled: enabled),
              );
            } else {
              _notice(
                "pm.request: the file field '$key' was dropped: scripts "
                "can't attach local files.",
              );
            }
          } else {
            fields.add(KV(key: key, value: _str(p['value']), enabled: enabled));
          }
        }
        r
          ..bodyType = BodyType.formData
          ..formFields = fields;
      case 'graphql':
        final g = j['graphql'] is Map ? j['graphql'] as Map : const {};
        final vars = g['variables'];
        r
          ..bodyType = BodyType.graphql
          ..body = _str(g['query'])
          ..graphqlVariables = vars == null
              ? ''
              : (vars is String ? vars : jsonEncode(vars));
      case 'file':
        final f = j['file'];
        final src = f is Map ? _str(f['src']) : _str(f);
        if (!(r.bodyType == BodyType.binary && r.body == src)) {
          _notice(
            "pm.request: the file body was not changed: scripts can't "
            'attach local files.',
          );
        }
      default:
        _notice('pm.request: unsupported body mode $mode was ignored.');
    }
  }

  /// [base] with the type and settings of a Postman auth object, or null
  /// (with a notice) for a type ApiWorkbench doesn't have.
  AuthConfig? authFromJson(Map<String, Object?> j, AuthConfig base) {
    final name = '${j['type'] ?? 'noauth'}';
    final type = name == 'inherit'
        ? AuthType.inherit
        : authTypeFromPostman(name);
    if (type == null) {
      _notice('pm.request.auth: the auth type "$name" is not supported.');
      return null;
    }
    final params = <String, String>{
      for (final p in (j[name] is List ? j[name] as List : const []))
        if (p is Map && p['key'] != null) '${p['key']}': _str(p['value']),
    };
    final a = base.clone()..type = type;
    switch (type) {
      case AuthType.bearer:
        a.bearerToken = params['token'] ?? '';
      case AuthType.basic:
        a
          ..basicUser = params['username'] ?? ''
          ..basicPassword = params['password'] ?? '';
      case AuthType.apiKey:
        a
          ..apiKeyName = params['key'] ?? ''
          ..apiKeyValue = params['value'] ?? ''
          ..apiKeyInHeader = (params['in'] ?? 'header') != 'query';
      case AuthType.none || AuthType.inherit:
        break;
      default:
        a.params = params;
    }
    return a;
  }

  /// The request a `pm.sendRequest` spec describes. Throws
  /// [ScriptRequestError] for what scripts may not do (attach files).
  RequestModel requestFromSpec(Map<String, Object?> spec) {
    final headers = _kvs(spec['headers'] as List? ?? const []);
    final r = RequestModel(
      name: 'pm.sendRequest',
      method: '${spec['method'] ?? 'GET'}'.toUpperCase(),
      url: _str(spec['url']),
      headers: headers,
    );
    final body = spec['body'];
    if (body is Map) {
      final mode = body['mode'];
      switch (mode) {
        case 'raw':
          final options = body['options'];
          final raw = options is Map ? options['raw'] : null;
          final lang = raw is Map ? '${raw['language'] ?? ''}' : '';
          final ct = headers
              .where((h) => h.enabled && h.key.toLowerCase() == 'content-type')
              .map((h) => h.value.toLowerCase())
              .firstOrNull;
          r
            ..bodyType = lang == 'json' || (ct?.contains('json') ?? false)
                ? BodyType.json
                : (lang == 'xml' ? BodyType.xml : BodyType.text)
            ..body = _str(body['raw']);
        case 'urlencoded':
          r
            ..bodyType = BodyType.formUrlEncoded
            ..formFields = _kvs(body['urlencoded'] as List? ?? const []);
        case 'formdata':
          final fields = <KV>[];
          for (final p in (body['formdata'] as List? ?? const [])) {
            if (p is! Map) continue;
            if (p['type'] == 'file' || p['src'] != null) {
              throw ScriptRequestError(
                "pm.sendRequest can't upload files: scripts have no access "
                'to local files',
              );
            }
            fields.add(
              KV(
                key: _str(p['key']),
                value: _str(p['value']),
                enabled: p['disabled'] != true,
              ),
            );
          }
          r
            ..bodyType = BodyType.formData
            ..formFields = fields;
        case 'graphql':
          final g = body['graphql'] is Map ? body['graphql'] as Map : const {};
          final vars = g['variables'];
          r
            ..bodyType = BodyType.graphql
            ..body = _str(g['query'])
            ..graphqlVariables = vars == null
                ? ''
                : (vars is String ? vars : jsonEncode(vars));
        case 'file':
          throw ScriptRequestError(
            "pm.sendRequest can't send a file body: scripts have no access "
            'to local files',
          );
      }
    }
    if (spec['auth'] is Map) {
      final a = authFromJson(
        (spec['auth'] as Map).cast<String, Object?>(),
        AuthConfig(),
      );
      if (a != null && a.type != AuthType.inherit) r.auth = a;
    }
    return r;
  }
}

/// A `pm.sendRequest` the sandbox refuses to send.
class ScriptRequestError implements Exception {
  ScriptRequestError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// [r] as Postman's request JSON. With [vars], placeholders are resolved.
Map<String, Object?> encodeRequest(
  RequestModel r, {
  Map<String, String>? vars,
}) {
  String s(String v) => vars == null ? v : substituteVars(v, vars);
  List<Map<String, Object?>> rows(List<KV> list) => [
    for (final kv in list)
      {
        'key': s(kv.key),
        'value': s(kv.value),
        if (!kv.enabled) 'disabled': true,
        if (kv.description.isNotEmpty) 'description': kv.description,
      },
  ];
  return {
    'id': r.id,
    'name': r.name,
    'description': r.description,
    'method': r.method,
    'url': {
      'raw': s(r.url),
      'query': rows(r.params),
      'variable': rows(r.pathVariables),
    },
    'header': rows(r.headers),
    'body': _encodeBody(r, s),
    'auth': encodeAuth(r.auth, s),
  };
}

Map<String, Object?>? _encodeBody(RequestModel r, String Function(String) s) {
  Map<String, Object?> raw(String language) => {
    'mode': 'raw',
    'raw': s(r.body),
    'options': {
      'raw': {'language': language},
    },
  };
  return switch (r.bodyType) {
    BodyType.none => null,
    BodyType.json => raw('json'),
    BodyType.text => raw('text'),
    BodyType.xml => raw('xml'),
    BodyType.formUrlEncoded => {
      'mode': 'urlencoded',
      'urlencoded': [
        for (final f in r.formFields)
          {
            'key': s(f.key),
            'value': s(f.value),
            if (!f.enabled) 'disabled': true,
          },
      ],
    },
    BodyType.formData => {
      'mode': 'formdata',
      'formdata': [
        for (final f in r.formFields)
          f.isFile
              ? {
                  'key': s(f.key),
                  'type': 'file',
                  'src': f.value,
                  if (!f.enabled) 'disabled': true,
                }
              : {
                  'key': s(f.key),
                  'value': s(f.value),
                  'type': 'text',
                  if (!f.enabled) 'disabled': true,
                },
      ],
    },
    BodyType.graphql => {
      'mode': 'graphql',
      'graphql': {'query': s(r.body), 'variables': s(r.graphqlVariables)},
    },
    BodyType.binary => {
      'mode': 'file',
      'file': {'src': r.body},
    },
  };
}

/// [a] as Postman's auth JSON (`{type, <type>: [{key, value}]}`).
Map<String, Object?> encodeAuth(
  AuthConfig a, [
  String Function(String)? resolve,
]) {
  final s = resolve ?? (String v) => v;
  List<Map<String, Object?>> kv(Map<String, String> m) => [
    for (final e in m.entries)
      {'key': e.key, 'value': s(e.value), 'type': 'string'},
  ];
  return switch (a.type) {
    AuthType.none => {'type': 'noauth'},
    AuthType.inherit => {'type': 'inherit'},
    AuthType.bearer => {
      'type': 'bearer',
      'bearer': kv({'token': a.bearerToken}),
    },
    AuthType.basic => {
      'type': 'basic',
      'basic': kv({'username': a.basicUser, 'password': a.basicPassword}),
    },
    AuthType.apiKey => {
      'type': 'apikey',
      'apikey': kv({
        'key': a.apiKeyName,
        'value': a.apiKeyValue,
        'in': a.apiKeyInHeader ? 'header' : 'query',
      }),
    },
    _ => {'type': a.type.postmanName, a.type.postmanName: kv(a.params)},
  };
}

/// [r] as the sandbox's response JSON.
Map<String, Object?> encodeResponse(ResponseData r) {
  final big = r.bodyBytes.length > scriptBodyLimit;
  final text = big
      ? utf8.decode(
          r.bodyBytes.sublist(0, scriptBodyLimit),
          allowMalformed: true,
        )
      : r.bodyText;
  return {
    'code': r.statusCode,
    'status': r.statusMessage,
    'header': [
      for (final e in r.headers.entries)
        for (final v in e.value) {'key': e.key, 'value': v},
    ],
    'body': text,
    'responseTime': r.durationMs,
    'responseSize': r.bodyBytes.length,
  };
}

List<KV> _kvs(List<Object?> rows) => [
  for (final p in rows)
    if (p is Map)
      KV(
        key: _str(p['key']),
        value: _str(p['value']),
        enabled: p['disabled'] != true,
        description: p['description'] is String
            ? p['description'] as String
            : '',
      ),
];

String _str(Object? v) => switch (v) {
  null => '',
  String s => s,
  num() || bool() => '$v',
  _ => jsonEncode(v),
};
