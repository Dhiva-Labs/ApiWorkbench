import 'dart:convert';

import 'package:uuid/uuid.dart';

const _uuid = Uuid();

String newId() => _uuid.v4();

/// A single key/value row used for params, headers and form fields.
class KV {
  KV({
    this.key = '',
    this.value = '',
    this.enabled = true,
    this.isFile = false,
    this.secret = false,
    this.current,
    this.description = '',
  });

  String key;

  /// For variables this is the initial value: the one that is shared and
  /// exported. [current] overrides it locally.
  String value;
  bool enabled;

  /// Multipart form-data only: [value] is a local file path to upload.
  bool isFile;

  /// Variables only: the value is masked in editors, the console and exports.
  bool secret;

  /// Variables only: the local current value, written by scripts and
  /// captures and used when sending. Null means "same as [value]".
  String? current;

  /// Optional note, e.g. a path variable's or a Postman param's description.
  String description;

  /// The value requests see: the current value when set, else the initial.
  String get effective => current ?? value;

  KV clone() => KV(
    key: key,
    value: value,
    enabled: enabled,
    isFile: isFile,
    secret: secret,
    current: current,
    description: description,
  );

  Map<String, dynamic> toJson() => {
    'k': key,
    'v': value,
    'e': enabled,
    if (isFile) 'f': true,
    if (secret) 's': true,
    'c': ?current,
    if (description.isNotEmpty) 'd': description,
  };

  factory KV.fromJson(Map<String, dynamic> j) => KV(
    key: j['k'] as String? ?? '',
    value: j['v'] as String? ?? '',
    enabled: j['e'] as bool? ?? true,
    isFile: j['f'] as bool? ?? false,
    secret: j['s'] as bool? ?? false,
    current: j['c'] as String?,
    description: j['d'] as String? ?? '',
  );
}

/// Enabled, named rows as a map of their effective values.
Map<String, String> kvMap(Iterable<KV>? rows) => {
  for (final v in rows ?? const <KV>[])
    if (v.enabled && v.key.isNotEmpty) v.key: v.effective,
};

enum BodyType {
  none,
  json,
  text,
  xml,
  formUrlEncoded,
  formData,
  graphql,
  binary,
}

/// Auth schemes. Values beyond the first four keep their settings in
/// [AuthConfig.params] under Postman's attribute names (see [AuthConfig]).
enum AuthType {
  none,
  bearer,
  basic,
  apiKey,

  /// Use the folder's, then the collection's auth.
  inherit,
  oauth2,
  oauth1,
  digest,
  awsV4,
  ntlm,
  hawk,
  edgegrid,
  jwt,
}

/// What kind of connection a saved request describes.
enum RequestKind { http, websocket, socketio, mqtt, sse, grpc }

extension RequestKindInfo on RequestKind {
  String get label => switch (this) {
    RequestKind.http => 'HTTP',
    RequestKind.websocket => 'WebSocket',
    RequestKind.socketio => 'Socket.IO',
    RequestKind.mqtt => 'MQTT',
    RequestKind.sse => 'Server-Sent Events',
    RequestKind.grpc => 'gRPC',
  };

  /// Short badge shown in place of the HTTP method.
  String get badge => switch (this) {
    RequestKind.http => 'HTTP',
    RequestKind.websocket => 'WS',
    RequestKind.socketio => 'SIO',
    RequestKind.mqtt => 'MQTT',
    RequestKind.sse => 'SSE',
    RequestKind.grpc => 'gRPC',
  };
}

extension BodyTypeLabel on BodyType {
  String get label => switch (this) {
    BodyType.none => 'None',
    BodyType.json => 'JSON',
    BodyType.text => 'Text',
    BodyType.xml => 'XML',
    BodyType.formUrlEncoded => 'Form URL-encoded',
    BodyType.formData => 'Form data',
    BodyType.graphql => 'GraphQL',
    BodyType.binary => 'Binary file',
  };

  String? get contentType => switch (this) {
    BodyType.none => null,
    BodyType.json || BodyType.graphql => 'application/json',
    BodyType.text => 'text/plain',
    BodyType.xml => 'application/xml',
    BodyType.formUrlEncoded => 'application/x-www-form-urlencoded',
    // The multipart boundary is generated per request by the HTTP client.
    BodyType.formData => null,
    BodyType.binary => 'application/octet-stream',
  };
}

extension AuthTypeLabel on AuthType {
  String get label => switch (this) {
    AuthType.none => 'No Auth',
    AuthType.bearer => 'Bearer Token',
    AuthType.basic => 'Basic Auth',
    AuthType.apiKey => 'API Key',
    AuthType.inherit => 'Inherit from parent',
    AuthType.oauth2 => 'OAuth 2.0',
    AuthType.oauth1 => 'OAuth 1.0',
    AuthType.digest => 'Digest Auth',
    AuthType.awsV4 => 'AWS Signature',
    AuthType.ntlm => 'NTLM',
    AuthType.hawk => 'Hawk',
    AuthType.edgegrid => 'Akamai EdgeGrid',
    AuthType.jwt => 'JWT Bearer',
  };

