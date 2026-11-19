import 'dart:convert';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/redact.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const mask = redactMask;
  final plain = Redactor.standard;

  group('query parameters', () {
    const names = [
      'api_key',
      'apikey',
      'apiKey',
      'api-key',
      'API_KEY',
      'access_token',
      'token',
      'id_token',
      'refresh_token',
      'client_secret',
      'password',
      'sig',
      'signature',
      'Signature',
      'X-Amz-Signature',
      'X-Amz-Credential',
      'X-Amz-Security-Token',
      'X-Goog-Signature',
      'oauth_signature',
      'oauth_token',
    ];

    for (final name in names) {
      test('$name is masked', () {
        expect(
          plain.url('https://api.example.com/v1/items?$name=abc123&page=2'),
          'https://api.example.com/v1/items?$name=$mask&page=2',
        );
      });
    }

    test('an encoded parameter name is still recognised', () {
      expect(
        plain.url('https://x.test/a?access%5Ftoken=abc&b=1'),
        'https://x.test/a?access%5Ftoken=$mask&b=1',
      );
    });

    test('only the credential parameters change', () {
      const url =
          'https://api.example.com/v1/items?page=2&limit=50&sort=name'
          '&q=token+ring&keyword=abc&next_token=zzz&pageToken=yyy'
          '&tokens=1&filter[key]=v&key=plain';
      expect(plain.url(url), url);
    });

    test('a fragment, as in an implicit OAuth redirect, is masked', () {
      expect(
        plain.url('https://app.test/cb#access_token=abc&token_type=bearer'),
        'https://app.test/cb#access_token=$mask&token_type=bearer',
      );
    });

    test('a URL without a query passes through', () {
      expect(plain.url('https://x.test/a/b'), 'https://x.test/a/b');
      expect(plain.url(''), '');
      expect(plain.url('/relative?token=abc'), '/relative?token=$mask');
    });

    test('empty values and template references are left alone', () {
      expect(
        plain.url('{{base}}/x?api_key={{apiKey}}&token='),
        '{{base}}/x?api_key={{apiKey}}&token=',
      );
      expect(
        plain.url('{{base}}/x?api_key=lit{{apiKey}}'),
        '{{base}}/x?api_key=$mask',
      );
    });

    test('credentials in the user-info part are masked', () {
      expect(
        plain.url('https://alice:hunter2@host.test/x'),
        'https://alice:$mask@host.test/x',
      );
      expect(
        plain.url('https://ghp_abcdef123456@host.test/x'),
        'https://$mask@host.test/x',
      );
      expect(plain.url('https://host.test/a@b'), 'https://host.test/a@b');
    });

    test('masking twice changes nothing more', () {
      final once = plain.url('https://x.test/?token=abc&sig=def');
      expect(plain.url(once), once);
    });
  });

  group('the auth helper\'s own names', () {
    test('a bare key is ordinary until the API Key helper uses that name', () {
      const url = 'https://maps.test/geocode?key=AIza123&page=2';
      expect(plain.url(url), url);

      final auth = AuthConfig(
        type: AuthType.apiKey,
        apiKeyName: 'key',
        apiKeyValue: 'AIza123',
        apiKeyInHeader: false,
      );
      expect(
        plain.withAuth(auth).url(url),
        'https://maps.test/geocode?key=$mask&page=2',
      );
    });

    test('any chosen parameter name is masked', () {
      final auth = AuthConfig(
        type: AuthType.apiKey,
        apiKeyName: 'My_Custom-Auth',
        apiKeyInHeader: false,
      );
      expect(
        plain.withAuth(auth).url('https://x.test/?my-custom-auth=v&a=b'),
        'https://x.test/?my-custom-auth=$mask&a=b',
      );
    });

    test('a name built from a variable is resolved', () {
      final auth = AuthConfig(
        type: AuthType.apiKey,
        apiKeyName: '{{keyParam}}',
        apiKeyInHeader: false,
      );
      expect(
        plain.withAuth(auth, {'keyParam': 'k'}).url('https://x.test/?k=v'),
        'https://x.test/?k=$mask',
      );
    });

    test('a header API key does not mask a query parameter', () {
      final auth = AuthConfig(
        type: AuthType.apiKey,
        apiKeyName: 'X-Tenant-Auth',
        apiKeyInHeader: true,
      );
      final r = plain.withAuth(auth);
      expect(
        r.url('https://x.test/?x-tenant-auth=v'),
        'https://x.test/?x-tenant-auth=v',
      );
      expect(r.headerValue('X-Tenant-Auth', 'v1'), mask);
      expect(plain.headerValue('X-Tenant-Auth', 'v1'), 'v1');
    });

    test('the JWT helper\'s query parameter is masked', () {
      final auth = AuthConfig(
        type: AuthType.jwt,
        params: {'addTokenTo': 'queryParam', 'queryParamKey': 'jwt_param'},
      );
      expect(
        plain.withAuth(auth).url('https://x.test/?jwt_param=e30.e30.sig'),
        'https://x.test/?jwt_param=$mask',
      );
    });
  });

  group('secret variable values', () {
    test('plain, URL-encoded and JSON-escaped forms are masked', () {
      const secret = 'p@ss w/rd!&=\'"';
      final r = Redactor(secrets: {secret});
      final forms = [
        secret,
        Uri.encodeComponent(secret),
        Uri.encodeQueryComponent(secret),
        Uri.encodeComponent(secret).toLowerCase(),
        Uri.encodeFull(secret),
        jsonEncode(secret).replaceAll(RegExp(r'^"|"$'), ''),
      ];
      for (final f in forms) {
        expect(r.text('before $f after'), 'before $mask after', reason: f);
        expect(r.url('https://x.test/$f?a=$f'), 'https://x.test/$mask?a=$mask');
      }
    });

    test('strict RFC 3986 encoding of ! \' ( ) * is covered', () {
      const secret = "a!b'c(d)e*fgh";
      final r = Redactor(secrets: {secret});
      expect(r.text('x=a%21b%27c%28d%29e%2Afgh'), 'x=$mask');
    });

    test('base64 of the value is masked', () {
      const secret = 'hunter2-secret';
      final b64 = base64.encode(utf8.encode(secret));
      expect(Redactor(secrets: {secret}).text('v=$b64.'), 'v=$mask.');
    });

    test('values under four characters are left alone', () {
      expect(Redactor(secrets: {'abc'}).text('abc abcd'), 'abc abcd');
    });

    test('the longer value wins when one contains another', () {
      final r = Redactor(secrets: {'abcd', 'abcd-efgh'});
      expect(r.text('x abcd-efgh y'), 'x $mask y');
    });

    test('Basic credentials holding a secret are masked as a whole', () {
      final r = Redactor(secrets: {'hunter2-secret'});
      for (final user in ['a', 'alice', 'bob-the-builder']) {
        final token = base64.encode(utf8.encode('$user:hunter2-secret'));
        expect(
          r.text('{"Authorization": "Basic $token"}'),
          '{"Authorization": "Basic $mask"}',
          reason: user,
        );
      }
    });

    test('Basic credentials without a secret stay', () {
      final r = Redactor(secrets: {'hunter2-secret'});
      final token = base64.encode(utf8.encode('alice:other'));
      expect(r.text('Basic $token'), 'Basic $token');
      expect(
        r.text('Basic authentication is required'),
        'Basic authentication is required',
      );
    });
  });

  group('headers', () {
    test('Authorization keeps its scheme only', () {
      expect(
        plain.headerValue('Authorization', 'Bearer abc.def.ghi'),
        'Bearer $mask',
      );
      expect(
        plain.headerValue('authorization', 'Basic dXNlcjpwYXNz'),
        'Basic $mask',
      );
      expect(plain.headerValue('Authorization', 'opaque'), mask);
      expect(
        plain.headerValue(
          'Authorization',
          'AWS4-HMAC-SHA256 Credential=AKIA/20260101/us-east-1/s3/aws4_request, Signature=ab',
        ),
        'AWS4-HMAC-SHA256 $mask',
      );
    });

    test('Proxy-Authorization is masked', () {
      expect(
        plain.headerValue('Proxy-Authorization', 'Basic dXNlcjpwYXNz'),
        'Basic $mask',
      );
    });

    test('Cookie hides every value and keeps the names', () {
      expect(
        plain.headerValue('Cookie', 'sid=abc; theme=dark'),
        'sid=$mask; theme=$mask',
      );
    });

    test('Set-Cookie hides the value and keeps the attributes', () {
      expect(
        plain.headerValue('Set-Cookie', 'sid=abc123; Path=/; HttpOnly; Secure'),
        'sid=$mask; Path=/; HttpOnly; Secure',
      );
      expect(plain.headerValue('set-cookie', 'a=b'), 'a=$mask');
      expect(plain.headerValue('Set-Cookie', 'garbage'), mask);
    });

    test('API key headers are masked, ordinary headers are not', () {
      expect(plain.headerValue('X-API-Key', 'k1'), mask);
      expect(plain.headerValue('x-goog-api-key', 'k1'), mask);
      expect(plain.headerValue('X-Auth-Token', 'k1'), mask);
      expect(plain.headerValue('X-Amz-Security-Token', 'k1'), mask);
      expect(plain.headerValue('X-Client-Secret', 'k1'), mask);
      expect(
        plain.headerValue('Content-Type', 'application/json'),
        'application/json',
      );
      expect(plain.headerValue('X-RateLimit-Remaining', '99'), '99');
      expect(plain.headerValue('Cache-Control', 'no-store'), 'no-store');
    });

    test('Location and other values lose credentials they carry', () {
      expect(
        plain.headerValue('Location', 'https://x.test/cb?access_token=abc&s=1'),
        'https://x.test/cb?access_token=$mask&s=1',
      );
      expect(
        plain.headerValue('Location', '/cb?code=1&token=abc'),
        '/cb?code=1&token=$mask',
      );
      expect(
        Redactor(
          secrets: {'s3cr3t-value'},
        ).headerValue('X-Echo', 'got s3cr3t-value'),
        'got $mask',
      );
    });

    test('a whole header map is masked, several values at once', () {
      final out = plain.headers({
        'set-cookie': ['a=1; Path=/', 'b=2; HttpOnly'],
        'content-type': ['text/plain'],
      });
      expect(out['set-cookie'], ['a=$mask; Path=/', 'b=$mask; HttpOnly']);
      expect(out['content-type'], ['text/plain']);
    });
  });

  group('free text', () {
    test('URLs inside an error message are masked', () {
      expect(
        plain.text('Failed: GET https://x.test/a?api_key=abc&b=1 (timeout).'),
        'Failed: GET https://x.test/a?api_key=$mask&b=1 (timeout).',
      );
    });

    test('trailing punctuation stays outside the URL', () {
      expect(
        plain.text('see (https://x.test/a?token=abc), then'),
        'see (https://x.test/a?token=$mask), then',
      );
    });

    test('text without credentials is returned unchanged', () {
      const text = 'HTTP 500 from https://x.test/a?page=2&sort=asc';
      expect(plain.text(text), text);
      expect(plain.text(''), '');
    });
  });
}
