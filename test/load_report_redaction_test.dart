import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/load_report.dart';
import 'package:api_workbench/services/load_test.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/temp_dir.dart';

/// Credentials that must never reach a report or the log file.
const _apiKey = 'AKv-k3y-0123456789';
const _jwt = 'eyJhbGciOi.payload.jwt-sig-987654';
const _oauthToken = 'oauth-access-token-5551212';
const _secretVar = 's3cret/var value+1';
const _cookie = 'session-cookie-777888';

/// The values above in every shape a report could carry them.
final _leaks = [
  _apiKey,
  _jwt,
  _oauthToken,
  _secretVar,
  Uri.encodeQueryComponent(_secretVar),
  Uri.encodeComponent(_secretVar),
  Uri.encodeFull(_secretVar),
  _cookie,
];

/// Every URL the fixture was asked for, as the server saw it.
final _seen = <String>[];

Future<HttpServer> _fixture() async {
  _seen.clear();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    _seen.add(req.requestedUri.toString());
    final res = req.response..headers.contentType = ContentType.json;
    res.headers.add('set-cookie', 'sid=$_cookie; Path=/; HttpOnly');
    if (req.uri.path == '/fail') {
      // A server that echoes what it was sent.
      res.statusCode = 500;
      res.write(
        jsonEncode({
          'error': 'rejected',
          'url': req.requestedUri.toString(),
          'secret': _secretVar,
        }),
      );
    } else {
      res.write('{"ok":true}');
    }
    await res.close();
  });
  return server;
}