  /// Postman's auth `type` name.
  String get postmanName => switch (this) {
    AuthType.none => 'noauth',
    AuthType.bearer => 'bearer',
    AuthType.basic => 'basic',
    AuthType.apiKey => 'apikey',
    AuthType.inherit => 'inherit',
    AuthType.oauth2 => 'oauth2',
    AuthType.oauth1 => 'oauth1',
    AuthType.digest => 'digest',
    AuthType.awsV4 => 'awsv4',
    AuthType.ntlm => 'ntlm',
    AuthType.hawk => 'hawk',
    AuthType.edgegrid => 'edgegrid',
    AuthType.jwt => 'jwt',
  };
}

AuthType? authTypeFromPostman(String name) {
  for (final t in AuthType.values) {
    if (t.postmanName == name) return t;
  }
  return null;
}

/// How a request (or a collection or folder) authenticates.
///
/// Bearer, Basic and API key keep their dedicated fields. Every other type
/// keeps its settings in [params] under Postman's attribute names, so
/// Postman import and export are a straight copy:
/// - oauth2: accessToken, tokenType, addTokenTo (header|queryParams),
///   headerPrefix, grant_type (authorization_code|
///   authorization_code_with_pkce|implicit|password_credentials|
///   client_credentials), authUrl, accessTokenUrl, clientId, clientSecret,
///   scope, state, redirect_uri, client_authentication (header|body),
///   username, password, challengeAlgorithm (S256|plain), code_verifier,
///   refreshToken, tokenName, useBrowser, refreshTokenUrl, audience,
///   resource, expiresAt (ISO time; ApiWorkbench addition)
/// - oauth1: consumerKey, consumerSecret, token, tokenSecret,
///   signatureMethod, timestamp, nonce, version, realm, callback, verifier,
///   addParamsToHeader, addEmptyParamsToSign, includeBodyHash, privateKey
/// - digest: username, password, realm, nonce, algorithm, qop, nonceCount,
///   clientNonce, opaque, disableRetryRequest
/// - awsv4: accessKey, secretKey, sessionToken, region, service,
///   addAuthDataToQuery
/// - ntlm: username, password, domain, workstation, disableRetryRequest
/// - hawk: authId, authKey, algorithm, user, nonce, extraData, app,
///   delegation, timestamp, includePayloadHash
/// - edgegrid: accessToken, clientToken, clientSecret, nonce, timestamp,
///   baseURL, headersToSign
/// - jwt: algorithm, secret, privateKey, isSecretBase64Encoded, payload,
///   header, addTokenTo (header|queryParam), headerPrefix, queryParamKey
class AuthConfig {
  AuthConfig({
    this.type = AuthType.none,
    this.bearerToken = '',
    this.basicUser = '',
    this.basicPassword = '',
    this.apiKeyName = '',
    this.apiKeyValue = '',
    this.apiKeyInHeader = true,
    Map<String, String>? params,
  }) : params = params ?? {};

  AuthType type;
  String bearerToken;
  String basicUser;
  String basicPassword;
  String apiKeyName;
  String apiKeyValue;
  bool apiKeyInHeader;
  Map<String, String> params;

  String param(String key, [String fallback = '']) => params[key] ?? fallback;

  AuthConfig clone() => AuthConfig(
    type: type,
    bearerToken: bearerToken,
    basicUser: basicUser,
    basicPassword: basicPassword,
    apiKeyName: apiKeyName,
    apiKeyValue: apiKeyValue,
    apiKeyInHeader: apiKeyInHeader,
    params: Map.of(params),
  );

  /// Flat keys, the same ones a request has always used.
  Map<String, dynamic> toJson() => {
    'authType': type.name,
    'bearerToken': bearerToken,
    'basicUser': basicUser,
    'basicPassword': basicPassword,
    'apiKeyName': apiKeyName,
    'apiKeyValue': apiKeyValue,
    'apiKeyInHeader': apiKeyInHeader,
    if (params.isNotEmpty) 'authParams': params,
  };

  factory AuthConfig.fromJson(
    Map<String, dynamic> j, {
    AuthType fallback = AuthType.none,
  }) => AuthConfig(
    type: AuthType.values.asNameMap()[j['authType']] ?? fallback,
    bearerToken: j['bearerToken'] as String? ?? '',
    basicUser: j['basicUser'] as String? ?? '',
    basicPassword: j['basicPassword'] as String? ?? '',
    apiKeyName: j['apiKeyName'] as String? ?? '',
    apiKeyValue: j['apiKeyValue'] as String? ?? '',
    apiKeyInHeader: j['apiKeyInHeader'] as bool? ?? true,
    params: (j['authParams'] as Map<String, dynamic>? ?? {}).map(
      (k, v) => MapEntry(k, v.toString()),
    ),
  );
}

/// Per-request transport options (Postman's request Settings tab /
/// `protocolProfileBehavior`). Null fields follow the app settings.
class RequestSettings {
  RequestSettings({
    this.followRedirects,
    this.maxRedirects,
    this.verifySsl,
    this.encodeUrl = true,
    this.useCookies = true,
    this.timeoutMs,
    this.followOriginalMethod = false,
    this.followAuthorizationHeader = false,
    this.removeRefererOnRedirect = false,
  });

