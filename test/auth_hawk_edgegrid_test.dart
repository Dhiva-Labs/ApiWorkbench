import 'dart:convert';
import 'dart:typed_data';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/auth/auth.dart';
import 'package:api_workbench/services/request_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Hawk (protocol example in the Hawk docs)', () {
    final url = Uri.parse('http://example.com:8000/resource/1?b=1&a=2');
    const key = 'werxhqb98rpaxn39848xrunpaw3489ruxnpa98w4rxn';

    test('normalized string and MAC', () {
      expect(
        HawkAuth.normalized(
          method: 'GET',
          url: url,
          ts: '1353832234',
          nonce: 'j4h3g2',
          ext: 'some-app-ext-data',
        ),
        'hawk.1.header\n1353832234\nj4h3g2\nGET\n/resource/1?b=1&a=2\n'
        'example.com\n8000\n\nsome-app-ext-data\n',
      );
      expect(
        HawkAuth.header(
          method: 'GET',
          url: url,
          id: 'dh37fgj492je',
          key: key,
          ts: '1353832234',
          nonce: 'j4h3g2',
          ext: 'some-app-ext-data',
        ),
        'Hawk id="dh37fgj492je", ts="1353832234", nonce="j4h3g2", '
        'ext="some-app-ext-data", '
        'mac="6R4rV5iE+NPoym+WwjeHzjAGXUtLNIxmo1vpMofpLAE="',
      );
    });

    test('payload hash through applyAuth', () async {
      final p = PreparedRequest(
        method: 'POST',
        url: url,
        headers: HeaderList([
          const MapEntry('Content-Type', 'text/plain; charset=utf-8'),
        ]),
        body: Uint8List.fromList(utf8.encode('Thank you for flying Hawk')),
      );
      await applyAuth(
        p,
        AuthConfig(
          type: AuthType.hawk,
          params: {
            'authId': 'dh37fgj492je',
            'authKey': key,
            'algorithm': 'sha256',
            'user': 'Steve',
            'timestamp': '1353832234',
            'nonce': 'j4h3g2',
            'extraData': 'some-app-ext-data',
            'includePayloadHash': 'true',
          },
        ),
        AuthContext(),
      );
      expect(
        p.headers.value('authorization'),
        'Hawk id="dh37fgj492je", ts="1353832234", nonce="j4h3g2", '
        'hash="Yi9LfIIFRtBEPt74PVmbTF/xVAwPn7ub15ePICfgnuY=", '
        'ext="some-app-ext-data", '
        'mac="aSe1DERmZuRl3pI36/9BdZmnErTw3sNzOOAUlfeKjVw="',
      );
    });

    test('app and dlg are covered by the MAC', () {
      String mac(String app, String dlg) => HawkAuth.header(
        method: 'GET',
        url: url,
        id: 'id',
        key: key,
        algorithm: 'sha1',
        ts: '1',
        nonce: 'n',
        app: app,
        dlg: dlg,
      );
      final a = mac('app1', 'd1');
      expect(a, endsWith('app="app1", dlg="d1"'));
      expect(a, isNot(mac('app1', 'd2')));
      expect(
        HawkAuth.normalized(
          method: 'GET',
          url: url,
          ts: '1',
          nonce: 'n',
          app: 'app1',
          dlg: 'd1',
        ),
        endsWith('\n\n\napp1\nd1\n'),
      );
    });
  });

  group('Akamai EdgeGrid (edgegrid-python testcases.json)', () {
    const host = 'akaa-baseurl-xxxxxxxxxxx-xxxxxxxxxxxxx.luna.akamaiapis.net';
    const prefix =
        'EG1-HMAC-SHA256 client_token=akab-client-token-xxx-xxxxxxxxxxxxxxxx;'
        'access_token=akab-access-token-xxx-xxxxxxxxxxxxxxxx;'
        'timestamp=20140321T19:34:21+0000;'
        'nonce=nonce-xx-xxxx-xxxx-xxxx-xxxxxxxxxxxx;signature=';

    String sign(
      String method,
      String path, {
      String? data,
      List<(String, String)> headers = const [],
    }) => EdgeGridAuth.header(
      method: method,
      url: Uri.parse('https://$host$path'),
      headers: HeaderList([for (final (k, v) in headers) MapEntry(k, v)]),
      body: data == null ? null : utf8.encode(data),
      clientToken: 'akab-client-token-xxx-xxxxxxxxxxxxxxxx',
      accessToken: 'akab-access-token-xxx-xxxxxxxxxxxxxxxx',
      clientSecret: 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=',
      timestamp: '20140321T19:34:21+0000',
      nonce: 'nonce-xx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',
      headersToSign: const ['X-Test1', 'X-Test2', 'X-Test3'],
      maxBody: 2048,
    );

    test('simple GET', () {
      expect(
        sign('GET', '/'),
        '${prefix}tL+y4hxyHxgWVD30X3pWnGKHcPzmrIF+LThiAOhMxYU=',
      );
    });

    test('GET with querystring', () {
      expect(
        sign('GET', '/testapi/v1/t1?p1=1&p2=2'),
        '${prefix}hKDH1UlnQySSHjvIcZpDMbQHihTQ0XyVAKZaApabdeA=',
      );
    });

    test('POST inside limit', () {
      expect(
        sign(
          'POST',
          '/testapi/v1/t3',
          data: 'datadatadatadatadatadatadatadata',
        ),
        '${prefix}hXm4iCxtpN22m4cbZb4lVLW5rhX8Ca82vCFqXzSTPe4=',
      );
    });

    test('POST too large is hashed up to max_body', () {
      expect(
        sign('POST', '/testapi/v1/t3', data: 'd' * 3000),
        '${prefix}6Q6PiTipLae6n4GsSIDTCJ54bEbHUBp+4MUXrbQCBoY=',
      );
      expect(
        sign('POST', '/testapi/v1/t3', data: 'd' * 2048),
        '${prefix}6Q6PiTipLae6n4GsSIDTCJ54bEbHUBp+4MUXrbQCBoY=',
      );
    });

    test('POST empty body', () {
      expect(
        sign('POST', '/testapi/v1/t6', data: ''),
        '${prefix}1gEDxeQGD5GovIkJJGcBaKnZ+VaPtrc4qBUHixjsPCQ=',
      );
    });

    test('header signing, spaces and order', () {
      expect(
        sign(
          'GET',
          '/testapi/v1/t4',
          headers: [('X-Test1', 'test-simple-header')],
        ),
        '${prefix}8F9AybcRw+PLxnvT+H0JRkjROrrUgsxJTnRXMzqvcwY=',
      );
      expect(
        sign(
          'GET',
          '/testapi/v1/t4',
          headers: [('X-Test1', '"     test-header-with-spaces     "')],
        ),
        '${prefix}ucq2AbjCNtobHfCTuS38fdkl5UDdWHZhQX46fYR8CqI=',
      );
      expect(
        sign(
          'GET',
          '/testapi/v1/t4',
          headers: [('X-Test1', '     first-thing      second-thing')],
        ),
        '${prefix}WtnneL539UadAAOJwnsXvPqT4Kt6z7HMgBEwAFpt3+c=',
      );
      expect(
        sign(
          'GET',
          '/testapi/v1/t4',
          headers: [('X-Test2', 't2'), ('X-Test1', 't1'), ('X-Test3', 't3')],
        ),
        '${prefix}Wus73Nx8jOYM+kkBFF2q8D1EATRIMr0WLWwpLBgkBqY=',
      );
      expect(
        sign(
          'GET',
          '/testapi/v1/t5',
          headers: [
            ('X-Test2', 't2'),
            ('X-Test1', 't1'),
            ('X-Test3', 't3'),
            ('X-Extra', "this won't be included"),
          ],
        ),
        '${prefix}Knd/jc0A5Ghhizjayr0AUUvl2MZjBpS3FDSzvtq4Ixc=',
      );
    });

    test('PUT and PATCH bodies are not hashed', () {
      expect(
        sign('PUT', '/testapi/v1/t6', data: 'PPPPPPPPPPPPPPPPPPPPPPPPPPPPPPP'),
        '${prefix}GNBWEYSEWOLtu+7dD52da2C39aX/Jchpon3K/AmBqBU=',
      );
      expect(
        sign(
          'PATCH',
          '/testapi/v1/t6',
          data: 'PPPPPPPPPPPPPPPPPPPPPPPPPPPPPPP',
        ),
        '${prefix}JIl05ImY1AOnMtmw+9LKgaFA8mnzsEKabbnHmI8LsQ4=',
      );
    });

    test('query params and a separator in the path', () {
      expect(
        sign('GET', '/testapi/v1/configs/111?from=12345&limit=200000'),
        '${prefix}XM+hsuSs6nuy/5eDRty1IjtVCAdr8xPFRAZ/b8RXDm8=',
      );
      expect(
        sign('GET', '/testapi/v1/configs/111;222;333?from=12345&limit=200000'),
        '${prefix}pmQF7Is2+O4r/mMojPR4yeF58BrempNNoBX5/DT0Fxs=',
      );
    });

    test('applyAuth reads the params and generates nonce and time', () async {
      final p = PreparedRequest(
        method: 'GET',
        url: Uri.parse('https://$host/'),
      );
      await applyAuth(
        p,
        AuthConfig(
          type: AuthType.edgegrid,
          params: {
            'clientToken': 'ct',
            'accessToken': 'at',
            'clientSecret': 'cs',
          },
        ),
        AuthContext(clock: () => DateTime.utc(2014, 3, 21, 19, 34, 21)),
      );
      final h = p.headers.value('authorization')!;
      expect(
        h,
        startsWith(
          'EG1-HMAC-SHA256 client_token=ct;access_token=at;'
          'timestamp=20140321T19:34:21+0000;nonce=',
        ),
      );
      expect(h, contains(';signature='));
    });
  });
}
