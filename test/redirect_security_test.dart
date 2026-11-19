import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/auth/auth.dart';
import 'package:api_workbench/services/cookie_store.dart';
import 'package:api_workbench/services/http_service.dart';
import 'package:api_workbench/services/protocols/live_connection.dart';
import 'package:api_workbench/services/redirect_policy.dart';
import 'package:api_workbench/services/request_builder.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/temp_dir.dart';

/// What one of the local servers saw.
class Hit {
  Hit(this.server, this.method, this.path, this.headers);
  final String server;
  final String method;
  final String path;

  /// Lower-case name → values joined with `, ` (Cookie with `; `).
  final Map<String, String> headers;

  String? operator [](String name) => headers[name.toLowerCase()];
}

String fx(String name) => '${Directory.current.path}/test/fixtures/certs/$name';

/// An NTLM CHALLENGE_MESSAGE (type 2) a client could answer.
String ntlmChallenge() {
  final b = BytesBuilder()
    ..add(ascii.encode('NTLMSSP'))
    ..addByte(0)
    ..add([2, 0, 0, 0])
    ..add([0, 0, 0, 0, 48, 0, 0, 0])
    ..add([0x35, 0x82, 0x8a, 0xe2])
    ..add(List.filled(8, 7))
    ..add(Uint8List(8))
    ..add([0, 0, 0, 0, 48, 0, 0, 0]);
  return base64.encode(b.toBytes());
}

