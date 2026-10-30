import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/cli/cli.dart';
import 'package:api_workbench/cli/format.dart';
import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/console_events.dart';
import 'package:api_workbench/services/scripting/script_engine.dart';
import 'package:api_workbench/services/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

/// A script engine that answers from a function, to drive the CLI without
/// JavaScript.
class FakeEngine implements ScriptEngine {
  FakeEngine(this.onRun);
  final ScriptOutcome Function(List<ScriptSource>, ScriptContext) onRun;
  var disposed = false;

  @override
  Future<ScriptOutcome> run(
    List<ScriptSource> scripts,
    ScriptContext ctx,
  ) async => onRun(scripts, ctx);

  @override
  void dispose() => disposed = true;
}

class Seen {
  Seen(this.method, this.path, this.query, this.headers, this.cookies);
  final String method;
  final String path;
  final String query;
  final HttpHeaders headers;
  final List<Cookie> cookies;
}

void main() {
  late HttpServer server;
  late String base;
  late Directory dir;
  final seen = <Seen>[];

  setUp(() async {
    seen.clear();
    dir = await Directory.systemTemp.createTemp('aw_cli_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      seen.add(
        Seen(req.method, req.uri.path, req.uri.query, req.headers, req.cookies),
      );
      final res = req.response..headers.contentType = ContentType.json;
      final path = req.uri.path;
      if (path == '/login') {
        res.cookies.add(Cookie('sid', 's1')..path = '/');
        res.write('{"token":"tok"}');
      } else if (path == '/slow') {
        await Future<void>.delayed(const Duration(seconds: 3));
        res.write('{}');
      } else if (path == '/fail') {
        res.statusCode = 500;
        res.write('{"error":"boom <b>"}');
      } else if (path.startsWith('/users/')) {
        final authorized =
            req.headers.value('x-token') == 'tok' &&
            req.cookies.any((c) => c.name == 'sid' && c.value == 's1');
        final id = path.substring('/users/'.length);
        if (!authorized) {
          res.statusCode = 401;
          res.write('{"error":"unauthorized"}');
        } else if (id == '404') {
          res.statusCode = 404;
          res.write('{"error":"not found"}');
        } else {
          res.write('{"id":"$id","name":"user $id"}');
        }
      } else {
        res.write('{"ok":true}');
      }
      try {
        await res.close();
      } catch (_) {
        // The client gave up (a timeout test).
      }
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await dir.delete(recursive: true);
  });

  String file(String name, String text) {
    final f = File('${dir.path}/$name')..writeAsStringSync(text);
    return f.path;
  }

  Future<({int code, String out, String err})> cli(
    List<String> args, {
    ScriptEngine? Function()? engine,
    Map<String, String> env = const {},
    bool? terminal,
  }) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runCli(
      args,
      out: out,
      err: err,
      engineFactory: engine ?? () => null,
      env: env,
      isTerminal: terminal,
    );
    return (code: code, out: '$out', err: '$err');
  }

  AssertionModel status(String code) =>
      AssertionModel(kind: AssertKind.statusEquals, expected: code);

  /// Login (captures a token and gets a cookie), then a request per data row
  /// in folder Users, then one in Users/Admin.
  CollectionModel shop() => CollectionModel(
    name: 'Shop',
    requests: [
      RequestModel(
        name: 'Login',
        method: 'POST',
        url: '{{base}}/login',
        assertions: [status('200')],
        captures: {'token': 'body.token'},
      ),
      RequestModel(
        name: 'Get user',
        url: '{{base}}/users/{{id}}?key={{apiKey}}',
        folder: 'Users',
        headers: [KV(key: 'X-Token', value: '{{token}}')],
        assertions: [
          status('200'),
          AssertionModel(kind: AssertKind.bodyContains, expected: 'user'),
        ],
      ),
      RequestModel(
        name: 'Admin ping',
        url: '{{base}}/ping',
        folder: 'Users/Admin',
        assertions: [status('200')],
      ),
    ],
  );

  EnvironmentModel staging() => EnvironmentModel(
    name: 'Staging',
    variables: [
      KV(key: 'base', value: base),
      KV(key: 'apiKey', value: 'sup3r-s3cret-key', secret: true),
      KV(key: 'id', value: '0'),
    ],
  );

  String workspace(
    List<CollectionModel> cols, [
    List<EnvironmentModel> envs = const [],
  ]) => file('workspace.json', buildWorkspaceJson(cols, envs));

  group('end to end', () {
    test('runs a workspace with an environment and a CSV file', () async {
      final ws = workspace([shop()], [staging()]);
      final csv = file('users.csv', 'id,name\n1,Ada\n2,"Linus, T"\n');
      final junit = '${dir.path}/out/results.xml';
      final json = '${dir.path}/out/results.json';

      final r = await cli([
        'run',
        ws,
        '-e',
        'Staging',
        '-d',
        csv,
        '-r',
        'cli,json,junit',
        '--reporter-json-export',
        json,
        '--reporter-junit-export',
        junit,
      ]);
      expect(r.code, 0, reason: '${r.out}\n${r.err}');
      expect(r.err, isEmpty);

      // Two iterations x three requests; the token and the cookie from the
      // login reached the user requests; the row's column filled {{id}}.
      expect(seen.map((s) => s.path), [
        '/login',
        '/users/1',
        '/ping',
        '/login',
        '/users/2',
        '/ping',
      ]);
      expect(seen[1].headers.value('x-token'), 'tok');

      final report = jsonDecode(File(json).readAsStringSync()) as Map;
      expect(report['passed'], isTrue);
      expect(report['collection'], containsPair('name', 'Shop'));
      expect(report['environment'], 'Staging');
      final summary = report['summary'] as Map;
      expect(summary['iterations'], containsPair('executed', 2));
      expect(summary['requests'], containsPair('executed', 6));
      expect(summary['requests'], containsPair('failed', 0));
      expect(summary['assertions'], containsPair('total', 8));
      expect(summary['assertions'], containsPair('failed', 0));
      final runs = report['executions'] as List;
      expect(runs.length, 6);
      final second = runs[4] as Map;
      expect(second['name'], 'Get user');
      expect((second['response'] as Map)['code'], 200);
      expect((second['response'] as Map)['body'], contains('user 2'));
      expect(second['iteration'], 2);

      final xml = File(junit).readAsStringSync();
      expect(xml, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
      expect(xml, contains('<testsuites name="Shop" tests="8" failures="0"'));
      expect(
        RegExp('<testsuite ').allMatches(xml).length,
        6,
        reason: 'one suite per request sent',
      );
      expect(xml, contains('classname="Shop.Users" name="Status equals 200"'));
      expect(xml, contains('name="Get user [iteration 2]"'));
      expect(xml, isNot(contains('<failure')));

      // The cli reporter: progress, the summary table, no failures list.
      expect(r.out, contains('Shop'));
      expect(r.out, contains('Iteration 2/2'));
      expect(r.out, contains('GET $base/users/1'));
      expect(r.out, contains('requests'));
      expect(r.out, contains('All checks passed.'));
      expect(r.out, isNot(contains('FAILURES')));
      expect(r.out, contains('Wrote the json report to $json'));
    });

    test('a failing request gives exit code 1 and a failures list', () async {
      final ws = workspace([shop()], [staging()]);
      final csv = file('users.csv', 'id\n1\n404\n');
      final junit = '${dir.path}/results.xml';
      final r = await cli([
        'run',
        ws,
        '-e',
        'Staging',
        '-d',
        csv,
        '-r',
        'cli,junit',
        '--reporter-junit-export',
        junit,
      ]);
      expect(r.code, 1);
      expect(r.out, contains('FAILURES (2)'));
      expect(r.out, contains('AssertionError'));
      expect(r.out, contains('Status equals 200'));
      expect(r.out, contains('"Get user" (Users) iteration 2'));
      expect(r.out, contains('The run failed.'));

      final xml = File(junit).readAsStringSync();
      expect(xml, contains('failures="2"'));
      expect(
        xml,
        contains(
          '<failure message="expected 200, got 404" type="AssertionError">',
        ),
      );
    });

    test(
      'Postman collection, environment, globals and variable overrides',
      () async {
        final collection = file(
          'postman.json',
          jsonEncode({
            'info': {
              'name': 'Postman API',
              'schema':
                  'https://schema.getpostman.com/json/collection/v2.1.0/collection.json',
            },
            'variable': [
              {'key': 'who', 'value': 'collection'},
            ],
            'item': [
              {
                'name': 'Echo',
                'request': {
                  'method': 'GET',
                  'url':
                      '{{base}}/echo?who={{who}}&g={{fromGlobals}}&e={{fromEnv}}',
                },
              },
            ],
          }),
        );
        final env = file(
          'env.json',
          jsonEncode({
            'name': 'Local',
            'values': [
              {'key': 'base', 'value': base},
              {'key': 'fromEnv', 'value': 'env-file'},
              {'key': 'who', 'value': 'environment'},
            ],
          }),
        );
        final globals = file(
          'globals.json',
          jsonEncode({
            '_postman_variable_scope': 'globals',
            'name': 'Globals',
            'values': [
              {'key': 'fromGlobals', 'value': 'globals-file'},
              {'key': 'who', 'value': 'globals'},
            ],
          }),
        );

        var r = await cli(['run', collection, '-e', env, '-g', globals]);
        expect(r.code, 0, reason: r.out + r.err);
        // environment > collection > globals
        expect(seen.single.query, 'who=environment&g=globals-file&e=env-file');

        seen.clear();
        r = await cli([
          'run',
          collection,
          '-e',
          env,
          '-g',
          globals,
          '--env-var',
          'who=cli-env',
          '--env-var',
          'fromEnv=a=b',
          '--global-var',
          'fromGlobals=cli-global',
        ]);
        expect(r.code, 0);
        expect(seen.single.query, 'who=cli-env&g=cli-global&e=a%3Db');

        // --env-var alone makes an environment; a Postman data file works too.
        seen.clear();
        r = await cli(['run', collection, '--env-var', 'base=$base']);
        expect(r.code, 0);
        expect(seen.single.query, contains('who=collection'));
      },
    );

    test('JSON data files, -n cycling the rows, and --delay-request', () async {
      final ws = workspace(
        [
          CollectionModel(
            name: 'Ping',
            requests: [RequestModel(name: 'P', url: '{{base}}/p/{{n}}')],
          ),
        ],
        [staging()],
      );
      final data = file('rows.json', '[{"n": 1}, {"n": "two"}]');
      final started = DateTime.now();
      final r = await cli([
        'run',
        ws,
        '-e',
        'Staging',
        '-d',
        data,
        '-n',
        '3',
        '--delay-request',
        '120',
      ]);
      expect(r.code, 0, reason: r.out + r.err);
      expect(seen.map((s) => s.path), ['/p/1', '/p/two', '/p/1']);
      expect(
        DateTime.now().difference(started).inMilliseconds,
        greaterThanOrEqualTo(3 * 120),
      );
    });

    test('--folder runs a folder and the folders inside it', () async {
      final ws = workspace([shop()], [staging()]);
      var r = await cli([
        'run',
        ws,
        '-e',
        'Staging',
        '--folder',
        'Users/Admin',
      ]);
      expect(r.code, 0, reason: r.out + r.err);
      expect(seen.map((s) => s.path), ['/ping']);

      seen.clear();
      r = await cli(['run', ws, '-e', 'Staging', '--folder', '/Users/']);
      // Get user needs the token from Login, which this selection leaves out.
      expect(r.code, 1);
      expect(seen.map((s) => s.path), ['/users/0', '/ping']);

      seen.clear();
      r = await cli([
        'run',
        ws,
        '-e',
        'Staging',
        '--folder',
        'Users/Admin',
        '--folder',
        'Users/Admin',
      ]);
      expect(seen.length, 1, reason: 'a request is not run twice');
    });

    test('--bail stops at the first failed request', () async {
      final ws = workspace(
        [
          CollectionModel(
            name: 'Bail',
            requests: [
              RequestModel(name: 'Ok', url: '{{base}}/ping'),
              RequestModel(name: 'Bad', url: '{{base}}/fail'),
              RequestModel(name: 'Never', url: '{{base}}/ping'),
            ],
          ),
        ],
        [staging()],
      );
      final json = '${dir.path}/bail.json';
      final r = await cli([
        'run',
        ws,
        '-e',
        'Staging',
        '-n',
        '3',
        '--bail',
        '-r',
        'json',
        '--reporter-json-export',
        json,
      ]);
      expect(r.code, 1);
      expect(seen.map((s) => s.path), ['/ping', '/fail']);
      final report = jsonDecode(File(json).readAsStringSync()) as Map;
      expect(report['stoppedEarly'], isTrue);
      expect(
        (report['failures'] as List).single,
        containsPair('type', 'StatusError'),
      );
      // Without --bail all of it runs.
      seen.clear();
      await cli(['run', ws, '-e', 'Staging']);
      expect(seen.length, 3);
    });

    test('--timeout-request fails a slow request', () async {
      final ws = workspace(
        [
          CollectionModel(
            name: 'Slow',
            requests: [RequestModel(name: 'Slow', url: '{{base}}/slow')],
          ),
        ],
        [staging()],
      );
      final clock = Stopwatch()..start();
      final r = await cli([
        'run',
        ws,
        '-e',
        'Staging',
        '--timeout-request',
        '300',
      ]);
      expect(r.code, 1);
      expect(clock.elapsedMilliseconds, lessThan(2500));
      expect(r.out, contains('RequestError'));
      expect(r.out, contains('timed out after 300 ms'));
      expect(r.out, contains('[errored]'));
    });

    test('an unreachable host is a failed request, not a crash', () async {
      final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadUrl = 'http://127.0.0.1:${dead.port}';
      await dead.close();
      final ws = workspace([
        CollectionModel(
          name: 'Down',
          requests: [RequestModel(name: 'Down', url: '$deadUrl/x')],
        ),
      ]);
      final r = await cli(['run', ws]);
      expect(r.code, 1);
      expect(r.out, contains('RequestError'));
    });

    test('secret variable values are masked in every report', () async {
      final ws = workspace([shop()], [staging()]);
      final json = '${dir.path}/secret.json';
      final html = '${dir.path}/secret.html';
      final r = await cli([
        'run',
        ws,
        '-e',
        'Staging',
        '-r',
        'cli,json,html',
        '--reporter-json-export',
        json,
        '--reporter-html-export',
        html,
        '--verbose',
      ]);
      expect(seen.any((s) => s.query.contains('sup3r-s3cret-key')), isTrue);
      for (final text in [
        r.out,
        File(json).readAsStringSync(),
        File(html).readAsStringSync(),
      ]) {
        expect(text, isNot(contains('sup3r-s3cret-key')));
      }
      expect(File(json).readAsStringSync(), contains('/users/0?key='));
    });
  });

  group('scripts', () {
    CollectionModel scripted() => CollectionModel(
      name: 'Scripted',
      requests: [
        RequestModel(name: 'A', url: '{{base}}/a', testScript: 'a'),
        RequestModel(name: 'B', url: '{{base}}/b'),
        RequestModel(name: 'C', url: '{{base}}/c', testScript: 'c'),
      ],
    );

    test('script tests, setNextRequest and logs reach the reports', () async {
      final ws = workspace([scripted()], [staging()]);
      final junit = '${dir.path}/s.xml';
      final engine = FakeEngine((scripts, ctx) {
        if (ctx.request.name == 'A') {
          return ScriptOutcome(
            tests: [
              const ScriptTestResult('status is 200', true),
              const ScriptTestResult('has a token', false, error: 'no token'),
            ],
            logs: [ConsoleLine(ConsoleLevel.log, 'hello from A')],
            next: const NextRequest.named('C'),
          );
        }
        return ScriptOutcome(tests: [const ScriptTestResult('c ran', true)]);
      });
      final r = await cli([
        'run',
        ws,
        '-e',
        'Staging',
        '-r',
        'cli,junit',
        '--reporter-junit-export',
        junit,
      ], engine: () => engine);
      expect(r.code, 1);
      expect(engine.disposed, isTrue);
      expect(seen.map((s) => s.path), ['/a', '/c'], reason: 'B is skipped');
      expect(r.err, isEmpty);
      expect(r.out, contains('hello from A'));
      expect(r.out, contains('has a token - no token'));
      expect(r.out, contains('TestError'));
      expect(r.out, contains('tests'));
      final xml = File(junit).readAsStringSync();
      expect(xml, contains('name="status is 200"'));
      expect(
        xml,
        contains(
          '<failure message="no token" type="TestError">no token</failure>',
        ),
      );
      expect(xml, contains('name="c ran"'));
    });

    test('a script error fails the request', () async {
      final ws = workspace([scripted()], [staging()]);
      final json = '${dir.path}/e.json';
      final engine = FakeEngine(
        (scripts, ctx) => ScriptOutcome(error: 'ReferenceError: nope'),
      );
      final r = await cli([
        'run',
        ws,
        '-e',
        'Staging',
        '-r',
        'json',
        '--reporter-json-export',
        json,
      ], engine: () => engine);
      expect(r.code, 1);
      final report = jsonDecode(File(json).readAsStringSync()) as Map;
      final failure = (report['failures'] as List).first as Map;
      expect(failure['type'], 'ScriptError');
      expect(failure['message'], 'ReferenceError: nope');
    });

    test(
      'without a script engine one warning says scripts are skipped',
      () async {
        final ws = workspace([scripted()], [staging()]);
        final json = '${dir.path}/w.json';
        final r = await cli([
          'run',
          ws,
          '-e',
          'Staging',
          '-r',
          'cli,json',
          '--reporter-json-export',
          json,
        ], engine: () => null);
        expect(r.code, 0);
        expect(
          RegExp('no script engine').allMatches(r.err).length,
          1,
          reason: r.err,
        );
        expect(r.err.trim().split('\n').length, 1);
        final report = jsonDecode(File(json).readAsStringSync()) as Map;
        expect(
          (report['warnings'] as List).single,
          contains('no script engine'),
        );

        // A collection without scripts gets no warning.
        final plain = workspace([shop()], [staging()]);
        final quiet = await cli(['run', plain, '-e', 'Staging']);
        expect(quiet.err, isEmpty);
      },
    );
  });

  group('reporters', () {
    test(
      'colors only on a terminal, and never with --no-color or NO_COLOR',
      () async {
        final ws = workspace([shop()], [staging()]);
        final args = ['run', ws, '-e', 'Staging'];
        expect((await cli(args)).out, isNot(contains('\u001B[')));
        expect((await cli(args, terminal: true)).out, contains('\u001B[32m'));
        expect(
          (await cli([...args, '--no-color'], terminal: true)).out,
          isNot(contains('\u001B[')),
        );
        expect(
          (await cli(args, terminal: true, env: {'NO_COLOR': '1'})).out,
          isNot(contains('\u001B[')),
        );
      },
    );

    test('--verbose shows response headers and bodies', () async {
      final ws = workspace([shop()], [staging()]);
      final quiet = await cli(['run', ws, '-e', 'Staging']);
      expect(quiet.out, isNot(contains('"token":"tok"')));
      final loud = await cli(['run', ws, '-e', 'Staging', '--verbose']);
      expect(loud.out, contains('< content-type: application/json'));
      expect(loud.out, contains('"token":"tok"'));
    });

    test('the html report is one self-contained, escaped page', () async {
      final ws = workspace(
        [
          CollectionModel(
            name: 'A <b>&"x"',
            requests: [RequestModel(name: '<i>Fail</i>', url: '{{base}}/fail')],
          ),
        ],
        [staging()],
      );
      final html = '${dir.path}/r.html';
      final r = await cli([
        'run',
        ws,
        '-e',
        'Staging',
        '-r',
        'html',
        '--reporter-html-export',
        html,
      ]);
      expect(r.code, 1);
      expect(r.out, isEmpty, reason: 'no cli reporter, no console output');
      final page = File(html).readAsStringSync();
      expect(page, startsWith('<!doctype html>'));
      expect(page, contains('A &lt;b&gt;&amp;&quot;x&quot;'));
      expect(page, contains('&lt;i&gt;Fail&lt;/i&gt;'));
      expect(page, contains('boom &lt;b&gt;'));
      expect(page, isNot(contains('<i>Fail')));
      expect(page, isNot(contains('<script')));
      expect(page, isNot(contains('<link')));
      expect(page, isNot(contains('src=')));
      expect(page, contains('prefers-color-scheme'));
      expect(page, contains('Failures (1)'));
    });

    test(
      'a reporter without an export path writes into apiworkbench-reports',
      () async {
        final ws = workspace([shop()], [staging()]);
        final before = Directory.current;
        Directory.current = dir;
        try {
          final r = await cli([
            'run',
            ws,
            '-e',
            'Staging',
            '-r',
            'json,junit,html',
          ]);
          expect(r.code, 0);
          final files = Directory(
            '${dir.path}/apiworkbench-reports',
          ).listSync().map((f) => f.path.split(RegExp(r'[\\/]')).last).toList();
          expect(files.length, 3);
          expect(files.where((f) => f.endsWith('.json')), hasLength(1));
          expect(files.where((f) => f.endsWith('.xml')), hasLength(1));
          expect(files.where((f) => f.endsWith('.html')), hasLength(1));
          expect(
            r.err,
            allOf(contains('Wrote the json report'), contains('.xml')),
          );
        } finally {
          Directory.current = before;
        }
      },
    );

    test('an export path that cannot be written is exit code 2', () async {
      final ws = workspace([shop()], [staging()]);
      final blocker = file('blocker', 'a file, not a folder');
      final r = await cli([
        'run',
        ws,
        '-e',
        'Staging',
        '--reporter-json-export',
        '$blocker/out.json',
      ]);
      expect(r.code, 2);
      expect(r.err, contains('Cannot write the json report'));
    });

    test('format helpers', () {
      expect(formatBytes(512), '512B');
      expect(formatBytes(1536), '1.5kB');
      expect(formatMs(85), '85ms');
      expect(formatMs(1234), '1.2s');
      expect(formatMs(125000), '2m 5s');
      expect(
        xmlEscape('a<b>&"\'\u0001\u0008x'),
        'a&lt;b&gt;&amp;&quot;&#39;x',
        reason: 'markup escaped, control characters dropped',
      );
    });
  });

  group('input files', () {
    test('--collection picks one of several, by name or id', () async {
      final a = CollectionModel(
        name: 'Alpha',
        requests: [RequestModel(name: 'A', url: '{{base}}/alpha')],
      );
      final b = CollectionModel(
        name: 'Beta',
        requests: [RequestModel(name: 'B', url: '{{base}}/beta')],
      );
      final ws = workspace([a, b], [staging()]);

      var r = await cli(['run', ws, '-e', 'Staging']);
      expect(r.code, 2);
      expect(r.err, allOf(contains('2 collections'), contains('"Alpha"')));

      r = await cli(['run', ws, '-e', 'Staging', '--collection', 'beta']);
      expect(r.code, 0, reason: r.out + r.err);
      expect(seen.single.path, '/beta');

      seen.clear();
      r = await cli(['run', ws, '-e', 'Staging', '--collection', a.id]);
      expect(r.code, 0);
      expect(seen.single.path, '/alpha');

      r = await cli(['run', ws, '--collection', 'Gamma']);
      expect(r.code, 2);
      expect(r.err, contains('No collection named "Gamma"'));
    });

    test('only HTTP requests run', () async {
      final ws = workspace([
        CollectionModel(
          name: 'Mixed',
          requests: [
            RequestModel(
              name: 'Socket',
              kind: RequestKind.websocket,
              url: 'ws://x',
            ),
            RequestModel(name: 'Http', url: '$base/http'),
          ],
        ),
      ]);
      final r = await cli(['run', ws]);
      expect(r.code, 0);
      expect(seen.single.path, '/http');
    });
  });

  group('arguments', () {
    test('--version and --help succeed', () async {
      final v = await cli(['--version']);
      expect(v.code, 0);
      expect(v.out.trim(), cliVersion);
      for (final args in [
        ['--help'],
        ['-h'],
        ['run', '--help'],
      ]) {
        final h = await cli(args);
        expect(h.code, 0);
        expect(h.out, contains('apiworkbench-cli run <file>'));
        expect(h.out, contains('--iteration-data'));
        expect(h.out, contains('--reporter-junit-export'));
        expect(h.out, contains('Exit codes'));
      }
    });

    test('the version matches pubspec.yaml', () {
      final line = File(
        'pubspec.yaml',
      ).readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
      final pubspec = line.replaceFirst('version:', '').trim().split('+').first;
      expect(
        cliVersion,
        pubspec,
        reason: 'update lib/cli/version.dart together with pubspec.yaml',
      );
    });

    test('the CLI and everything it imports are free of Flutter', () {
      // `dart compile` of bin/apiworkbench_cli.dart fails on a Flutter import;
      // this finds the file that brought it in.
      final seenFiles = <String>{};
      final queue = ['bin/apiworkbench_cli.dart'];
      final importRe = RegExp(
        r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
        multiLine: true,
      );
      while (queue.isNotEmpty) {
        final path = queue.removeLast();
        if (!seenFiles.add(path)) continue;
        final text = File(path).readAsStringSync();
        for (final m in importRe.allMatches(text)) {
          final uri = m.group(1)!;
          expect(
            uri.startsWith('package:flutter') || uri == 'dart:ui',
            isFalse,
            reason: '$path imports $uri',
          );
          if (uri.startsWith('package:api_workbench/')) {
            queue.add('lib/${uri.substring('package:api_workbench/'.length)}');
          } else if (!uri.contains(':')) {
            final dir = path.substring(0, path.lastIndexOf('/'));
            queue.add(Uri.parse('$dir/$uri').normalizePath().path);
          }
        }
      }
      expect(seenFiles, contains('lib/services/executor.dart'));
      expect(seenFiles, contains('lib/cli/runner.dart'));
      expect(seenFiles, isNot(contains('lib/services/runner.dart')));
      expect(seenFiles, isNot(contains('lib/state/app_state.dart')));
    });

    test('wrong arguments exit with code 2 and say why', () async {
      final ws = workspace([shop()], [staging()]);
      final cases = <List<String>, String>{
        []: 'Missing command',
        ['walk']: 'Unknown command "walk"',
        ['run']: 'Missing the collection file',
        ['run', 'a.json', 'b.json']: 'Expected one file',
        ['run', ws, '--bogus']: 'Could not find an option named "--bogus"',
        ['run', ws, '-n', '0']:
            '--iteration-count needs a whole number of at least 1',
        ['run', ws, '-n', 'many']: '--iteration-count needs a whole number',
        ['run', ws, '--delay-request', '-5']:
            '--delay-request needs a whole number',
        ['run', ws, '--timeout-request', '0']:
            '--timeout-request needs a whole number',
        ['run', ws, '-r', 'xml']: 'Unknown reporter "xml"',
        ['run', ws, '--env-var', 'novalue']: '--env-var needs key=value',
        ['run', ws, '--global-var', '=x']: '--global-var needs key=value',
        ['run', ws, '--reporter-json-export']: 'Missing argument',
        ['run', ws, '--reporter-junit-export', ' ']: 'needs a file name',
        ['--no-such-flag']: 'Could not find an option',
      };
      for (final e in cases.entries) {
        final r = await cli(e.key);
        expect(r.code, 2, reason: '${e.key}\n${r.out}${r.err}');
        expect(r.err, contains(e.value), reason: '${e.key}');
        expect(r.out, isEmpty, reason: 'errors go to stderr: ${e.key}');
      }
      expect(seen, isEmpty, reason: 'nothing was sent');
    });

    test('unreadable or wrong files exit with code 2', () async {
      final ws = workspace([shop()], [staging()]);
      final cases = <List<String>, String>{
        ['run', '${dir.path}/missing.json']: 'Cannot read',
        ['run', file('bad.json', 'not json')]: 'not valid JSON',
        ['run', file('other.json', '{"hello": 1}')]: 'Not a Postman',
        [
          'run',
          file('envonly.json', jsonEncode({'name': 'E', 'values': []})),
        ]: 'no collection to run',
        ['run', ws, '-e', 'Nowhere']: 'Cannot find the environment "Nowhere"',
        ['run', ws, '-e', '${dir.path}/nope.json']:
            'Cannot find the environment',
        ['run', ws, '-g', '${dir.path}/nope.json']: 'Cannot read',
        ['run', ws, '-d', '${dir.path}/nope.csv']: 'Cannot read',
        ['run', ws, '-d', file('empty.csv', '')]: 'empty',
        ['run', ws, '-d', file('header.csv', 'id\n')]: 'no data rows',
        ['run', ws, '-d', file('broken.csv', 'a,b\n"x')]: 'never closed',
        ['run', ws, '--folder', 'Orders']: 'No folder "Orders"',
      };
      for (final e in cases.entries) {
        final r = await cli(e.key);
        expect(r.code, 2, reason: '${e.key}\n${r.out}${r.err}');
        expect(r.err, contains(e.value), reason: '${e.key}');
      }
      expect(seen, isEmpty, reason: 'nothing was sent');
    });
  });
}
