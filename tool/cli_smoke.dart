// Smoke test for a built apiworkbench-cli, on any platform:
//
//   dart tool/cli_smoke.dart <path to apiworkbench-cli[.exe|.cmd]>
//
// Starts a throwaway HTTP server on 127.0.0.1, runs a small collection against
// it with an environment file and a CSV data file, and checks the exit codes
// (0 passed, 1 failed, 2 wrong arguments) and the json and junit reports.
// Plain Dart with no package imports, so CI can run it with the Flutter SDK's
// dart before and after packaging.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: dart tool/cli_smoke.dart <apiworkbench-cli>');
    exit(2);
  }
  final exe = args.single;
  final viaShell = exe.toLowerCase().endsWith('.cmd');

  Future<ProcessResult> cli(List<String> a) =>
      Process.run(exe, a, runInShell: viaShell);

  void check(bool ok, String what, [ProcessResult? r]) {
    if (ok) {
      stdout.writeln('ok   $what');
      return;
    }
    stderr.writeln('FAIL $what');
    if (r != null) {
      stderr.writeln('exit code ${r.exitCode}\n${r.stdout}\n${r.stderr}');
    }
    exitCode = 1;
  }

  final version = await cli(['--version']);
  check(
    version.exitCode == 0 &&
        RegExp(r'^\d+\.\d+\.\d+').hasMatch('${version.stdout}'.trim()),
    '--version prints a version (${'${version.stdout}'.trim()})',
    version,
  );

  // GET /ping gives a token; GET /users/<id> needs it back in X-Token and
  // answers 404 for the id 404.
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final path = req.uri.path;
    final res = req.response..headers.contentType = ContentType.json;
    if (path == '/ping') {
      res.write('{"ok":true,"token":"tok-123"}');
    } else if (path.startsWith('/users/') &&
        req.headers.value('x-token') == 'tok-123') {
      final id = path.substring('/users/'.length);
      if (id == '404') {
        res.statusCode = 404;
        res.write('{"error":"not found"}');
      } else {
        res.write('{"id":"$id","name":"user $id"}');
      }
    } else {
      res.statusCode = 401;
      res.write('{"error":"no token"}');
    }
    await res.close();
  });

  final dir = Directory.systemTemp.createTempSync('aw_cli_smoke_');
  try {
    String write(String name, String text) {
      final f = File('${dir.path}${Platform.pathSeparator}$name')
        ..writeAsStringSync(text);
      return f.path;
    }

    Map<String, Object?> assertion(String kind, String target, String want) => {
      'kind': kind,
      't': target,
      'x': want,
      'e': true,
    };
    final collection = write(
      'workspace.json',
      jsonEncode({
        'app': 'apiworkbench',
        'format': 1,
        'collections': [
          {
            'name': 'Smoke',
            'requests': [
              {
                'name': 'Ping',
                'method': 'GET',
                'url': '{{base}}/ping',
                'assertions': [
                  assertion('statusEquals', '', '200'),
                  assertion('jsonEquals', 'ok', 'true'),
                ],
                'captures': {'token': 'body.token'},
              },
              {
                'name': 'Get user',
                'method': 'GET',
                'url': '{{base}}/users/{{id}}',
                'folder': 'Users',
                'headers': [
                  {'k': 'X-Token', 'v': '{{token}}'},
                ],
                'assertions': [assertion('statusEquals', '', '200')],
              },
            ],
          },
        ],
        'environments': [],
      }),
    );
    final env = write(
      'env.json',
      jsonEncode({
        'name': 'smoke',
        'values': [
          {'key': 'base', 'value': 'http://127.0.0.1:${server.port}'},
        ],
      }),
    );
    final good = write('good.csv', 'id,name\n1,Ada\n2,"Linus, T"\n');
    final bad = write('bad.csv', 'id,name\n1,Ada\n404,Missing\n');
    final jsonOut = '${dir.path}${Platform.pathSeparator}report.json';
    final xmlOut = '${dir.path}${Platform.pathSeparator}report.xml';

    final pass = await cli([
      'run',
      collection,
      '-e',
      env,
      '-d',
      good,
      '--no-color',
      '-r',
      'cli,json,junit',
      '--reporter-json-export',
      jsonOut,
      '--reporter-junit-export',
      xmlOut,
    ]);
    check(pass.exitCode == 0, 'a passing run exits 0', pass);
    check('${pass.stdout}'.contains('Get user'), 'the cli reporter lists it');
    final report =
        jsonDecode(File(jsonOut).readAsStringSync()) as Map<String, dynamic>;
    final summary = report['summary'] as Map<String, dynamic>;
    check(
      (summary['iterations'] as Map)['executed'] == 2 &&
          (summary['requests'] as Map)['executed'] == 4 &&
          (summary['assertions'] as Map)['total'] == 6 &&
          (summary['assertions'] as Map)['failed'] == 0,
      'the json report counts 2 iterations, 4 requests, 6 assertions',
    );
    final xml = File(xmlOut).readAsStringSync();
    check(
      xml.contains('<testsuites') && xml.contains('failures="0"'),
      'the junit report has no failures',
    );

    final fail = await cli([
      'run', collection, '-e', env, '-d', bad, '--no-color', //
    ]);
    check(fail.exitCode == 1, 'a run with a failing request exits 1', fail);

    final usage = await cli(['run', collection, '--bogus']);
    check(usage.exitCode == 2, 'a wrong option exits 2', usage);
    final missing = await cli(['run', '${dir.path}/no-such-file.json']);
    check(missing.exitCode == 2, 'a missing file exits 2', missing);
  } finally {
    await server.close(force: true);
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // A temp folder left behind is not a failure.
    }
  }
  if (exitCode == 0) stdout.writeln('apiworkbench-cli smoke test passed');
}
