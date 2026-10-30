import 'dart:convert';

import '../../models/models.dart';
import '../request_builder.dart';
import 'aws_sigv4.dart';
import 'digest.dart';
import 'edgegrid.dart';
import 'hawk.dart';
import 'jwt.dart';
import 'ntlm.dart';
import 'oauth1.dart';
import 'oauth2.dart';

export 'aws_sigv4.dart' show AwsSigV4;
export 'digest.dart' show DigestAuth;
export 'edgegrid.dart' show EdgeGridAuth;
export 'hawk.dart' show HawkAuth;
export 'jwt.dart' show JwtAuth;
export 'ntlm.dart' show NtlmAuth, NtlmChallenge, md4;
export 'oauth1.dart' show OAuth1Auth;
export 'oauth2.dart' show OAuth2, OAuth2Grant, OAuth2Token, OAuth2Redirect;

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
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

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

  final DateTime Function() _clock;

  /// Scratch space kept for one send, e.g. a challenge's state.
  final Map<String, Object?> state = {};

  /// The time signatures and token expiry use (fixed in tests).
  DateTime now() => _clock();

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

/// Adds [auth] to [p] before it is sent. Signers see the final method,
/// URL, headers and body bytes, so this runs last.
///
/// Throws [AuthException] only: a crypto library error (say, a key too
/// small for RSA-PSS) is reported the same way instead of failing the send.
Future<void> applyAuth(
  PreparedRequest p,
  AuthConfig auth,
  AuthContext ctx,
) async {
  try {
    await _apply(p, auth, ctx);
  } on AuthException {
    rethrow;
  } catch (e) {
    throw AuthException('${auth.type.label} could not be applied: $e');
  }
}

Future<void> _apply(PreparedRequest p, AuthConfig auth, AuthContext ctx) async {
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
    case AuthType.oauth2:
      await OAuth2.apply(p, auth, ctx);
    case AuthType.oauth1:
      OAuth1Auth.apply(p, auth, ctx);
    case AuthType.digest:
      DigestAuth.apply(p, auth, ctx);
    case AuthType.awsV4:
      AwsSigV4.apply(p, auth, ctx);
    case AuthType.ntlm:
      NtlmAuth.apply(p, auth, ctx);
    case AuthType.hawk:
      HawkAuth.apply(p, auth, ctx);
    case AuthType.edgegrid:
      EdgeGridAuth.apply(p, auth, ctx);
    case AuthType.jwt:
      JwtAuth.apply(p, auth, ctx);
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
) async {
  if (ctx.offline) return null;
  try {
    return switch (auth.type) {
      AuthType.digest => DigestAuth.retry(sent, res, auth, ctx),
      AuthType.ntlm => NtlmAuth.retry(sent, res, auth, ctx),
      _ => null,
    };
  } catch (_) {
    // A challenge we can't answer: the 401 is the answer.
    return null;
  }
}

/// [url] with `key=value` appended to its query, keeping what is there.
Uri appendQuery(Uri url, String key, String value) {
  final pair =
      '${Uri.encodeQueryComponent(key)}=${Uri.encodeQueryComponent(value)}';
  final q = url.hasQuery && url.query.isNotEmpty ? '${url.query}&$pair' : pair;
  return url.replace(query: q);
}