  bool? followRedirects;
  int? maxRedirects;
  bool? verifySsl;

  /// Percent-encode characters in the URL and params that need it. Off sends
  /// them as typed (as far as a valid URL allows).
  bool encodeUrl;

  /// Send cookies from the jar and store the ones the response sets.
  bool useCookies;

  /// Overrides the app's receive timeout for this request.
  int? timeoutMs;

  /// Keep POST/PUT/… on 301 and 302 instead of switching to GET.
  bool followOriginalMethod;

  /// Keep the Authorization header when a redirect leaves the origin.
  bool followAuthorizationHeader;
  bool removeRefererOnRedirect;

  bool get isDefault =>
      followRedirects == null &&
      maxRedirects == null &&
      verifySsl == null &&
      encodeUrl &&
      useCookies &&
      timeoutMs == null &&
      !followOriginalMethod &&
      !followAuthorizationHeader &&
      !removeRefererOnRedirect;

  RequestSettings clone() => RequestSettings.fromJson(toJson());

  Map<String, dynamic> toJson() => {
    'followRedirects': ?followRedirects,
    'maxRedirects': ?maxRedirects,
    'verifySsl': ?verifySsl,
    if (!encodeUrl) 'encodeUrl': false,
    if (!useCookies) 'useCookies': false,
    'timeoutMs': ?timeoutMs,
    if (followOriginalMethod) 'followOriginalMethod': true,
    if (followAuthorizationHeader) 'followAuthorizationHeader': true,
    if (removeRefererOnRedirect) 'removeRefererOnRedirect': true,
  };

  factory RequestSettings.fromJson(Map<String, dynamic>? j) => j == null
      ? RequestSettings()
      : RequestSettings(
          followRedirects: j['followRedirects'] as bool?,
          maxRedirects: (j['maxRedirects'] as num?)?.toInt(),
          verifySsl: j['verifySsl'] as bool?,
          encodeUrl: j['encodeUrl'] as bool? ?? true,
          useCookies: j['useCookies'] as bool? ?? true,
          timeoutMs: (j['timeoutMs'] as num?)?.toInt(),
          followOriginalMethod: j['followOriginalMethod'] as bool? ?? false,
          followAuthorizationHeader:
              j['followAuthorizationHeader'] as bool? ?? false,
          removeRefererOnRedirect:
              j['removeRefererOnRedirect'] as bool? ?? false,
        );
}

/// A saved response kept with its request (Postman "example").
class ResponseExample {
  ResponseExample({
    String? id,
    this.name = 'Example',
    this.statusCode = 200,
    this.statusText = 'OK',
    List<KV>? headers,
    this.body = '',
    this.originalRequest,
  }) : id = id ?? newId(),
       headers = headers ?? [];

  String id;
  String name;
  int statusCode;
  String statusText;
  List<KV> headers;

  /// Body text. Binary bodies are not kept.
  String body;

  /// The request as it was when the example was saved (no examples inside).
  RequestModel? originalRequest;

  String? get contentType {
    for (final h in headers) {
      if (h.enabled && h.key.toLowerCase() == 'content-type') return h.value;
    }
    return null;
  }

  ResponseExample clone({bool sameId = true}) =>
      ResponseExample.fromJson(toJson())..id = sameId ? id : newId();

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'status': statusCode,
    'statusText': statusText,
    'headers': headers.map((e) => e.toJson()).toList(),
    'body': body,
    if (originalRequest != null) 'request': originalRequest!.toJson(),
  };

  factory ResponseExample.fromJson(Map<String, dynamic> j) => ResponseExample(
    id: j['id'] as String?,
    name: j['name'] as String? ?? 'Example',
    statusCode: (j['status'] as num?)?.toInt() ?? 200,
    statusText: j['statusText'] as String? ?? '',
    headers: RequestModel._kvList(j['headers']),
    body: j['body'] as String? ?? '',
    originalRequest: j['request'] is Map<String, dynamic>
        ? RequestModel.fromJson(j['request'] as Map<String, dynamic>)
        : null,
  );
}

/// Settings shared by everything inside a folder of a collection.
class FolderMeta {
  FolderMeta({
    this.description = '',
    AuthConfig? auth,
    this.preRequestScript = '',
    this.testScript = '',
  }) : auth = auth ?? AuthConfig(type: AuthType.inherit);

  String description;
  AuthConfig auth;
  String preRequestScript;
  String testScript;

  bool get isEmpty =>
      description.isEmpty &&
      auth.type == AuthType.inherit &&
      preRequestScript.isEmpty &&
      testScript.isEmpty;

  FolderMeta clone() => FolderMeta.fromJson(toJson());

  Map<String, dynamic> toJson() => {
    if (description.isNotEmpty) 'description': description,
    if (auth.type != AuthType.inherit) 'auth': auth.toJson(),
    if (preRequestScript.isNotEmpty) 'preRequestScript': preRequestScript,
    if (testScript.isNotEmpty) 'testScript': testScript,
  };

