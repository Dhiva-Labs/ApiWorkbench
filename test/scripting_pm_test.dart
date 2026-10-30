import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/console_events.dart';
import 'package:api_workbench/services/scripting/engine_factory.dart';
import 'package:api_workbench/services/scripting/script_engine.dart';
import 'package:api_workbench/services/var_scopes.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pm API on the real QuickJS engine (worker isolate).
void main() {
  late ScriptEngine engine;

  setUpAll(() {
    final e = createScriptEngine();
    expect(e, isNotNull, reason: 'the QuickJS library must load in tests');
    engine = e!;
  });
  tearDownAll(() => engine.dispose());

  ResponseData json200(Object body, {Map<String, List<String>>? headers}) =>
      ResponseData(
        statusCode: 200,
        statusMessage: 'OK',
        headers: {
          'content-type': ['application/json; charset=utf-8'],
          ...?headers,
        },
        bodyBytes: utf8.encode(jsonEncode(body)),
        durationMs: 42,
      );

  Future<ScriptOutcome> run(
    String code, {
    ScriptPhase phase = ScriptPhase.preRequest,
    RequestModel? request,
    ResponseData? response,
    VarScopes? scopes,
    List<Cookie> cookies = const [],
    int timeoutMs = 5000,
    String origin = 'Request R',
    ScriptInfo info = const ScriptInfo(requestName: 'R', requestId: 'r1'),
    List<ScriptSource>? scripts,
  }) => engine.run(
    scripts ?? [ScriptSource(code, origin)],
    ScriptContext(
      phase: phase,
      request: request ?? RequestModel(name: 'R', url: 'https://api.test/x'),
      scopes: scopes ?? VarScopes(),
      info: info,
      response: response,
      responseCookies: cookies,
      timeoutMs: timeoutMs,
    ),
  );

  Future<ScriptOutcome> runTest(String code, ResponseData response) =>
      run(code, phase: ScriptPhase.test, response: response);

  group('variables', () {
    test('scopes read, write, unset and clear the live lists', () async {
      final globals = [KV(key: 'g', value: 'G0')];
      final collection = [KV(key: 'c', value: 'C0')];
      final env = [KV(key: 'e', value: 'E0'), KV(key: 'gone', value: 'x')];
      final scopes = VarScopes(
        globals: globals,
        collection: collection,
        environment: env,
        data: {'d': 'D0'},
      );
      final out = await run('''
        pm.test('reads', () => {
          pm.expect(pm.globals.get('g')).to.equal('G0');
          pm.expect(pm.collectionVariables.get('c')).to.equal('C0');
          pm.expect(pm.environment.get('e')).to.equal('E0');
          pm.expect(pm.iterationData.get('d')).to.equal('D0');
          pm.expect(pm.environment.has('e')).to.be.true;
          pm.expect(pm.environment.get('nope')).to.be.undefined;
        });
        pm.globals.set('g2', 7);
        pm.collectionVariables.set('c', 'C1');
        pm.environment.set('obj', {a: 1});
        pm.environment.unset('gone');
        pm.variables.set('local', 'L');
        pm.test('same run keeps the value type', () => {
          pm.expect(pm.globals.get('g2')).to.equal(7);
          pm.expect(pm.environment.get('obj')).to.deep.equal({a: 1});
          pm.expect(pm.environment.toObject()).to.have.property('e', 'E0');
        });
      ''', scopes: scopes);
      expect(out.error, isNull);
      expect(out.tests.every((t) => t.pass), isTrue, reason: '${out.tests}');
      expect(kvMap(globals), {'g': 'G0', 'g2': '7'});
      expect(kvMap(collection), {'c': 'C1'});
      expect(kvMap(env), {'e': 'E0', 'obj': '{"a":1}'});
      expect(scopes.local, {'local': 'L'});
      expect(scopes.globalsChanged && scopes.environmentChanged, isTrue);
      // A new variable gets an empty initial value, like Postman.
      expect(globals.last.value, '');
      expect(globals.last.current, '7');
    });

    test('clear empties a scope', () async {
      final env = [KV(key: 'a', value: '1'), KV(key: 'b', value: '2')];
      final out = await run(
        'pm.environment.clear(); pm.test("empty", () => '
        'pm.expect(pm.environment.toObject()).to.deep.equal({}));',
        scopes: VarScopes(environment: env),
      );
      expect(out.tests.single.pass, isTrue);
      expect(env, isEmpty);
    });

    test('without an environment, pm.environment is the session', () async {
      final scopes = VarScopes(session: {'s': '1'});
      final out = await run(
        'pm.environment.set("t", pm.environment.get("s") + "2");',
        scopes: scopes,
      );
      expect(out.error, isNull);
      expect(scopes.session, {'s': '1', 't': '12'});
    });

    test(
      'pm.variables resolves by precedence and replaces placeholders',
      () async {
        final scopes = VarScopes(
          globals: [
            KV(key: 'x', value: 'global'),
            KV(key: 'only', value: 'g'),
          ],
          collection: [KV(key: 'x', value: 'collection')],
          environment: [
            KV(key: 'x', value: 'env'),
            KV(key: 'host', value: 'h'),
          ],
          data: {'x': 'data'},
        );
        final out = await run('''
        pm.test('data beats environment', () => pm.expect(pm.variables.get('x')).to.equal('data'));
        pm.variables.set('x', 'local');
        pm.test('local beats all', () => pm.expect(pm.variables.get('x')).to.equal('local'));
        pm.test('falls back to globals', () => pm.expect(pm.variables.get('only')).to.equal('g'));
        pm.test('has', () => pm.expect(pm.variables.has('host')).to.be.true);
        pm.test('replaceIn', () => {
          pm.expect(pm.variables.replaceIn('https://{{host}}/{{x}}/{{missing}}'))
            .to.equal('https://h/local/{{missing}}');
          pm.expect(pm.variables.replaceIn('{{\$guid}}')).to.match(/^[0-9a-f-]{36}\$/);
          pm.expect(pm.variables.replaceIn('{{\$randomFirstName}}')).to.not.include('{{');
        });
        pm.test('toObject merges', () => pm.expect(pm.variables.toObject()).to.include({x: 'local', host: 'h', only: 'g'}));
      ''', scopes: scopes);
        expect(out.error, isNull);
        for (final t in out.tests) {
          expect(t.pass, isTrue, reason: '${t.name}: ${t.error}');
        }
        expect(scopes.local['x'], 'local');
      },
    );
  });

  group('request', () {
    test('pre-request edits map back onto the request', () async {
      final req = RequestModel(
        name: 'R',
        method: 'GET',
        url: '{{base}}/users/:id',
        params: [KV(key: 'page', value: '1')],
        pathVariables: [KV(key: 'id', value: '7')],
        headers: [
          KV(key: 'Accept', value: 'text/plain'),
          KV(key: 'X-Old'),
        ],
      );
      final out = await run('''
        pm.test('reads', () => {
          pm.expect(pm.request.method).to.equal('GET');
          pm.expect(pm.request.url.toString()).to.equal('{{base}}/users/7?page=1');
          pm.expect(pm.request.url.getPath(true)).to.equal('/users/:id');
          pm.expect(pm.request.url.query.get('page')).to.equal('1');
          pm.expect(pm.request.headers.get('accept')).to.equal('text/plain');
          pm.expect(pm.request.headers.has('X-Old')).to.be.true;
        });
        pm.request.method = 'post';
        pm.request.headers.add({key: 'X-New', value: 'n'});
        pm.request.headers.upsert({key: 'accept', value: 'application/json'});
        pm.request.headers.remove('X-Old');
        pm.request.addHeader('X-Line: yes');
        pm.request.url.query.add({key: 'q', value: 'two'});
        pm.request.url.query.remove('page');
        pm.request.url.variables.upsert({key: 'id', value: '9'});
        pm.request.body.update({mode: 'raw', raw: JSON.stringify({a: 1}), options: {raw: {language: 'json'}}});
        pm.request.auth.use('bearer', {token: 'secret'});
      ''', request: req);
      expect(out.error, isNull);
      expect(out.tests.single.pass, isTrue, reason: out.tests.single.error);
      expect(req.method, 'POST');
      expect(req.url, '{{base}}/users/:id');
      expect(kvMap(req.params), {'q': 'two'});
      expect(kvMap(req.pathVariables), {'id': '9'});
      expect(
        [for (final h in req.headers) '${h.key}: ${h.value}'],
        // upsert keeps the row and takes the new spelling, like Postman.
        ['accept: application/json', 'X-New: n', 'X-Line: yes'],
      );
      expect(req.bodyType, BodyType.json);
      expect(jsonDecode(req.body), {'a': 1});
      expect(req.auth.type, AuthType.bearer);
      expect(req.bearerToken, 'secret');
    });

    test('an untouched request is left exactly as it was', () async {
      final req = RequestModel(
        url: 'localhost:8080/a//b/',
        params: [KV(key: 'k', value: '', enabled: false, description: 'd')],
        headers: [KV(key: 'A', value: '{{x}}', description: 'note')],
        bodyType: BodyType.formUrlEncoded,
        formFields: [KV(key: 'f', value: 'v')],
        authType: AuthType.inherit,
      );
      final before = jsonEncode(req.toJson());
      final out = await run(
        'pm.request.url.toString(); pm.request.headers.all();',
        request: req,
      );
      expect(out.error, isNull);
      expect(jsonEncode(req.toJson()), before);
    });

    test('url can be replaced as a string', () async {
      final req = RequestModel(url: 'https://old.test/a');
      await run(
        'pm.request.url = "http://new.test:81/b/c?x=1&y#frag";',
        request: req,
      );
      expect(req.url, 'http://new.test:81/b/c#frag');
      expect(
        [for (final p in req.params) '${p.key}=${p.value}'],
        ['x=1', 'y='],
      );
    });

    test('form bodies and auth types round-trip', () async {
      final req = RequestModel(
        bodyType: BodyType.formUrlEncoded,
        formFields: [KV(key: 'a', value: '1')],
        authType: AuthType.basic,
        basicUser: 'u',
      );
      final out = await run('''
        pm.test('reads', () => {
          pm.expect(pm.request.body.mode).to.equal('urlencoded');
          pm.expect(pm.request.body.urlencoded.get('a')).to.equal('1');
          pm.expect(pm.request.auth.type).to.equal('basic');
          pm.expect(pm.request.auth.parameters().get('username')).to.equal('u');
        });
        pm.request.body.urlencoded.add({key: 'b', value: '2'});
        pm.request.auth.update({password: 'p'});
      ''', request: req);
      expect(out.tests.single.pass, isTrue, reason: out.tests.single.error);
      expect(kvMap(req.formFields), {'a': '1', 'b': '2'});
      expect(req.basicUser, 'u');
      expect(req.basicPassword, 'p');
    });

    test('scripts cannot point the request at local files', () async {
      final req = RequestModel(
        bodyType: BodyType.formData,
        formFields: [KV(key: 'up', value: '/ok/file.txt', isFile: true)],
      );
      final out = await run('''
        pm.request.body.formdata.add({key: 'steal', type: 'file', src: '/etc/passwd'});
      ''', request: req);
      expect(out.error, isNull);
      expect([for (final f in req.formFields) f.value], ['/ok/file.txt']);
      expect(
        out.logs.map((l) => l.message),
        contains(contains("can't attach")),
      );

      final raw = RequestModel(bodyType: BodyType.json, body: '{}');
      final out2 = await run(
        "pm.request.body.update({mode: 'file', file: {src: '/etc/passwd'}});",
        request: raw,
      );
      expect(raw.bodyType, BodyType.json);
      expect(raw.body, '{}');
      expect(
        out2.logs.map((l) => l.message),
        contains(contains("can't attach")),
      );
    });

    test('test scripts see the request with variables resolved', () async {
      final out = await run(
        'pm.test("resolved", () => pm.expect(pm.request.url.toString())'
        '.to.equal("https://h.test/a?k=v"));',
        phase: ScriptPhase.test,
        request: RequestModel(
          url: 'https://{{host}}/a',
          params: [KV(key: 'k', value: '{{val}}')],
        ),
        scopes: VarScopes(session: {'host': 'h.test', 'val': 'v'}),
        response: json200({}),
      );
      expect(out.tests.single.pass, isTrue, reason: out.tests.single.error);
    });
  });

  group('response', () {
    test('fields, json() and text()', () async {
      final out = await runTest(
        '''
        pm.test('fields', () => {
          pm.expect(pm.response.code).to.equal(200);
          pm.expect(pm.response.status).to.equal('OK');
          pm.expect(pm.response.responseTime).to.equal(42);
          pm.expect(pm.response.responseSize).to.be.above(10);
          pm.expect(pm.response.headers.get('Content-Type')).to.include('json');
          pm.expect(pm.response.json().items[1].id).to.equal(2);
          pm.expect(pm.response.text()).to.include('"items"');
        });
      ''',
        json200({
          'items': [
            {'id': 1},
            {'id': 2},
          ],
          'name': 'n',
        }),
      );
      expect(out.tests.single.pass, isTrue, reason: out.tests.single.error);
    });

    test('to.have / to.be assertions pass and fail like Postman', () async {
      final res = json200(
        {
          'user': {
            'name': 'Ada',
            'tags': ['a'],
          },
        },
        headers: {
          'x-rate': ['10'],
        },
      );
      final out = await runTest('''
        const ok = [
          () => pm.response.to.have.status(200),
          () => pm.response.to.have.status('OK'),
          () => pm.response.to.have.statusCode(200),
          () => pm.response.to.be.ok,
          () => pm.response.to.be.success,
          () => pm.response.to.not.be.error,
          () => pm.response.to.not.be.clientError,
          () => pm.response.to.not.be.serverError,
          () => pm.response.to.be.json,
          () => pm.response.to.be.withBody,
          () => pm.response.to.have.header('X-Rate'),
          () => pm.response.to.have.header('x-rate', '10'),
          () => pm.response.to.not.have.header('X-Missing'),
          () => pm.response.to.have.body(),
          () => pm.response.to.have.body(/Ada/),
          () => pm.response.to.have.jsonBody(),
          () => pm.response.to.have.jsonBody('user.name'),
          () => pm.response.to.have.jsonBody('user.name', 'Ada'),
          () => pm.response.to.have.jsonBody('user.tags[0]', 'a'),
          () => pm.response.to.not.have.jsonBody('user.age'),
          () => pm.response.to.have.responseTime.below(100),
          () => pm.response.to.have.jsonSchema({type: 'object', required: ['user']}),
          () => pm.expect(pm.response.json()).to.have.jsonSchema({type: 'object'}),
          () => pm.expect(pm.response.responseTime).to.be.below(200),
          () => pm.expect(1).to.be.ok,
        ];
        ok.forEach((f, i) => pm.test('ok ' + i, f));
        const bad = [
          () => pm.response.to.have.status(404),
          () => pm.response.to.be.clientError,
          () => pm.response.to.be.notFound,
          () => pm.response.to.have.header('X-Missing'),
          () => pm.response.to.have.jsonBody('user.name', 'Bob'),
          () => pm.response.to.have.jsonSchema({type: 'array'}),
          () => pm.response.to.have.responseTime.below(10),
        ];
        bad.forEach((f, i) => pm.test('bad ' + i, f));
      ''', res);
      expect(out.error, isNull);
      for (final t in out.tests) {
        expect(
          t.pass,
          t.name.startsWith('ok'),
          reason: '${t.name}: ${t.error}',
        );
      }
      final messages = out.tests.where((t) => !t.pass).map((t) => t.error);
      expect(
        messages.first,
        'AssertionError: expected response to have status code 404 but got 200',
      );
      expect(
        messages,
        contains(contains("to have header with key 'X-Missing'")),
      );
    });

    test('status classes', () async {
      final out = await runTest('''
        pm.test('4xx', () => { pm.response.to.be.clientError; pm.response.to.be.error; pm.response.to.be.notFound; });
        pm.test('reason', () => pm.expect(pm.response.status).to.equal('Not Found'));
      ''', ResponseData(statusCode: 404, bodyBytes: utf8.encode('nope')));
      for (final t in out.tests) {
        expect(t.pass, isTrue, reason: '${t.name}: ${t.error}');
      }
    });

    test('cookies', () async {
      final out = await runTest(
        '''
        pm.test('jar cookies', () => {
          pm.expect(pm.cookies.has('sid')).to.be.true;
          pm.expect(pm.cookies.get('sid')).to.equal('abc');
          pm.expect(pm.cookies.toObject()).to.deep.equal({sid: 'abc'});
        });
        pm.test('set-cookie', () => pm.expect(pm.response.cookies.get('n')).to.equal('1'));
        pm.test('assertion', () => pm.response.to.have.cookie('n', '1'));
      ''',
        json200(
          {},
          headers: {
            'set-cookie': ['n=1; Path=/; HttpOnly'],
          },
        ),
      );
      // runTest has no cookies; run directly with a jar cookie.
      expect(out.tests[0].pass, isFalse);
      final out2 = await run(
        'pm.test("jar", () => pm.expect(pm.cookies.get("sid")).to.equal("abc"));',
        phase: ScriptPhase.test,
        response: json200({}),
        cookies: [Cookie('sid', 'abc')..path = '/'],
      );
      expect(out2.tests.single.pass, isTrue, reason: out2.tests.single.error);
      expect(out.tests[1].pass && out.tests[2].pass, isTrue);
    });
  });

  group('tests and chai', () {
    test('pm.expect is chai 4 with deep equality and messages', () async {
      final out = await run('''
        pm.test('deep', () => pm.expect({a: [1, {b: 2}]}).to.deep.equal({a: [1, {b: 2}]}));
        pm.test('include', () => pm.expect('hello world').to.include('world'));
        pm.test('length', () => pm.expect([1, 2, 3]).to.have.lengthOf(3));
        pm.test('oneOf', () => pm.expect(201).to.be.oneOf([200, 201]));
        pm.test('fails', () => pm.expect({a: 1}).to.deep.equal({a: 2}));
        pm.test('throws inside', () => { null.x; });
      ''');
      expect(
        [for (final t in out.tests) t.pass],
        [true, true, true, true, false, false],
      );
      expect(out.tests[4].error, startsWith('AssertionError: expected'));
      expect(out.tests[5].error, startsWith('TypeError'));
      expect(
        out.error,
        isNull,
        reason: 'failures inside pm.test are not script errors',
      );
    });

    test('async tests: promises and done callbacks', () async {
      final out = await run('''
        pm.test('promise', async () => {
          await new Promise(r => setTimeout(r, 30));
          pm.expect(1).to.equal(1);
        });
        pm.test('promise fails', async () => {
          await null;
          throw new Error('late');
        });
        pm.test('done', (done) => setTimeout(() => done(), 10));
        pm.test('done with error', (done) => setTimeout(() => done(new Error('nope')), 10));
        pm.test('never settles', () => new Promise(() => {}));
        pm.test.skip('skipped', () => { throw 1; });
      ''');
      expect(
        [for (final t in out.tests) (t.name, t.pass)],
        [
          ('promise', true),
          ('promise fails', false),
          ('done', true),
          ('done with error', false),
          ('never settles', false),
          ('skipped', true),
        ],
      );
      expect(out.tests[1].error, 'Error: late');
      expect(out.tests[4].error, contains('did not finish'));
      expect(out.tests[5].skipped, isTrue);
    });

    test('legacy tests[] and globals', () async {
      final scopes = VarScopes(
        environment: [KV(key: 'e', value: '1')],
      );
      final out = await run(
        '''
        tests['status is 200'] = responseCode.code === 200;
        tests['body has id'] = JSON.parse(responseBody).id === 5;
        tests['wrong'] = responseTime > 1000;
        tests['header'] = postman.getResponseHeader('Content-Type').indexOf('json') >= 0;
        tests['headers object'] = responseHeaders['content-type'] !== undefined;
        tests['any case'] = responseHeaders['Content-Type'] === responseHeaders['content-type'];
        tests['env'] = environment.e === '1' && postman.getEnvironmentVariable('e') === '1';
        postman.setEnvironmentVariable('legacy', 'yes');
        postman.setGlobalVariable('lg', 'g');
        postman.clearEnvironmentVariable('e');
      ''',
        phase: ScriptPhase.test,
        response: json200({'id': 5}),
        scopes: scopes,
      );
      expect(out.error, isNull);
      expect(
        {for (final t in out.tests) t.name: t.pass},
        {
          'status is 200': true,
          'body has id': true,
          'wrong': false,
          'header': true,
          'headers object': true,
          'any case': true,
          'env': true,
        },
      );
      expect(kvMap(scopes.environment), {'legacy': 'yes'});
    });

    test('tests carry the origin of their script', () async {
      final out = await run(
        '',
        scripts: const [
          ScriptSource('pm.test("c", () => {});', 'Collection C'),
          ScriptSource('pm.test("r", () => {});', 'Request R'),
        ],
      );
      expect(
        [for (final t in out.tests) t.origin],
        ['Collection C', 'Request R'],
      );
    });
  });

  group('scripts', () {
    test('share one realm but not their declarations', () async {
      final out = await run(
        '',
        scripts: const [
          ScriptSource(
            'helpers = { twice: (x) => x * 2 }; const hidden = 1; var alsoHidden = 2;',
            'Collection C',
          ),
          ScriptSource(
            'pm.test("helper", () => pm.expect(helpers.twice(2)).to.equal(4));'
                'pm.test("scoped", () => pm.expect(typeof hidden + typeof alsoHidden)'
                '.to.equal("undefinedundefined"));',
            'Request R',
          ),
        ],
      );
      for (final t in out.tests) {
        expect(t.pass, isTrue, reason: '${t.name}: ${t.error}');
      }
    });

    test('top-level await and timers run before the next script', () async {
      final out = await run(
        '',
        scripts: const [
          ScriptSource('''
            await new Promise(r => setTimeout(r, 20));
            setTimeout(() => console.log('timer'), 10);
            const id = setInterval(() => { n = (globalThis.n || 0) + 1; if (n === 3) clearInterval(id); }, 5);
            setTimeout(() => console.log('cleared'), 5) && clearTimeout(setTimeout(() => console.log('never'), 1));
          ''', 'Collection C'),
          ScriptSource('console.log("next", n);', 'Request R'),
        ],
      );
      expect(out.error, isNull);
      expect(
        [for (final l in out.logs) l.message],
        ['cleared', 'timer', 'next 3'],
      );
    });

    test('an uncaught error reports its origin and line', () async {
      final out = await run(
        '',
        scripts: const [
          ScriptSource('pm.test("before", () => {});', 'Collection C'),
          ScriptSource(
            'const a = 1;\nconst b = undefinedThing + a;',
            'Request R',
          ),
        ],
      );
      expect(
        out.error,
        'Request R: ReferenceError: undefinedThing is not defined (line 2)',
      );
      expect(out.tests.single.name, 'before');
    });

    test('syntax errors report the script and line', () async {
      final out = await run('let x = ;\n');
      expect(out.error, startsWith('Request R: SyntaxError'));
      expect(out.error, contains('(line 1)'));
    });

    test(
      'a failing pre-request script stops the chain; test scripts go on',
      () async {
        final scripts = const [
          ScriptSource('throw new Error("first")', 'Collection C'),
          ScriptSource('console.log("second ran")', 'Request R'),
        ];
        final pre = await run('', scripts: scripts);
        expect(pre.error, 'Collection C: Error: first (line 1)');
        expect(pre.logs, isEmpty);
        final post = await run(
          '',
          scripts: scripts,
          phase: ScriptPhase.test,
          response: json200({}),
        );
        expect(post.error, 'Collection C: Error: first (line 1)');
        expect(post.logs.single.message, 'second ran');
      },
    );

    test('errors in callbacks belong to the running script', () async {
      final out = await run(
        'setTimeout(() => { throw new TypeError("in timer"); }, 1);',
      );
      expect(out.error, 'Request R: TypeError: in timer (line 1)');
    });
  });

  group('control', () {
    test('pm.info', () async {
      final out = await run(
        'pm.test("info", () => pm.expect(pm.info).to.deep.equal({eventName: "prerequest", '
        'iteration: 2, iterationCount: 5, requestName: "Get", requestId: "id-1"}));',
        info: const ScriptInfo(
          requestName: 'Get',
          requestId: 'id-1',
          iteration: 2,
          iterationCount: 5,
        ),
      );
      expect(out.tests.single.pass, isTrue, reason: out.tests.single.error);
    });

    test('setNextRequest: name, null and the legacy form', () async {
      expect(
        (await run('pm.execution.setNextRequest("Login")')).next?.nameOrId,
        'Login',
      );
      expect((await run('postman.setNextRequest(null)')).next?.stop, isTrue);
      expect(
        (await run(
          'postman.setNextRequest("A"); postman.setNextRequest("B")',
        )).next?.nameOrId,
        'B',
      );
      expect((await run('1')).next, isNull);
    });

    test('skipRequest stops the remaining pre-request scripts', () async {
      final out = await run(
        '',
        scripts: const [
          ScriptSource(
            'pm.execution.skipRequest(); console.log("same script");',
            'Collection C',
          ),
          ScriptSource('console.log("never")', 'Request R'),
        ],
      );
      expect(out.skipRequest, isTrue);
      expect([for (final l in out.logs) l.message], ['same script']);
      final post = await run(
        'pm.execution.skipRequest()',
        phase: ScriptPhase.test,
        response: json200({}),
      );
      expect(post.skipRequest, isFalse);
    });
  });

  group('helpers', () {
    test('console levels, formatting and source', () async {
      final out = await run('''
        console.log('plain', 1, true, null, undefined);
        console.info('%s has %d items', 'cart', 3);
        console.warn({a: [1, 2], b: 'x'});
        console.error(new Error('bad'));
        console.debug([1, 'two']);
        const cyc = {}; cyc.self = cyc; console.log(cyc);
      ''');
      expect(
        [for (final l in out.logs) l.level],
        [
          ConsoleLevel.log,
          ConsoleLevel.info,
          ConsoleLevel.warn,
          ConsoleLevel.error,
          ConsoleLevel.debug,
          ConsoleLevel.log,
        ],
      );
      final m = [for (final l in out.logs) l.message];
      expect(m[0], 'plain 1 true null undefined');
      expect(m[1], 'cart has 3 items');
      expect(m[2], '{"a":[1,2],"b":"x"}');
      expect(m[3], startsWith('Error: bad'));
      expect(m[4], '[1,"two"]');
      expect(m[5], '{"self":"[Circular]"}');
      expect(out.logs.first.source, 'Pre-request: Request R');
    });

    test('require() loads the bundled libraries', () async {
      final out = await run(r'''
        const _ = require('lodash');
        const CryptoJS = require('crypto-js');
        const moment = require('moment');
        const uuid = require('uuid');
        const tv4 = require('tv4');
        const Ajv = require('ajv');
        const chai = require('chai');
        pm.test('lodash', () => pm.expect(_.sumBy([{n: 1}, {n: 2}], 'n')).to.equal(3));
        pm.test('lodash global', () => pm.expect(globalThis._.VERSION).to.equal(_.VERSION));
        pm.test('crypto-js', () => {
          pm.expect(CryptoJS.MD5('abc').toString()).to.equal('900150983cd24fb0d6963f7d28e17f72');
          pm.expect(CryptoJS.HmacSHA256('m', 'k').toString(CryptoJS.enc.Base64)).to.have.lengthOf(44);
          pm.expect(CryptoJS.enc.Base64.stringify(CryptoJS.enc.Utf8.parse('hi'))).to.equal('aGk=');
          pm.expect(CryptoJS.lib.WordArray.random(16).sigBytes).to.equal(16);
        });
        pm.test('moment', () => pm.expect(moment.utc('2024-02-29T10:00:00Z').add(1, 'day').format('YYYY-MM-DD')).to.equal('2024-03-01'));
        pm.test('uuid', () => pm.expect(uuid.v4()).to.match(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/));
        pm.test('tv4', () => pm.expect(tv4.validate({a: 1}, {properties: {a: {type: 'string'}}})).to.be.false);
        pm.test('ajv', () => {
          const v = new Ajv().compile({type: 'object', properties: {n: {type: 'number'}}, required: ['n']});
          pm.expect(v({n: 1})).to.be.true;
          pm.expect(v({})).to.be.false;
        });
        pm.test('chai', () => chai.expect(chai.assert).to.be.a('function'));
        pm.test('same instance', () => pm.expect(require('lodash')).to.equal(_));
        pm.test('atob/btoa', () => {
          pm.expect(btoa('user:pass')).to.equal('dXNlcjpwYXNz');
          pm.expect(atob('aGk=')).to.equal('hi');
          pm.expect(require('btoa')('x')).to.equal('eA==');
        });
        pm.test('Buffer', () => {
          pm.expect(Buffer.from('héllo').toString('base64')).to.equal('aMOpbGxv');
          pm.expect(Buffer.from('aMOpbGxv', 'base64').toString()).to.equal('héllo');
          pm.expect(Buffer.from('ff00', 'hex')[0]).to.equal(255);
        });
        pm.test('URL', () => {
          const u = new URL('https://user@Example.com:443/a/b?x=1&y=two#h');
          pm.expect(u.hostname).to.equal('example.com');
          pm.expect(u.port).to.equal('');
          pm.expect(u.searchParams.get('y')).to.equal('two');
          u.searchParams.append('z', 'a b');
          pm.expect(u.href).to.equal('https://user@example.com/a/b?x=1&y=two&z=a+b#h');
        });
        pm.test('random', () => {
          const a = crypto.getRandomValues(new Uint8Array(32));
          pm.expect(Array.from(a).some(x => x !== 0)).to.be.true;
          pm.expect(crypto.randomUUID()).to.have.lengthOf(36);
        });
      ''');
      expect(out.error, isNull);
      for (final t in out.tests) {
        expect(t.pass, isTrue, reason: '${t.name}: ${t.error}');
      }
    });

    test('unknown modules and Node built-ins are not available', () async {
      final out = await run("require('fs')");
      expect(out.error, contains("Cannot find module 'fs'"));
    });

    test('pm.visualizer.set renders a Handlebars template', () async {
      final out = await runTest(
        '''
        const tpl = '<h1>{{title}}</h1><ul>{{#each items}}<li>{{this.name}}</li>{{/each}}</ul><p>{{escaped}}</p>';
        pm.visualizer.set(tpl, {
          title: 'Users',
          items: pm.response.json().users,
          escaped: '<b>x</b>',
        });
      ''',
        json200({
          'users': [
            {'name': 'Ada'},
            {'name': 'Linus'},
          ],
        }),
      );
      expect(out.error, isNull);
      expect(
        out.visualizer?.html,
        '<h1>Users</h1><ul><li>Ada</li><li>Linus</li></ul>'
        '<p>&lt;b&gt;x&lt;/b&gt;</p>',
      );
      final cleared = await runTest(
        'pm.visualizer.set("x", {}); pm.visualizer.clear();',
        json200({}),
      );
      expect(cleared.visualizer, isNull);
    });
  });

  group('sandbox', () {
    test('an infinite loop times out, even inside try/catch', () async {
      final sw = Stopwatch()..start();
      final out = await run('''
        pm.test('before', () => {});
        try { while (true) {} } catch (e) { console.log('caught'); }
      ''', timeoutMs: 400);
      expect(sw.elapsedMilliseconds, lessThan(4000));
      expect(out.error, contains('did not finish within 400 ms'));
      expect(out.error, startsWith('Request R:'));
      expect(out.logs, isEmpty);
      expect(
        out.tests.single.name,
        'before',
        reason: 'results so far are kept',
      );
    });

    test('loops inside tests, promises and intervals time out too', () async {
      for (final code in [
        'pm.test("spin", () => { for (;;) {} });',
        'Promise.resolve().then(() => { for (;;) {} });',
        'setInterval(() => {}, 5);',
        'await new Promise(r => setTimeout(r, 60000));',
        // Catastrophic regex backtracking is interruptible too.
        r"/(a+)+$/.test('a'.repeat(40) + 'b');",
      ]) {
        final out = await run(code, timeoutMs: 300);
        expect(
          out.error,
          contains('did not finish within 300 ms'),
          reason: code,
        );
      }
    });

    test('the engine is usable after a timeout', () async {
      await run('for (;;) {}', timeoutMs: 200);
      final out = await run('pm.test("ok", () => {});');
      expect(out.tests.single.pass, isTrue);
    });

    test('deep recursion is a RangeError, not a crash', () async {
      final out = await run('function f(n) { return f(n + 1) + 1; } f(0);');
      expect(out.error, contains('RangeError'));
    });

    test('runaway memory is an error, not a crash', () async {
      final out = await run(
        'const a = []; for (;;) a.push(new Array(100000).fill(1));',
        timeoutMs: 20000,
      );
      expect(out.error, contains('out of memory'));
      final after = await run('pm.test("ok", () => {});');
      expect(after.tests.single.pass, isTrue);
    });

    test(
      'scripts cannot reach the file system, processes or the network',
      () async {
        final out = await run(r'''
        const missing = ['std', 'os', 'process', 'fetch', 'XMLHttpRequest', 'WebSocket',
          'Deno', 'Bun', '__awLoad', 'scriptArgs', 'print', 'Worker'];
        for (const name of missing) {
          pm.test(name, () => pm.expect(typeof globalThis[name]).to.equal('undefined'));
        }
        for (const mod of ['fs', 'child_process', 'net', 'http', 'os', 'std', 'path']) {
          pm.test('require ' + mod, () => pm.expect(() => require(mod)).to.throw(/Cannot find module/));
        }
        let imported = 'not run';
        await import('std').then(() => { imported = 'loaded'; }, (e) => { imported = String(e); });
        pm.test('import()', () => pm.expect(imported).to.not.equal('loaded'));
        let imported2 = 'not run';
        await import('/etc/passwd').then(() => { imported2 = 'loaded'; }, (e) => { imported2 = String(e); });
        pm.test('import() of a path', () => pm.expect(imported2).to.not.equal('loaded'));
      ''');
        expect(out.error, isNull);
        for (final t in out.tests) {
          expect(t.pass, isTrue, reason: '${t.name}: ${t.error}');
        }
      },
    );

    test('runs do not leak globals into each other', () async {
      await run('leaked = 1; Object.prototype.polluted = 1;');
      final out = await run(
        'pm.test("clean", () => pm.expect(typeof leaked + typeof ({}).polluted)'
        '.to.equal("undefinedundefined"));',
      );
      expect(out.tests.single.pass, isTrue, reason: out.tests.single.error);
    });

    test('pm.sendRequest without a sender reports an error', () async {
      final out = await run('''
        pm.sendRequest('http://127.0.0.1:1/x', (err, res) => {
          pm.test('error', () => pm.expect(err.message).to.include('not available'));
        });
      ''');
      expect(out.tests.single.pass, isTrue, reason: out.tests.single.error);
    });
  });
}
