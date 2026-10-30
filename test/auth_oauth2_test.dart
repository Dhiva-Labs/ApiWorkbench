import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/auth/auth.dart';
import 'package:api_workbench/services/request_builder.dart';
import 'package:flutter_test/flutter_test.dart';

PreparedRequest get _req =>
    PreparedRequest(method: 'GET', url: Uri.parse('https://api.test/x'));

AuthConfig _oauth(Map<String, String> params) =>
    AuthConfig(type: AuthType.oauth2, params: params);

void main() {
  group('PKCE (RFC 7636)', () {
    test('appendix B: S256 challenge', () {
      expect(
        OAuth2.codeChallenge(
          'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
          'S256',
        ),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
    });

    test('plain challenge is the verifier', () {
      expect(OAuth2.codeChallenge('abc', 'plain'), 'abc');
    });

    test('new verifiers are 43-128 unreserved characters', () {
      final v = OAuth2.newCodeVerifier();
      expect(v.length, inInclusiveRange(43, 128));
      expect(RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(v), isTrue);
      expect(OAuth2.newCodeVerifier(), isNot(v));
    });
  });

  group('authorization URL', () {
    test('code with PKCE, scope, state, audience and resource', () {
      final a = _oauth({
        'grant_type': 'authorization_code_with_pkce',
        'authUrl': 'https://idp.test/authorize?prompt=login',
        'clientId': '{{client}}',
        'scope': 'openid profile',
        'challengeAlgorithm': 'plain',
        'audience': '{"https://idp.test/authorize": "api://default"}',
        'resource': 'https://api.test',
      });
      final u = OAuth2.authorizationUrl(
        a,
        AuthContext(vars: {'client': 'my-app'}),
        redirectUri: 'http://127.0.0.1:5000/cb',
        state: 'xyz',
        codeVerifier: 'verifier',
      );
      final q = u.queryParameters;
      expect(u.host, 'idp.test');
      expect(q['prompt'], 'login');
      expect(q['response_type'], 'code');
      expect(q['client_id'], 'my-app');
      expect(q['redirect_uri'], 'http://127.0.0.1:5000/cb');
      expect(q['scope'], 'openid profile');
      expect(q['state'], 'xyz');
      expect(q['code_challenge'], 'verifier');
      expect(q['code_challenge_method'], 'plain');
      expect(q['audience'], 'api://default');
      expect(q['resource'], 'https://api.test');
    });

    test('implicit asks for a token; no PKCE for plain code', () {
      final implicit = OAuth2.authorizationUrl(
        _oauth({'grant_type': 'implicit', 'authUrl': 'idp.test/auth'}),
        AuthContext(),
        redirectUri: 'https://cb.test',
      );
      expect(implicit.scheme, 'https');
      expect(implicit.queryParameters['response_type'], 'token');
      final code = OAuth2.authorizationUrl(
        _oauth({'authUrl': 'https://idp.test/auth', 'audience': '{}'}),
        AuthContext(),
        redirectUri: 'https://cb.test',
      );
      expect(code.queryParameters.containsKey('code_challenge'), isFalse);
      expect(code.queryParameters.containsKey('audience'), isFalse);
    });

    test('a missing auth URL is explained', () {
      expect(
        () =>
            OAuth2.authorizationUrl(_oauth({}), AuthContext(), redirectUri: ''),
        throwsA(isA<AuthException>()),
      );
    });
  });

  group('redirects', () {
    test('query, fragment and bare forms', () {
      final a = OAuth2Redirect.parse('https://cb.test/done?code=abc&state=s1');
      expect(a.code, 'abc');
      expect(a.state, 's1');
      final b = OAuth2Redirect.parse(
        'https://cb.test/#access_token=t%2B1&token_type=bearer&state=s2',
      );
      expect(b.accessToken, 't+1');
      expect(b.state, 's2');
      expect(OAuth2Redirect.parse('?code=c').code, 'c');
      expect(OAuth2Redirect.parse('code=c&state=x').state, 'x');
    });

    test('errors, state mismatches and missing codes are refused', () async {
      final a = _oauth({'grant_type': 'authorization_code'});
      Future<void> complete(String url, {bool strict = false}) =>
          OAuth2.completeRedirect(
            a,
            AuthContext(),
            url,
            redirectUri: 'https://cb.test',
            state: 'good',
            strictState: strict,
          );
      await expectLater(
        complete(
          'https://cb.test/?error=access_denied&error_description=No+thanks',
        ),
        throwsA(
          isA<AuthException>().having(
            (e) => e.message,
            'message',
            contains('access_denied (No thanks)'),
          ),
        ),
      );
      await expectLater(
        complete('https://cb.test/?code=c&state=evil'),
        throwsA(
          isA<AuthException>().having(
            (e) => e.message,
            'message',
            contains('state'),
          ),
        ),
      );
      await expectLater(
        complete('https://cb.test/?code=c', strict: true),
        throwsA(isA<AuthException>()),
      );
      await expectLater(
        complete('https://cb.test/?state=good'),
        throwsA(
          isA<AuthException>().having(
            (e) => e.message,
            'message',
            contains('No authorization code'),
          ),
        ),
      );
    });
  });

  group('applying the token', () {
    test('header prefix: default Bearer, custom, or none', () async {
      for (final (prefix, want) in [
        (null, 'Bearer tok'),
        ('Token', 'Token tok'),
        ('', 'tok'),
      ]) {
        final p = _req;
        await applyAuth(
          p,
          _oauth({
            'grant_type': 'authorization_code',
            'accessToken': 'tok',
            'headerPrefix': ?prefix,
          }),
          AuthContext(),
        );
        expect(p.headers.value('authorization'), want);
      }
    });

    test(
      'a browser grant without a token asks for "Get new access token"',
      () async {
        await expectLater(
          applyAuth(
            _req,
            _oauth({'grant_type': 'authorization_code_with_pkce'}),
            AuthContext(sendRaw: (_) async => ResponseData()),
          ),
          throwsA(
            isA<AuthException>().having(
              (e) => e.message,
              'message',
              contains('Get new access token'),
            ),
          ),
        );
      },
    );

    test('code snippets never fetch or refresh', () async {
      var calls = 0;
      final ctx = AuthContext(
        offline: true,
        sendRaw: (_) async {
          calls++;
          return ResponseData();
        },
      );
      final p = _req;
      await applyAuth(
        p,
        _oauth({
          'grant_type': 'client_credentials',
          'accessTokenUrl': 'https://idp.test/token',
        }),
        ctx,
      );
      expect(p.headers.has('authorization'), isFalse);

      final q = _req;
      await applyAuth(
        q,
        _oauth({
          'grant_type': 'client_credentials',
          'accessToken': 'stale',
          'refreshToken': 'r',
          'expiresAt': '2000-01-01T00:00:00Z',
        }),
        ctx,
      );
      expect(q.headers.value('authorization'), 'Bearer stale');
      expect(calls, 0);
    });

    test(
      'an expired token without refresh is still sent for code grants',
      () async {
        final p = _req;
        await applyAuth(
          p,
          _oauth({
            'grant_type': 'authorization_code',
            'accessToken': 'old',
            'expiresAt': '2000-01-01T00:00:00Z',
          }),
          AuthContext(sendRaw: (_) async => ResponseData()),
        );
        expect(p.headers.value('authorization'), 'Bearer old');
      },
    );
  });

  group('token list', () {
    test('store, pick, clear', () {
      final a = _oauth({});
      final t1 = OAuth2Token(
        accessToken: 'a1',
        refreshToken: 'r1',
        name: 'first',
        expiresAt: DateTime.utc(2030),
      );
      final t2 = OAuth2Token(accessToken: 'a2', name: 'second');
      OAuth2.store(a, t1);
      OAuth2.store(a, t2);
      expect(a.params['accessToken'], 'a2');
      expect(a.params.containsKey('refreshToken'), isFalse);
      expect(OAuth2.saved(a).map((t) => t.name), ['second', 'first']);

      OAuth2.use(a, OAuth2.saved(a)[1]);
      expect(a.params['accessToken'], 'a1');
      expect(a.params['refreshToken'], 'r1');
      expect(OAuth2.expiresAt(a), DateTime.utc(2030));

      OAuth2.clear(a);
      expect(OAuth2.current(a), isNull);
      expect(OAuth2.saved(a), hasLength(2));

      OAuth2.setSaved(a, []);
      expect(a.params.containsKey(OAuth2.savedTokensKey), isFalse);
    });

    test('the list keeps the newest 20', () {
      final a = _oauth({});
      for (var i = 0; i < 25; i++) {
        OAuth2.store(a, OAuth2Token(accessToken: 't$i'));
      }
      final saved = OAuth2.saved(a);
      expect(saved, hasLength(20));
      expect(saved.first.accessToken, 't24');
    });

    test('token responses: expires_in as text, no expiry, extras', () {
      final now = DateTime.utc(2026);
      final t = OAuth2Token.fromResponse({
        'access_token': 'x',
        'expires_in': '120',
        'id_token': 'id',
        'scope': 'a b',
      }, now);
      expect(t.expiresAt, now.add(const Duration(minutes: 2)));
      expect(t.idToken, 'id');
      expect(t.isExpired(now), isFalse);
      expect(t.isExpired(now.add(const Duration(minutes: 2))), isTrue);
      expect(
        OAuth2Token.fromResponse({'access_token': 'y'}, now).expiresAt,
        isNull,
      );
      final round = OAuth2Token.fromJson(t.toJson());
      expect(round.expiresAt, t.expiresAt);
      expect(round.scope, 'a b');
    });

    test('grant names follow Postman', () {
      expect(OAuth2.grant(_oauth({})), OAuth2Grant.authorizationCode);
      expect(
        OAuth2.grant(_oauth({'grant_type': 'password_credentials'})),
        OAuth2Grant.password,
      );
      expect(OAuth2Grant.canAutoFetch(OAuth2Grant.clientCredentials), isTrue);
      expect(OAuth2Grant.usesBrowser(OAuth2Grant.implicit), isTrue);
    });
  });
}
