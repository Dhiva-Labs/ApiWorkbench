import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../models/models.dart';
import '../request_builder.dart';
import 'auth.dart';
import 'auth_util.dart';
import 'keys.dart';

/// JWT Bearer: builds and signs a JSON Web Token on every send and adds it
/// as a header or query parameter.
abstract final class JwtAuth {
  static const algorithms = [
    'HS256',
    'HS384',
    'HS512',
    'RS256',
    'RS384',
    'RS512',
    'PS256',
    'PS384',
    'PS512',
    'ES256',
    'ES384',
    'ES512',
  ];

  static void apply(PreparedRequest p, AuthConfig auth, AuthContext ctx) {
    final token = build(
      algorithm: ctx.param(auth, 'algorithm', 'HS256'),
      secret: ctx.param(auth, 'secret'),
      secretBase64: authFlag(auth, 'isSecretBase64Encoded'),
      privateKey: ctx.param(auth, 'privateKey'),
      payload: ctx.param(auth, 'payload', '{}'),
      header: ctx.param(auth, 'header', '{}'),
    );
    if (auth.params['addTokenTo'] == 'queryParam') {
      final key = ctx.param(auth, 'queryParamKey', 'token');
      p.url = appendQuery(p.url, key.isEmpty ? 'token' : key, token);
    } else {
      final prefix = ctx.resolve(auth.params['headerPrefix'] ?? 'Bearer');
      p.headers.set(
        'Authorization',
        prefix.trim().isEmpty ? token : '${prefix.trim()} $token',
      );
    }
  }

  static Map<String, Object?> _object(String json, String what) {
    if (json.trim().isEmpty) return {};
    try {
      final v = jsonDecode(json);
      if (v is Map<String, Object?>) return v;
    } on FormatException catch (e) {
      throw AuthException('The JWT $what is not valid JSON: ${e.message}');
    }
    throw AuthException('The JWT $what must be a JSON object.');
  }

  /// A signed compact JWT. [header] fields are merged over
  /// `{"alg": ..., "typ": "JWT"}`; `alg` always matches [algorithm].
  static String build({
    required String algorithm,
    String secret = '',
    bool secretBase64 = false,
    String privateKey = '',
    String payload = '{}',
    String header = '{}',
  }) {
    final alg = algorithm.toUpperCase();
    if (!algorithms.contains(alg)) {
      throw AuthException('Unsupported JWT algorithm $algorithm.');
    }
    final head = <String, Object?>{
      'alg': alg,
      'typ': 'JWT',
      ..._object(header, 'header'),
    }..['alg'] = alg;
    final body = _object(payload, 'payload');
    final input =
        '${base64UrlNoPad(utf8.encode(jsonEncode(head)))}.'
        '${base64UrlNoPad(utf8.encode(jsonEncode(body)))}';
    return '$input.${base64UrlNoPad(sign(alg, input, secret: secret, secretBase64: secretBase64, privateKey: privateKey))}';
  }

  /// The JWS signature of [input] for [alg].
  static List<int> sign(
    String alg,
    String input, {
    String secret = '',
    bool secretBase64 = false,
    String privateKey = '',
  }) {
    final bits = int.parse(alg.substring(2));
    final data = utf8.encode(input);
    if (alg.startsWith('HS')) {
      final List<int> key;
      try {
        key = secretBase64
            ? base64.decode(_padded(secret))
            : utf8.encode(secret);
      } on FormatException {
        throw AuthException('The JWT secret is not valid base64.');
      }
      final h = switch (bits) {
        256 => sha256,
        384 => sha384,
        _ => sha512,
      };
      return Hmac(h, key).convert(data).bytes;
    }
    if (privateKey.trim().isEmpty) {
      throw AuthException('$alg needs a private key (PEM).');
    }
    final k = PemPrivateKey.parse(privateKey);
    switch (k) {
      case RsaPemKey(:final key) when alg.startsWith('RS'):
        return rsaPkcs1Sign(key, bits, data);
      case RsaPemKey(:final key) when alg.startsWith('PS'):
        return rsaPssSign(key, bits, data);
      case EcPemKey(:final key, :final curve) when alg.startsWith('ES'):
        final want = switch (bits) {
          256 => 'P-256',
          384 => 'P-384',
          _ => 'P-521',
        };
        if (curve != want) {
          throw AuthException('$alg needs a $want key; this key is $curve.');
        }
        return ecdsaSign(key, bits, data);
      case EcPemKey():
        throw AuthException(
          '$alg needs an RSA private key; this is an EC key.',
        );
      case RsaPemKey():
        throw AuthException(
          '$alg needs an EC private key; this is an RSA key.',
        );
    }
  }

  /// Accepts base64url and unpadded secrets too.
  static String _padded(String s) {
    final t = s.trim().replaceAll('-', '+').replaceAll('_', '/');
    return t.padRight((t.length + 3) ~/ 4 * 4, '=');
  }
}
