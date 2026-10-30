import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/console_events.dart';
import 'package:api_workbench/services/cookie_store.dart';
import 'package:api_workbench/services/executor.dart';
import 'package:api_workbench/services/http_service.dart';
import 'package:api_workbench/services/request_builder.dart';
import 'package:api_workbench/services/runner.dart';
import 'package:api_workbench/services/scripting/script_engine.dart';
import 'package:api_workbench/services/var_scopes.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records what a local server saw.
class Seen {
  Seen(this.method, this.path, this.query, this.headers, this.body);
  final String method;
  final String path;
  final String query;
  final HttpHeaders headers;
  final String body;
}

/// Returns a scripted outcome per phase, for executor and runner tests.
class FakeEngine implements ScriptEngine {
  FakeEngine(this.onRun);
  final ScriptOutcome Function(List<ScriptSource>, ScriptContext) onRun;
  final runs = <List<String>>[];

  @override
  Future<ScriptOutcome> run(
    List<ScriptSource> scripts,
    ScriptContext ctx,
  ) async {
    runs.add([for (final s in scripts) s.origin]);
    return onRun(scripts, ctx);
  }

  @override
  void dispose() {}
}

void main() {
  late HttpServer server;
  late HttpServer other;
  late String base;
  late String otherBase;
  final seen = <Seen>[];

  setUp(() async {
    seen.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    otherBase = 'http://127.0.0.1:${other.port}';
    Future<void> handle(HttpRequest req) async {
      final body = await utf8.decoder.bind(req).join();
      seen.add(
        Seen(req.method, req.uri.path, req.uri.query, req.headers, body),
      );
      final res = req.response;
      switch (req.uri.path) {
        case '/redirect':
          res.statusCode = int.parse(req.uri.queryParameters['code'] ?? '302');
          res.headers.set('location', req.uri.queryParameters['to'] ?? '/echo');
        case '/loop':
          res.statusCode = 302;
          res.headers.set('location', '/loop');
        case '/login':
          res.cookies.add(Cookie('session', 'abc')..path = '/');
          res.statusCode = 302;
          res.headers.set('location', '/me');
        case '/challenge':
          res.statusCode = 401;
        default:
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({'method': req.method, 'body': body}));
      }
      await res.close();
    }

    server.listen(handle);
    other.listen(handle);
  });

  tearDown(() async {
    await server.close(force: true);
    await other.close(force: true);
  });

  group('request building', () {
    test('GET sends its body; HEAD never does', () async {
      final http = HttpService();
      addTearDown(http.dispose);
      final res = await http.send(
        RequestModel(
          url: '$base/echo',
          bodyType: BodyType.json,
          body: '{"q":"{{term}}"}',
        ),
        {'term': 'flutter'},
        tabId: 't',
      );
      expect(res.error, isNull);
      expect(seen.single.method, 'GET');
      expect(seen.single.body, '{"q":"flutter"}');
      expect(seen.single.headers.contentType?.mimeType, 'application/json');

      await http.send(
        RequestModel(
          method: 'HEAD',
          url: '$base/echo',
          bodyType: BodyType.text,
          body: 'nope',
        ),
        const {},
        tabId: 't',
      );
      expect(seen.last.method, 'HEAD');
      expect(seen.last.body, isEmpty);
    });

    test('path variables are filled in and encoded', () async {
      final r = RequestModel(
        url: '{{base}}/users/:id/posts/:slug?x=1',
        pathVariables: [
          KV(key: 'id', value: '{{uid}}'),
          KV(key: 'slug', value: 'a b/c'),
        ],
      );
      final p = await buildRequest(r, {'base': base, 'uid': '42'});
      expect(p.url.path, '/users/42/posts/a%20b%2Fc');
      expect(p.url.query, 'x=1');
      expect(pathVariableNames('https://h:8080/a/:x/b/:y?z=:w'), ['x', 'y']);
    });

    test('param rows keep existing %XX and encode the rest', () async {
      final r = RequestModel(
        url: 'https://h/s?raw=a%2Bb',
        params: [
          KV(key: 'q', value: 'a b&c'),
          KV(key: 'pre', value: '50%25'),
          KV(key: 'off', value: 'x', enabled: false),
        ],
      );
      final p = await buildRequest(r, const {});
      expect(p.url.query, 'raw=a%2Bb&q=a%20b%26c&pre=50%25');
    });

    test('empty and invalid URLs give readable errors', () async {
      final http = HttpService();
      addTearDown(http.dispose);
      expect(
        (await http.send(RequestModel(), const {}, tabId: 't')).error,
        'Request URL is empty.',
      );
    });
  });

  group('redirects', () {
    test('302 after POST becomes a bodiless GET; 307 keeps both', () async {
      final http = HttpService();
      addTearDown(http.dispose);
      final post = RequestModel(
        method: 'POST',
        url: '$base/redirect?code=302',
        bodyType: BodyType.text,
        body: 'payload',
      );
      final res = await http.send(post, const {}, tabId: 't');
      expect(res.statusCode, 200);
      expect(seen.map((s) => s.method), ['POST', 'GET']);
      expect(seen.last.body, isEmpty);
      expect(res.finalUrl, '$base/echo');

      seen.clear();
      post.url = '$base/redirect?code=307';
      await http.send(post, const {}, tabId: 't');
      expect(seen.map((s) => s.method), ['POST', 'POST']);
      expect(seen.last.body, 'payload');
    });

    test('Authorization is dropped when the origin changes', () async {
      final http = HttpService();
      addTearDown(http.dispose);
      final r = RequestModel(
        url: '$base/redirect?to=${Uri.encodeQueryComponent('$otherBase/echo')}',
        authType: AuthType.bearer,
        bearerToken: 'secret',
      );
      await http.send(r, const {}, tabId: 't');
      expect(seen.first.headers.value('authorization'), 'Bearer secret');
      expect(seen.last.headers.value('authorization'), isNull);

      seen.clear();
      r.settings.followAuthorizationHeader = true;
      await http.send(r, const {}, tabId: 't');
      expect(seen.last.headers.value('authorization'), 'Bearer secret');
    });

    test('per-request settings: off returns the 3xx; a loop stops', () async {
      final http = HttpService();
      addTearDown(http.dispose);
      final r = RequestModel(
        url: '$base/redirect',
        settings: RequestSettings(followRedirects: false),
      );
      final res = await http.send(r, const {}, tabId: 't');
      expect(res.statusCode, 302);
      expect(seen, hasLength(1));

      final loop = await http.send(
        RequestModel(
          url: '$base/loop',
          settings: RequestSettings(maxRedirects: 3),
        ),
        const {},
        tabId: 't',
      );
      expect(loop.error, contains('3 redirects'));
      expect(seen, hasLength(1 + 4));
    });

    test('cookies set on a redirect reach the next hop', () async {
      final http = HttpService()..cookieJar = PersistentCookieJar();
      addTearDown(http.dispose);
      final res = await http.send(
        RequestModel(url: '$base/login'),
        const {},
        tabId: 't',
      );
      expect(res.statusCode, 200);
      expect(seen.last.path, '/me');
      expect(seen.last.headers.value('cookie'), 'session=abc');

      // A request that opts out sends none.
      await http.send(
        RequestModel(
          url: '$base/echo',
          settings: RequestSettings(useCookies: false),
        ),
        const {},
        tabId: 't',
      );
      expect(seen.last.headers.value('cookie'), isNull);
    });

    test('every hop is reported to the console stream', () async {
      final http = HttpService();
      addTearDown(http.dispose);
      final records = <ExchangeRecord>[];
      final sub = http.exchanges.listen(records.add);
      addTearDown(sub.cancel);
      await http.send(
        RequestModel(url: '$base/redirect'),
        const {},
        tabId: 't',
      );
      await http.send(
        RequestModel(url: '$base/echo'),
        const {},
        tabId: 't',
        record: false,
      );
      await Future<void>.delayed(Duration.zero);
      expect(records.map((r) => r.hop), [0, 1]);
      expect(records.map((r) => r.status), [302, 200]);
      expect(records.last.responseBody, isNotEmpty);
    });
  });

  group('variables', () {
    test('scopes resolve in Postman order and writes set current values', () {
      final globals = [KV(key: 'a', value: 'g'), KV(key: 'g', value: 'g')];
      final collection = [KV(key: 'a', value: 'c'), KV(key: 'c', value: 'c')];
      final env = [KV(key: 'a', value: 'e')];
      final scopes = VarScopes(
        globals: globals,
        collection: collection,
        environment: env,
        data: {'d': 'row'},
      );
      expect(scopes.resolve(), {'a': 'e', 'g': 'g', 'c': 'c', 'd': 'row'});

      scopes.set(VarScope.environment, 'a', 'new');
      expect(env.single.value, 'e', reason: 'initial value untouched');
      expect(env.single.current, 'new');
      expect(scopes.resolve()['a'], 'new');
      expect(scopes.environmentChanged, isTrue);

      scopes.set(VarScope.globals, 'fresh', '1');
      expect(globals.last.value, '');
      expect(globals.last.effective, '1');

      scopes.set(VarScope.local, 'a', 'local');
      expect(scopes.resolve()['a'], 'local');
    });

    test('captures go to the environment, else collection, else session', () {
      final col = <KV>[];
      final s1 = VarScopes(collection: col);
      s1.capture({'token': 't1'});
      expect(col.single.effective, 't1');

      final session = <String, String>{};
      VarScopes(session: session).capture({'token': 't2'});
      expect(session, {'token': 't2'});
    });

    test('KV keeps secret, current and description through JSON', () {
      final kv = KV(key: 'k', value: 'v', secret: true, current: 'c');
      final back = KV.fromJson(kv.toJson());
      expect(back.secret, isTrue);
      expect(back.current, 'c');
      expect(KV.fromJson(KV(key: 'k').toJson()).current, isNull);
    });
  });

  group('models', () {
    test('new request and collection fields round-trip', () {
      final r = RequestModel(
        kind: RequestKind.websocket,
        url: 'wss://x',
        pathVariables: [KV(key: 'id', value: '1')],
        authType: AuthType.oauth2,
        authParams: {'accessToken': 'abc', 'grant_type': 'client_credentials'},
        settings: RequestSettings(followRedirects: false, timeoutMs: 500),
        examples: [ResponseExample(name: 'ok', body: '{}')],
        protocolConfig: {
          'messages': ['hi'],
        },
      );
      final back = RequestModel.fromJson(
        jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>,
      );
      expect(back.kind, RequestKind.websocket);
      expect(back.pathVariables.single.value, '1');
      expect(back.authType, AuthType.oauth2);
      expect(back.auth.params['accessToken'], 'abc');
      expect(back.settings.followRedirects, isFalse);
      expect(back.settings.timeoutMs, 500);
      expect(back.examples.single.name, 'ok');
      expect(back.protocolConfig['messages'], ['hi']);

      final c = CollectionModel(
        name: 'C',
        auth: AuthConfig(type: AuthType.bearer, bearerToken: 't'),
        preRequestScript: 'pre',
        folders: {'a/b': FolderMeta(description: 'd')},
      );
      final cb = CollectionModel.fromJson(
        jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>,
      );
      expect(cb.auth.bearerToken, 't');
      expect(cb.preRequestScript, 'pre');
      expect(cb.folders['a/b']!.description, 'd');
      expect(cb.folders['a/b']!.auth.type, AuthType.inherit);
    });

    test('old saved requests load with defaults', () {
      final r = RequestModel.fromJson({
        'id': 'x',
        'url': 'https://h',
        'authType': 'bearer',
        'bearerToken': 't',
      });
      expect(r.kind, RequestKind.http);
      expect(r.auth.type, AuthType.bearer);
      expect(r.settings.isDefault, isTrue);
      expect(r.examples, isEmpty);
    });
  });

  group('executor', () {
    test('inherit resolves folder auth before collection auth', () async {
      final http = HttpService();
      addTearDown(http.dispose);
      final col = CollectionModel(
        name: 'C',
        auth: AuthConfig(type: AuthType.bearer, bearerToken: 'col'),
        folders: {
          'a': FolderMeta(
            auth: AuthConfig(
              type: AuthType.apiKey,
              apiKeyName: 'X-Key',
              apiKeyValue: 'folder',
            ),
          ),
        },
      );
      final exec = RequestExecutor(http);
      await exec.execute(
        RequestModel(
          url: '$base/echo',
          folder: 'a/b',
          authType: AuthType.inherit,
        ),
        ExecContext(scopes: VarScopes(), collection: col),
      );
      expect(seen.last.headers.value('x-key'), 'folder');
      await exec.execute(
        RequestModel(url: '$base/echo', authType: AuthType.inherit),
        ExecContext(scopes: VarScopes(), collection: col),
      );
      expect(seen.last.headers.value('authorization'), 'Bearer col');
    });

    test('scripts run collection → folder → request around the send', () async {
      final http = HttpService();
      addTearDown(http.dispose);
      final engine = FakeEngine((scripts, ctx) {
        if (ctx.phase == ScriptPhase.preRequest) {
          ctx.request.headers.add(KV(key: 'X-Pre', value: '1'));
          ctx.scopes.set(VarScope.local, 'v', 'from-script');
          return ScriptOutcome();
        }
        return ScriptOutcome(
          tests: [ScriptTestResult('status', ctx.response!.statusCode == 200)],
        );
      });
      final col = CollectionModel(
        name: 'C',
        preRequestScript: '//c',
        testScript: '//c',
        folders: {'f': FolderMeta(preRequestScript: '//f')},
      );
      final req = RequestModel(
        url: '$base/echo?v={{v}}',
        folder: 'f',
        preRequestScript: '//r',
        testScript: '//r',
      );
      final result = await RequestExecutor(
        http,
        engine: engine,
      ).execute(req, ExecContext(scopes: VarScopes(), collection: col));
      expect(engine.runs.first, [
        'Collection C',
        'Folder f',
        'Request Untitled request',
      ]);
      expect(seen.last.headers.value('x-pre'), '1');
      expect(seen.last.query, 'v=from-script');
      expect(req.headers, isEmpty, reason: 'the saved request is untouched');
      expect(result.scriptTests.single.pass, isTrue);
      expect(result.pass, isTrue);
    });

    test('a failing pre-request script stops the send', () async {
      final http = HttpService();
      addTearDown(http.dispose);
      final engine = FakeEngine((_, _) => ScriptOutcome(error: 'boom'));
      final result = await RequestExecutor(http, engine: engine).execute(
        RequestModel(url: '$base/echo', preRequestScript: 'throw 1'),
        ExecContext(scopes: VarScopes()),
      );
      expect(seen, isEmpty);
      expect(result.response.error, contains('boom'));
      expect(result.pass, isFalse);
    });

    test('runner follows setNextRequest and stops on null', () async {
      final http = HttpService();
      final engine = FakeEngine((_, ctx) {
        if (ctx.phase != ScriptPhase.test) return ScriptOutcome();
        return switch (ctx.info.requestName) {
          'A' => ScriptOutcome(next: const NextRequest.named('C')),
          'C' => ScriptOutcome(next: const NextRequest.stop()),
          _ => ScriptOutcome(),
        };
      });
      final runner = RunnerService(http, engine: engine);
      addTearDown(runner.dispose);
      RequestModel req(String name) =>
          RequestModel(name: name, url: '$base/$name', testScript: '//');
      await runner.start(requests: [req('A'), req('B'), req('C'), req('D')]);
      expect(seen.map((s) => s.path), ['/A', '/C']);
      expect(runner.passed, 2);
    });
  });
}