  factory FolderMeta.fromJson(Map<String, dynamic> j) => FolderMeta(
    description: j['description'] as String? ?? '',
    auth: j['auth'] is Map<String, dynamic>
        ? AuthConfig.fromJson(
            j['auth'] as Map<String, dynamic>,
            fallback: AuthType.inherit,
          )
        : null,
    preRequestScript: j['preRequestScript'] as String? ?? '',
    testScript: j['testScript'] as String? ?? '',
  );
}

// QUERY is the IETF "safe method with body" (draft-ietf-httpbis-safe-method-w-body):
// GET-like semantics, but the query lives in the request body.
const httpMethods = [
  'GET',
  'POST',
  'PUT',
  'PATCH',
  'DELETE',
  'QUERY',
  'HEAD',
  'OPTIONS',
];

/// Declarative response tests, evaluated after every send.
enum AssertKind {
  statusEquals,
  bodyContains,
  jsonEquals,
  headerContains,
  timeBelow,
}

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
    kind: kind,
    target: target,
    expected: expected,
    enabled: enabled,
  );

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    't': target,
    'x': expected,
    'e': enabled,
  };

  factory AssertionModel.fromJson(Map<String, dynamic> j) => AssertionModel(
    kind: AssertKind.values.asNameMap()[j['kind']] ?? AssertKind.statusEquals,
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

/// Colour theme family.
enum AppThemeId { teal, graphite }

/// Light/dark choice for themes that have both.
enum ThemeModePref { system, light, dark }

/// Preferred HTTP protocol version.
enum HttpVersionPref { v1, v2, v3 }

extension HttpVersionPrefLabel on HttpVersionPref {
  String get label => switch (this) {
    HttpVersionPref.v1 => 'HTTP/1.1',
    HttpVersionPref.v2 => 'HTTP/2',
    HttpVersionPref.v3 => 'HTTP/3',
  };
}

/// Whether this build bundles the third-party meme clips for Chaos Mode
/// (assets/sounds/meme/). On by default; the Microsoft Store build turns it
/// off with --dart-define=CHAOS_MEME_SOUNDS=false and leaves the clips out of
/// the bundle (tool/build_store_msix.ps1), because their rights belong to
/// others. Without them Chaos Mode uses the synthesized originals.
const bool kChaosMemeSounds = bool.fromEnvironment(
  'CHAOS_MEME_SOUNDS',
  defaultValue: true,
);

/// False for a bundled meme clip in a build that leaves the clips out.
bool chaosSoundAvailable(String id) =>
    kChaosMemeSounds || !id.startsWith('meme_');

/// Default Chaos Mode sound rules — the real meme clips per status code,
/// synthesized originals as class fallbacks.
const _memeChaosRules = {
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

/// The per-status synthesized set (tool/gen_sounds.dart): the defaults when
/// the meme clips are not bundled.
const _synthChaosRules = {
  '200': 'mission_passed',
  '201': 'boom_applause',
  '204': 'crickets',
  '301': 'head_out',
  '302': 'slide_whistle',
  '304': 'ding',
  '400': 'bruh',
  '401': 'access_denied',
  '403': 'open_up',
  '404': 'fail',
  '405': 'nope',
  '408': 'thinking',
  '409': 'metal_pipe',
  '410': 'its_gone',
  '418': 'kettle',
  '422': 'task_failed',
  '429': 'alarm',
  '500': 'this_is_fine',
  '501': 'construction',
  '502': 'record_scratch',
  '503': 'flatline',
  '504': 'phone_ring',
  '505': 'retro_startup',
  '2xx': 'tada',
  '3xx': 'whoosh',
  '4xx': 'fail',
  '5xx': 'dramatic',
  'error': 'alarm',
};

/// Default Chaos Mode sound rules: the meme clips per status code where the
/// build bundles them, otherwise the synthesized set.
Map<String, String> defaultChaosRules() =>
    Map.of(kChaosMemeSounds ? _memeChaosRules : _synthChaosRules);

/// Older default rule sets; a saved config that still matches one of these
/// was never customized and upgrades to the current defaults.
const legacyChaosRuleSets = [
  // v1: class-only synthesized rules
  {
    '2xx': 'tada',
    '3xx': 'whoosh',
    '4xx': 'fail',
    '5xx': 'dramatic',
    'error': 'alarm',
  },
  // v2: per-status synthesized rules
  _synthChaosRules,
];

enum ProxyMode { none, system, custom }

/// A client certificate presented to matching hosts (mutual TLS).
class ClientCertificate {
  ClientCertificate({
    String? id,
    this.host = '',
    this.certPath = '',
    this.keyPath = '',
    this.pfxPath = '',
    this.passphrase = '',
    this.enabled = true,
  }) : id = id ?? newId();

  String id;

  /// Host name, optionally with a port and a leading `*.` wildcard:
  /// `api.example.com`, `*.example.com`, `localhost:8443`.
  String host;

  /// PEM certificate (chain) and private key, or a PFX/P12 bundle.
  String certPath;
  String keyPath;
  String pfxPath;
  String passphrase;
  bool enabled;

  Map<String, dynamic> toJson() => {
    'id': id,
    'host': host,
    if (certPath.isNotEmpty) 'cert': certPath,
    if (keyPath.isNotEmpty) 'key': keyPath,
    if (pfxPath.isNotEmpty) 'pfx': pfxPath,
    if (passphrase.isNotEmpty) 'passphrase': passphrase,
    if (!enabled) 'enabled': false,
  };

  factory ClientCertificate.fromJson(Map<String, dynamic> j) =>
      ClientCertificate(
        id: j['id'] as String?,
        host: j['host'] as String? ?? '',
        certPath: j['cert'] as String? ?? '',
        keyPath: j['key'] as String? ?? '',
        pfxPath: j['pfx'] as String? ?? '',
        passphrase: j['passphrase'] as String? ?? '',
        enabled: j['enabled'] as bool? ?? true,
      );
}

/// Proxy and certificate settings.
class NetworkSettings {
  NetworkSettings({
    this.proxyMode = ProxyMode.system,
    this.proxyHost = '',
    this.proxyPort = 8080,
    this.proxyUser = '',
    this.proxyPassword = '',
    this.proxyBypass = 'localhost, 127.0.0.1, ::1',
    this.caCertPath = '',
    List<ClientCertificate>? clientCerts,
  }) : clientCerts = clientCerts ?? [];

  /// system: the HTTP_PROXY / HTTPS_PROXY / NO_PROXY environment variables.
  ProxyMode proxyMode;
  String proxyHost;
  int proxyPort;
  String proxyUser;
  String proxyPassword;

  /// Comma-separated hosts that skip the custom proxy (`*.local` allowed).
  String proxyBypass;

  /// Extra trusted CA certificate (PEM), on top of the system store.
  String caCertPath;
  List<ClientCertificate> clientCerts;

  Map<String, dynamic> toJson() => {
    'proxyMode': proxyMode.name,
    'proxyHost': proxyHost,
    'proxyPort': proxyPort,
    if (proxyUser.isNotEmpty) 'proxyUser': proxyUser,
    if (proxyPassword.isNotEmpty) 'proxyPassword': proxyPassword,
    'proxyBypass': proxyBypass,
    if (caCertPath.isNotEmpty) 'caCertPath': caCertPath,
    if (clientCerts.isNotEmpty)
      'clientCerts': clientCerts.map((e) => e.toJson()).toList(),
  };

  factory NetworkSettings.fromJson(Map<String, dynamic>? j) => j == null
      ? NetworkSettings()
      : NetworkSettings(
          proxyMode:
              ProxyMode.values.asNameMap()[j['proxyMode']] ?? ProxyMode.system,
          proxyHost: j['proxyHost'] as String? ?? '',
          proxyPort: (j['proxyPort'] as num?)?.toInt() ?? 8080,
          proxyUser: j['proxyUser'] as String? ?? '',
          proxyPassword: j['proxyPassword'] as String? ?? '',
          proxyBypass:
              j['proxyBypass'] as String? ?? 'localhost, 127.0.0.1, ::1',
          caCertPath: j['caCertPath'] as String? ?? '',
          clientCerts: (j['clientCerts'] as List<dynamic>? ?? [])
              .map((e) => ClientCertificate.fromJson(e as Map<String, dynamic>))
              .toList(),
        );
}

class AppSettings {
  AppSettings({
    this.verifySsl = true,
    this.httpVersion = HttpVersionPref.v1,
    this.connectTimeoutS = 30,
    this.receiveTimeoutS = 60,
    this.chaosMode = false,
    Map<String, String>? chaosRules,
    this.theme = AppThemeId.teal,
    this.themeMode = ThemeModePref.system,
    this.hoverHelp = true,
    this.followRedirects = true,
    this.maxRedirects = 10,
    this.cookiesEnabled = true,
    this.scriptsEnabled = true,
    this.scriptTimeoutMs = 10000,
    NetworkSettings? network,
  }) : chaosRules = chaosRules ?? defaultChaosRules(),
       network = network ?? NetworkSettings();

  /// Defaults for requests whose own settings don't say otherwise.
  bool followRedirects;
  int maxRedirects;

  /// Keep a cookie jar: store Set-Cookie and send matching cookies.
  bool cookiesEnabled;

  /// Run pre-request and test scripts (when the platform has an engine).
  bool scriptsEnabled;
  int scriptTimeoutMs;

  /// Proxy and certificates.
  NetworkSettings network;

  /// Explanation cards when pointing at fields, buttons and badges.
  bool hoverHelp;

  AppThemeId theme;
  ThemeModePref themeMode;

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
    'theme': theme.name,
    'themeMode': themeMode.name,
    'hoverHelp': hoverHelp,
    'followRedirects': followRedirects,
    'maxRedirects': maxRedirects,
    'cookiesEnabled': cookiesEnabled,
    'scriptsEnabled': scriptsEnabled,
    'scriptTimeoutMs': scriptTimeoutMs,
    'network': network.toJson(),
  };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
    verifySsl: j['verifySsl'] as bool? ?? true,
    httpVersion:
        HttpVersionPref.values.asNameMap()[j['httpVersion']] ??
        // Migration from the earlier boolean setting.
        (j['useHttp2'] == true ? HttpVersionPref.v2 : HttpVersionPref.v1),
    connectTimeoutS: (j['connectTimeoutS'] as num?)?.toInt() ?? 30,
    receiveTimeoutS: (j['receiveTimeoutS'] as num?)?.toInt() ?? 60,
    chaosMode: j['chaosMode'] as bool? ?? j['funMode'] as bool? ?? false,
    chaosRules: _migrateChaosRules(
      (j['chaosRules'] ?? j['funRules']) as Map<String, dynamic>?,
    ),
    theme: AppThemeId.values.asNameMap()[j['theme']] ?? AppThemeId.teal,
    themeMode:
        ThemeModePref.values.asNameMap()[j['themeMode']] ??
        ThemeModePref.system,
    hoverHelp: j['hoverHelp'] as bool? ?? true,
    followRedirects: j['followRedirects'] as bool? ?? true,
    maxRedirects: (j['maxRedirects'] as num?)?.toInt() ?? 10,
    cookiesEnabled: j['cookiesEnabled'] as bool? ?? true,
    scriptsEnabled: j['scriptsEnabled'] as bool? ?? true,
    scriptTimeoutMs: (j['scriptTimeoutMs'] as num?)?.toInt() ?? 10000,
    network: NetworkSettings.fromJson(j['network'] as Map<String, dynamic>?),
  );

  static Map<String, String> _migrateChaosRules(Map<String, dynamic>? raw) {
    if (raw == null) return defaultChaosRules();
    final rules = raw.map((k, v) => MapEntry(k, v.toString()));
    // An untouched default set (an older one, or the meme set in a build
    // without the clips) follows this build's defaults.
    for (final known in [...legacyChaosRuleSets, _memeChaosRules]) {
      if (rules.length == known.length &&
          known.entries.every((e) => rules[e.key] == e.value)) {
        return defaultChaosRules();
      }
    }
    if (!kChaosMemeSounds) {
      // Customized rules that name a clip this build does not have: an exact
      // code falls back to its class rule, a class rule to this build's
      // default for that class.
      final defaults = defaultChaosRules();
      for (final key in rules.keys.toList()) {
        if (chaosSoundAvailable(rules[key]!)) continue;
        if (RegExp(r'^\d{3}$').hasMatch(key)) {
          rules.remove(key);
        } else {
          rules[key] = defaults[key] ?? '';
        }
      }
    }
    return rules;
  }
}

