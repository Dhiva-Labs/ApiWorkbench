import 'dart:convert';
import 'dart:typed_data';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/auth/auth.dart';
import 'package:api_workbench/services/auth/auth_util.dart';
import 'package:api_workbench/services/auth/keys.dart';
import 'package:api_workbench/services/request_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

// Throwaway keys generated with OpenSSL for these tests only.

const rsaPkcs1 = '''
-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEA549wJZr1QCtSnE5KZaKTVdgNNcR9OIhSW2Jq550rweQiq/C9
KnkkEDqJoV/Bz4JhvySG0kjj1qHPg72yoCtYlY07lgc4tbvuLaWO0JJNLWRXi+Sl
8hU8lPCiOYxI3Ob6eo0O2bZZFuQEYhgmlCv9WhETlrbUuAeuK7kPVf/Ir4gaCxvF
U6ObfRoAjFq4bReDIO+XgNeTUuZ7YRjnjG2oX93PtBN7N1DChmkg8zybgIJ7SNpi
63YVbNEo+fbN4ATBf74phcDTSOTObhO9912s6hwl7DJROrZIZHiQSBkoSr4+lvdz
I/USo1F574+x4gRhooRDYg7+83/AbSHBhJ0FuQIDAQABAoIBAAKg3o5jQ7/UNJsW
TNKi8f/kx5cm9PDe6eVnRF4WMNJcBHc7sKXQ5efiqU6c4hYKQddkwtmCgHTtG2KG
Q6y9ANrroPgwl6LBRkkqYSMEPHowRvhBjNrMouNwf/FDzl6x/lttpOWiT4DdjDIN
iKXvHx7dc7vpuu89a4hXitW8ze4YwOCqxJiVuqoOlyUa3QvI5MmTfDVqDy/RskFt
1kJu1BgzFcEek4YXFnDIGNMKmXcDNGKZJDYOLZJYNBFBCat5O9MVijdhZTR4T/3d
aRjCkFPVRDMKLvNcHMfQXwJXdeIFBx2TH8GyU/H34y+zsjN3kfbh0OTmuxRZVPkk
n/5ruRECgYEA+DL19XhBxT9nvMxtAAxbpuzI42g0/fBcs/1S6Myj8LCeYKBXlFFP
F6uwcB823A98fsq1RK8bozLEDQbs4kodCU+3jd2Mx0YBhRPMZW/tlUeKi5aTJlN6
Mt70IfpEaROHDUYqR6zohpJpHj3tozpdwDF1/uGUMOGtWteQy/PuJpECgYEA7taZ
j7YKkm4trSvMvbA001lITZ5CGvpUWZRtufxuRDDYl85cBfQ26VUKRMMHmmqcPVf8
5YrdlnFkr6voYbiYGkAFGMjkitLnEc7VMFr5Sg8GRL9FnDW97DI2VJnHE48EFtk7
/ejXjnqHNGGOkaKkVdGxJqPX5U5ueb2Dtb10kKkCgYEAiLZxWqPB/qc9OfaUd7lW
5qx4vyJQRiwWtCHugELwboyqwGixtQXQfiZZCnl3G2IAXkrD7DBUFeHJsa9F3iOa
uN1LKv6FI+LAxY+xP5KWmGqOuvLW3P6QSeMbMHgNJJ/X/QzQDykD79RHyJuuAQIO
T+Yuq5WPrhkxBt/EZ0NWw7ECgYBmkr+smq/7p1nyj2cE6FInmqaUvy0AzRXAyyA8
yg7JNnku6S9YV0Pl/eHFGkV/qd2j8s/n/TWhUN2/HINWxKJ+U5RcyppsjJs0aLHi
bI+3oLA+gi7xIZuJfx8aQljfK4LEFVPQflllFXZPpr5GCaWuPbppL+Ce2IpVunCA
cvdG0QKBgAe4rs2ZDzaCSyCHi/1s2ilAblkw8IFioAHb4peHt9q3l1KbjVsdGltw
dtN9dMyIrwNyX9ysX8rBO535juy3IKjmKQX2v6adp6Fhir8WveXtKsmuiexwaddX
kqc72GQ914xgAT5JxKU1tqWkATk80SCnpTQHmZ6OkUJJ7SJ4Tzxv
-----END RSA PRIVATE KEY-----
''';

