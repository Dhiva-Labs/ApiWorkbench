import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'auth.dart' show AuthException;
import 'auth_util.dart';

/// PEM private keys for the RSA and ECDSA signers (OAuth 1.0 RSA-SHA*,
/// JWT RS/PS/ES). Reads PKCS#1 (`RSA PRIVATE KEY`), PKCS#8
/// (`PRIVATE KEY`) and SEC1 (`EC PRIVATE KEY`).
sealed class PemPrivateKey {
  const PemPrivateKey();

  /// Parses the first private key block in [pem]. Throws [AuthException]
  /// with a readable reason.
  factory PemPrivateKey.parse(String pem) {
    // Keys pasted from JSON or env files often carry literal "\n".
    final text = pem.replaceAll(r'\n', '\n').trim();
    if (text.isEmpty) throw AuthException('The private key is empty.');
    if (text.contains('ENCRYPTED PRIVATE KEY') ||
        text.contains('Proc-Type: 4,ENCRYPTED')) {
      throw AuthException(
        'The private key is encrypted. Export it without a passphrase, '
        'e.g. openssl pkey -in key.pem -out plain.pem',
      );
    }
    final block = RegExp(
      r'-----BEGIN ([A-Z0-9 ]*PRIVATE KEY)-----([\s\S]*?)-----END \1-----',
    ).firstMatch(text);
    final label = block?.group(1);
    final body = (block?.group(2) ?? text).replaceAll(RegExp(r'\s'), '');
    final Uint8List der;
    try {
      der = base64.decode(body);
    } on FormatException {
      throw AuthException(
        'The private key is not valid PEM. Paste the whole key, including '
        'the -----BEGIN ... PRIVATE KEY----- line.',
      );
    }
    try {
      return switch (label) {
        'RSA PRIVATE KEY' => _pkcs1(der),
        'EC PRIVATE KEY' => _sec1(der, null),
        'PRIVATE KEY' => _pkcs8(der),
        null => _guess(der),
        _ => throw AuthException('Unsupported key type: $label.'),
      };
    } on AuthException {
      rethrow;
    } catch (_) {
      throw AuthException(
        'The private key could not be read. Use an unencrypted PKCS#1, '
        'PKCS#8 or SEC1 (EC) PEM key.',
      );
    }
  }

  static PemPrivateKey _guess(Uint8List der) {
    for (final f in <PemPrivateKey Function(Uint8List)>[
      _pkcs8,
      _pkcs1,
      (d) => _sec1(d, null),
    ]) {
      try {
        return f(der);
      } catch (_) {}
    }
    throw AuthException('The private key could not be read.');
  }
}

class RsaPemKey extends PemPrivateKey {
  const RsaPemKey(this.key, this.publicExponent);
  final RSAPrivateKey key;

  /// From the key file: OpenSSL computes `d` modulo λ(n), so the exponent
  /// pointycastle derives from `d` can differ from the real `e`.
  final BigInt publicExponent;

  RSAPublicKey get publicKey => RSAPublicKey(key.modulus!, publicExponent);
}

class EcPemKey extends PemPrivateKey {
  const EcPemKey(this.key, this.curve);
  final ECPrivateKey key;

  /// `P-256`, `P-384`, `P-521` or `secp256k1`.
  final String curve;

  ECPublicKey get publicKey =>
      ECPublicKey(key.parameters!.G * key.d, key.parameters);
}

// ---- DER ----

class _Tlv {
  _Tlv(this.tag, this.value);
  final int tag;
  final Uint8List value;

  List<_Tlv> get children => _readAll(value);
  BigInt get integer {
    var r = BigInt.zero;
    for (final b in value) {
      r = (r << 8) | BigInt.from(b);
    }
    return r;
  }
}

List<_Tlv> _readAll(Uint8List b) {
  final out = <_Tlv>[];
  var i = 0;
  while (i < b.length) {
    final tag = b[i++];
    var len = b[i++];
    if (len & 0x80 != 0) {
      final n = len & 0x7f;
      len = 0;
      for (var k = 0; k < n; k++) {
        len = (len << 8) | b[i++];
      }
    }
    if (i + len > b.length) throw const FormatException('truncated DER');
    out.add(_Tlv(tag, Uint8List.sublistView(b, i, i + len)));
    i += len;
  }
  return out;
}

_Tlv _one(Uint8List der) {
  final all = _readAll(der);
  if (all.isEmpty || all.first.tag != 0x30) {
    throw const FormatException('not a DER sequence');
  }
  return all.first;
}

const _oidRsa = '2a864886f70d010101';
const _oidEc = '2a8648ce3d0201';
const _curves = {
  '2a8648ce3d030107': 'P-256',
  '2b81040022': 'P-384',
  '2b81040023': 'P-521',
  '2b8104000a': 'secp256k1',
};