class RequestModel {
  RequestModel({
    String? id,
    this.name = 'Untitled request',
    this.kind = RequestKind.http,
    this.method = 'GET',
    this.url = '',
    List<KV>? params,
    List<KV>? pathVariables,
    List<KV>? headers,
    this.bodyType = BodyType.none,
    this.body = '',
    this.graphqlVariables = '',
    List<KV>? formFields,
    AuthConfig? auth,
    AuthType authType = AuthType.none,
    String bearerToken = '',
    String basicUser = '',
    String basicPassword = '',
    String apiKeyName = '',
    String apiKeyValue = '',
    bool apiKeyInHeader = true,
    Map<String, String>? authParams,
    List<AssertionModel>? assertions,
    this.folder = '',
    this.description = '',
    this.preRequestScript = '',
    this.testScript = '',
    Map<String, String>? captures,
    RequestSettings? settings,
    List<ResponseExample>? examples,
    Map<String, dynamic>? protocolConfig,
  }) : id = id ?? newId(),
       params = params ?? [],
       pathVariables = pathVariables ?? [],
       headers = headers ?? [],
       formFields = formFields ?? [],
       auth =
           auth ??
           AuthConfig(
             type: authType,
             bearerToken: bearerToken,
             basicUser: basicUser,
             basicPassword: basicPassword,
             apiKeyName: apiKeyName,
             apiKeyValue: apiKeyValue,
             apiKeyInHeader: apiKeyInHeader,
             params: authParams,
           ),
       assertions = assertions ?? [],
       captures = captures ?? {},
       settings = settings ?? RequestSettings(),
       examples = examples ?? [],
       protocolConfig = protocolConfig ?? {};

