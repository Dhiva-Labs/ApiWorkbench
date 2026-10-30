import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../models/models.dart';
import '../request_builder.dart';
import 'auth.dart';
import 'auth_util.dart';

/// Postman's `grant_type` values.
abstract final class OAuth2Grant {
  static const authorizationCode = 'authorization_code';
  static const pkce = 'authorization_code_with_pkce';
  static const implicit = 'implicit';
  static const password = 'password_credentials';
  static const clientCredentials = 'client_credentials';

  static const all = [
    authorizationCode,
    pkce,
    implicit,
    password,
    clientCredentials,
  ];

  static String label(String g) => switch (g) {
    authorizationCode => 'Authorization Code',
    pkce => 'Authorization Code (With PKCE)',
    implicit => 'Implicit',
    password => 'Password Credentials',
    clientCredentials => 'Client Credentials',
    _ => g,
  };

  /// Grants that need a user to sign in in a browser.
  static bool usesBrowser(String g) =>
      g == authorizationCode || g == pkce || g == implicit;

  /// Grants whose token can be fetched without a user, on send.
  static bool canAutoFetch(String g) => g == clientCredentials || g == password;
}

/// An access token and what came with it.
class OAuth2Token {
  OAuth2Token({
    required this.accessToken,
    this.tokenType = '',
    this.refreshToken = '',
    this.expiresAt,
    this.scope = '',
    this.idToken = '',
    this.name = '',
    DateTime? obtainedAt,
  }) : obtainedAt = obtainedAt ?? DateTime.now();

  /// From a token endpoint response (or an implicit redirect's fragment).
  factory OAuth2Token.fromResponse(
    Map<String, Object?> j,
    DateTime now, {
    String name = '',
  }) {
    final expiresIn = int.tryParse('${j['expires_in'] ?? ''}');
    return OAuth2Token(
      accessToken: '${j['access_token'] ?? ''}',
      tokenType: '${j['token_type'] ?? ''}',
      refreshToken: '${j['refresh_token'] ?? ''}',
      expiresAt: expiresIn == null
          ? null
          : now.toUtc().add(Duration(seconds: expiresIn)),
      scope: '${j['scope'] ?? ''}',
      idToken: '${j['id_token'] ?? ''}',
      name: name,
      obtainedAt: now,
    );
  }

  factory OAuth2Token.fromJson(Map<String, dynamic> j) => OAuth2Token(
    accessToken: j['accessToken'] as String? ?? '',
    tokenType: j['tokenType'] as String? ?? '',
    refreshToken: j['refreshToken'] as String? ?? '',
    expiresAt: DateTime.tryParse(j['expiresAt'] as String? ?? ''),
    scope: j['scope'] as String? ?? '',
    idToken: j['idToken'] as String? ?? '',
    name: j['name'] as String? ?? '',
    obtainedAt: DateTime.tryParse(j['obtainedAt'] as String? ?? ''),
  );

  final String accessToken;
  final String tokenType;
  final String refreshToken;
  final DateTime? expiresAt;
  final String scope;
  final String idToken;
  final String name;
  final DateTime obtainedAt;

  bool isExpired(DateTime now) =>
      expiresAt != null && !now.isBefore(expiresAt!);

  Map<String, dynamic> toJson() => {
    'accessToken': accessToken,
    if (tokenType.isNotEmpty) 'tokenType': tokenType,
    if (refreshToken.isNotEmpty) 'refreshToken': refreshToken,
    if (expiresAt != null) 'expiresAt': expiresAt!.toUtc().toIso8601String(),
    if (scope.isNotEmpty) 'scope': scope,
    if (idToken.isNotEmpty) 'idToken': idToken,
    if (name.isNotEmpty) 'name': name,
    'obtainedAt': obtainedAt.toUtc().toIso8601String(),
  };
}

/// What an authorization server sent back to the redirect URI.
class OAuth2Redirect {
  OAuth2Redirect(this.params);

  /// Query and fragment parameters together.
  final Map<String, String> params;

  String? get code => params['code'];
  String? get state => params['state'];
  String? get error => params['error'];
  String? get accessToken => params['access_token'];

