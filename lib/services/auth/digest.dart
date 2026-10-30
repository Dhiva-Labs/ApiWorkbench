import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../models/models.dart';
import '../request_builder.dart';
import 'auth.dart';
import 'auth_util.dart';

/// Digest access authentication (RFC 7616, compatible with RFC 2617
/// servers).
///
/// With a realm and nonce already set the header is sent on the first
/// request. Otherwise the request goes out without one and the server's
/// 401 challenge is answered, unless `disableRetryRequest` is on.
abstract final class DigestAuth {
  static const algorithms = ['MD5', 'MD5-sess', 'SHA-256', 'SHA-256-sess'];

  /// Preemptive: sign with the realm and nonce set by hand.
  static void apply(PreparedRequest p, AuthConfig auth, AuthContext ctx) {
    final nonce = ctx.param(auth, 'nonce');
    final realm = ctx.param(auth, 'realm');
    if (nonce.isEmpty || realm.isEmpty) return;
    p.headers.set(
      'Authorization',
      header(
        method: p.method,
        uri: requestTarget(p.url),
        username: ctx.param(auth, 'username'),
        password: ctx.param(auth, 'password'),
        realm: realm,
        nonce: nonce,
        algorithm: ctx.param(auth, 'algorithm', 'MD5'),
        qop: ctx.param(auth, 'qop'),
        nc: ctx.param(auth, 'nonceCount'),
        cnonce: ctx.param(auth, 'clientNonce'),
        opaque: ctx.param(auth, 'opaque'),
        body: p.body,
      ),
    );
  }

  /// Answers a `WWW-Authenticate: Digest` challenge.
  static PreparedRequest? retry(
    PreparedRequest sent,
    ResponseData res,
    AuthConfig auth,
    AuthContext ctx,
  ) {
    if (authFlag(auth, 'disableRetryRequest')) return null;
    final offered = parseChallenges(
      wwwAuthenticate(res),
    ).where((c) => c.isScheme('Digest') && c.params['nonce'] != null).toList();
    if (offered.isEmpty) return null;

    // The server lists the algorithms it accepts; prefer the configured one.
    final wanted = ctx.param(auth, 'algorithm', 'MD5').toUpperCase();
    String algOf(AuthChallenge c) =>
        (c.params['algorithm'] ?? 'MD5').toUpperCase();
    final challenge =
        offered.where((c) => algOf(c) == wanted).firstOrNull ??
        offered.where((c) => _hash(algOf(c)) != null).firstOrNull;
    if (challenge == null) return null;

    final qops = (challenge.params['qop'] ?? '')
        .split(',')
        .map((q) => q.trim().toLowerCase())
        .where((q) => q.isNotEmpty)
        .toList();
    final configuredQop = ctx.param(auth, 'qop').toLowerCase();
    final qop = qops.isEmpty
        ? ''
        : qops.contains(configuredQop)
        ? configuredQop
        : (qops.contains('auth') ? 'auth' : qops.first);

    final retry = sent.copy();
    retry.headers.set(
      'Authorization',
      header(
        method: sent.method,
        uri: requestTarget(sent.url),
        username: ctx.param(auth, 'username'),
        password: ctx.param(auth, 'password'),
        realm: challenge.params['realm'] ?? '',
        nonce: challenge.params['nonce']!,
        algorithm: challenge.params['algorithm'] ?? '',
        qop: qop,
        cnonce: ctx.param(auth, 'clientNonce'),
        opaque: challenge.params['opaque'] ?? '',
        body: sent.body,
      ),
    );
    return retry;
  }

  static Hash? _hash(String algorithm) {
    final a = algorithm.toUpperCase();
    final base = a.endsWith('-SESS') ? a.substring(0, a.length - 5) : a;
    return switch (base) {
      '' || 'MD5' => md5,
      'SHA-256' => sha256,
      'SHA-512-256' => sha512256,
      _ => null,
    };
  }

  /// The `response` value of RFC 7616 §3.4.1.
  static String response({
    required String method,
    required String uri,
    required String username,
    required String password,
    required String realm,
    required String nonce,
    String algorithm = 'MD5',
    String qop = '',
    String nc = '00000001',
    String cnonce = '',
    List<int>? body,
  }) {
    final h =
        _hash(algorithm) ??
        (throw AuthException('Unsupported Digest algorithm "$algorithm".'));
    String hx(List<int> bytes) => hexOf(h.convert(bytes).bytes);
    String hs(String s) => hx(utf8.encode(s));
    var ha1 = hs('$username:$realm:$password');
    if (algorithm.toUpperCase().endsWith('-SESS')) {
      ha1 = hs('$ha1:$nonce:$cnonce');
    }
    final ha2 = qop == 'auth-int'
        ? hs('$method:$uri:${hx(body ?? const [])}')
        : hs('$method:$uri');
    return qop.isEmpty
        ? hs('$ha1:$nonce:$ha2')
        : hs('$ha1:$nonce:$nc:$cnonce:$qop:$ha2');
  }

  /// A complete `Authorization: Digest ...` value. An empty [cnonce] or
  /// [nc] gets a fresh client nonce and `00000001`.
  static String header({
    required String method,
    required String uri,
    required String username,
    required String password,
    required String realm,
    required String nonce,
    String algorithm = '',
    String qop = '',
    String nc = '',
    String cnonce = '',
    String opaque = '',
    List<int>? body,
  }) {
    final q = qop.trim().toLowerCase();
    final count = nc.isEmpty ? '00000001' : nc;
    final cn = cnonce.isEmpty ? hexOf(randomBytes(16)) : cnonce;
    final needsCnonce =
        q.isNotEmpty || algorithm.toUpperCase().endsWith('-SESS');
    final r = response(
      method: method,
      uri: uri,
      username: username,
      password: password,
      realm: realm,
      nonce: nonce,
      algorithm: algorithm.isEmpty ? 'MD5' : algorithm,
      qop: q,
      nc: count,
      cnonce: cn,
      body: body,
    );
    return [
      'Digest username=${quoted(username)}',
      'realm=${quoted(realm)}',
      'nonce=${quoted(nonce)}',
      'uri=${quoted(uri)}',
      if (algorithm.isNotEmpty) 'algorithm=$algorithm',
      if (q.isNotEmpty) ...['qop=$q', 'nc=$count'],
      if (needsCnonce) 'cnonce=${quoted(cn)}',
      'response=${quoted(r)}',
      if (opaque.isNotEmpty) 'opaque=${quoted(opaque)}',
    ].join(', ');
  }
}