  String id;
  String name;

  /// HTTP (including GraphQL bodies) or one of the streaming protocols.
  RequestKind kind;
  String method;
  String url;
  List<KV> params;

  /// Values for `:name` segments in [url]. Postman keeps these apart from
  /// the URL; they are substituted on send.
  List<KV> pathVariables;
  List<KV> headers;
  BodyType bodyType;
  String body;
  String graphqlVariables; // JSON, only used when bodyType == graphql
  List<KV> formFields;
  AuthConfig auth;
  List<AssertionModel> assertions;

  /// Folder path inside its collection, segments joined by '/' ('' = root).
  String folder;

  /// Free-form documentation (Markdown), e.g. imported from Postman.
  String description;

  /// JavaScript run before the request is sent / after the response
  /// arrives, with Postman's `pm` API (when a script engine is available).
  String preRequestScript;
  String testScript;

  /// Values saved from each successful response for later requests:
  /// variable name → `body.<json path>`, `header.<name>` or `status`.
  Map<String, String> captures;

  RequestSettings settings;
  List<ResponseExample> examples;

  /// Saved settings of non-HTTP kinds (WebSocket messages, MQTT topics,
  /// gRPC service and method, ...). Each protocol owns its keys; values
  /// must be JSON-encodable.
  Map<String, dynamic> protocolConfig;