const rsaPkcs8 = '''
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDnj3AlmvVAK1Kc
TkplopNV2A01xH04iFJbYmrnnSvB5CKr8L0qeSQQOomhX8HPgmG/JIbSSOPWoc+D
vbKgK1iVjTuWBzi1u+4tpY7Qkk0tZFeL5KXyFTyU8KI5jEjc5vp6jQ7ZtlkW5ARi
GCaUK/1aEROWttS4B64ruQ9V/8iviBoLG8VTo5t9GgCMWrhtF4Mg75eA15NS5nth
GOeMbahf3c+0E3s3UMKGaSDzPJuAgntI2mLrdhVs0Sj59s3gBMF/vimFwNNI5M5u
E733XazqHCXsMlE6tkhkeJBIGShKvj6W93Mj9RKjUXnvj7HiBGGihENiDv7zf8Bt
IcGEnQW5AgMBAAECggEAAqDejmNDv9Q0mxZM0qLx/+THlyb08N7p5WdEXhYw0lwE
dzuwpdDl5+KpTpziFgpB12TC2YKAdO0bYoZDrL0A2uug+DCXosFGSSphIwQ8ejBG
+EGM2syi43B/8UPOXrH+W22k5aJPgN2MMg2Ipe8fHt1zu+m67z1riFeK1bzN7hjA
4KrEmJW6qg6XJRrdC8jkyZN8NWoPL9GyQW3WQm7UGDMVwR6ThhcWcMgY0wqZdwM0
YpkkNg4tklg0EUEJq3k70xWKN2FlNHhP/d1pGMKQU9VEMwou81wcx9BfAld14gUH
HZMfwbJT8ffjL7OyM3eR9uHQ5Oa7FFlU+SSf/mu5EQKBgQD4MvX1eEHFP2e8zG0A
DFum7MjjaDT98Fyz/VLozKPwsJ5goFeUUU8Xq7BwHzbcD3x+yrVErxujMsQNBuzi
Sh0JT7eN3YzHRgGFE8xlb+2VR4qLlpMmU3oy3vQh+kRpE4cNRipHrOiGkmkePe2j
Ol3AMXX+4ZQw4a1a15DL8+4mkQKBgQDu1pmPtgqSbi2tK8y9sDTTWUhNnkIa+lRZ
lG25/G5EMNiXzlwF9DbpVQpEwweaapw9V/zlit2WcWSvq+hhuJgaQAUYyOSK0ucR
ztUwWvlKDwZEv0WcNb3sMjZUmccTjwQW2Tv96NeOeoc0YY6RoqRV0bEmo9flTm55
vYO1vXSQqQKBgQCItnFao8H+pz059pR3uVbmrHi/IlBGLBa0Ie6AQvBujKrAaLG1
BdB+JlkKeXcbYgBeSsPsMFQV4cmxr0XeI5q43Usq/oUj4sDFj7E/kpaYao668tbc
/pBJ4xsweA0kn9f9DNAPKQPv1EfIm64BAg5P5i6rlY+uGTEG38RnQ1bDsQKBgGaS
v6yar/unWfKPZwToUieappS/LQDNFcDLIDzKDsk2eS7pL1hXQ+X94cUaRX+p3aPy
z+f9NaFQ3b8cg1bEon5TlFzKmmyMmzRoseJsj7egsD6CLvEhm4l/HxpCWN8rgsQV
U9B+WWUVdk+mvkYJpa49umkv4J7YilW6cIBy90bRAoGAB7iuzZkPNoJLIIeL/Wza
KUBuWTDwgWKgAdvil4e32reXUpuNWx0aW3B20310zIivA3Jf3KxfysE7nfmO7Lcg
qOYpBfa/pp2noWGKvxa95e0qya6J7HBp11eSpzvYZD3XjGABPknEpTW2paQBOTzR
IKelNAeZno6RQkntInhPPG8=
-----END PRIVATE KEY-----
''';