void main() {
  final hits = <Hit>[];
  late HttpServer a;
  late HttpServer b;
  late String aBase;
  late String bBase;

  Future<void> handle(String name, HttpRequest req) async {
    final headers = <String, String>{};
    req.headers.forEach((k, v) {
      headers[k.toLowerCase()] = v.join(
        k.toLowerCase() == 'cookie' ? '; ' : ', ',
      );
    });
    await req.drain<void>();
    hits.add(Hit(name, req.method, req.uri.path, headers));
    final res = req.response;
    final q = req.uri.queryParameters;
    switch (req.uri.path) {
      case '/to':
        res.statusCode = int.parse(q['code'] ?? '302');
        res.headers.set('location', q['u']!);
      case '/setcookie':
        res.cookies.add(Cookie('sid', name)..path = '/');
      case '/challenge':
        res.statusCode = 401;
        res.headers
          ..add(
            'www-authenticate',
            'Digest realm="r", qop="auth", nonce="abc", opaque="o"',
          )
          ..add('www-authenticate', 'NTLM ${ntlmChallenge()}');
      case '/sse':
        res.headers.contentType = ContentType('text', 'event-stream');
        res.bufferOutput = false;
        res.write('data: from $name\n\n');
        await res.flush();
        await Future<void>.delayed(const Duration(seconds: 30));
      default:
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({'server': name}));
    }
    await res.close();
  }

  setUp(() async {
    hits.clear();
    a = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    b = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // Different ports are different origins.
    aBase = 'http://127.0.0.1:${a.port}';
    bBase = 'http://127.0.0.1:${b.port}';
    a.listen((r) => handle('a', r));
    b.listen((r) => handle('b', r));
  });

  tearDown(() async {
    await a.close(force: true);
    await b.close(force: true);
  });

  String to(String target, {int code = 302}) =>
      '$aBase/to?code=$code&u=${Uri.encodeQueryComponent(target)}';

  Future<ResponseData> send(
    RequestModel r, {
    HttpService? http,
    Map<String, String> vars = const {},
  }) async {
    final svc = http ?? HttpService();
    if (http == null) addTearDown(svc.dispose);
    return svc.send(r, vars, tabId: 't', record: false);
  }

  List<KV> credentialRows() => [
    KV(key: 'X-API-Key', value: 'k-123'),
    KV(key: 'Proxy-Authorization', value: 'Basic cHJveHk6cHc='),
    KV(key: 'Cookie', value: 'hand=typed'),
    KV(key: 'X-Amz-Security-Token', value: 'session-token'),
    KV(key: 'X-Request-Id', value: 'req-1'),
    KV(key: 'Accept', value: 'application/json'),
    KV(key: 'Idempotency-Key', value: 'idem-1'),
  ];

  group('redirect to another origin', () {
    test('drops every credential and keeps the other headers', () async {
      final res = await send(
        RequestModel(
          url: to('$bBase/echo'),
          headers: credentialRows(),
          authType: AuthType.bearer,
          bearerToken: 'tok',
        ),
      );
      expect(res.statusCode, 200);
      expect(hits.map((h) => h.server), ['a', 'b']);
      final first = hits[0];
      expect(first['authorization'], 'Bearer tok');
      expect(first['x-api-key'], 'k-123');
      expect(first['proxy-authorization'], isNotNull);
      expect(first['cookie'], 'hand=typed');
      expect(first['x-amz-security-token'], 'session-token');

      final second = hits[1];
      for (final name in [
        'authorization',
        'x-api-key',
        'proxy-authorization',
        'cookie',
        'x-amz-security-token',
      ]) {
        expect(second[name], isNull, reason: name);
      }
      expect(second['x-request-id'], 'req-1');
      expect(second['accept'], 'application/json');
      expect(second['idempotency-key'], 'idem-1');
    });

    test('a same-origin redirect keeps them', () async {
      await send(
        RequestModel(
          url: to('/echo'),
          headers: credentialRows(),
          authType: AuthType.bearer,
          bearerToken: 'tok',
        ),
      );
      expect(hits.map((h) => h.server), ['a', 'a']);
      final second = hits[1];
      expect(second['authorization'], 'Bearer tok');
      expect(second['x-api-key'], 'k-123');
      expect(second['proxy-authorization'], isNotNull);
      expect(second['cookie'], 'hand=typed');
      expect(second['x-amz-security-token'], 'session-token');
    });

    test('credentials stay dropped when a later hop comes back', () async {
      // a -> b -> a: nothing the helper set reaches b, and b cannot send
      // the request back to a to have them re-added on its behalf.
      final back = '$bBase/to?u=${Uri.encodeQueryComponent('$aBase/echo')}';
      await send(
        RequestModel(
          url: to(back),
          authType: AuthType.apiKey,
          apiKeyName: 'X-Tenant',
          apiKeyValue: 'secret',
        ),
      );
      expect(hits.map((h) => h.server), ['a', 'b', 'a']);
      expect(hits[0]['x-tenant'], 'secret');
      expect(hits[1]['x-tenant'], isNull);
      expect(hits[2]['x-tenant'], isNull);
    });

    test('the API key helper header is dropped whatever its name', () async {
      expect(isCredentialHeaderName('X-Tenant'), isFalse);
      RequestModel r(String url) => RequestModel(
        url: url,
        authType: AuthType.apiKey,
        apiKeyName: 'X-Tenant',
        apiKeyValue: 'secret',
      );
      await send(r(to('$bBase/echo')));
      expect(hits[0]['x-tenant'], 'secret');
      expect(hits[1]['x-tenant'], isNull);

      hits.clear();
      await send(r(to('/echo')));
      expect(hits[1]['x-tenant'], 'secret');
    });

    test('AWS Signature headers are dropped', () async {
      RequestModel r(String url) => RequestModel(
        url: url,
        authType: AuthType.awsV4,
        authParams: {
          'accessKey': 'AKIDEXAMPLE',
          'secretKey': 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
          'sessionToken': 'the-session',
          'region': 'us-east-1',
          'service': 's3',
        },
      );
      await send(r(to('$bBase/echo')));
      const amz = [
        'authorization',
        'x-amz-date',
        'x-amz-security-token',
        'x-amz-content-sha256',
      ];
      for (final name in amz) {
        expect(hits[0][name], isNotNull, reason: name);
        expect(hits[1][name], isNull, reason: name);
      }

      hits.clear();
      await send(r(to('/echo')));
      for (final name in amz) {
        expect(hits[1][name], isNotNull, reason: name);
      }
    });

    test('cookie jar on: each origin gets its own cookies only', () async {
      final http = HttpService()..cookieJar = PersistentCookieJar();
      addTearDown(http.dispose);
      // localhost and 127.0.0.1 are different cookie hosts.
      final bLocal = 'http://localhost:${b.port}';
      await send(RequestModel(url: '$aBase/setcookie'), http: http);
      await send(RequestModel(url: '$bLocal/setcookie'), http: http);
      hits.clear();

      await send(
        RequestModel(
          url: to('$bLocal/echo'),
          headers: [KV(key: 'Cookie', value: 'hand=typed')],
        ),
        http: http,
      );
      expect(hits.map((h) => h.server), ['a', 'b']);
      expect(hits[0]['cookie'], 'hand=typed; sid=a');
      expect(hits[1]['cookie'], 'sid=b');
    });

    test(
      'cookie jar off: a typed Cookie header stays with its origin',
      () async {
        await send(
          RequestModel(
            url: to('$bBase/echo'),
            headers: [KV(key: 'Cookie', value: 'hand=typed')],
            settings: RequestSettings(useCookies: false),
          ),
        );
        expect(hits[0]['cookie'], 'hand=typed');
        expect(hits[1]['cookie'], isNull);
      },
    );

    test('"Keep Authorization" keeps that header alone', () async {
      await send(
        RequestModel(
          url: to('$bBase/echo', code: 307),
          headers: credentialRows(),
          authType: AuthType.bearer,
          bearerToken: 'tok',
          settings: RequestSettings(followAuthorizationHeader: true),
        ),
      );
      final second = hits[1];
      expect(second['authorization'], 'Bearer tok');
      expect(second['x-api-key'], isNull);
      expect(second['cookie'], isNull);
      expect(second['proxy-authorization'], isNull);
    });

    test('https to http drops Authorization even when kept', () async {
      final ctx = SecurityContext()
        ..useCertificateChain(fx('server.pem'))
        ..usePrivateKey(fx('server.key'));
      final tls = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        ctx,
      );
      addTearDown(() => tls.close(force: true));
      tls.listen((r) => handle('tls', r));
      final res = await send(
        RequestModel(
          url:
              'https://127.0.0.1:${tls.port}/to?u='
              '${Uri.encodeQueryComponent('$aBase/echo')}',
          authType: AuthType.bearer,
          bearerToken: 'tok',
          settings: RequestSettings(
            verifySsl: false,
            followAuthorizationHeader: true,
          ),
        ),
      );
      expect(res.error, isNull);
      expect(hits.map((h) => h.server), ['tls', 'a']);
      expect(hits[0]['authorization'], 'Bearer tok');
      expect(hits[1]['authorization'], isNull);
    });

    test('the decision: downgrades and other origins', () {
      final https = Uri.parse('https://api.example.com/a');
      const keep = RedirectCredentialPolicy(keepAuthorization: true);
      const strict = RedirectCredentialPolicy(authHeaders: {'x-tenant'});
      bool drops(RedirectCredentialPolicy p, String name, Uri from, Uri to) =>
          p.namesToDrop([MapEntry(name, 'v')], from: from, to: to).isNotEmpty;

      final down = Uri.parse('http://api.example.com/a');
      final other = Uri.parse('https://other.example.com/a');
      final port = Uri.parse('https://api.example.com:8443/a');
      final same = Uri.parse('https://API.example.com:443/b');
      expect(isDowngrade(https, down), isTrue);
      expect(drops(keep, 'Authorization', https, down), isTrue);
      expect(drops(keep, 'Authorization', https, other), isFalse);
      expect(drops(keep, 'Cookie', https, other), isTrue);
      expect(drops(strict, 'Authorization', https, other), isTrue);
      expect(drops(strict, 'X-Tenant', https, port), isTrue);
      expect(drops(strict, 'X-Trace', https, other), isFalse);
      expect(drops(strict, 'Authorization', https, same), isFalse);
      // http -> https on the same host is another origin too.
      expect(drops(strict, 'Authorization', down, https), isTrue);
    });

    test('credential header names', () {
      for (final n in [
        'Authorization',
        'proxy-authorization',
        'Cookie',
        'X-API-Key',
        'apikey',
        'X-Auth-Token',
        'Private-Token',
        'X-Amz-Date',
        'Ocp-Apim-Subscription-Key',
        'X-CSRF-Token',
        'X-Client-Secret',
      ]) {
        expect(isCredentialHeaderName(n), isTrue, reason: n);
      }
      for (final n in [
        'Accept',
        'Content-Type',
        'X-Request-Id',
        'Idempotency-Key',
        'User-Agent',
        'Referer',
      ]) {
        expect(isCredentialHeaderName(n), isFalse, reason: n);
      }
    });
  });

  group('auth challenges', () {
    for (final type in [AuthType.digest, AuthType.ntlm]) {
      test('a 401 from another origin is returned (${type.name})', () async {
        final res = await send(
          RequestModel(
            url: to('$bBase/challenge'),
            authType: type,
            authParams: {'username': 'ada', 'password': 's3cret'},
          ),
        );
        expect(res.statusCode, 401);
        final atB = hits.where((h) => h.server == 'b').toList();
        expect(atB, hasLength(1));
        expect(atB.single['authorization'], isNull);
      });
    }

    test('a 401 from the configured origin is answered', () async {
      final res = await send(
        RequestModel(
          url: '$aBase/challenge',
          authType: AuthType.digest,
          authParams: {'username': 'ada', 'password': 's3cret'},
        ),
      );
      expect(res.statusCode, 401);
      expect(hits, hasLength(2));
      expect(hits[1]['authorization'], startsWith('Digest '));
    });

    test('applyAuth and retryAfterChallenge report what they set', () async {
      final ctx = AuthContext();
      final p = PreparedRequest(method: 'GET', url: Uri.parse('$aBase/x'))
        ..headers.add('X-Trace', '1');
      await applyAuth(
        p,
        AuthConfig(
          type: AuthType.apiKey,
          apiKeyName: 'X-Tenant',
          apiKeyValue: 'v',
        ),
        ctx,
      );
      expect(ctx.authHeaders, {'x-tenant'});

      final digest = AuthConfig(
        type: AuthType.digest,
        params: {'username': 'u', 'password': 'p'},
      );
      final retry = await retryAfterChallenge(
        p,
        ResponseData(
          statusCode: 401,
          headers: {
            'www-authenticate': ['Digest realm="r", nonce="n"'],
          },
        ),
        digest,
        ctx,
      );
      expect(retry, isNotNull);
      expect(ctx.authHeaders, {'x-tenant', 'authorization'});
    });
  });

  group('Location that cannot be followed', () {
    for (final location in [
      'file:///etc/passwd',
      'ftp://127.0.0.1/file',
      'gopher://127.0.0.1/',
      'mailto:someone@example.com',
      'javascript:alert(1)',
      'http:',
      'https:///no-host',
      'http://[not-an-address',
    ]) {
      test('"$location" returns the 3xx', () async {
        final res = await send(RequestModel(url: to(location)));
        expect(res.error, isNull);
        expect(res.statusCode, 302);
        expect(hits, hasLength(1));
      });
    }

    test('redirectTarget resolves relative and protocol-relative ones', () {
      final from = Uri.parse('https://api.example.com/a/b?q=1');
      expect(
        redirectTarget(from, '/c').toString(),
        'https://api.example.com/c',
      );
      expect(
        redirectTarget(from, '//cdn.example.com/x').toString(),
        'https://cdn.example.com/x',
      );
      expect(
        redirectTarget(from, 'HTTP://Other.example/').toString(),
        'http://other.example/',
      );
      expect(redirectTarget(from, 'data:text/plain,hi'), isNull);
    });

    test('the send path never leaves a tab loading', () async {
      final dir = await Directory.systemTemp.createTemp('aw_redirect_state');
      final storage = Storage(overrideDir: dir);
      final state = AppState(storage: storage);
      addTearDown(() async {
        await state.flushPending();
        await storage.flush();
        await deleteTempDir(dir);
      });
      while (!state.loaded) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final tab = state.activeTab!;
      tab.request.url = to('gopher://127.0.0.1/');
      await state.sendActive();
      expect(tab.loading, isFalse);
      expect(tab.response?.statusCode, 302);
    });
  });

  group('URL schemes', () {
    test('buildUrl accepts http and https only', () {
      Uri build(String url) => buildUrl(RequestModel(url: url), const {});
      for (final url in [
        'file:///etc/passwd',
        'FILE://localhost/etc/passwd',
        'ftp://example.com/x',
        'gopher://example.com/',
        'dict://example.com/',
        'ws://example.com/',
      ]) {
        expect(
          () => build(url),
          throwsA(
            isA<RequestBuildException>().having(
              (e) => e.message,
              'message',
              contains('Only http:// and https://'),
            ),
          ),
          reason: url,
        );
      }
      expect(build('http://example.com/').scheme, 'http');
      expect(build('HTTPS://example.com/').scheme, 'https');
      expect(build('example.com/x').scheme, 'https');
      // Live protocols check their own schemes.
      expect(
        buildUrl(
          RequestModel(url: 'wss://example.com/'),
          const {},
          schemes: null,
        ).scheme,
        'wss',
      );
    });

    test('sending a file: URL is an error, not a read', () async {
      final f = File('${Directory.systemTemp.path}/aw-scheme-probe.txt')
        ..writeAsStringSync('local secret');
      addTearDown(() => f.deleteSync());
      final res = await send(RequestModel(url: Uri.file(f.path).toString()));
      expect(res.error, contains('Only http:// and https://'));
      expect(res.bodyBytes, isEmpty);
    });

    test('WebSocket URLs still resolve', () {
      final uri = resolveUrl(
        RequestModel(url: 'ws://127.0.0.1:1/socket'),
        const {},
        plain: 'ws',
        secure: 'wss',
        allowed: const {'ws', 'wss'},
        map: const {'http': 'ws', 'https': 'wss'},
        what: 'WebSocket',
      );
      expect(uri.scheme, 'ws');
    });
  });
}
