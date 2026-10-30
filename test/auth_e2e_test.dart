import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/auth/auth.dart';
import 'package:api_workbench/services/auth/auth_util.dart';
import 'package:api_workbench/services/auth/oauth2_redirect.dart';
import 'package:api_workbench/services/http_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the local server saw: path, Authorization header, body and the
/// client port (to tell connections apart).
class Hit {
  Hit(this.path, this.authorization, this.body, this.port);
  final String path;
  final String? authorization;
  final String body;
  final int port;
}

typedef Handler = Future<void> Function(HttpRequest req, String body);

void main() {
  late HttpServer server;
  late String base;
  final hits = <Hit>[];
  late Handler handler;
  late HttpService http;

  setUp(() async {
    hits.clear();
    http = HttpService();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      hits.add(
        Hit(
          req.uri.path,
          req.headers.value('authorization'),
          body,
          req.connectionInfo!.remotePort,
        ),
      );
      await handler(req, body);
      await req.response.close();
    });
  });

  tearDown(() async {
    http.dispose();
    await server.close(force: true);
  });

  group('Digest', () {
    const nonce = 'dcd98b7102dd2f0e8b11d0f600bfb0c093';

    setUp(() {
      handler = (req, body) async {
        final h = req.headers.value('authorization');
        if (h == null) {
          req.response
            ..statusCode = 401
            ..headers.add(
              'www-authenticate',
              'Digest realm="api@local", qop="auth,auth-int", '
                  'algorithm=SHA-256, nonce="$nonce", opaque="op"',
            );
          return;
        }
        final c = parseChallenges([h]).single;
        final p = c.params;
        final want = DigestAuth.response(
          method: req.method,
          uri: p['uri']!,
          username: 'ada',
          password: 's3cret',
          realm: 'api@local',
          nonce: nonce,
          algorithm: p['algorithm']!,
          qop: p['qop']!,
          nc: p['nc']!,
          cnonce: p['cnonce']!,
          body: utf8.encode(body),
        );
        final ok =
            p['response'] == want &&
            p['opaque'] == 'op' &&
            p['uri'] == '/secret?x=1';
        req.response.statusCode = ok ? 200 : 403;
        req.response.write(ok ? 'welcome' : 'bad digest');
      };
    });

    for (final qop in ['auth', 'auth-int']) {
      test('answers the 401 challenge (qop=$qop)', () async {
        var updated = 0;
        final r = RequestModel(
          method: 'POST',
          url: '$base/secret?x=1',
          bodyType: BodyType.text,
          body: 'payload',
          authType: AuthType.digest,
          authParams: {
            'username': '{{user}}',
            'password': 's3cret',
            'algorithm': 'SHA-256',
            'qop': qop,
          },
        );
        final res = await http.send(
          r,
          {'user': 'ada'},
          tabId: 't',
          onAuthUpdated: () => updated++,
        );
        expect(res.error, isNull);
        expect(res.statusCode, 200);
        expect(utf8.decode(res.bodyBytes), 'welcome');
        expect(hits, hasLength(2));
        expect(hits[0].authorization, isNull);
        expect(hits[1].authorization, contains('qop=$qop'));
        expect(hits[1].body, 'payload');
        // Answering a challenge doesn't change the saved request.
        expect(updated, 0);
        expect(r.auth.params.containsKey('nonce'), isFalse);
      });
    }

    test('disableRetryRequest returns the 401', () async {
      final res = await http.send(
        RequestModel(
          url: '$base/secret?x=1',
          authType: AuthType.digest,
          authParams: {
            'username': 'ada',
            'password': 's3cret',
            'disableRetryRequest': 'true',
          },
        ),
        const {},
        tabId: 't',
      );
      expect(res.statusCode, 401);
      expect(hits, hasLength(1));
    });
  });

  group('NTLM', () {
    final serverChallenge = hexBytes('0123456789abcdef');
    final targetInfo = Uint8List.fromList([
      2, 0, 12, 0, ...NtlmAuth.utf16le('Domain'), //
      1, 0, 12, 0, ...NtlmAuth.utf16le('Server'),
      0, 0, 0, 0,
    ]);
    Uint8List challengeMessage() {
      final b = BytesBuilder()
        ..add(ascii.encode('NTLMSSP'))
        ..addByte(0)
        ..add([2, 0, 0, 0])
        ..add([0, 0, 0, 0, 48, 0, 0, 0]) // target name: empty
        ..add([0x35, 0x82, 0x8a, 0xe2]) // flags (unicode on)
        ..add(serverChallenge)
        ..add(Uint8List(8))
        ..add([targetInfo.length, 0, targetInfo.length, 0, 48, 0, 0, 0])
        ..add(targetInfo);
      return b.toBytes();
    }

    Uint8List field(Uint8List m, int at) {
      final len = m[at] | m[at + 1] << 8;
      final off = m[at + 4] | m[at + 5] << 8;
      return Uint8List.sublistView(m, off, off + len);
    }

    setUp(() {
      handler = (req, body) async {
        final h = req.headers.value('authorization') ?? '';
        if (!h.startsWith('NTLM ')) {
          req.response
            ..statusCode = 401
            ..headers.add('www-authenticate', 'NTLM');
          return;
        }
        final msg = base64.decode(h.substring(5));
        if (msg[8] == 1) {
          req.response
            ..statusCode = 401
            ..headers.add(
              'www-authenticate',
              'NTLM ${base64.encode(challengeMessage())}',
            );
          return;
        }
        // Type 3: check the NTLMv2 proof with the password.
        String str(Uint8List b) => String.fromCharCodes([
          for (var i = 0; i + 1 < b.length; i += 2) b[i] | b[i + 1] << 8,
        ]);
        final nt = field(msg, 20);
        final user = str(field(msg, 36));
        final domain = str(field(msg, 28));
        final temp = nt.sublist(16);
        final r = NtlmAuth.responses(
          responseKey: NtlmAuth.ntowfv2('Password', user, domain),
          serverChallenge: serverChallenge,
          clientChallenge: temp.sublist(16, 24),
          timestamp: temp.sublist(8, 16),
          targetInfo: targetInfo,
        );
        final ok = hexOf(r.ntProofStr) == hexOf(nt.sublist(0, 16));
        req.response.statusCode = ok ? 200 : 403;
        req.response.write('$domain\\$user');
      };
    });

    test('NEGOTIATE, CHALLENGE, AUTHENTICATE on one connection', () async {
      final res = await http.send(
        RequestModel(
          url: '$base/ntlm',
          authType: AuthType.ntlm,
          authParams: {
            'username': 'User',
            'password': 'Password',
            'domain': 'Domain',
            'workstation': 'WS',
          },
        ),
        const {},
        tabId: 't',
      );
      expect(res.error, isNull);
      expect(res.statusCode, 200);
      expect(utf8.decode(res.bodyBytes), r'Domain\User');
      expect(hits, hasLength(2));
      expect(hits[0].authorization, startsWith('NTLM '));
      // NTLM authenticates the connection, so both legs must share it.
      expect(hits[1].port, hits[0].port);
    });

    test('a wrong password is rejected by the server', () async {
      final res = await http.send(
        RequestModel(
          url: '$base/ntlm',
          authType: AuthType.ntlm,
          authParams: {'username': r'Domain\User', 'password': 'nope'},
        ),
        const {},
        tabId: 't',
      );
      expect(res.statusCode, 403);
    });
  });

  group('OAuth 2.0', () {
    var issued = 0;
    final tokenRequests = <Map<String, String>>[];

    setUp(() {
      issued = 0;
      tokenRequests.clear();
      handler = (req, body) async {
        final res = req.response;
        if (req.uri.path == '/token') {
          final form = Uri.splitQueryString(body);
          tokenRequests.add({
            ...form,
            'authorization': req.headers.value('authorization') ?? '',
          });
          res.headers.contentType = ContentType.json;
          final basic = 'Basic ${base64.encode(utf8.encode('cid:csecret'))}';
          final clientOk =
              req.headers.value('authorization') == basic ||
              (form['client_id'] == 'cid' &&
                  form['client_secret'] == 'csecret');
          if (!clientOk) {
            res.statusCode = 401;
            res.write(jsonEncode({'error': 'invalid_client'}));
            return;
          }
          switch (form['grant_type']) {
            case 'client_credentials' || 'password':
              issued++;
              res.write(
                jsonEncode({
                  'access_token': 'at$issued',
                  'token_type': 'Bearer',
                  'expires_in': 3600,
                  'refresh_token': 'rt$issued',
                  'scope': form['scope'],
                }),
              );
            case 'refresh_token' when form['refresh_token'] == 'rt1':
              res.write(
                jsonEncode({'access_token': 'refreshed', 'expires_in': '60'}),
              );
            default:
              res.statusCode = 400;
              res.write(
                jsonEncode({
                  'error': 'invalid_grant',
                  'error_description': 'unknown grant',
                }),
              );
          }
          return;
        }
        final h = req.headers.value('authorization');
        final q = req.uri.queryParameters['access_token'];
        res.statusCode = h != null || q != null ? 200 : 401;
        res.write(h ?? 'query:$q');
      };
    });

    AuthConfig ccAuth() => AuthConfig(
      type: AuthType.oauth2,
      params: {
        'grant_type': 'client_credentials',
        'accessTokenUrl': '{{base}}/token',
        'clientId': 'cid',
        'clientSecret': 'csecret',
        'scope': 'read write',
        'client_authentication': 'header',
        'tokenName': 'CI token',
      },
    );

    test('client credentials: fetched on first send, then refreshed', () async {
      final auth = ccAuth();
      var updated = 0;
      final r = RequestModel(url: '$base/api', auth: auth);
      var res = await http.send(
        r,
        {'base': base},
        tabId: 't',
        onAuthUpdated: () => updated++,
      );
      expect(res.error, isNull);
      expect(utf8.decode(res.bodyBytes), 'Bearer at1');
      expect(updated, 1);
      expect(auth.params['accessToken'], 'at1');
      expect(auth.params['refreshToken'], 'rt1');
      final exp = DateTime.parse(auth.params['expiresAt']!);
      expect(
        exp.isAfter(DateTime.now().add(const Duration(minutes: 59))),
        isTrue,
      );
      expect(tokenRequests.single['grant_type'], 'client_credentials');
      expect(tokenRequests.single['scope'], 'read write');
      expect(tokenRequests.single['authorization'], startsWith('Basic '));
      expect(OAuth2.saved(auth).single.name, 'CI token');

      // Valid token: no token request.
      res = await http.send(r, {'base': base}, tabId: 't');
      expect(utf8.decode(res.bodyBytes), 'Bearer at1');
      expect(tokenRequests, hasLength(1));

      // Expired: the refresh token is used and kept.
      auth.params['expiresAt'] = DateTime.now()
          .subtract(const Duration(minutes: 1))
          .toUtc()
          .toIso8601String();
      res = await http.send(
        r,
        {'base': base},
        tabId: 't',
        onAuthUpdated: () => updated++,
      );
      expect(utf8.decode(res.bodyBytes), 'Bearer refreshed');
      expect(updated, 2);
      expect(tokenRequests.last['grant_type'], 'refresh_token');
      expect(tokenRequests.last['refresh_token'], 'rt1');
      expect(auth.params['accessToken'], 'refreshed');
      expect(auth.params['refreshToken'], 'rt1');
      // The refreshed token replaced the old one in the list.
      expect(OAuth2.saved(auth).map((t) => t.accessToken), ['refreshed']);
    });

    test(
      'a failed refresh falls back to a new client credentials token',
      () async {
        final auth = ccAuth()
          ..params['accessToken'] = 'old'
          ..params['refreshToken'] = 'revoked'
          ..params['expiresAt'] = '2000-01-01T00:00:00.000Z';
        final res = await http.send(
          RequestModel(url: '$base/api', auth: auth),
          {'base': base},
          tabId: 't',
        );
        expect(utf8.decode(res.bodyBytes), 'Bearer at1');
        expect(
          [for (final t in tokenRequests) t['grant_type']],
          ['refresh_token', 'client_credentials'],
        );
      },
    );

    test(
      'password grant, credentials in the body, token in the query',
      () async {
        final auth = AuthConfig(
          type: AuthType.oauth2,
          params: {
            'grant_type': 'password_credentials',
            'accessTokenUrl': '$base/token',
            'clientId': 'cid',
            'clientSecret': 'csecret',
            'client_authentication': 'body',
            'username': 'ada',
            'password': 'pw',
            'addTokenTo': 'queryParams',
          },
        );
        final res = await http.send(
          RequestModel(url: '$base/api?x=1', auth: auth),
          const {},
          tabId: 't',
        );
        expect(utf8.decode(res.bodyBytes), 'query:at1');
        final t = tokenRequests.single;
        expect(t['grant_type'], 'password');
        expect(t['username'], 'ada');
        expect(t['password'], 'pw');
        expect(t['client_id'], 'cid');
        expect(t['authorization'], isEmpty);
      },
    );

    test('a token endpoint error becomes the send error', () async {
      final auth = ccAuth()..params['clientSecret'] = 'wrong';
      final res = await http.send(RequestModel(url: '$base/api', auth: auth), {
        'base': base,
      }, tabId: 't');
      expect(res.error, contains('invalid_client'));
      expect(res.error, contains('HTTP 401'));
      expect(hits.where((h) => h.path == '/api'), isEmpty);
    });

    test(
      'authorization code with PKCE through the loopback listener',
      () async {
        // The authorization server: checks the PKCE pair at the token step.
        String? challenge;
        final prev = handler;
        handler = (req, body) async {
          if (req.uri.path == '/token') {
            final form = Uri.splitQueryString(body);
            final verifierOk =
                OAuth2.codeChallenge(form['code_verifier'] ?? '', 'S256') ==
                challenge;
            req.response.headers.contentType = ContentType.json;
            if (form['grant_type'] != 'authorization_code' ||
                form['code'] != 'the-code' ||
                !verifierOk) {
              req.response.statusCode = 400;
              req.response.write(jsonEncode({'error': 'invalid_grant'}));
              return;
            }
            req.response.write(
              jsonEncode({
                'access_token': 'user-token',
                'redirect_uri': form['redirect_uri'],
              }),
            );
            return;
          }
          await prev(req, body);
        };

        final auth = AuthConfig(
          type: AuthType.oauth2,
          params: {
            'grant_type': 'authorization_code_with_pkce',
            'authUrl': '$base/authorize',
            'accessTokenUrl': '$base/token',
            'clientId': 'cid',
            'redirect_uri': 'https://oauth.pstmn.io/v1/callback',
            'challengeAlgorithm': 'S256',
            'scope': 'openid',
          },
        );
        final listener = await LoopbackRedirectListener.start(
          auth.params['redirect_uri']!,
        );
        addTearDown(listener.close);
        expect(listener.usesConfiguredUri, isFalse);
        expect(listener.note, contains('not a loopback'));
        expect(listener.redirectUri.host, '127.0.0.1');

        final ctx = AuthContext(
          sendRaw: (p) => http.sendPrepared(p, tabId: 'auth'),
        );
        final verifier = OAuth2.newCodeVerifier();
        final url = OAuth2.authorizationUrl(
          auth,
          ctx,
          redirectUri: listener.redirectUri.toString(),
          state: 'st-1',
          codeVerifier: verifier,
        );
        challenge = url.queryParameters['code_challenge'];
        expect(url.queryParameters['code_challenge_method'], 'S256');
        expect(url.queryParameters['response_type'], 'code');

        // The "browser" follows the provider's redirect to the listener.
        final client = HttpClient();
        addTearDown(client.close);
        final cb = listener.redirectUri.replace(
          queryParameters: {'code': 'the-code', 'state': 'st-1'},
        );
        final page = await (await client.getUrl(cb)).close();
        expect(await utf8.decoder.bind(page).join(), contains('Signed in'));

        final redirected = await listener.result;
        final t = await OAuth2.completeRedirect(
          auth,
          ctx,
          redirected.toString(),
          redirectUri: listener.redirectUri.toString(),
          state: 'st-1',
          codeVerifier: verifier,
          strictState: true,
        );
        expect(t.accessToken, 'user-token');
        expect(auth.params['accessToken'], 'user-token');

        final res = await http.send(
          RequestModel(url: '$base/api', auth: auth),
          const {},
          tabId: 't',
        );
        expect(utf8.decode(res.bodyBytes), 'Bearer user-token');
      },
    );

    test('implicit grant: the listener page posts the fragment back', () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final listener = await LoopbackRedirectListener.start(
        'http://localhost:$port/cb',
      );
      addTearDown(listener.close);
      expect(listener.usesConfiguredUri, isTrue);
      expect(listener.redirectUri.toString(), 'http://localhost:$port/cb');

      final client = HttpClient();
      addTearDown(client.close);
      final page = await (await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/cb'),
      )).close();
      expect(await utf8.decoder.bind(page).join(), contains('location.hash'));
      final post = await client.postUrl(
        Uri.parse('http://127.0.0.1:$port/__apiworkbench/fragment'),
      );
      post.write('access_token=imp&token_type=bearer&expires_in=60&state=s');
      await (await post.close()).drain<void>();

      final redirected = await listener.result;
      final auth = AuthConfig(
        type: AuthType.oauth2,
        params: {'grant_type': 'implicit'},
      );
      final t = await OAuth2.completeRedirect(
        auth,
        AuthContext(),
        redirected.toString(),
        redirectUri: listener.redirectUri.toString(),
        state: 's',
        strictState: true,
      );
      expect(t.accessToken, 'imp');
      expect(auth.params['expiresAt'], isNotNull);
    });
  });
}