  /// Parses a pasted or caught redirect URL. A bare query or fragment
  /// (`code=...&state=...`) works too.
  factory OAuth2Redirect.parse(String raw) {
    final s = raw.trim();
    final out = <String, String>{};
    final uri = Uri.tryParse(s);
    if (uri != null && (uri.hasScheme || s.startsWith('/'))) {
      for (final e in formPairs(uri.query)) {
        out[e.key] = e.value;
      }
      for (final e in formPairs(uri.fragment)) {
        out[e.key] = e.value;
      }
    } else {
      for (final e in formPairs(s.replaceFirst(RegExp(r'^[?#]'), ''))) {
        out[e.key] = e.value;
      }
    }
    return OAuth2Redirect(out);
  }
}

/// OAuth 2.0 (RFC 6749, PKCE RFC 7636). Settings live in [AuthConfig.params]
/// under Postman's names. ApiWorkbench adds `expiresAt` (ISO time of the
/// current token's expiry) and `savedTokens` (a JSON list of the tokens
/// fetched so far, newest first, for the token list).
abstract final class OAuth2 {
  static const savedTokensKey = 'savedTokens';
  static const _maxSaved = 20;

  static String grant(AuthConfig a) {
    final g = a.params['grant_type'] ?? '';
    return OAuth2Grant.all.contains(g) ? g : OAuth2Grant.authorizationCode;
  }

  static DateTime? expiresAt(AuthConfig a) =>
      DateTime.tryParse(a.params['expiresAt'] ?? '');

  /// The stored current token, or null.
  static OAuth2Token? current(AuthConfig a) {
    final t = a.params['accessToken'] ?? '';
    if (t.isEmpty) return null;
    return OAuth2Token(
      accessToken: t,
      tokenType: a.params['tokenType'] ?? '',
      refreshToken: a.params['refreshToken'] ?? '',
      expiresAt: expiresAt(a),
      name: a.params['tokenName'] ?? '',
    );
  }

  static List<OAuth2Token> saved(AuthConfig a) {
    final raw = a.params[savedTokensKey];
    if (raw == null || raw.isEmpty) return [];
    try {
      return [
        for (final j in jsonDecode(raw) as List)
          if (j is Map<String, dynamic>) OAuth2Token.fromJson(j),
      ];
    } catch (_) {
      return [];
    }
  }

  static void setSaved(AuthConfig a, List<OAuth2Token> tokens) {
    if (tokens.isEmpty) {
      a.params.remove(savedTokensKey);
    } else {
      a.params[savedTokensKey] = jsonEncode([
        for (final t in tokens.take(_maxSaved)) t.toJson(),
      ]);
    }
  }

  /// Makes [t] the current token.
  static void use(AuthConfig a, OAuth2Token t) {
    a.params['accessToken'] = t.accessToken;
    _setOrRemove(a, 'tokenType', t.tokenType);
    _setOrRemove(a, 'refreshToken', t.refreshToken);
    _setOrRemove(a, 'expiresAt', t.expiresAt?.toUtc().toIso8601String() ?? '');
  }

  /// Stores [t] as current and in the saved list. A refreshed token
  /// replaces the one it came from and keeps its refresh token when the
  /// server sends no new one.
  static void store(AuthConfig a, OAuth2Token t, {OAuth2Token? replacing}) {
    var token = t;
    if (replacing != null && t.refreshToken.isEmpty) {
      token = OAuth2Token(
        accessToken: t.accessToken,
        tokenType: t.tokenType.isEmpty ? replacing.tokenType : t.tokenType,
        refreshToken: replacing.refreshToken,
        expiresAt: t.expiresAt,
        scope: t.scope,
        idToken: t.idToken,
        name: t.name.isEmpty ? replacing.name : t.name,
        obtainedAt: t.obtainedAt,
      );
    }
    use(a, token);
    final list = saved(a)
      ..removeWhere(
        (s) =>
            s.accessToken == token.accessToken ||
            (replacing != null && s.accessToken == replacing.accessToken),
      );
    setSaved(a, [token, ...list]);
  }

  /// Forgets the current token (the saved list is kept).
  static void clear(AuthConfig a) {
    for (final k in ['accessToken', 'tokenType', 'refreshToken', 'expiresAt']) {
      a.params.remove(k);
    }
  }

  static void _setOrRemove(AuthConfig a, String key, String v) {
    if (v.isEmpty) {
      a.params.remove(key);
    } else {
      a.params[key] = v;
    }
  }