void main() {
  late HttpServer server;
  late String base;
  late Directory logDir;

  setUp(() async {
    server = await _fixture();
    base = 'http://127.0.0.1:${server.port}';
    logDir = await Directory.systemTemp.createTemp('aw_report_redact_');
  });
  tearDown(() async {
    await server.close(force: true);
    await deleteTempDir(logDir);
  });

  List<LoadStep> plan() => [
    // The API Key helper adds `auth_code` to the query.
    LoadStep(
      RequestModel(
        name: 'Key in query',
        url: '$base/fail?page=1',
        apiKeyName: 'auth_code',
        apiKeyValue: _apiKey,
        apiKeyInHeader: false,
        authType: AuthType.apiKey,
      ),
    ),
    // The JWT helper adds its token to the query.
    LoadStep(
      RequestModel(
        name: 'JWT in query',
        url: '$base/fail?page=2',
        authType: AuthType.jwt,
        authParams: {
          'addTokenTo': 'queryParam',
          'queryParamKey': 'jwt_param',
          'secret': 'a-jwt-signing-secret',
        },
      ),
    ),
    // OAuth 2.0 with the token in the query (the token is fixed here).
    LoadStep(
      RequestModel(
        name: 'Typed token and secret variable',
        url:
            '$base/fail?access_token=$_oauthToken&sv={{sv}}&sig=zz9'
            '&limit=5',
      ),
    ),
    // A request that passes: its Set-Cookie header must not leak either.
    LoadStep(RequestModel(name: 'Fine', url: '$base/ok?page=3')),
  ];

  Future<LoadTestService> run({bool recordBodies = true}) async {
    final svc = LoadTestService(AppSettings(), logDir: logDir);
    await svc.start(
      plan: plan(),
      config: LoadTestConfig(
        virtualUsers: 2,
        iterations: 1,
        stopOnFailure: false,
        bodies: recordBodies ? BodyCapture.all : BodyCapture.none,
      ),
      vars: const {'sv': _secretVar},
      secrets: const {_secretVar},
    );
    return svc;
  }

  void expectClean(String text, String where) {
    for (final leak in _leaks) {
      expect(text, isNot(contains(leak)), reason: '$where holds $leak');
    }
  }

  test('the stored call log and every export hold no credential', () async {
    final svc = await run();
    // Sanity: the requests really carried the credentials.
    expect(_seen.any((u) => u.contains('auth_code=$_apiKey')), isTrue);
    expect(_seen.any((u) => u.contains('jwt_param=eyJ')), isTrue);
    expect(_seen.any((u) => u.contains('access_token=$_oauthToken')), isTrue);
    expect(_seen.any((u) => u.contains(Uri.encodeFull(_secretVar))), isTrue);
    final entries = await svc.log!.entries().toList();
    expect(entries.length, 8);

    final json = await buildLoadJson(svc, 'Run');
    final csv = await buildLoadCsv(svc);
    final html = await buildLoadHtml(svc, 'Run');
    final onDisk = await svc.log!.file.readAsString();
    for (final (where, text) in [
      ('json', json),
      ('csv', csv),
      ('html', html),
      ('log file', onDisk),
    ]) {
      expectClean(text, where);
    }

    // The URLs are still useful: only the credentials are gone.
    final urls = entries.map((e) => e.url).toSet();
    expect(
      urls,
      containsAll([
        '$base/fail?page=1&auth_code=••••••',
        '$base/fail?page=2&jwt_param=••••••',
        '$base/ok?page=3',
      ]),
    );
    expect(
      urls.any(
        (u) =>
            u.contains('access_token=••••••') &&
            u.contains('sig=••••••') &&
            u.contains('limit=5'),
      ),
      isTrue,
    );
    final summary = jsonDecode(json)['summary'] as Map;
    final requests = (summary['requests'] as List).cast<Map>();
    expect(requests[2]['url'], contains('access_token=••••••'));
    expect(requests[2]['url'], isNot(contains(_oauthToken)));
    svc.dispose();
  });

  test('a response body that echoes a secret is masked in the log', () async {
    final svc = await run();
    final bodies = [
      for (final e in await svc.log!.entries().toList())
        if (e.body != null) e.body!,
    ];
    expect(bodies, isNotEmpty);
    for (final b in bodies) {
      expect(b, isNot(contains(_secretVar)));
      expect(b, isNot(contains(_apiKey)));
    }
    svc.dispose();
  });

  test('errors are masked before they are cut or counted', () async {
    // A refused connection: the transport error mentions the URL.
    final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final deadUrl = 'http://127.0.0.1:${dead.port}';
    await dead.close(force: true);
    final svc = LoadTestService(AppSettings(), logDir: logDir);
    await svc.start(
      plan: [
        LoadStep(RequestModel(url: '$deadUrl/x?api_key=$_apiKey&token={{sv}}')),
      ],
      config: LoadTestConfig(virtualUsers: 1, iterations: 1),
      vars: const {'sv': _secretVar},
      secrets: const {_secretVar},
    );
    final entry = (await svc.log!.entries().toList()).single;
    expect(entry.status, 0);
    for (final text in [
      entry.error ?? '',
      entry.url,
      await buildLoadJson(svc, 'Dead'),
      await buildLoadCsv(svc),
      await buildLoadHtml(svc, 'Dead'),
    ]) {
      expectClean(text, 'error report');
      expect(text, isNot(contains(_apiKey)));
    }
    svc.dispose();
  });

  test('HTML escaping and CSV formula neutralising still apply', () async {
    final svc = LoadTestService(AppSettings(), logDir: logDir);
    await svc.start(
      plan: [
        LoadStep(
          RequestModel(
            name: '=HYPERLINK("x")<script>alert(1)</script>',
            url: '$base/fail?token=$_apiKey',
          ),
        ),
      ],
      config: LoadTestConfig(
        virtualUsers: 1,
        iterations: 1,
        bodies: BodyCapture.all,
      ),
      vars: const {},
    );
    final html = await buildLoadHtml(svc, 'T <b>');
    expect(html, isNot(contains('<script>alert(1)')));
    expect(html, contains('&lt;script&gt;'));
    final csv = await buildLoadCsv(svc);
    expect(csv, contains("\"'=HYPERLINK(\"\"x\"\")<script>"));
    expect(csv, isNot(contains(_apiKey)));
    svc.dispose();
  });
}
