import 'dart:convert';
import 'dart:typed_data';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/auth/auth.dart';
import 'package:api_workbench/services/request_builder.dart';
import 'package:flutter_test/flutter_test.dart';

/// Cases from the AWS Signature Version 4 test suite
/// (aws-sig-v4-test-suite, as shipped with botocore): access key
/// AKIDEXAMPLE, region us-east-1, service "service", 2015-08-30T12:36:00Z.
class _Case {
  const _Case(
    this.name,
    this.method,
    this.target,
    this.signature, {
    this.headers = const [],
    this.body,
    this.signed = 'host;x-amz-date',
  });
  final String name;
  final String method;
  final String target;
  final List<(String, String)> headers;
  final String? body;
  final String signed;
  final String signature;
}

const _token =
    'AQoDYXdzEPT//////////wEXAMPLEtc764bNrC9SAPBSM22wDOk4x4HIZ8j4FZTwdQWLWsKWHG'
    'BuFqwAeMicRXmxfpSPfIeoIYRqTflfKD8YUuwthAx7mSEI/qkPpKPi/kMcGdQrmGdeehM4IC1'
    'NtBmUpp2wUE8phUZampKsburEDy0KPkyQDYwT7WZ0wq5VSXDvp75YU9HFvlRd8Tx6q6fE8YQc'
    'HNVXAkiY9q6d+xo0rKwT38xVqr7ZD0u0iPPkUL64lIZbqBAz+scqKmlzm8FDrypNC9Yjc8fPO'
    'Ln9FX9KSYvKTr4rvx3iSIlTJabIQwj2ICCR/oLxBA==';

const _cases = [
  _Case(
    'get-vanilla',
    'GET',
    '/',
    '5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31',
  ),
  _Case(
    'get-vanilla-query-order-key-case',
    'GET',
    '/?Param2=value2&Param1=value1',
    'b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500',
  ),
  _Case(
    'get-vanilla-query-unreserved',
    'GET',
    '/?-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz='
        '-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz',
    '9c3e54bfcdf0b19771a7f523ee5669cdf59bc7cc0884027167c21bb143a40197',
  ),
  _Case(
    'get-vanilla-empty-query-key',
    'GET',
    '/?Param1=value1',
    'a67d582fa61cc504c4bae71f336f98b97f1ea3c7a6bfe1b6e45aec72011b9aeb',
  ),
  _Case(
    'get-header-value-trim',
    'GET',
    '/',
    'acc3ed3afb60bb290fc8d2dd0098b9911fcaa05412b367055dee359757a9c736',
    headers: [('My-Header1', ' value1'), ('My-Header2', ' "a   b   c"')],
    signed: 'host;my-header1;my-header2;x-amz-date',
  ),
  _Case(
    'get-header-key-duplicate',
    'GET',
    '/',
    'c9d5ea9f3f72853aea855b47ea873832890dbdd183b4468f858259531a5138ea',
    headers: [
      ('My-Header1', 'value2'),
      ('My-Header1', 'value2'),
      ('My-Header1', 'value1'),
    ],
    signed: 'host;my-header1;x-amz-date',
  ),
  _Case(
    'post-vanilla',
    'POST',
    '/',
    '5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b',
  ),
  _Case(
    'post-vanilla-query',
    'POST',
    '/?Param1=value1',
    '28038455d6de14eafc1f9222cf5aa6f1a96197d7deb8263271d420d138af7f11',
  ),
  _Case(
    'post-header-key-sort',
    'POST',
    '/',
    'c5410059b04c1ee005303aed430f6e6645f61f4dc9e1461ec8f8916fdf18852c',
    headers: [('My-Header1', 'value1')],
    signed: 'host;my-header1;x-amz-date',
  ),
  _Case(
    'post-header-value-case',
    'POST',
    '/',
    'cdbc9802e29d2942e5e10b5bccfdd67c5f22c7c4e8ae67b53629efa58b974b7d',
    headers: [('My-Header1', 'VALUE1')],
    signed: 'host;my-header1;x-amz-date',
  ),
  _Case(
    'post-x-www-form-urlencoded',
    'POST',
    '/',
    'ff11897932ad3f4e8b18135d722051e5ac45fc38421b1da7b9d196a0fe09473a',
    headers: [('Content-Type', 'application/x-www-form-urlencoded')],
    body: 'Param1=value1',
    signed: 'content-type;host;x-amz-date',
  ),
  _Case(
    'post-x-www-form-urlencoded-parameters',
    'POST',
    '/',
    '1a72ec8f64bd914b0e42e42607c7fbce7fb2c7465f63e3092b3b0d39fa77a6fe',
    headers: [
      ('Content-Type', 'application/x-www-form-urlencoded; charset=utf8'),
    ],
    body: 'Param1=value1',
    signed: 'content-type;host;x-amz-date',
  ),
  _Case(
    'post-sts-header-before',
    'POST',
    '/',
    '85d96828115b5dc0cfc3bd16ad9e210dd772bbebba041836c64533a82be05ead',
    headers: [('X-Amz-Security-Token', _token)],
    signed: 'host;x-amz-date;x-amz-security-token',
  ),
];

