import 'dart:convert';

import 'package:uuid/uuid.dart';

const _uuid = Uuid();

String newId() => _uuid.v4();

/// A single key/value row used for params, headers and form fields.
class KV {
  KV({this.key = '', this.value = '', this.enabled = true});

  String key;
  String value;
  bool enabled;

  KV clone() => KV(key: key, value: value, enabled: enabled);

  Map<String, dynamic> toJson() => {'k': key, 'v': value, 'e': enabled};

  factory KV.fromJson(Map<String, dynamic> j) => KV(
        key: j['k'] as String? ?? '',
        value: j['v'] as String? ?? '',
        enabled: j['e'] as bool? ?? true,
      );
}

enum BodyType { none, json, text, xml, formUrlEncoded, graphql }

enum AuthType { none, bearer, basic, apiKey }

extension BodyTypeLabel on BodyType {
  String get label => switch (this) {
        BodyType.none => 'None',
        BodyType.json => 'JSON',
        BodyType.text => 'Text',
        BodyType.xml => 'XML',
        BodyType.formUrlEncoded => 'Form URL-encoded',
        BodyType.graphql => 'GraphQL',
      };

  String? get contentType => switch (this) {
        BodyType.none => null,
        BodyType.json || BodyType.graphql => 'application/json',
        BodyType.text => 'text/plain',
        BodyType.xml => 'application/xml',
        BodyType.formUrlEncoded => 'application/x-www-form-urlencoded',
      };
}

extension AuthTypeLabel on AuthType {
  String get label => switch (this) {
        AuthType.none => 'No Auth',
        AuthType.bearer => 'Bearer Token',
        AuthType.basic => 'Basic Auth',
        AuthType.apiKey => 'API Key',
      };
}

// QUERY is the IETF "safe method with body" (draft-ietf-httpbis-safe-method-w-body):
// GET-like semantics, but the query lives in the request body.
const httpMethods = [
  'GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'QUERY', 'HEAD', 'OPTIONS',
];

/// Declarative response tests, evaluated after every send.
enum AssertKind { statusEquals, bodyContains, jsonEquals, headerContains, timeBelow }

extension AssertKindLabel on AssertKind {
  String get label => switch (this) {
        AssertKind.statusEquals => 'Status equals',
        AssertKind.bodyContains => 'Body contains',
        AssertKind.jsonEquals => 'JSON field equals',
        AssertKind.headerContains => 'Header contains',
        AssertKind.timeBelow => 'Time below (ms)',
      };

  /// Whether this kind uses the target field (JSON path / header name).
  bool get hasTarget =>
      this == AssertKind.jsonEquals || this == AssertKind.headerContains;
}

class AssertionModel {
  AssertionModel({
    this.kind = AssertKind.statusEquals,
    this.target = '',
    this.expected = '',
    this.enabled = true,
  });

  AssertKind kind;
  String target; // JSON path (data.items[0].id) or header name
  String expected;
  bool enabled;

  AssertionModel clone() => AssertionModel(
      kind: kind, target: target, expected: expected, enabled: enabled);

  Map<String, dynamic> toJson() =>
      {'kind': kind.name, 't': target, 'x': expected, 'e': enabled};

  factory AssertionModel.fromJson(Map<String, dynamic> j) => AssertionModel(
        kind: AssertKind.values.asNameMap()[j['kind']] ??
            AssertKind.statusEquals,
        target: j['t'] as String? ?? '',
        expected: j['x'] as String? ?? '',
        enabled: j['e'] as bool? ?? true,
      );
}

class AssertionResult {
  AssertionResult(this.assertion, this.pass, this.message);

  final AssertionModel assertion;
  final bool pass;
  final String message;
}

/// Global app settings (persisted).
/// Preferred HTTP protocol version.
enum HttpVersionPref { v1, v2, v3 }

extension HttpVersionPrefLabel on HttpVersionPref {
  String get label => switch (this) {
        HttpVersionPref.v1 => 'HTTP/1.1',
        HttpVersionPref.v2 => 'HTTP/2',
        HttpVersionPref.v3 => 'HTTP/3',
      };
}