ECDomainParameters _domain(String curve) => switch (curve) {
  'P-256' => ECCurve_secp256r1(),
  'P-384' => ECCurve_secp384r1(),
  'P-521' => ECCurve_secp521r1(),
  'secp256k1' => ECCurve_secp256k1(),
  _ => throw AuthException('Unsupported EC curve $curve.'),
};

/// RSAPrivateKey ::= SEQUENCE { version, n, e, d, p, q, dP, dQ, qInv }
RsaPemKey _pkcs1(Uint8List der) {
  final f = _one(der).children;
  return RsaPemKey(
    RSAPrivateKey(f[1].integer, f[3].integer, f[4].integer, f[5].integer),
    f[2].integer,
  );
}

/// PrivateKeyInfo ::= SEQUENCE { version, AlgorithmIdentifier, OCTET STRING }
PemPrivateKey _pkcs8(Uint8List der) {
  final f = _one(der).children;
  final alg = f[1].children;
  final oid = hexOf(alg[0].value);
  if (oid == _oidRsa) return _pkcs1(f[2].value);
  if (oid == _oidEc) {
    final curve = alg.length > 1 ? _curves[hexOf(alg[1].value)] : null;
    return _sec1(f[2].value, curve);
  }
  throw AuthException(
    'Unsupported key algorithm in the PKCS#8 key (only RSA and EC keys).',
  );
}

/// ECPrivateKey ::= SEQUENCE { version 1, OCTET STRING d,
///   [0] OID curve OPTIONAL, [1] BIT STRING publicKey OPTIONAL }
EcPemKey _sec1(Uint8List der, String? curveFromPkcs8) {
  final f = _one(der).children;
  final d = _Tlv(0x02, f[1].value).integer;
  var curve = curveFromPkcs8;
  for (final t in f.skip(2)) {
    if (t.tag == 0xa0) {
      final oid = _readAll(t.value).first;
      curve = _curves[hexOf(oid.value)] ?? curve;
    }
  }
  if (curve == null) {
    throw AuthException('The EC key does not name a supported curve.');
  }
  return EcPemKey(ECPrivateKey(d, _domain(curve)), curve);
}

/// A seeded CSPRNG for the PSS salt.
SecureRandom secureRandom() {
  final r = FortunaRandom();
  final rng = Random.secure();
  r.seed(
    KeyParameter(
      Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256))),
    ),
  );
  return r;
}

/// The digests the signers take, by size.
Digest digestFor(int bits) => switch (bits) {
  1 => SHA1Digest(),
  256 => SHA256Digest(),
  384 => SHA384Digest(),
  512 => SHA512Digest(),
  _ => throw ArgumentError('digest $bits'),
};

const _digestOids = {
  1: '06052b0e03021a',
  256: '0609608648016503040201',
  384: '0609608648016503040202',
  512: '0609608648016503040203',
};

/// RSASSA-PKCS1-v1_5 signature of [data] with SHA-[bits] (1 = SHA-1).
Uint8List rsaPkcs1Sign(RSAPrivateKey key, int bits, List<int> data) {
  final s = RSASigner(digestFor(bits), _digestOids[bits]!)
    ..init(true, PrivateKeyParameter<RSAPrivateKey>(key));
  return s.generateSignature(Uint8List.fromList(data)).bytes;
}

/// RSASSA-PSS with SHA-[bits], MGF1 with the same hash and a salt as long
/// as the hash (RFC 7518 §3.5).
Uint8List rsaPssSign(RSAPrivateKey key, int bits, List<int> data) {
  final d = digestFor(bits);
  final s = PSSSigner(RSAEngine(), d, digestFor(bits))
    ..init(
      true,
      ParametersWithSaltConfiguration(
        PrivateKeyParameter<RSAPrivateKey>(key),
        secureRandom(),
        d.digestSize,
      ),
    );
  return s.generateSignature(Uint8List.fromList(data)).bytes;
}

/// Deterministic ECDSA (RFC 6979) with SHA-[bits], as JWS wants it: the
/// raw `r || s`, each padded to the curve size.
Uint8List ecdsaSign(ECPrivateKey key, int bits, List<int> data) {
  final digest = digestFor(bits);
  final s = ECDSASigner(digest, HMac(digestFor(bits), bits == 256 ? 64 : 128))
    ..init(true, PrivateKeyParameter<ECPrivateKey>(key));
  final sig = s.generateSignature(Uint8List.fromList(data)) as ECSignature;
  final size = (key.parameters!.n.bitLength + 7) ~/ 8;
  return Uint8List.fromList([..._fixed(sig.r, size), ..._fixed(sig.s, size)]);
}

Uint8List _fixed(BigInt v, int size) {
  final out = Uint8List(size);
  var x = v;
  for (var i = size - 1; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xff)).toInt();
    x = x >> 8;
  }
  return out;
}