const p256Sec1 = '''
-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIDA2jI/bfbNzRcjyTep40ZLlvl3L0je9133qgssODMlmoAoGCCqGSM49
AwEHoUQDQgAEPEFmKd+afUv69D7TKP0vUdhr8sKoUQwNic9HEUepz4mka5PUft+i
Gh8cAzyaFnCbYPEy+06T9iwuFYVZIm1eTg==
-----END EC PRIVATE KEY-----
''';

const p256Pkcs8 = '''
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgMDaMj9t9s3NFyPJN
6njRkuW+XcvSN73XfeqCyw4MyWahRANCAAQ8QWYp35p9S/r0PtMo/S9R2GvywqhR
DA2Jz0cRR6nPiaRrk9R+36IaHxwDPJoWcJtg8TL7TpP2LC4VhVkibV5O
-----END PRIVATE KEY-----
''';

const p384Sec1 = '''
-----BEGIN EC PRIVATE KEY-----
MIGkAgEBBDAFHYSz0DzJKgnkRIBrjcfo9xIcWqhPnO+izBcdWcdDelJdcOXwTu9a
O7hsZYvN9Q2gBwYFK4EEACKhZANiAASIahdynounV9DPKPPJURdVxWtRYPGVTGQ9
PQSDAraIWZ10sOCdNN3y+SYozDLmE+kLkcxuVtQzQIyPYgzv/AMFz7cZXLku3OrL
0Cg70PuDC4DwHFMqH1fageoGPyDXVqA=
-----END EC PRIVATE KEY-----
''';

const p521Pkcs8 = '''
-----BEGIN PRIVATE KEY-----
MIHuAgEAMBAGByqGSM49AgEGBSuBBAAjBIHWMIHTAgEBBEIAB0+yIbh/A1hPPbon
jUuYqNqKI1v9Vkz0dWM1ugZQ+IyAUmCXrwHNHYQyJn3IoScSGCzSbaLkNWAySo58
VdpRkyGhgYkDgYYABABoL5xF4H4C4M98OUqLsQit8GTLfN4zKdolZkgqKKe3uqsm
afEWEgBefoxKAISXIp/3q9csVQupsoiqlttt569uhwHr2wqeiC+d49uS2ESvfhR8
pATDAVl921CLsq5pN+6G3it9dkkck4cQCfeO2YIobnqO2rHEHpe1r9CyCJcOJhPr
cw==
-----END PRIVATE KEY-----
''';
const _payload = '{"sub":"1234567890","name":"John Doe","iat":1516239022}';

Uint8List _b64url(String s) =>
    base64Url.decode(s.padRight((s.length + 3) ~/ 4 * 4, '='));

({String input, Uint8List sig, Map<String, dynamic> header}) _split(
  String jwt,
) {
  final parts = jwt.split('.');
  expect(parts, hasLength(3));
  return (
    input: '${parts[0]}.${parts[1]}',
    sig: _b64url(parts[2]),
    header: jsonDecode(utf8.decode(_b64url(parts[0]))) as Map<String, dynamic>,
  );
}

Digest _digest(int bits) => switch (bits) {
  256 => SHA256Digest(),
  384 => SHA384Digest(),
  _ => SHA512Digest(),
};

const _oids = {
  256: '0609608648016503040201',
  384: '0609608648016503040202',
  512: '0609608648016503040203',
};