/// Default Chaos Mode sound rules — the real meme clips per status code,
/// synthesized originals as class fallbacks.
Map<String, String> defaultChaosRules() => {
      // exact codes (bundled meme clips; 301 stays synthesized — no good
      // "imma head out" clip was findable on myinstants)
      '200': 'meme_200',
      '201': 'meme_201',
      '204': 'meme_204',
      '301': 'head_out',
      '302': 'meme_302',
      '304': 'meme_304',
      '400': 'meme_400',
      '401': 'meme_401',
      '403': 'meme_403',
      '404': 'meme_404',
      '405': 'meme_405',
      '408': 'meme_408',
      '409': 'meme_409',
      '410': 'meme_410',
      '418': 'meme_418',
      '422': 'meme_422',
      '429': 'meme_429',
      '500': 'meme_500',
      '501': 'meme_501',
      '502': 'meme_502',
      '503': 'meme_503',
      '504': 'meme_504',
      '505': 'meme_505',
      // class fallbacks for everything else
      '2xx': 'tada',
      '3xx': 'whoosh',
      '4xx': 'fail',
      '5xx': 'dramatic',
      'error': 'alarm',
    };

/// Older default rule sets; a saved config that still matches one of these
/// was never customized and upgrades to the current defaults.
const legacyChaosRuleSets = [
  // v1: class-only synthesized rules
  {
    '2xx': 'tada', '3xx': 'whoosh', '4xx': 'fail',
    '5xx': 'dramatic', 'error': 'alarm',
  },
  // v2: per-status synthesized rules
  {
    '200': 'mission_passed', '201': 'boom_applause', '204': 'crickets',
    '301': 'head_out', '302': 'slide_whistle', '304': 'ding',
    '400': 'bruh', '401': 'access_denied', '403': 'open_up', '404': 'fail',
    '405': 'nope', '408': 'thinking', '409': 'metal_pipe',
    '410': 'its_gone', '418': 'kettle', '422': 'task_failed',
    '429': 'alarm', '500': 'this_is_fine', '501': 'construction',
    '502': 'record_scratch', '503': 'flatline', '504': 'phone_ring',
    '505': 'retro_startup',
    '2xx': 'tada', '3xx': 'whoosh', '4xx': 'fail',
    '5xx': 'dramatic', 'error': 'alarm',
  },
];

class AppSettings {
  AppSettings({
    this.verifySsl = true,
    this.httpVersion = HttpVersionPref.v1,
    this.connectTimeoutS = 30,
    this.receiveTimeoutS = 60,
    this.chaosMode = false,
    Map<String, String>? chaosRules,
  }) : chaosRules = chaosRules ?? defaultChaosRules();

  /// When false, self-signed / invalid TLS certificates are accepted —
  /// intended for local development servers only.
  bool verifySsl;

  /// v2: ALPN-negotiated HTTP/2 for https with automatic HTTP/1.1 fallback.
  /// v3: QUIC via the platform network stack (Android/iOS/macOS) or the
  /// system curl (Linux/Windows, needs a curl built with HTTP3).
  HttpVersionPref httpVersion;
  int connectTimeoutS;
  int receiveTimeoutS;

  /// Chaos Mode: status-code meme sounds + confetti/shake effects.
  bool chaosMode;

  /// Sound rules: keys are '2xx'…'5xx', 'error', or exact codes ('404').
  /// Values are sound ids from the sound library; '' disables that rule.
  Map<String, String> chaosRules;