  // Flat auth accessors, kept for the many call sites that predate
  // [AuthConfig].
  AuthType get authType => auth.type;
  set authType(AuthType v) => auth.type = v;
  String get bearerToken => auth.bearerToken;
  set bearerToken(String v) => auth.bearerToken = v;
  String get basicUser => auth.basicUser;
  set basicUser(String v) => auth.basicUser = v;
  String get basicPassword => auth.basicPassword;
  set basicPassword(String v) => auth.basicPassword = v;
  String get apiKeyName => auth.apiKeyName;
  set apiKeyName(String v) => auth.apiKeyName = v;
  String get apiKeyValue => auth.apiKeyValue;
  set apiKeyValue(String v) => auth.apiKeyValue = v;
  bool get apiKeyInHeader => auth.apiKeyInHeader;
  set apiKeyInHeader(bool v) => auth.apiKeyInHeader = v;

  RequestModel clone({bool sameId = false}) => RequestModel(
    id: sameId ? id : null,
    name: name,
    kind: kind,
    method: method,
    url: url,
    params: params.map((e) => e.clone()).toList(),
    pathVariables: pathVariables.map((e) => e.clone()).toList(),
    headers: headers.map((e) => e.clone()).toList(),
    bodyType: bodyType,
    body: body,
    graphqlVariables: graphqlVariables,
    formFields: formFields.map((e) => e.clone()).toList(),
    auth: auth.clone(),
    assertions: assertions.map((e) => e.clone()).toList(),
    folder: folder,
    description: description,
    preRequestScript: preRequestScript,
    testScript: testScript,
    captures: Map.of(captures),
    settings: settings.clone(),
    examples: examples.map((e) => e.clone(sameId: sameId)).toList(),
    protocolConfig: protocolConfig.isEmpty
        ? null
        : (jsonDecode(jsonEncode(protocolConfig)) as Map<String, dynamic>),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (kind != RequestKind.http) 'kind': kind.name,
    'method': method,
    'url': url,
    'params': params.map((e) => e.toJson()).toList(),
    if (pathVariables.isNotEmpty)
      'pathVariables': pathVariables.map((e) => e.toJson()).toList(),
    'headers': headers.map((e) => e.toJson()).toList(),
    'bodyType': bodyType.name,
    'body': body,
    'graphqlVariables': graphqlVariables,
    'formFields': formFields.map((e) => e.toJson()).toList(),
    ...auth.toJson(),
    'assertions': assertions.map((e) => e.toJson()).toList(),
    if (folder.isNotEmpty) 'folder': folder,
    if (description.isNotEmpty) 'description': description,
    if (preRequestScript.isNotEmpty) 'preRequestScript': preRequestScript,
    if (testScript.isNotEmpty) 'testScript': testScript,
    if (captures.isNotEmpty) 'captures': captures,
    if (!settings.isDefault) 'settings': settings.toJson(),
    if (examples.isNotEmpty)
      'examples': examples.map((e) => e.toJson()).toList(),
    if (protocolConfig.isNotEmpty) 'protocol': protocolConfig,
  };

  factory RequestModel.fromJson(Map<String, dynamic> j) => RequestModel(
    id: j['id'] as String?,
    name: j['name'] as String? ?? 'Untitled request',
    kind: RequestKind.values.asNameMap()[j['kind']] ?? RequestKind.http,
    method: j['method'] as String? ?? 'GET',
    url: j['url'] as String? ?? '',
    params: _kvList(j['params']),
    pathVariables: _kvList(j['pathVariables']),
    headers: _kvList(j['headers']),
    bodyType: BodyType.values.asNameMap()[j['bodyType']] ?? BodyType.none,
    body: j['body'] as String? ?? '',
    graphqlVariables: j['graphqlVariables'] as String? ?? '',
    formFields: _kvList(j['formFields']),
    auth: AuthConfig.fromJson(j),
    assertions: (j['assertions'] as List<dynamic>? ?? [])
        .map((e) => AssertionModel.fromJson(e as Map<String, dynamic>))
        .toList(),
    folder: j['folder'] as String? ?? '',
    description: j['description'] as String? ?? '',
    preRequestScript: j['preRequestScript'] as String? ?? '',
    testScript: j['testScript'] as String? ?? '',
    captures: (j['captures'] as Map<String, dynamic>? ?? {}).map(
      (k, v) => MapEntry(k, v.toString()),
    ),
    settings: RequestSettings.fromJson(j['settings'] as Map<String, dynamic>?),
    examples: (j['examples'] as List<dynamic>? ?? [])
        .map((e) => ResponseExample.fromJson(e as Map<String, dynamic>))
        .toList(),
    protocolConfig: (j['protocol'] as Map<String, dynamic>?) == null
        ? null
        : Map<String, dynamic>.of(j['protocol'] as Map<String, dynamic>),
  );