void main() {
  group('AWS SigV4 test suite', () {
    for (final c in _cases) {
      test(c.name, () {
        final p = PreparedRequest(
          method: c.method,
          url: Uri.parse('https://example.amazonaws.com${c.target}'),
          headers: HeaderList([
            const MapEntry('Host', 'example.amazonaws.com'),
            for (final (k, v) in c.headers) MapEntry(k, v),
            const MapEntry('X-Amz-Date', '20150830T123600Z'),
          ]),
          body: c.body == null
              ? null
              : Uint8List.fromList(utf8.encode(c.body!)),
        );
        AwsSigV4.sign(
          p,
          accessKey: 'AKIDEXAMPLE',
          secretKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
          region: 'us-east-1',
          service: 'service',
          now: DateTime.utc(2000),
        );
        expect(
          p.headers.value('authorization'),
          'AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/'
          'aws4_request, SignedHeaders=${c.signed}, Signature=${c.signature}',
        );
      });
    }

    test('session token through applyAuth adds the header', () async {
      final p = PreparedRequest(
        method: 'POST',
        url: Uri.parse('https://example.amazonaws.com/'),
        headers: HeaderList([const MapEntry('Host', 'example.amazonaws.com')]),
      );
      await applyAuth(
        p,
        AuthConfig(
          type: AuthType.awsV4,
          params: {
            'accessKey': 'AKIDEXAMPLE',
            'secretKey': 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
            'sessionToken': '{{token}}',
            'region': 'us-east-1',
            'service': 'service',
          },
        ),
        AuthContext(
          vars: {'token': _token},
          clock: () => DateTime.utc(2015, 8, 30, 12, 36),
        ),
      );
      expect(p.headers.value('x-amz-date'), '20150830T123600Z');
      expect(p.headers.value('x-amz-security-token'), _token);
      expect(
        p.headers.value('authorization'),
        endsWith(
          'SignedHeaders=host;x-amz-date;x-amz-security-token, '
          'Signature=85d96828115b5dc0cfc3bd16ad9e210dd772bbebba041836c64533a82be05ead',
        ),
      );
    });
  });

  group('AWS S3 examples (SigV4 documentation)', () {
    const ak = 'AKIAIOSFODNN7EXAMPLE';
    const sk = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY';
    final at = DateTime.utc(2013, 5, 24);

    test('GET object with a Range header', () {
      final p = PreparedRequest(
        method: 'GET',
        url: Uri.parse('https://examplebucket.s3.amazonaws.com/test.txt'),
        headers: HeaderList([const MapEntry('Range', 'bytes=0-9')]),
      );
      AwsSigV4.sign(p, accessKey: ak, secretKey: sk, now: at);
      expect(
        p.headers.value('x-amz-content-sha256'),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        p.headers.value('authorization'),
        'AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/'
        's3/aws4_request, '
        'SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, '
        'Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41',
      );
    });

    test('presigned URL (query mode)', () {
      final p = PreparedRequest(
        method: 'GET',
        url: Uri.parse('https://examplebucket.s3.amazonaws.com/test.txt'),
      );
      AwsSigV4.sign(p, accessKey: ak, secretKey: sk, query: true, now: at);
      expect(p.headers.has('authorization'), isFalse);
      final q = p.url.queryParameters;
      expect(q['X-Amz-Algorithm'], 'AWS4-HMAC-SHA256');
      expect(
        q['X-Amz-Credential'],
        'AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request',
      );
      expect(p.url.query, contains('X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F'));
      expect(q['X-Amz-Expires'], '86400');
      expect(q['X-Amz-SignedHeaders'], 'host');
      expect(
        q['X-Amz-Signature'],
        'aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404',
      );
    });
  });

  group('canonical form', () {
    test('non-S3 paths are normalized and encoded again', () {
      expect(AwsSigV4.canonicalUri('//example//', s3: false), '/example/');
      expect(AwsSigV4.canonicalUri('/example/..', s3: false), '/');
      expect(AwsSigV4.canonicalUri('/./example', s3: false), '/example');
      expect(
        AwsSigV4.canonicalUri('/example%20space/', s3: false),
        '/example%2520space/',
      );
      expect(
        AwsSigV4.canonicalUri('/my%20key/a+b', s3: true),
        '/my%20key/a%2Bb',
      );
    });

    test('query pairs sort by name, then value', () {
      expect(AwsSigV4.canonicalQuery('b=2&a=z&a=y&c'), 'a=y&a=z&b=2&c=');
    });

    test('service and region come from the host', () {
      expect(AwsSigV4.inferServiceRegion('dynamodb.eu-west-1.amazonaws.com'), (
        service: 'dynamodb',
        region: 'eu-west-1',
      ));
      expect(AwsSigV4.inferServiceRegion('bucket.s3.us-west-2.amazonaws.com'), (
        service: 's3',
        region: 'us-west-2',
      ));
      expect(
        AwsSigV4.inferServiceRegion('abc.execute-api.us-east-1.amazonaws.com'),
        (service: 'execute-api', region: 'us-east-1'),
      );
      expect(AwsSigV4.inferServiceRegion('iam.amazonaws.com'), (
        service: 'iam',
        region: null,
      ));
      expect(AwsSigV4.inferServiceRegion('api.example.com'), (
        service: null,
        region: null,
      ));
    });

    test('a missing service on a custom domain is explained', () async {
      final p = PreparedRequest(
        method: 'GET',
        url: Uri.parse('https://api.example.com/'),
      );
      expect(
        () => applyAuth(
          p,
          AuthConfig(
            type: AuthType.awsV4,
            params: {'accessKey': 'a', 'secretKey': 'b'},
          ),
          AuthContext(),
        ),
        throwsA(isA<AuthException>()),
      );
    });
  });
}
