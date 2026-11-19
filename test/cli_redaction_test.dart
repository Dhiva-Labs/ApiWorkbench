import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/cli/cli.dart';
import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/temp_dir.dart';

const _secretVar = 'pa ss/w+rd&=1';
const _cookie = 'session-cookie-424242';
const _literalToken = 'literal-access-token-99';
const _apiKeyValue = 'key-value-from-helper-31337';

/// The ways the secret can show up in a report.
final _secretForms = [
  _secretVar,
  Uri.encodeComponent(_secretVar),
  Uri.encodeQueryComponent(_secretVar),
  Uri.encodeFull(_secretVar),
];

void main() {
  late HttpServer server;
  late String base;
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('aw_cli_redact_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final res = req.response..headers.contentType = ContentType.json;
      res.headers
        ..add('set-cookie', 'sid=$_cookie; Path=/; HttpOnly')
        ..add('x-api-key', 'echoed-key-1234')
        ..add('location-hint', 'https://x.test/cb?token=hdr-token-5');
      // Echoes the URL it was called with, like many debugging endpoints.
      res.write(jsonEncode({'url': req.requestedUri.toString(), 'ok': true}));
      await res.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await deleteTempDir(dir);
  });

  String file(String name, String text) {
    final f = File('${dir.path}/$name')..writeAsStringSync(text);
    return f.path;
  }

  CollectionModel collection() => CollectionModel(
    name: 'Redaction',
    requests: [
      RequestModel(
        name: 'Secret variable in the query',
        url: '{{base}}/a?pw={{pw}}&page=1',
      ),
      RequestModel(
        name: 'Literal token',
        url: '{{base}}/b?access_token=$_literalToken&page=2',
      ),
      RequestModel(
        name: 'API Key helper',
        url: '{{base}}/c?page=3',
        authType: AuthType.apiKey,
        apiKeyName: 'k',
        apiKeyValue: _apiKeyValue,
        apiKeyInHeader: false,
      ),
    ],
  );

  EnvironmentModel env() => EnvironmentModel(
    name: 'Env',
    variables: [
      KV(key: 'base', value: base),
      KV(key: 'pw', value: _secretVar, secret: true),
    ],
  );

  Future<({int code, String out, Map<String, String> files})> run() async {
    final ws = file('ws.json', buildWorkspaceJson([collection()], [env()]));
    final paths = {
      'json': '${dir.path}/r.json',
      'html': '${dir.path}/r.html',
      'junit': '${dir.path}/r.xml',
    };
    final out = StringBuffer();
    final code = await runCli(
      [
        'run',
        ws,
        '-e',
        'Env',
        '-r',
        'cli,json,html,junit',
        '--reporter-json-export',
        paths['json']!,
        '--reporter-html-export',
        paths['html']!,
        '--reporter-junit-export',
        paths['junit']!,
        '--verbose',
      ],
      out: out,
      err: StringBuffer(),
      engineFactory: () => null,
      env: const {},
      isTerminal: false,
    );
    return (
      code: code,
      out: '$out',
      files: {
        'cli': '$out',
        for (final e in paths.entries) e.key: File(e.value).readAsStringSync(),
      },
    );
  }

  test('no report carries a credential, URL-encoded or not', () async {
    final r = await run();
    expect(r.code, 0);
    expect(r.files.keys, containsAll(['cli', 'json', 'html', 'junit']));
    for (final MapEntry(key: where, value: text) in r.files.entries) {
      for (final leak in [
        ..._secretForms,
        _cookie,
        _literalToken,
        _apiKeyValue,
        'echoed-key-1234',
        'hdr-token-5',
      ]) {
        expect(text, isNot(contains(leak)), reason: '$where holds $leak');
      }
    }
  });

  test('the JSON report keeps what is not a credential', () async {
    final r = await run();
    final json = jsonDecode(r.files['json']!) as Map<String, dynamic>;
    final steps = (json['executions'] as List).cast<Map>();
    final urls = [for (final s in steps) (s['request'] as Map)['url']];
    expect(urls, [
      '$base/a?pw=••••••&page=1',
      '$base/b?access_token=••••••&page=2',
      '$base/c?page=3&k=••••••',
    ]);

    final headers = (steps.first['response'] as Map)['headers'] as Map;
    // Set-Cookie keeps its name and attributes, never the value.
    expect(
      (headers['set-cookie'] as List).single,
      'sid=••••••; Path=/; HttpOnly',
    );
    expect(headers['x-api-key'], ['••••••']);
    expect(headers['content-type'], ['application/json; charset=utf-8']);
  });

  test('a body echoing the request URL is masked too', () async {
    final r = await run();
    final json = jsonDecode(r.files['json']!) as Map<String, dynamic>;
    final steps = (json['executions'] as List).cast<Map>();
    final bodies = [
      for (final s in steps) (s['response'] as Map)['body'] as String,
    ];
    expect(bodies[0], contains('pw=••••••&page=1'));
    expect(bodies[1], contains('access_token=••••••&page=2'));
    expect(bodies[2], contains('k=••••••'));
  });
}
