import 'dart:convert';
import 'dart:typed_data';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/auth/auth.dart';
import 'package:api_workbench/services/auth/auth_util.dart';
import 'package:api_workbench/services/request_builder.dart';
import 'package:flutter_test/flutter_test.dart';

String hex(List<int> b) => hexOf(b);

void main() {
  group('MD4 (RFC 1320 appendix A.5)', () {
    const vectors = {
      '': '31d6cfe0d16ae931b73c59d7e0c089c0',
      'a': 'bde52cb31de33e46245e05fbdbd6fb24',
      'abc': 'a448017aaf21d8525fc10ae87aa6729d',
      'message digest': 'd9130a8164549fe818874806e1c7014b',
      'abcdefghijklmnopqrstuvwxyz': 'd79e1c308aa5bbcdeea8ed63df412da9',
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789':
          '043f8582f241db351ce627e153e7f0e4',
      '1234567890123456789012345678901234567890'
              '1234567890123456789012345678901234567890':
          'e33b4ddc9c38f2199c3e7b164fcc0536',
    };
    vectors.forEach((input, want) {
      test('"$input"', () => expect(hex(md4(utf8.encode(input))), want));
    });
  });

  group('Digest (RFC 7616 §3.9.1)', () {
    const nonce = '7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v';
    const cnonce = 'f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ';
    String response(String algorithm) => DigestAuth.response(
      method: 'GET',
      uri: '/dir/index.html',
      username: 'Mufasa',
      password: 'Circle of Life',
      realm: 'http-auth@example.org',
      nonce: nonce,
      algorithm: algorithm,
      qop: 'auth',
      nc: '00000001',
      cnonce: cnonce,
    );

    test('SHA-256', () {
      expect(
        response('SHA-256'),
        '753927fa0e85d155564e2e272a28d1802ca10daf4496794697cf8db5856cb6c1',
      );
    });

    test('MD5', () {
      expect(response('MD5'), '8ca523f5e9506fed4657c9700eebdbec');
    });

    test('RFC 2617 §3.5 example', () {
      expect(
        DigestAuth.response(
          method: 'GET',
          uri: '/dir/index.html',
          username: 'Mufasa',
          password: 'Circle Of Life',
          realm: 'testrealm@host.com',
          nonce: 'dcd98b7102dd2f0e8b11d0f600bfb0c093',
          qop: 'auth',
          nc: '00000001',
          cnonce: '0a4f113b',
        ),
        '6629fae49393a05397450978507c4ef1',
      );
    });

    test('-sess and auth-int change the response', () {
      final base = response('SHA-256');
      expect(response('SHA-256-sess'), isNot(base));
      expect(response('MD5-sess'), isNot(response('MD5')));
      final intA = DigestAuth.response(
        method: 'POST',
        uri: '/',
        username: 'u',
        password: 'p',
        realm: 'r',
        nonce: 'n',
        qop: 'auth-int',
        cnonce: 'c',
        body: utf8.encode('a'),
      );
      final intB = DigestAuth.response(
        method: 'POST',
        uri: '/',
        username: 'u',
        password: 'p',
        realm: 'r',
        nonce: 'n',
        qop: 'auth-int',
        cnonce: 'c',
        body: utf8.encode('b'),
      );
      expect(intA, isNot(intB));
    });

    test('answers the challenge, picking the configured algorithm', () async {
      final auth = AuthConfig(
        type: AuthType.digest,
        params: {
          'username': 'Mufasa',
          'password': 'Circle of Life',
          'algorithm': 'SHA-256',
          'clientNonce': cnonce,
        },
      );
      final sent = PreparedRequest(
        method: 'GET',
        url: Uri.parse('http://www.example.org/dir/index.html'),
      );
      final res = ResponseData(
        statusCode: 401,
        headers: {
          'www-authenticate': [
            'Digest realm="http-auth@example.org", qop="auth, auth-int", '
                'algorithm=SHA-256, nonce="$nonce", '
                'opaque="FQhe/qaU925kfnzjCev0ciny7QMkPqMAFRtzCUYo5tdS"',
            'Digest realm="http-auth@example.org", qop="auth, auth-int", '
                'algorithm=MD5, nonce="$nonce", '
                'opaque="FQhe/qaU925kfnzjCev0ciny7QMkPqMAFRtzCUYo5tdS"',
          ],
        },
      );
      final retry = await retryAfterChallenge(sent, res, auth, AuthContext());
      final h = retry!.headers.value('authorization')!;
      expect(h, startsWith('Digest '));
      expect(
        h,
        contains(
          'response="753927fa0e85d155564e2e272a28d1802ca10daf4496794697cf8db5856cb6c1"',
        ),
      );
      expect(h, contains('qop=auth, nc=00000001'));
      expect(
        h,
        contains('opaque="FQhe/qaU925kfnzjCev0ciny7QMkPqMAFRtzCUYo5tdS"'),
      );
      expect(sent.headers.has('authorization'), isFalse);
    });

    test('disableRetryRequest keeps the 401', () async {
      final auth = AuthConfig(
        type: AuthType.digest,
        params: {'username': 'u', 'disableRetryRequest': 'true'},
      );
      final res = ResponseData(
        statusCode: 401,
        headers: {
          'WWW-Authenticate': ['Digest realm="r", nonce="n"'],
        },
      );
      expect(
        await retryAfterChallenge(
          PreparedRequest(method: 'GET', url: Uri.parse('http://h/')),
          res,
          auth,
          AuthContext(),
        ),
        isNull,
      );
    });

    test('preset realm and nonce sign the first request', () async {
      final auth = AuthConfig(
        type: AuthType.digest,
        params: {
          'username': 'Mufasa',
          'password': 'Circle of Life',
          'realm': 'http-auth@example.org',
          'nonce': nonce,
          'algorithm': 'MD5',
          'qop': 'auth',
          'nonceCount': '00000001',
          'clientNonce': cnonce,
        },
      );
      final p = PreparedRequest(
        method: 'GET',
        url: Uri.parse('http://www.example.org/dir/index.html'),
      );
      await applyAuth(p, auth, AuthContext());
      expect(
        p.headers.value('authorization'),
        contains('response="8ca523f5e9506fed4657c9700eebdbec"'),
      );
    });
  });

  group('WWW-Authenticate parsing', () {
    test('several challenges in one value', () {
      final c = parseChallenges([
        'Basic realm="simple", Digest realm="x, y", nonce="n=1", '
            'qop="auth,auth-int", algorithm=MD5, NTLM, Negotiate abc+/==',
      ]);
      expect(
        [for (final x in c) x.scheme],
        ['Basic', 'Digest', 'NTLM', 'Negotiate'],
      );
      expect(c[1].params['realm'], 'x, y');
      expect(c[1].params['nonce'], 'n=1');
      expect(c[1].params['algorithm'], 'MD5');
      expect(c[3].token68, 'abc+/==');
    });

    test('an NTLM challenge blob', () {
      final c = parseChallenges(['NTLM TlRMTVNTUAACAAAADAAMADgAAAA=']).single;
      expect(c.token68, 'TlRMTVNTUAACAAAADAAMADgAAAA=');
    });
  });

  group('NTLMv2 (MS-NLMP §4.2.4)', () {
    final serverChallenge = hexBytes('0123456789abcdef');
    final clientChallenge = hexBytes('aaaaaaaaaaaaaaaa');
    // MsvAvNbDomainName "Domain", MsvAvNbComputerName "Server", MsvAvEOL.
    final targetInfo = hexBytes(
      '02000c0044006f006d00610069006e00'
      '01000c00530065007200760065007200'
      '00000000',
    );

    test('NTOWFv2', () {
      expect(
        hex(NtlmAuth.ntowfv2('Password', 'User', 'Domain')),
        '0c868a403bfd7a93a3001ef22ef02e3f',
      );
    });

    test('NTProofStr, LMv2 response and session base key', () {
      final r = NtlmAuth.responses(
        responseKey: NtlmAuth.ntowfv2('Password', 'User', 'Domain'),
        serverChallenge: serverChallenge,
        clientChallenge: clientChallenge,
        timestamp: Uint8List(8),
        targetInfo: targetInfo,
      );
      expect(hex(r.ntProofStr), '68cd0ab851e51c96aabc927bebef6a1c');
      expect(
        hex(r.lmResponse),
        '86c35097ac9cec102554764a57cccc19aaaaaaaaaaaaaaaa',
      );
      expect(hex(r.sessionBaseKey), '8de40ccadbc14a82f15cb0ad0de95ca3');
      // temp: header, time, client challenge, AV pairs, padding.
      expect(
        hex(r.ntResponse.sublist(16)),
        '0101000000000000'
        '0000000000000000'
        'aaaaaaaaaaaaaaaa'
        '00000000'
        '${hex(targetInfo)}'
        '00000000',
      );
    });

    test('parses the §4.2.4.3 CHALLENGE_MESSAGE', () {
      final msg = hexBytes(
        '4e544c4d53535000020000000c000c003800000033828ae2'
        '0123456789abcdef0000000000000000240024004400000006007017'
        '0000000f530065007200760065007200${hex(targetInfo)}',
      );
      final c = NtlmChallenge.parse(msg);
      expect(c.flags, 0xe28a8233);
      expect(hex(c.serverChallenge), '0123456789abcdef');
      expect(c.targetName, 'Server');
      expect(hex(c.targetInfo), hex(targetInfo));
      expect(c.avPairs[2], NtlmAuth.utf16le('Domain'));
      expect(c.avPairs[1], NtlmAuth.utf16le('Server'));
    });

    test(
      'NEGOTIATE then AUTHENTICATE through applyAuth and the retry',
      () async {
        final auth = AuthConfig(
          type: AuthType.ntlm,
          params: {
            'username': r'Domain\User',
            'password': 'Password',
            'workstation': 'COMPUTER',
          },
        );
        final p = PreparedRequest(method: 'GET', url: Uri.parse('http://h/'));
        final ctx = AuthContext();
        await applyAuth(p, auth, ctx);
        final type1 = base64.decode(
          p.headers.value('authorization')!.substring(5),
        );
        expect(utf8.decode(type1.sublist(0, 7)), 'NTLMSSP');
        expect(type1[8], 1);

        final challenge = hexBytes(
          '4e544c4d53535000020000000c000c003800000033828ae2'
          '0123456789abcdef0000000000000000240024004400000006007017'
          '0000000f530065007200760065007200${hex(targetInfo)}',
        );
        final res = ResponseData(
          statusCode: 401,
          headers: {
            'www-authenticate': ['NTLM ${base64.encode(challenge)}'],
          },
        );
        final retry = (await retryAfterChallenge(p, res, auth, ctx))!;
        final type3 = base64.decode(
          retry.headers.value('authorization')!.substring(5),
        );
        expect(type3[8], 3);
        Uint8List field(int at) {
          final len = type3[at] | type3[at + 1] << 8;
          final off =
              type3[at + 4] |
              type3[at + 5] << 8 |
              type3[at + 6] << 16 |
              type3[at + 7] << 24;
          return Uint8List.sublistView(type3, off, off + len);
        }

        expect(field(28), NtlmAuth.utf16le('Domain'));
        expect(field(36), NtlmAuth.utf16le('User'));
        expect(field(44), NtlmAuth.utf16le('COMPUTER'));
        // The server can check the proof with the password it knows.
        final nt = field(20);
        final temp = nt.sublist(16);
        final r = NtlmAuth.responses(
          responseKey: NtlmAuth.ntowfv2('Password', 'User', 'Domain'),
          serverChallenge: serverChallenge,
          clientChallenge: temp.sublist(16, 24),
          timestamp: temp.sublist(8, 16),
          targetInfo: targetInfo,
        );
        expect(nt.sublist(0, 16), r.ntProofStr);
      },
    );

    test('nothing is added for code snippets', () async {
      final p = PreparedRequest(method: 'GET', url: Uri.parse('http://h/'));
      await applyAuth(
        p,
        AuthConfig(type: AuthType.ntlm, params: {'username': 'u'}),
        AuthContext(offline: true),
      );
      expect(p.headers.has('authorization'), isFalse);
    });
  });
}
