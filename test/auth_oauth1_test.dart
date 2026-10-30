import 'dart:convert';
import 'dart:typed_data';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/auth/auth.dart';
import 'package:api_workbench/services/request_builder.dart';
import 'package:flutter_test/flutter_test.dart';

/// The oauth_* fields of an `Authorization: OAuth ...` header, decoded.
Map<String, String> oauthFields(String header) {
  expect(header, startsWith('OAuth '));
  return {
    for (final m in RegExp(r'(\w+)="([^"]*)"').allMatches(header))
      m.group(1)!: Uri.decodeComponent(m.group(2)!),
  };
}

PreparedRequest formRequest(String method, String url, String body) =>
    PreparedRequest(
      method: method,
      url: Uri.parse(url),
      headers: HeaderList([
        const MapEntry('Content-Type', 'application/x-www-form-urlencoded'),
      ]),
      body: Uint8List.fromList(utf8.encode(body)),
    );

void main() {
  final now = DateTime.utc(2020);

  test('RFC 5849 §3.4.1.1 signature base string', () {
    final p = formRequest(
      'POST',
      'http://example.com/request?b5=%3D%253D&a3=a&c%40=&a2=r%20b',
      'c2&a3=2+q',
    );
    final base = OAuth1Auth.baseString(p.method, p.url, [
      ...formPairsOf(p.url.query),
      ...formPairsOf(p.bodyText),
      const MapEntry('oauth_consumer_key', '9djdj82h48djs9d2'),
      const MapEntry('oauth_token', 'kkk9d7dh3k39sjv7'),
      const MapEntry('oauth_signature_method', 'HMAC-SHA1'),
      const MapEntry('oauth_timestamp', '137131201'),
      const MapEntry('oauth_nonce', '7d8f3e4a'),
    ]);
    expect(
      base,
      'POST&http%3A%2F%2Fexample.com%2Frequest&a2%3Dr%2520b%26a3%3D2%2520q'
      '%26a3%3Da%26b5%3D%253D%25253D%26c%2540%3D%26c2%3D%26oauth_consumer_'
      'key%3D9djdj82h48djs9d2%26oauth_nonce%3D7d8f3e4a%26oauth_signature_m'
      'ethod%3DHMAC-SHA1%26oauth_timestamp%3D137131201%26oauth_token%3Dkkk'
      '9d7dh3k39sjv7',
    );
  });

  test('Twitter "Creating a signature" example (form body signed)', () async {
    final p = formRequest(
      'POST',
      'https://api.twitter.com/1.1/statuses/update.json?include_entities=true',
      'status=Hello%20Ladies%20%2B%20Gentlemen%2C%20a%20signed%20OAuth%20request%21',
    );
    await applyAuth(
      p,
      AuthConfig(
        type: AuthType.oauth1,
        params: {
          'consumerKey': 'xvz1evFS4wEEPTGEFPHBog',
          'consumerSecret': 'kAcSOqF21Fu85e7zjz7ZN2U4ZRhfV3WpwPAoE3Z7kBw',
          'token': '370773112-GmHxMAgYyLbNEtIKZeRNFsMKPR9EyMZeS9weJAEb',
          'tokenSecret': 'LswwdoUaIvS8ltyTt5jkRh4J50vUPVVHtR2YPi5kE',
          'signatureMethod': 'HMAC-SHA1',
          'timestamp': '1318622958',
          'nonce': 'kYjzVBB8Y0ZFabxSWbWovY3uYSQ2pTgmZeNu2VS4cg',
          'version': '1.0',
          'addParamsToHeader': 'true',
        },
      ),
      AuthContext(clock: () => now),
    );
    final f = oauthFields(p.headers.value('authorization')!);
    expect(f['oauth_signature'], 'hCtSmYh+iHYCEqBWrE7C7hYmtUk=');
    expect(f['oauth_version'], '1.0');
    expect(p.bodyText, startsWith('status=Hello'));
  });

  test('RFC 5849 §1.2 example, with realm and no version', () {
    final p = PreparedRequest(
      method: 'GET',
      url: Uri.parse(
        'http://photos.example.net/photos?file=vacation.jpg&size=original',
      ),
    );
    OAuth1Auth.sign(
      p,
      consumerKey: 'dpf43f3p2l4k3l03',
      consumerSecret: 'kd94hf93k423kf44',
      token: 'nnch734d00sl2jdk',
      tokenSecret: 'pfkkdhi9sl3r4s00',
      timestamp: '137131202',
      nonce: 'chapoH',
      version: '',
      realm: 'Photos',
      now: now,
    );
    final h = p.headers.value('authorization')!;
    expect(h, startsWith('OAuth realm="Photos", oauth_consumer_key='));
    expect(h, isNot(contains('oauth_version')));
    expect(oauthFields(h)['oauth_signature'], 'MdpQcU8iPSUjWoN/UDMsK2sui9I=');
  });

  test('OAuth Core 1.0 appendix A.5 example (HMAC-SHA1)', () {
    final p = PreparedRequest(
      method: 'GET',
      url: Uri.parse(
        'http://photos.example.net/photos?file=vacation.jpg&size=original',
      ),
    );
    OAuth1Auth.sign(
      p,
      consumerKey: 'dpf43f3p2l4k3l03',
      consumerSecret: 'kd94hf93k423kf44',
      token: 'nnch734d00sl2jdk',
      tokenSecret: 'pfkkdhi9sl3r4s00',
      timestamp: '1191242096',
      nonce: 'kllo9940pd9333jh',
      now: now,
    );
    expect(
      oauthFields(p.headers.value('authorization')!)['oauth_signature'],
      'tR3+Ty81lMeYAr/Fid0kMTYa/WM=',
    );
  });

  test('PLAINTEXT signs with the encoded secrets', () {
    final p = PreparedRequest(method: 'GET', url: Uri.parse('https://h/x'));
    OAuth1Auth.sign(
      p,
      consumerKey: 'ck',
      consumerSecret: 'c s&',
      tokenSecret: 't/s',
      signatureMethod: 'PLAINTEXT',
      now: now,
    );
    expect(
      oauthFields(p.headers.value('authorization')!)['oauth_signature'],
      'c%20s%26&t%2Fs',
    );
  });

  test('HMAC-SHA256 and HMAC-SHA512 differ from SHA-1 and are stable', () {
    String sigFor(String m) {
      final p = PreparedRequest(method: 'GET', url: Uri.parse('https://h/x'));
      OAuth1Auth.sign(
        p,
        consumerKey: 'ck',
        consumerSecret: 'cs',
        signatureMethod: m,
        timestamp: '1',
        nonce: 'n',
        now: now,
      );
      return oauthFields(p.headers.value('authorization')!)['oauth_signature']!;
    }

    final s1 = sigFor('HMAC-SHA1');
    final s256 = sigFor('HMAC-SHA256');
    final s512 = sigFor('HMAC-SHA512');
    expect(base64.decode(s1), hasLength(20));
    expect(base64.decode(s256), hasLength(32));
    expect(base64.decode(s512), hasLength(64));
    expect(sigFor('HMAC-SHA256'), s256);
  });

  test('params go in the body for forms and the query otherwise', () async {
    final auth = AuthConfig(
      type: AuthType.oauth1,
      params: {
        'consumerKey': 'ck',
        'consumerSecret': 'cs',
        'addParamsToHeader': 'false',
      },
    );
    final form = formRequest('POST', 'https://h/x', 'a=1');
    await applyAuth(form, auth, AuthContext());
    expect(form.headers.has('authorization'), isFalse);
    expect(form.bodyText, startsWith('a=1&oauth_consumer_key=ck&'));
    expect(form.bodyText, contains('oauth_signature='));

    final get = PreparedRequest(
      method: 'GET',
      url: Uri.parse('https://h/x?b=2'),
    );
    await applyAuth(get, auth, AuthContext());
    expect(get.url.queryParameters['b'], '2');
    expect(get.url.queryParameters['oauth_consumer_key'], 'ck');
    expect(get.url.queryParameters['oauth_signature'], isNotEmpty);
  });

  test('body hash for non-form bodies, empty params on request', () {
    final p = PreparedRequest(
      method: 'POST',
      url: Uri.parse('https://h/x'),
      headers: HeaderList([const MapEntry('Content-Type', 'application/json')]),
      body: Uint8List.fromList(utf8.encode('{"a":1}')),
    );
    OAuth1Auth.sign(
      p,
      consumerKey: 'ck',
      consumerSecret: 'cs',
      includeBodyHash: true,
      addEmptyParamsToSign: true,
      now: now,
    );
    final f = oauthFields(p.headers.value('authorization')!);
    // SHA-1 of {"a":1}, base64.
    expect(f['oauth_body_hash'], 'n4nHQM60bXQYySSnisV5QdXpZSA=');
    expect(f['oauth_token'], '');
    expect(f['oauth_callback'], '');
  });
}

List<MapEntry<String, String>> formPairsOf(String raw) => [
  for (final part in raw.split('&'))
    if (part.isNotEmpty)
      part.contains('=')
          ? MapEntry(
              Uri.decodeQueryComponent(part.substring(0, part.indexOf('='))),
              Uri.decodeQueryComponent(part.substring(part.indexOf('=') + 1)),
            )
          : MapEntry(Uri.decodeQueryComponent(part), ''),
];