  /// One fetch or refresh per auth at a time; concurrent sends (a runner,
  /// a load test) wait for it instead of each asking for a token.
  static final _inflight = Expando<Future<void>>();

  static Future<void> _once(AuthConfig a, Future<void> Function() job) {
    final running = _inflight[a];
    if (running != null) return running;
    final f = job().whenComplete(() => _inflight[a] = null);
    _inflight[a] = f;
    return f;
  }

  /// Adds the token to [p], first fetching or refreshing it when needed
  /// and possible.
  static Future<void> apply(
    PreparedRequest p,
    AuthConfig auth,
    AuthContext ctx,
  ) async {
    final g = grant(auth);
    if (!ctx.offline && ctx.sendRaw != null) {
      final token = auth.params['accessToken'] ?? '';
      final exp = expiresAt(auth);
      final expired = exp != null && !ctx.now().isBefore(exp);
      final canRefresh = (auth.params['refreshToken'] ?? '').isNotEmpty;
      if (token.isNotEmpty && expired && canRefresh) {
        try {
          await _once(auth, () => refresh(auth, ctx, settings: p.settings));
        } on AuthException catch (e) {
          if (!OAuth2Grant.canAutoFetch(g)) {
            throw AuthException(
              'The access token expired and could not be refreshed: '
              '${e.message} Use "Get new access token" in the Auth tab.',
            );
          }
          await _once(auth, () => fetch(auth, ctx, settings: p.settings));
        }
      } else if (OAuth2Grant.canAutoFetch(g) && (token.isEmpty || expired)) {
        await _once(auth, () => fetch(auth, ctx, settings: p.settings));
      }
    }

    final token = ctx.param(auth, 'accessToken');
    if (token.isEmpty) {
      if (ctx.offline) return;
      throw AuthException(
        OAuth2Grant.usesBrowser(g)
            ? 'No OAuth 2.0 access token yet. In the Auth tab, click "Get new '
                  'access token" and sign in.'
            : 'No OAuth 2.0 access token. Check the access token URL and '
                  'client credentials, or click "Get new access token" in the '
                  'Auth tab.',
      );
    }
    if (auth.params['addTokenTo'] == 'queryParams') {
      p.url = appendQuery(p.url, 'access_token', token);
    } else {
      final prefix = ctx.resolve(auth.params['headerPrefix'] ?? 'Bearer');
      p.headers.set(
        'Authorization',
        prefix.trim().isEmpty ? token : '${prefix.trim()} $token',
      );
    }
  }

  /// Fetches a token with the client credentials or password grant and
  /// stores it.
  static Future<OAuth2Token> fetch(
    AuthConfig a,
    AuthContext ctx, {
    ResolvedSettings settings = const ResolvedSettings(),
  }) async {
    final g = grant(a);
    if (!OAuth2Grant.canAutoFetch(g)) {
      throw AuthException(
        '${OAuth2Grant.label(g)} needs a browser sign-in: use "Get new '
        'access token" in the Auth tab.',
      );
    }
    final t = await _tokenRequest(a, ctx, ctx.param(a, 'accessTokenUrl'), {
      if (g == OAuth2Grant.password) ...{
        'grant_type': 'password',
        'username': ctx.param(a, 'username'),
        'password': ctx.param(a, 'password'),
      } else
        'grant_type': 'client_credentials',
      ..._scopeAudience(a, ctx),
    }, settings: settings);
    store(a, t);
    ctx.onUpdated?.call();
    return t;
  }

  /// Uses the refresh token for a new access token and stores it.
  static Future<OAuth2Token> refresh(
    AuthConfig a,
    AuthContext ctx, {
    ResolvedSettings settings = const ResolvedSettings(),
  }) async {
    final old = current(a);
    final rt = ctx.resolve(old?.refreshToken ?? '');
    if (old == null || rt.isEmpty) {
      throw AuthException('There is no refresh token.');
    }
    final url = ctx.param(a, 'refreshTokenUrl');
    final t = await _tokenRequest(
      a,
      ctx,
      url.isNotEmpty ? url : ctx.param(a, 'accessTokenUrl'),
      {'grant_type': 'refresh_token', 'refresh_token': rt},
      settings: settings,
    );
    store(a, t, replacing: old);
    ctx.onUpdated?.call();
    return t;
  }