  static List<KV> _kvList(dynamic v) => (v as List<dynamic>? ?? [])
      .map((e) => KV.fromJson(e as Map<String, dynamic>))
      .toList();
}

/// `:name` path segments in [url], in order, without duplicates. Matches
/// Postman: a segment that starts with ':' and runs to the next '/', '?' or
/// '#'. Ports (`host:8080`) and `{{vars}}` are not path variables.
List<String> pathVariableNames(String url) {
  var rest = url;
  final scheme = rest.indexOf('://');
  if (scheme >= 0) rest = rest.substring(scheme + 3);
  final slash = rest.indexOf('/');
  if (slash < 0) return const [];
  rest = rest.substring(slash);
  final cut = rest.indexOf(RegExp(r'[?#]'));
  if (cut >= 0) rest = rest.substring(0, cut);
  final names = <String>[];
  for (final seg in rest.split('/')) {
    if (seg.length > 1 && seg.startsWith(':')) {
      final name = seg.substring(1);
      if (!names.contains(name)) names.add(name);
    }
  }
  return names;
}

class CollectionModel {
  CollectionModel({
    String? id,
    required this.name,
    List<RequestModel>? requests,
    List<KV>? variables,
    this.description = '',
    AuthConfig? auth,
    this.preRequestScript = '',
    this.testScript = '',
    Map<String, FolderMeta>? folders,
  }) : id = id ?? newId(),
       requests = requests ?? [],
       variables = variables ?? [],
       auth = auth ?? AuthConfig(),
       folders = folders ?? {};

  String id;
  String name;
  List<RequestModel> requests;

  /// Collection-scoped {{variables}}. The active environment overrides
  /// them on a name clash, like Postman's scope order.
  List<KV> variables;
  String description;

  /// Auth for requests (and folders) set to [AuthType.inherit].
  AuthConfig auth;

  /// Scripts run around every request in the collection, before the
  /// folder's and the request's own.
  String preRequestScript;
  String testScript;

  /// Folder settings keyed by folder path ('Orders/Refunds'). Folders
  /// themselves exist through their requests' [RequestModel.folder].
  Map<String, FolderMeta> folders;

  Map<String, String> get variableMap => kvMap(variables);

  /// Folder paths from the root down to [folder]: 'a/b' → ['a', 'a/b'].
  static List<String> folderChain(String folder) {
    if (folder.isEmpty) return const [];
    final parts = folder.split('/');
    return [for (var i = 1; i <= parts.length; i++) parts.take(i).join('/')];
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'requests': requests.map((e) => e.toJson()).toList(),
    if (variables.isNotEmpty)
      'variables': variables.map((e) => e.toJson()).toList(),
    if (description.isNotEmpty) 'description': description,
    if (auth.type != AuthType.none) 'auth': auth.toJson(),
    if (preRequestScript.isNotEmpty) 'preRequestScript': preRequestScript,
    if (testScript.isNotEmpty) 'testScript': testScript,
    if (folders.values.any((f) => !f.isEmpty))
      'folders': {
        for (final e in folders.entries)
          if (!e.value.isEmpty) e.key: e.value.toJson(),
      },
  };

  factory CollectionModel.fromJson(Map<String, dynamic> j) => CollectionModel(
    id: j['id'] as String?,
    name: j['name'] as String? ?? 'Collection',
    requests: (j['requests'] as List<dynamic>? ?? [])
        .map((e) => RequestModel.fromJson(e as Map<String, dynamic>))
        .toList(),
    variables: RequestModel._kvList(j['variables']),
    description: j['description'] as String? ?? '',
    auth: j['auth'] is Map<String, dynamic>
        ? AuthConfig.fromJson(j['auth'] as Map<String, dynamic>)
        : null,
    preRequestScript: j['preRequestScript'] as String? ?? '',
    testScript: j['testScript'] as String? ?? '',
    folders: (j['folders'] as Map<String, dynamic>? ?? {}).map(
      (k, v) => MapEntry(k, FolderMeta.fromJson(v as Map<String, dynamic>)),
    ),
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

  /// Decode only a bounded preview for rendering; full bytes remain available
  /// to assertions, clipboard and exports. Cache it for repeated UI rebuilds.
  static const previewByteLimit = 64 * 1024;
  bool get previewTruncated => bodyBytes.length > previewByteLimit;
  late final String bodyPreview = previewTruncated
      ? utf8.decode(
          bodyBytes.sublist(0, previewByteLimit),
          allowMalformed: true,
        )
      : bodyText;

  String get bodyText {
    try {
      return utf8.decode(bodyBytes);
    } catch (_) {
      return latin1.decode(bodyBytes, allowInvalid: true);
    }
  }
}