  Map<String, dynamic> toJson() => {
        'verifySsl': verifySsl,
        'httpVersion': httpVersion.name,
        'connectTimeoutS': connectTimeoutS,
        'receiveTimeoutS': receiveTimeoutS,
        'chaosMode': chaosMode,
        'chaosRules': chaosRules,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        verifySsl: j['verifySsl'] as bool? ?? true,
        httpVersion: HttpVersionPref.values.asNameMap()[j['httpVersion']] ??
            // Migration from the earlier boolean setting.
            (j['useHttp2'] == true ? HttpVersionPref.v2 : HttpVersionPref.v1),
        connectTimeoutS: (j['connectTimeoutS'] as num?)?.toInt() ?? 30,
        receiveTimeoutS: (j['receiveTimeoutS'] as num?)?.toInt() ?? 60,
        chaosMode: j['chaosMode'] as bool? ?? j['funMode'] as bool? ?? false,
        chaosRules: _migrateChaosRules(
            (j['chaosRules'] ?? j['funRules']) as Map<String, dynamic>?),
      );

  static Map<String, String> _migrateChaosRules(Map<String, dynamic>? raw) {
    if (raw == null) return defaultChaosRules();
    final rules = raw.map((k, v) => MapEntry(k, v.toString()));
    for (final legacy in legacyChaosRuleSets) {
      if (rules.length == legacy.length &&
          legacy.entries.every((e) => rules[e.key] == e.value)) {
        return defaultChaosRules();
      }
    }
    return rules;
  }
}

class RequestModel {
  RequestModel({
    String? id,
    this.name = 'Untitled request',
    this.method = 'GET',
    this.url = '',
    List<KV>? params,
    List<KV>? headers,
    this.bodyType = BodyType.none,
    this.body = '',
    this.graphqlVariables = '',
    List<KV>? formFields,
    this.authType = AuthType.none,
    this.bearerToken = '',
    this.basicUser = '',
    this.basicPassword = '',
    this.apiKeyName = '',
    this.apiKeyValue = '',
    this.apiKeyInHeader = true,
    List<AssertionModel>? assertions,
  })  : id = id ?? newId(),
        params = params ?? [],
        headers = headers ?? [],
        formFields = formFields ?? [],
        assertions = assertions ?? [];

  String id;
  String name;
  String method;
  String url;
  List<KV> params;
  List<KV> headers;
  BodyType bodyType;
  String body;
  String graphqlVariables; // JSON, only used when bodyType == graphql
  List<KV> formFields;
  AuthType authType;
  String bearerToken;
  String basicUser;
  String basicPassword;
  String apiKeyName;
  String apiKeyValue;
  bool apiKeyInHeader;
  List<AssertionModel> assertions;

  RequestModel clone({bool sameId = false}) => RequestModel(
        id: sameId ? id : null,
        name: name,
        method: method,
        url: url,
        params: params.map((e) => e.clone()).toList(),
        headers: headers.map((e) => e.clone()).toList(),
        bodyType: bodyType,
        body: body,
        graphqlVariables: graphqlVariables,
        formFields: formFields.map((e) => e.clone()).toList(),
        authType: authType,
        bearerToken: bearerToken,
        basicUser: basicUser,
        basicPassword: basicPassword,
        apiKeyName: apiKeyName,
        apiKeyValue: apiKeyValue,
        apiKeyInHeader: apiKeyInHeader,
        assertions: assertions.map((e) => e.clone()).toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'method': method,
        'url': url,
        'params': params.map((e) => e.toJson()).toList(),
        'headers': headers.map((e) => e.toJson()).toList(),
        'bodyType': bodyType.name,
        'body': body,
        'graphqlVariables': graphqlVariables,
        'formFields': formFields.map((e) => e.toJson()).toList(),
        'authType': authType.name,
        'bearerToken': bearerToken,
        'basicUser': basicUser,
        'basicPassword': basicPassword,
        'apiKeyName': apiKeyName,
        'apiKeyValue': apiKeyValue,
        'apiKeyInHeader': apiKeyInHeader,
        'assertions': assertions.map((e) => e.toJson()).toList(),
      };

