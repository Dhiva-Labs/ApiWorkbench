import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../models/models.dart';
import '../request_builder.dart';
import 'auth.dart';
import 'auth_util.dart';
import 'keys.dart';

/// OAuth 1.0a request signing (RFC 5849).
abstract final class OAuth1Auth {
  static const methods = [
    'HMAC-SHA1',
    'HMAC-SHA256',
    'HMAC-SHA512',
    'RSA-SHA1',
    'RSA-SHA256',
    'RSA-SHA512',
    'PLAINTEXT',
  ];

  static void apply(PreparedRequest p, AuthConfig auth, AuthContext ctx) {
    sign(
      p,
      consumerKey: ctx.param(auth, 'consumerKey'),
      consumerSecret: ctx.param(auth, 'consumerSecret'),
      token: ctx.param(auth, 'token'),
      tokenSecret: ctx.param(auth, 'tokenSecret'),
      signatureMethod: ctx.param(auth, 'signatureMethod', 'HMAC-SHA1'),
      timestamp: ctx.param(auth, 'timestamp'),
      nonce: ctx.param(auth, 'nonce'),
      // Postman's default; an explicitly empty version is left out.
      version: ctx.resolve(auth.params['version'] ?? '1.0'),
      realm: ctx.param(auth, 'realm'),
      callback: ctx.param(auth, 'callback'),
      verifier: ctx.param(auth, 'verifier'),
      inHeader: authFlag(auth, 'addParamsToHeader', fallback: true),
      addEmptyParamsToSign: authFlag(auth, 'addEmptyParamsToSign'),
      includeBodyHash: authFlag(auth, 'includeBodyHash'),
      privateKey: ctx.param(auth, 'privateKey'),
      now: ctx.now(),
    );
  }

  /// Signs [p]. With [inHeader] off the oauth_* params go in a form body
  /// when the request has one, else in the query, like Postman. Empty
  /// [timestamp] or [nonce] are generated.
  static void sign(
    PreparedRequest p, {
    required String consumerKey,
    String consumerSecret = '',
    String token = '',
    String tokenSecret = '',
    String signatureMethod = 'HMAC-SHA1',
    String timestamp = '',
    String nonce = '',
    String version = '1.0',
    String realm = '',
    String callback = '',
    String verifier = '',
    bool inHeader = true,
    bool addEmptyParamsToSign = false,
    bool includeBodyHash = false,
    String privateKey = '',
    required DateTime now,
  }) {
    final method = signatureMethod.toUpperCase();
    if (!methods.contains(method)) {
      throw AuthException('Unsupported OAuth 1.0 signature method $method.');
    }
    final form = isFormBody(p);
    final oauth = <String, String>{
      'oauth_consumer_key': consumerKey,
      'oauth_token': token,
      'oauth_signature_method': method,
      'oauth_timestamp': timestamp.isEmpty
          ? '${now.millisecondsSinceEpoch ~/ 1000}'
          : timestamp,
      'oauth_nonce': nonce.isEmpty ? randomAlnum(11) : nonce,
      'oauth_version': version,
      'oauth_callback': callback,
      'oauth_verifier': verifier,
      if (includeBodyHash && !form && method != 'PLAINTEXT')
        'oauth_body_hash': base64.encode(
          _hash(method).convert(p.body ?? const []).bytes,
        ),
    };
    // Optional params with no value are left out unless asked for.
    const optional = {
      'oauth_token',
      'oauth_version',
      'oauth_callback',
      'oauth_verifier',
    };
    oauth.removeWhere(
      (k, v) =>
          v.isEmpty &&
          optional.contains(k) &&
          (k == 'oauth_version' || !addEmptyParamsToSign),
    );

    final params = [
      ...formPairs(p.url.query),
      if (form && p.body != null) ...formPairs(p.bodyText),
      ...oauth.entries,
    ];
    final base = baseString(p.method, p.url, params);
    final signature = _signature(
      method,
      base,
      consumerSecret: consumerSecret,
      tokenSecret: tokenSecret,
      privateKey: privateKey,
    );
    oauth['oauth_signature'] = signature;

    if (inHeader) {
      final fields = [
        if (realm.isNotEmpty) 'realm=${quoted(realm)}',
        for (final e in oauth.entries) '${e.key}="${rfc3986(e.value)}"',
      ];
      p.headers.set('Authorization', 'OAuth ${fields.join(', ')}');
    } else if (form && _allowsBody(p.method)) {
      final extra = oauth.entries
          .map((e) => '${rfc3986(e.key)}=${rfc3986(e.value)}')
          .join('&');
      final text = p.bodyText;
      p.body = Uint8List.fromList(
        utf8.encode(text.isEmpty ? extra : '$text&$extra'),
      );
    } else {
      final extra = oauth.entries
          .map((e) => '${rfc3986(e.key)}=${rfc3986(e.value)}')
          .join('&');
      final q = p.url.hasQuery && p.url.query.isNotEmpty
          ? '${p.url.query}&$extra'
          : extra;
      p.url = p.url.replace(query: q);
    }
  }

  static bool _allowsBody(String method) =>
      !const {'GET', 'HEAD'}.contains(method.toUpperCase());

  /// The signature base string of RFC 5849 §3.4.1: method, base URI and
  /// the normalized parameters, each encoded and joined with `&`.
  static String baseString(
    String method,
    Uri url,
    Iterable<MapEntry<String, String>> params,
  ) {
    final scheme = url.scheme.toLowerCase();
    final defaultPort = scheme == 'https' ? 443 : 80;
    final port = url.hasPort && url.port != defaultPort ? ':${url.port}' : '';
    final path = url.path.isEmpty ? '/' : url.path;
    final baseUri = '$scheme://${url.host.toLowerCase()}$port$path';
    final encoded =
        [for (final e in params) MapEntry(rfc3986(e.key), rfc3986(e.value))]
          ..sort((a, b) {
            final c = a.key.compareTo(b.key);
            return c != 0 ? c : a.value.compareTo(b.value);
          });
    final normalized = encoded.map((e) => '${e.key}=${e.value}').join('&');
    return '${method.toUpperCase()}&${rfc3986(baseUri)}&${rfc3986(normalized)}';
  }

  static Hash _hash(String method) => method.endsWith('512')
      ? sha512
      : method.endsWith('256')
      ? sha256
      : sha1;

  static int _bits(String method) => method.endsWith('512')
      ? 512
      : method.endsWith('256')
      ? 256
      : 1;

  static String _signature(
    String method,
    String base, {
    required String consumerSecret,
    required String tokenSecret,
    required String privateKey,
  }) {
    final key = '${rfc3986(consumerSecret)}&${rfc3986(tokenSecret)}';
    if (method == 'PLAINTEXT') return key;
    if (method.startsWith('HMAC-')) {
      return base64.encode(
        Hmac(_hash(method), utf8.encode(key)).convert(utf8.encode(base)).bytes,
      );
    }
    if (privateKey.trim().isEmpty) {
      throw AuthException('$method needs a private key (PEM).');
    }
    final k = PemPrivateKey.parse(privateKey);
    if (k is! RsaPemKey) {
      throw AuthException('$method needs an RSA private key.');
    }
    return base64.encode(rsaPkcs1Sign(k.key, _bits(method), utf8.encode(base)));
  }
}
