import 'dart:convert';

import '../../models/models.dart';
import '../request_builder.dart';

/// Auth could not be applied (missing field, token fetch failed, ...).
class AuthException implements Exception {
  AuthException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// What an auth scheme may use while signing or answering a challenge.
class AuthContext {
  AuthContext({
    this.vars = const {},
    this.request,
    this.sendRaw,
    this.onUpdated,
    this.offline = false,
  });

  /// Variables for {{substitution}} in auth fields.
  final Map<String, String> vars;

  /// The request being sent (as saved, before variables).
  final RequestModel? request;

  /// Sends a request without auth, cookies-only, e.g. to fetch or refresh
  /// an OAuth 2.0 token. Null when there is no network (code snippets).
  final Future<ResponseData> Function(PreparedRequest p)? sendRaw;

  /// Called after the scheme changed its stored settings (a refreshed
  /// token), so the owner can be saved.
  final void Function()? onUpdated;

  /// True for code snippets: never touch the network or block on a user.
  final bool offline;

  /// Scratch space kept for one send, e.g. a challenge's state.
  final Map<String, Object?> state = {};

  String resolve(String s) => substituteVars(s, vars);

  /// [AuthConfig.params] value with variables applied.
  String param(AuthConfig auth, String key, [String fallback = '']) =>
      resolve(auth.params[key] ?? fallback);
}

/// The auth a request uses: its own, or for [AuthType.inherit] the nearest
/// folder's, then the collection's. Returns the live object so a refreshed
/// token is stored where it came from.
AuthConfig resolveAuth(RequestModel r, CollectionModel? c) {
  if (r.auth.type != AuthType.inherit) return r.auth;
  if (c == null) return AuthConfig();
  for (final path in CollectionModel.folderChain(r.folder).reversed) {
    final f = c.folders[path];
    if (f != null && f.auth.type != AuthType.inherit) return f.auth;
  }
  return c.auth.type == AuthType.inherit ? AuthConfig() : c.auth;
}

/// Adds [auth] to [p] before it is sent.
Future<void> applyAuth(
  PreparedRequest p,
  AuthConfig auth,
  AuthContext ctx,
) async {
  switch (auth.type) {
    case AuthType.none || AuthType.inherit:
      break;
    case AuthType.bearer:
      p.headers.set('Authorization', 'Bearer ${ctx.resolve(auth.bearerToken)}');
    case AuthType.basic:
      final cred = base64Encode(
        utf8.encode(
          '${ctx.resolve(auth.basicUser)}:${ctx.resolve(auth.basicPassword)}',
        ),
      );
      p.headers.set('Authorization', 'Basic $cred');
    case AuthType.apiKey:
      final k = ctx.resolve(auth.apiKeyName);
      final v = ctx.resolve(auth.apiKeyValue);
      if (k.isEmpty) break;
      if (auth.apiKeyInHeader) {
        p.headers.set(k, v);
      } else {
        p.url = appendQuery(p.url, k, v);
      }
    case AuthType.oauth2 ||
        AuthType.oauth1 ||
        AuthType.digest ||
        AuthType.awsV4 ||
        AuthType.ntlm ||
        AuthType.hawk ||
        AuthType.edgegrid ||
        AuthType.jwt:
      // Implemented by the auth schemes (issues #6, #7, #8).
      break;
  }
}

/// Called with a 401 response. Returns the request to send again (for
/// challenge-response schemes such as Digest and NTLM), or null to keep
/// the response.
Future<PreparedRequest?> retryAfterChallenge(
  PreparedRequest sent,
  ResponseData res,
  AuthConfig auth,
  AuthContext ctx,
) async => null;

/// [url] with `key=value` appended to its query, keeping what is there.
Uri appendQuery(Uri url, String key, String value) {
  final pair =
      '${Uri.encodeQueryComponent(key)}=${Uri.encodeQueryComponent(value)}';
  final q = url.hasQuery && url.query.isNotEmpty ? '${url.query}&$pair' : pair;
  return url.replace(query: q);
}