  factory RequestModel.fromJson(Map<String, dynamic> j) => RequestModel(
        id: j['id'] as String?,
        name: j['name'] as String? ?? 'Untitled request',
        method: j['method'] as String? ?? 'GET',
        url: j['url'] as String? ?? '',
        params: _kvList(j['params']),
        headers: _kvList(j['headers']),
        bodyType: BodyType.values.asNameMap()[j['bodyType']] ?? BodyType.none,
        body: j['body'] as String? ?? '',
        graphqlVariables: j['graphqlVariables'] as String? ?? '',
        formFields: _kvList(j['formFields']),
        authType: AuthType.values.asNameMap()[j['authType']] ?? AuthType.none,
        bearerToken: j['bearerToken'] as String? ?? '',
        basicUser: j['basicUser'] as String? ?? '',
        basicPassword: j['basicPassword'] as String? ?? '',
        apiKeyName: j['apiKeyName'] as String? ?? '',
        apiKeyValue: j['apiKeyValue'] as String? ?? '',
        apiKeyInHeader: j['apiKeyInHeader'] as bool? ?? true,
        assertions: (j['assertions'] as List<dynamic>? ?? [])
            .map((e) => AssertionModel.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  static List<KV> _kvList(dynamic v) => (v as List<dynamic>? ?? [])
      .map((e) => KV.fromJson(e as Map<String, dynamic>))
      .toList();
}

class CollectionModel {
  CollectionModel({String? id, required this.name, List<RequestModel>? requests})
      : id = id ?? newId(),
        requests = requests ?? [];

  String id;
  String name;
  List<RequestModel> requests;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'requests': requests.map((e) => e.toJson()).toList(),
      };

  factory CollectionModel.fromJson(Map<String, dynamic> j) => CollectionModel(
        id: j['id'] as String?,
        name: j['name'] as String? ?? 'Collection',
        requests: (j['requests'] as List<dynamic>? ?? [])
            .map((e) => RequestModel.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class EnvironmentModel {
  EnvironmentModel({String? id, required this.name, List<KV>? variables})
      : id = id ?? newId(),
        variables = variables ?? [];

  String id;
  String name;
  List<KV> variables;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'variables': variables.map((e) => e.toJson()).toList(),
      };

  factory EnvironmentModel.fromJson(Map<String, dynamic> j) => EnvironmentModel(
        id: j['id'] as String?,
        name: j['name'] as String? ?? 'Environment',
        variables: RequestModel._kvList(j['variables']),
      );
}

class HistoryEntry {
  HistoryEntry({
    String? id,
    required this.request,
    required this.statusCode,
    required this.durationMs,
    required this.at,
  }) : id = id ?? newId();

  String id;
  RequestModel request;
  int statusCode; // 0 = network error
  int durationMs;
  DateTime at;

  Map<String, dynamic> toJson() => {
        'id': id,
        'request': request.toJson(),
        'statusCode': statusCode,
        'durationMs': durationMs,
        'at': at.toIso8601String(),
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
        id: j['id'] as String?,
        request: RequestModel.fromJson(j['request'] as Map<String, dynamic>),
        statusCode: j['statusCode'] as int? ?? 0,
        durationMs: j['durationMs'] as int? ?? 0,
        at: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime.now(),
      );
}

class ResponseData {
  ResponseData({
    this.statusCode = 0,
    this.statusMessage = '',
    this.headers = const {},
    this.bodyBytes = const [],
    this.durationMs = 0,
    this.error,
    this.finalUrl,
    this.protocol,
  });

  final int statusCode;
  final String statusMessage;
  final Map<String, List<String>> headers;
  final List<int> bodyBytes;
  final int durationMs;
  final String? error;
  final String? finalUrl;

  /// Negotiated HTTP version ("3", "2", "1.1") when the transport reports
  /// it (currently the curl HTTP/3 engine); null when unknown.
  final String? protocol;

  int get sizeBytes => bodyBytes.length;

  String? get contentType {
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == 'content-type') return e.value.join('; ');
    }
    return null;
  }

  String get bodyText {
    try {
      return utf8.decode(bodyBytes);
    } catch (_) {
      return latin1.decode(bodyBytes, allowInvalid: true);
    }
  }
}