  /// Exchanges an authorization code for a token and stores it.
  static Future<OAuth2Token> exchangeCode(
    AuthConfig a,
    AuthContext ctx, {
    required String code,
    required String redirectUri,
    String codeVerifier = '',
    ResolvedSettings settings = const ResolvedSettings(),
  }) async {
    final t = await _tokenRequest(a, ctx, ctx.param(a, 'accessTokenUrl'), {
      'grant_type': 'authorization_code',
      'code': code,
      if (redirectUri.isNotEmpty) 'redirect_uri': redirectUri,
      if (grant(a) == OAuth2Grant.pkce) 'code_verifier': codeVerifier,
      ..._audience(a, ctx),
    }, settings: settings);
    store(a, t);
    ctx.onUpdated?.call();
    return t;
  }

  /// Finishes a browser sign-in from the URL the browser was sent back to:
  /// checks the state, then exchanges the code (or, for the implicit
  /// grant, takes the token from the fragment) and stores the token.
  ///
  /// [strictState] also rejects a redirect without the state, as the
  /// loopback listener does: anything on the machine can reach it.
  static Future<OAuth2Token> completeRedirect(
    AuthConfig a,
    AuthContext ctx,
    String redirected, {
    required String redirectUri,
    required String state,
    String codeVerifier = '',
    bool strictState = false,
    ResolvedSettings settings = const ResolvedSettings(),
  }) async {
    final r = OAuth2Redirect.parse(redirected);
    if (r.error != null) {
      final desc = r.params['error_description'];
      throw AuthException(
        'The authorization server refused: ${r.error}'
        '${desc == null || desc.isEmpty ? '' : ' ($desc)'}',
      );
    }
    if (state.isNotEmpty &&
        (r.state != null || strictState) &&
        r.state != state) {
      throw AuthException(
        'The state in the redirect does not match the one sent, so it was '
        'not accepted. Start the sign-in again.',
      );
    }
    if (grant(a) == OAuth2Grant.implicit) {
      if ((r.accessToken ?? '').isEmpty) {
        throw AuthException(
          'No access_token in the redirect. For the implicit grant the '
          'token is in the part after #; paste the whole URL.',
        );
      }
      final t = OAuth2Token.fromResponse(
        r.params,
        ctx.now(),
        name: ctx.param(a, 'tokenName'),
      );
      store(a, t);
      ctx.onUpdated?.call();
      return t;
    }
    final code = r.code;
    if (code == null || code.isEmpty) {
      throw AuthException('No authorization code in the redirect URL.');
    }
    return exchangeCode(
      a,
      ctx,
      code: code,
      redirectUri: redirectUri,
      codeVerifier: codeVerifier,
      settings: settings,
    );
  }

  /// The URL to open for the authorization code and implicit grants.
  static Uri authorizationUrl(
    AuthConfig a,
    AuthContext ctx, {
    required String redirectUri,
    String state = '',
    String codeVerifier = '',
  }) {
    final g = grant(a);
    final base = _parseUrl(ctx.param(a, 'authUrl'), 'Auth URL');
    final method = ctx.param(a, 'challengeAlgorithm', 'S256');
    final scope = ctx.param(a, 'scope');
    final q = <String, String>{
      ...base.queryParameters,
      'response_type': g == OAuth2Grant.implicit ? 'token' : 'code',
      'client_id': ctx.param(a, 'clientId'),
      if (redirectUri.isNotEmpty) 'redirect_uri': redirectUri,
      if (scope.isNotEmpty) 'scope': scope,
      if (state.isNotEmpty) 'state': state,
      if (g == OAuth2Grant.pkce) ...{
        'code_challenge': codeChallenge(codeVerifier, method),
        'code_challenge_method': method == 'plain' ? 'plain' : 'S256',
      },
      ..._audience(a, ctx),
    };
    return base.replace(queryParameters: q);
  }

  /// RFC 7636 §4.2: S256 is base64url(SHA-256(verifier)).
  static String codeChallenge(String verifier, String method) =>
      method == 'plain'
      ? verifier
      : base64UrlNoPad(sha256.convert(ascii.encode(verifier)).bytes);