void main() {
  group('HMAC', () {
    test('jwt.io HS256 example', () {
      expect(
        JwtAuth.build(
          algorithm: 'HS256',
          secret: 'your-256-bit-secret',
          payload: _payload,
        ),
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmF'
        'tZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf'
        '36POk6yJV_adQssw5c',
      );
    });

    test('HS384 and HS512', () {
      expect(
        JwtAuth.build(
          algorithm: 'HS384',
          secret: 'your-256-bit-secret',
          payload: _payload,
        ).split('.').last,
        'RGFdh_VuEuURSubru7xP4rbaA4boUyueI7rEm75l1cNdE9gQ7H6mx2DYpauBjX5S',
      );
      expect(
        JwtAuth.build(
          algorithm: 'HS512',
          secret: 'your-256-bit-secret',
          payload: _payload,
        ).split('.').last,
        'pazba9Pj009HgANP4pTCQAHpXNU7pVbjIGff_plktSzsa9rXTGzFngaawzXGEO6Q0Hx5d'
        'tGi-dMDlIadV81o3Q',
      );
    });

    test('base64 secret and extra header fields', () {
      expect(
        JwtAuth.build(
          algorithm: 'HS256',
          secret: 'c2VjcmV0IGJ5dGVz',
          secretBase64: true,
          payload: _payload,
          header: '{"kid": "k1", "alg": "none"}',
        ),
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6ImsxIn0.eyJzdWIiOiIxMjM0N'
        'TY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.Q_NbXs-Afoc'
        '6zcvO7xT2ovZkmPFjnVwsq58mbjDmA88',
      );
    });

    test('bad JSON is explained', () {
      expect(
        () => JwtAuth.build(algorithm: 'HS256', secret: 's', payload: '{oops'),
        throwsA(
          isA<AuthException>().having(
            (e) => e.message,
            'message',
            contains('payload is not valid JSON'),
          ),
        ),
      );
      expect(
        () => JwtAuth.build(algorithm: 'HS256', secret: 's', payload: '[1]'),
        throwsA(isA<AuthException>()),
      );
    });
  });

  group('PEM keys', () {
    test('PKCS#1 and PKCS#8 RSA keys are the same key', () {
      final a = PemPrivateKey.parse(rsaPkcs1) as RsaPemKey;
      final b = PemPrivateKey.parse(rsaPkcs8) as RsaPemKey;
      expect(a.key.modulus, b.key.modulus);
      expect(a.publicExponent, BigInt.from(65537));
      expect(a.key.modulus!.bitLength, 2048);
    });

    test('SEC1 and PKCS#8 EC keys name their curve', () {
      final a = PemPrivateKey.parse(p256Sec1) as EcPemKey;
      final b = PemPrivateKey.parse(p256Pkcs8) as EcPemKey;
      expect(a.curve, 'P-256');
      expect(b.key.d, a.key.d);
      expect((PemPrivateKey.parse(p384Sec1) as EcPemKey).curve, 'P-384');
      expect((PemPrivateKey.parse(p521Pkcs8) as EcPemKey).curve, 'P-521');
    });

    test('keys pasted on one line or with literal \\n still parse', () {
      final oneLine = rsaPkcs8.replaceAll('\n', r'\n');
      expect(PemPrivateKey.parse(oneLine), isA<RsaPemKey>());
      final noBreaks = p256Sec1.replaceAll('\n', '');
      expect(PemPrivateKey.parse(noBreaks), isA<EcPemKey>());
    });

    test('encrypted and broken keys get a reason', () {
      expect(
        () => PemPrivateKey.parse(
          '-----BEGIN ENCRYPTED PRIVATE KEY-----\nMIIB\n'
          '-----END ENCRYPTED PRIVATE KEY-----',
        ),
        throwsA(
          isA<AuthException>().having(
            (e) => e.message,
            'message',
            contains('encrypted'),
          ),
        ),
      );
      expect(
        () => PemPrivateKey.parse(
          '-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----',
        ),
        throwsA(isA<AuthException>()),
      );
    });
  });

  group('RSA', () {
    test('RS256 matches OpenSSL (PKCS#1 v1.5 is deterministic)', () {
      const want =
          'YCAH8j7xG0pYFoIEGmgJ-9qxKZWGsXc-I7FGtJ54YNAt-Nd8ogRoqmZgGDAFqFMuGrDG1'
          'qWIM4q9lgT9ZjwJIMUTj8qLnermYq2odT0UTPdR7rG9ge7SfHYhFyku-KlBnD4mLk1ntc'
          'RgnVqffs8txfsAs2p1yP_dbA6qRVGiv0T7Fdmof6AFY_s5Cfhrg_FHSw_xSNS2FUENuNe'
          'de3MFaUbsXWGAvjl9buah4fXGJrXAt-R1QP7pazAgNxlocoaUxXdRHWbehJ25BPZ0N1g7'
          'lydSny1-L_DSL47gx1CSm9CJ3P8nmE7kg0DOrWHdtjP7goNNuEXeh5w-K11EtigunA';
      for (final key in [rsaPkcs1, rsaPkcs8]) {
        final jwt = JwtAuth.build(
          algorithm: 'RS256',
          privateKey: key,
          payload: _payload,
        );
        expect(jwt.split('.').last, want);
      }
    });

    for (final bits in [256, 384, 512]) {
      test('RS$bits verifies with pointycastle', () {
        final k = PemPrivateKey.parse(rsaPkcs8) as RsaPemKey;
        final t = _split(
          JwtAuth.build(
            algorithm: 'RS$bits',
            privateKey: rsaPkcs8,
            payload: _payload,
          ),
        );
        expect(t.header['alg'], 'RS$bits');
        final v = RSASigner(_digest(bits), _oids[bits]!)
          ..init(false, PublicKeyParameter<RSAPublicKey>(k.publicKey));
        expect(
          v.verifySignature(
            Uint8List.fromList(utf8.encode(t.input)),
            RSASignature(t.sig),
          ),
          isTrue,
        );
      });

      test('PS$bits verifies with pointycastle', () {
        final k = PemPrivateKey.parse(rsaPkcs1) as RsaPemKey;
        final t = _split(
          JwtAuth.build(
            algorithm: 'PS$bits',
            privateKey: rsaPkcs1,
            payload: _payload,
          ),
        );
        final v = PSSSigner(RSAEngine(), _digest(bits), _digest(bits))
          ..init(
            false,
            ParametersWithSaltConfiguration(
              PublicKeyParameter<RSAPublicKey>(k.publicKey),
              secureRandom(),
              bits ~/ 8,
            ),
          );
        expect(
          v.verifySignature(
            Uint8List.fromList(utf8.encode(t.input)),
            PSSSignature(t.sig),
          ),
          isTrue,
        );
      });
    }

    test('OAuth 1.0 RSA-SHA1 matches OpenSSL', () {
      final p = PreparedRequest(
        method: 'GET',
        url: Uri.parse(
          'http://photos.example.net/photos?file=vacation.jpg&size=original',
        ),
      );
      OAuth1Auth.sign(
        p,
        consumerKey: 'dpf43f3p2l4k3l03',
        signatureMethod: 'RSA-SHA1',
        timestamp: '1196666512',
        nonce: '13917289812797014437',
        privateKey: rsaPkcs1,
        now: DateTime.utc(2020),
      );
      final h = p.headers.value('authorization')!;
      final sig = Uri.decodeComponent(
        RegExp(r'oauth_signature="([^"]+)"').firstMatch(h)!.group(1)!,
      );
      expect(
        sig,
        '3hKO6RFmsjNIGIl3puQhT5ad76hwlAm3gofHWVm9D/PS1mCSyht2jkmS4eMI0JLGGCk'
        'PjTLYHG/aEfHfQ+KrTEVl1/yLw/PzK1oD0UjRpHLivWYlqx7Np6b96qM5oIp8FU7VPz'
        'BwAaeI5kLHdmKTC04TPEChttKHTx7ycWMrUTQZdPUn5xY4eVMTVjF/VjSl1q8TY70OT'
        'OaIvwBpCYccik/SSLLDOUzqf4WcyG+IVB1iOxqPe59fB43UU4luxeerW+hiap016Ual'
        'ch4Njqmn1iYrxHC2gQhITVZKRR/jvgV0OtrLiNvNhYgF+OlDAmP4e9iXJoNX4qoQRWD'
        'RhUWcvA==',
      );
    });
  });

  group('ECDSA', () {
    test('RFC 6979 §A.2.5 deterministic P-256 / SHA-256 vector', () {
      final d = BigInt.parse(
        'C9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721',
        radix: 16,
      );
      final sig = ecdsaSign(
        ECPrivateKey(d, ECCurve_secp256r1()),
        256,
        utf8.encode('sample'),
      );
      expect(
        hexOf(sig),
        'efd48b2aacb6a8fd1140dd9cd45e81d69d2c877b56aaf991c34d0ea84eaf3716'
        'f7cb1c942d657c41d436c7a1b6e29f65f3e900dbb9aff4064dc4ab2f843acda8',
      );
    });

    for (final (alg, key, format, size) in [
      ('ES256', p256Sec1, 'SEC1', 64),
      ('ES256', p256Pkcs8, 'PKCS#8', 64),
      ('ES384', p384Sec1, 'SEC1', 96),
      ('ES512', p521Pkcs8, 'PKCS#8', 132),
    ]) {
      test('$alg with a $format key verifies with pointycastle', () {
        final k = PemPrivateKey.parse(key) as EcPemKey;
        final t = _split(
          JwtAuth.build(algorithm: alg, privateKey: key, payload: _payload),
        );
        expect(t.sig, hasLength(size));
        final half = size ~/ 2;
        BigInt num(List<int> b) =>
            b.fold(BigInt.zero, (a, x) => (a << 8) | BigInt.from(x));
        final bits = int.parse(alg.substring(2));
        final v = ECDSASigner(_digest(bits))
          ..init(false, PublicKeyParameter<ECPublicKey>(k.publicKey));
        expect(
          v.verifySignature(
            Uint8List.fromList(utf8.encode(t.input)),
            ECSignature(num(t.sig.sublist(0, half)), num(t.sig.sublist(half))),
          ),
          isTrue,
        );
      });
    }

    test('a key for the wrong curve or type is refused', () {
      expect(
        () => JwtAuth.build(algorithm: 'ES384', privateKey: p256Sec1),
        throwsA(
          isA<AuthException>().having(
            (e) => e.message,
            'message',
            contains('P-384'),
          ),
        ),
      );
      expect(
        () => JwtAuth.build(algorithm: 'RS256', privateKey: p256Sec1),
        throwsA(isA<AuthException>()),
      );
      expect(
        () => JwtAuth.build(algorithm: 'ES256', privateKey: rsaPkcs1),
        throwsA(isA<AuthException>()),
      );
    });
  });

  group('applyAuth', () {
    test('header with prefix, variables in the payload', () async {
      final p = PreparedRequest(method: 'GET', url: Uri.parse('https://h/x'));
      await applyAuth(
        p,
        AuthConfig(
          type: AuthType.jwt,
          params: {
            'algorithm': 'HS256',
            'secret': '{{secret}}',
            'payload': '{"sub":"{{user}}"}',
            'addTokenTo': 'header',
            'headerPrefix': 'JWT',
          },
        ),
        AuthContext(vars: {'secret': 's3', 'user': 'ada'}),
      );
      final h = p.headers.value('authorization')!;
      expect(h, startsWith('JWT ey'));
      final payload = utf8.decode(_b64url(h.split('.')[1]));
      expect(payload, '{"sub":"ada"}');
    });

    test('query param', () async {
      final p = PreparedRequest(
        method: 'GET',
        url: Uri.parse('https://h/x?a=1'),
      );
      await applyAuth(
        p,
        AuthConfig(
          type: AuthType.jwt,
          params: {
            'algorithm': 'HS512',
            'secret': 's',
            'addTokenTo': 'queryParam',
            'queryParamKey': 'jwt',
          },
        ),
        AuthContext(),
      );
      expect(p.headers.has('authorization'), isFalse);
      expect(p.url.queryParameters['a'], '1');
      expect(p.url.queryParameters['jwt']!.split('.'), hasLength(3));
    });
  });
}
