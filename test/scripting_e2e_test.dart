import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/executor.dart';
import 'package:api_workbench/services/http_service.dart';
import 'package:api_workbench/services/runner.dart';
import 'package:api_workbench/services/scripting/engine_factory.dart';
import 'package:api_workbench/services/scripting/script_engine.dart';
import 'package:api_workbench/services/var_scopes.dart';
import 'package:flutter_test/flutter_test.dart';

/// pm.sendRequest, RequestExecutor and RunnerService with the real engine
/// against a local server.
void main() {
  late HttpServer server;
  late String base;
  late ScriptEngine engine;
  final seen = <Map<String, Object?>>[];

  setUpAll(() async {
    engine = createScriptEngine()!;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final body = await utf8.decodeStream(req);
      final headers = <String, String>{};
      req.headers.forEach((k, v) => headers[k] = v.join(', '));
      final record = {
        'method': req.method,
        'path': req.uri.path,
        'query': req.uri.queryParameters,
        'headers': headers,
        'body': body,
      };
      seen.add(record);
      final res = req.response;
      switch (req.uri.path) {
        case '/token':
          res.headers.contentType = ContentType.json;
          res.write(
            jsonEncode({'token': 'tok-${req.uri.queryParameters['n'] ?? '1'}'}),
          );
        case '/slow':
          await Future<void>.delayed(const Duration(milliseconds: 300));
          res.write('slow');
        case '/status/404':
          res.statusCode = 404;
          res.write('missing');
        default:
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode(record));
      }
      await res.close();
    });
  });

  tearDownAll(() async {
    engine.dispose();
    await server.close(force: true);
  });

  setUp(seen.clear);

  ScriptContext ctx({
    required VarScopes scopes,
    Future<ResponseData> Function(RequestModel)? send,
    int timeoutMs = 5000,
  }) => ScriptContext(
    phase: ScriptPhase.preRequest,
    request: RequestModel(name: 'R'),
    scopes: scopes,
    info: const ScriptInfo(requestName: 'R', requestId: 'r'),
    sendRequest: send,
    timeoutMs: timeoutMs,
  );

  group('pm.sendRequest', () {
    late HttpService http;
    setUp(() => http = HttpService());
    tearDown(() => http.dispose());

    Future<ResponseData> Function(RequestModel) sender(VarScopes scopes) =>
        (r) => http.send(r, scopes.resolve(), tabId: 'test', record: false);

    test('callback and promise forms, JSON and form bodies', () async {
      final scopes = VarScopes(session: {'base': base});
      final out = await engine.run([
        ScriptSource(r'''
          await new Promise((done) => pm.sendRequest(pm.variables.get('base') + '/token?n=7', (err, res) => {
            pm.test('callback', () => {
              pm.expect(err).to.equal(null);
              pm.expect(res.code).to.equal(200);
              pm.expect(res.json().token).to.equal('tok-7');
              res.to.have.status(200);
              res.to.have.header('content-type');
            });
            // Written before the next request is built: {{token}} resolves.
            pm.environment.set('token', res.json().token);
            done();
          }));
          const echo = await pm.sendRequest({
            url: '{{base}}/echo',
            method: 'POST',
            header: {'Content-Type': 'application/json', 'X-Token': '{{token}}'},
            body: {mode: 'raw', raw: JSON.stringify({hello: 'world'})},
          });
          pm.test('promise', () => {
            const e = echo.json();
            pm.expect(e.method).to.equal('POST');
            pm.expect(JSON.parse(e.body)).to.deep.equal({hello: 'world'});
            pm.expect(e.headers['x-token']).to.equal('tok-7');
          });
          const form = await pm.sendRequest({
            url: pm.variables.get('base') + '/echo',
            method: 'POST',
            header: [{key: 'X-A', value: '1'}],
            body: {mode: 'urlencoded', urlencoded: [{key: 'a', value: 'b c'}, {key: 'x', value: '1', disabled: true}]},
          });
          pm.test('urlencoded', () => {
            pm.expect(form.json().body).to.equal('a=b+c');
            pm.expect(form.json().headers['content-type']).to.include('x-www-form-urlencoded');
          });
          const notFound = await pm.sendRequest(pm.variables.get('base') + '/status/404');
          pm.test('4xx is a response, not an error', () => {
            pm.expect(notFound.code).to.equal(404);
            pm.expect(notFound.status).to.equal('Not Found');
          });
        ''', 'Request R'),
      ], ctx(scopes: scopes, send: sender(scopes)));
      expect(out.error, isNull);
      expect(out.tests.length, 4);
      for (final t in out.tests) {
        expect(t.pass, isTrue, reason: '${t.name}: ${t.error}');
      }
      expect(scopes.session['token'], 'tok-7');
      expect(seen.map((s) => s['path']), [
        '/token',
        '/echo',
        '/echo',
        '/status/404',
      ]);
    });

    test(
      'requests run in parallel; transport errors reach the script',
      () async {
        final scopes = VarScopes(session: {'base': base});
        final sw = Stopwatch()..start();
        final out = await engine.run([
          ScriptSource('''
          const b = pm.variables.get('base');
          const all = await Promise.all([1, 2, 3].map(() => pm.sendRequest(b + '/slow')));
          pm.test('all', () => pm.expect(all.map(r => r.text())).to.deep.equal(['slow', 'slow', 'slow']));
          try {
            await pm.sendRequest('http://127.0.0.1:1/closed');
            pm.test('refused', () => { throw new Error('no error'); });
          } catch (e) {
            pm.test('refused', () => pm.expect(e).to.be.an('error'));
          }
          pm.sendRequest('http://127.0.0.1:1/closed', (err, res) => {
            pm.test('callback error', () => { pm.expect(err).to.be.an('error'); pm.expect(res).to.equal(null); });
          });
        ''', 'Request R'),
        ], ctx(scopes: scopes, send: sender(scopes)));
        expect(out.error, isNull);
        for (final t in out.tests) {
          expect(t.pass, isTrue, reason: '${t.name}: ${t.error}');
        }
        expect(out.tests.length, 3);
        expect(
          sw.elapsedMilliseconds,
          lessThan(2500),
          reason: 'not sequential',
        );
      },
    );

    test('scripts cannot upload local files', () async {
      final scopes = VarScopes(session: {'base': base});
      final out = await engine.run([
        ScriptSource(r'''
          pm.sendRequest({
            url: pm.variables.get('base') + '/echo', method: 'POST',
            body: {mode: 'formdata', formdata: [{key: 'f', type: 'file', src: '/etc/passwd'}]},
          }, (err) => pm.test('refused', () => pm.expect(err.message).to.include("can't upload files")));
          pm.sendRequest({
            url: pm.variables.get('base') + '/echo', method: 'POST',
            body: {mode: 'file', file: {src: '/etc/passwd'}},
          }, (err) => pm.test('refused file body', () => pm.expect(err.message).to.include("can't send a file")));
        ''', 'Request R'),
      ], ctx(scopes: scopes, send: sender(scopes)));
      for (final t in out.tests) {
        expect(t.pass, isTrue, reason: '${t.name}: ${t.error}');
      }
      expect(out.tests.length, 2);
      expect(seen, isEmpty);
    });

    test('a request slower than the script timeout stops the script', () async {
      final scopes = VarScopes(session: {'base': base});
      final out = await engine.run([
        ScriptSource(
          "await pm.sendRequest(pm.variables.get('base') + '/slow');",
          'Request R',
        ),
      ], ctx(scopes: scopes, send: sender(scopes), timeoutMs: 100));
      expect(out.error, contains('did not finish within 100 ms'));
    });

    test('runs overlap in the worker', () async {
      final scopes = VarScopes(session: {'base': base});
      final slow = engine.run([
        ScriptSource(
          "await pm.sendRequest(pm.variables.get('base') + '/slow'); console.log('slow done');",
          'Request Slow',
        ),
      ], ctx(scopes: scopes, send: sender(scopes)));
      final fast = await engine.run([
        const ScriptSource("console.log('fast done')", 'Request Fast'),
      ], ctx(scopes: VarScopes()));
      expect(fast.logs.single.message, 'fast done');
      expect((await slow).logs.single.message, 'slow done');
    });
  });

  group('RequestExecutor', () {
    test('collection, folder and request scripts around a real send', () async {
      final http = HttpService();
      addTearDown(http.dispose);
      final env = [KV(key: 'base', value: base)];
      final col = CollectionModel(
        name: 'Shop',
        variables: [KV(key: 'apiVersion', value: 'v1')],
        preRequestScript: r'''
          if (!pm.environment.get('token')) {
            const res = await pm.sendRequest(pm.environment.get('base') + '/token?n=42');
            pm.environment.set('token', res.json().token);
            console.log('fetched token');
          }
        ''',
        testScript:
            'pm.test("collection: not 5xx", () => pm.response.to.not.be.serverError);',
        folders: {
          'orders': FolderMeta(
            preRequestScript:
                'pm.request.headers.add({key: "X-Folder", value: pm.collectionVariables.get("apiVersion")});',
          ),
        },
      );
      final req = RequestModel(
        name: 'Create order',
        method: 'POST',
        url: '{{base}}/orders',
        folder: 'orders',
        headers: [KV(key: 'Authorization', value: 'Bearer {{token}}')],
        bodyType: BodyType.json,
        body: '{"qty": 1}',
        preRequestScript: r'''
          const body = JSON.parse(pm.request.body.raw);
          body.qty += 1;
          body.at = pm.variables.replaceIn('{{$timestamp}}');
          pm.request.body.raw = JSON.stringify(body);
          pm.variables.set('sentQty', body.qty);
        ''',
        testScript: r'''
          const echo = pm.response.json();
          pm.test('status', () => pm.response.to.have.status(200));
          pm.test('auth header', () => pm.expect(echo.headers.authorization).to.equal('Bearer tok-42'));
          pm.test('folder header', () => pm.expect(echo.headers['x-folder']).to.equal('v1'));
          pm.test('mutated body', () => pm.expect(JSON.parse(echo.body).qty).to.equal(Number(pm.variables.get('sentQty'))));
          pm.collectionVariables.set('lastPath', echo.path);
          pm.visualizer.set('<b>{{path}}</b>', echo);
          pm.execution.setNextRequest('List orders');
        ''',
        assertions: [
          AssertionModel(kind: AssertKind.statusEquals, expected: '200'),
        ],
      );
      final scopes = VarScopes(environment: env, collection: col.variables);
      final result = await RequestExecutor(
        http,
        engine: engine,
      ).execute(req, ExecContext(scopes: scopes, collection: col));
      expect(result.scriptError, isNull);
      expect(result.response.statusCode, 200);
      expect(
        {for (final t in result.scriptTests) t.name: t.pass},
        {
          'collection: not 5xx': true,
          'status': true,
          'auth header': true,
          'folder header': true,
          'mutated body': true,
        },
      );
      expect(
        [for (final t in result.scriptTests) t.origin],
        [
          'Collection Shop',
          'Request Create order',
          'Request Create order',
          'Request Create order',
          'Request Create order',
        ],
      );
      expect(result.assertions.single.pass, isTrue);
      expect(result.pass, isTrue);
      expect(result.logs.single.message, 'fetched token');
      expect(result.logs.single.source, 'Pre-request: Collection Shop');
      expect(result.visualizer?.html, '<b>/orders</b>');
      expect(result.next?.nameOrId, 'List orders');
      expect(kvMap(env)['token'], 'tok-42');
      expect(kvMap(col.variables)['lastPath'], '/orders');
      expect(seen.map((s) => s['path']), ['/token', '/orders']);
      expect(jsonDecode(seen.last['body']! as String)['qty'], 2);
      // The saved request is untouched; the sent copy carries the edits.
      expect(req.body, '{"qty": 1}');
      expect(req.headers.length, 1);
      expect(result.sent.headers.map((h) => h.key), contains('X-Folder'));
    });

    test('skipRequest and pre-request failures stop the send', () async {
      final http = HttpService();
      addTearDown(http.dispose);
      final exec = RequestExecutor(http, engine: engine);
      final skipped = await exec.execute(
        RequestModel(
          url: '$base/x',
          preRequestScript: 'pm.execution.skipRequest()',
          testScript: 'console.log("tests must not run")',
        ),
        ExecContext(scopes: VarScopes()),
      );
      expect(skipped.skipped, isTrue);
      expect(skipped.logs, isEmpty);
      final failed = await exec.execute(
        RequestModel(url: '$base/x', preRequestScript: 'nope()'),
        ExecContext(scopes: VarScopes()),
      );
      expect(failed.scriptError, contains('ReferenceError'));
      expect(failed.pass, isFalse);
      expect(seen, isEmpty);
    });

    test('a failing test script fails the result', () async {
      final http = HttpService();
      addTearDown(http.dispose);
      final result = await RequestExecutor(http, engine: engine).execute(
        RequestModel(
          url: '$base/x',
          testScript: 'pm.response.to.have.status(201);',
        ),
        ExecContext(scopes: VarScopes()),
      );
      expect(
        result.scriptError,
        contains('expected response to have status code 201'),
      );
      expect(result.pass, isFalse);
    });

    test('the inline engine works the same', () async {
      final http = HttpService();
      addTearDown(http.dispose);
      final inline = createScriptEngine(isolate: false)!;
      addTearDown(inline.dispose);
      final result = await RequestExecutor(http, engine: inline).execute(
        RequestModel(
          url: '$base/x',
          preRequestScript:
              'pm.request.headers.add({key: "X-Inline", value: "1"})',
          testScript:
              'pm.test("ok", () => pm.expect(pm.response.json().headers["x-inline"]).to.equal("1"));',
        ),
        ExecContext(scopes: VarScopes()),
      );
      expect(
        result.scriptTests.single.pass,
        isTrue,
        reason: result.scriptTests.single.error,
      );
    });
  });

  group('RunnerService', () {
    test(
      'variables flow between requests; setNextRequest and data rows',
      () async {
        final http = HttpService();
        final runner = RunnerService(http, engine: engine);
        addTearDown(runner.dispose);
        final env = [KV(key: 'base', value: base)];
        RequestModel req(String name, {String pre = '', String post = ''}) =>
            RequestModel(
              name: name,
              url: '{{base}}/$name',
              params: [KV(key: 'user', value: '{{user}}')],
              preRequestScript: pre,
              testScript: post,
            );
        final results = <ExecResult>[];
        await runner.start(
          requests: [
            req(
              'login',
              post: r'''
              pm.environment.set('session', 'S-' + pm.iterationData.get('user'));
              pm.test('iteration ' + pm.info.iteration, () => pm.expect(pm.info.iterationCount).to.equal(2));
              postman.setNextRequest('profile');
            ''',
            ),
            req('skipped-by-jump'),
            req(
              'profile',
              pre:
                  'pm.request.headers.add({key: "X-Session", value: pm.environment.get("session")});',
              post: r'''
              pm.test('session sent', () => pm.expect(pm.response.json().headers['x-session']).to.equal(pm.environment.get('session')));
              pm.test('data row', () => pm.expect(pm.response.json().query.user).to.equal(pm.iterationData.get('user')));
              postman.setNextRequest(null);
            ''',
            ),
            req('never'),
          ],
          scopes: VarScopes(environment: env),
          dataRows: [
            {'user': 'ada'},
            {'user': 'linus'},
          ],
          onResult: (r, _) => results.add(r),
        );
        expect(seen.map((s) => '${s['path']}?${(s['query'] as Map)['user']}'), [
          '/login?ada',
          '/profile?ada',
          '/login?linus',
          '/profile?linus',
        ]);
        expect(runner.total, 4);
        expect(runner.passed, 4);
        for (final r in results) {
          for (final t in r.scriptTests) {
            expect(t.pass, isTrue, reason: '${t.name}: ${t.error}');
          }
        }
        expect(kvMap(env)['session'], 'S-linus');
      },
    );
  });
}