  /// A 64-character code verifier (RFC 7636 allows 43 to 128).
  static String newCodeVerifier() => base64UrlNoPad(randomBytes(48));

  static Map<String, String> _scopeAudience(AuthConfig a, AuthContext ctx) {
    final scope = ctx.param(a, 'scope');
    return {if (scope.isNotEmpty) 'scope': scope, ..._audience(a, ctx)};
  }

  static Map<String, String> _audience(AuthConfig a, AuthContext ctx) {
    final audience = _flat(ctx.param(a, 'audience'));
    final resource = _flat(ctx.param(a, 'resource'));
    return {
      if (audience.isNotEmpty) 'audience': audience,
      if (resource.isNotEmpty) 'resource': resource,
    };
  }

  /// Postman may export audience and resource as `{url: value}` objects.
  static String _flat(String v) {
    final t = v.trim();
    if (!t.startsWith('{')) return t;
    try {
      final m = jsonDecode(t);
      if (m is Map) {
        return m.values
            .map((x) => '$x')
            .firstWhere((x) => x.isNotEmpty, orElse: () => '');
      }
    } on FormatException {
      // Not JSON after all; send as typed.
    }
    return t;
  }

  static Uri _parseUrl(String raw, String what) {
    if (raw.trim().isEmpty) throw AuthException('Set the $what.');
    final s = raw.trim().contains('://') ? raw.trim() : 'https://${raw.trim()}';
    final u = Uri.tryParse(s);
    if (u == null || u.host.isEmpty) {
      throw AuthException('The $what is not a valid URL: $raw');
    }
    return u;
  }

  static Future<OAuth2Token> _tokenRequest(
    AuthConfig a,
    AuthContext ctx,
    String url,
    Map<String, String> form, {
    required ResolvedSettings settings,
  }) async {
    final send = ctx.sendRaw;
    if (send == null || ctx.offline) {
      throw AuthException('A token can only be fetched when sending.');
    }
    final uri = _parseUrl(url, 'access token URL');
    final id = ctx.param(a, 'clientId');
    final secret = ctx.param(a, 'clientSecret');
    final body = {...form};
    final headers = HeaderList([
      const MapEntry('Content-Type', 'application/x-www-form-urlencoded'),
      const MapEntry('Accept', 'application/json'),
    ]);
    // A public client (no secret) sends its id in the body either way.
    if (a.params['client_authentication'] == 'body' || secret.isEmpty) {
      if (id.isNotEmpty) body['client_id'] = id;
      if (secret.isNotEmpty) body['client_secret'] = secret;
    } else {
      headers.set(
        'Authorization',
        'Basic ${base64.encode(utf8.encode('$id:$secret'))}',
      );
    }
    final encoded = body.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}='
              '${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
    final res = await send(
      PreparedRequest(
        method: 'POST',
        url: uri,
        headers: headers,
        body: Uint8List.fromList(utf8.encode(encoded)),
        settings: settings,
      ),
    );
    if (res.error != null) {
      throw AuthException('The token request to $uri failed: ${res.error}');
    }
    final data = _tokenBody(res);
    final error = data['error'];
    if (res.statusCode >= 400 || error != null) {
      final desc = data['error_description'];
      final detail = error == null
          ? ''
          : ': $error${desc == null || '$desc'.isEmpty ? '' : ' ($desc)'}';
      throw AuthException(
        'The token request failed (HTTP ${res.statusCode})$detail.',
      );
    }
    final t = OAuth2Token.fromResponse(
      data,
      ctx.now(),
      name: ctx.param(a, 'tokenName'),
    );
    if (t.accessToken.isEmpty) {
      throw AuthException('The token response has no access_token.');
    }
    return t;
  }

  /// JSON, or form-encoded as some servers (GitHub) send by default.
  static Map<String, Object?> _tokenBody(ResponseData res) {
    final text = utf8.decode(res.bodyBytes, allowMalformed: true).trim();
    if (text.startsWith('{')) {
      try {
        final j = jsonDecode(text);
        if (j is Map<String, Object?>) return j;
      } on FormatException {
        // Fall through.
      }
    }
    if (text.contains('=') && !text.contains('<')) {
      return {for (final e in formPairs(text)) e.key: e.value};
    }
    return {};
  }
}
