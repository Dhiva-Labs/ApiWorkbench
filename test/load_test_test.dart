import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/load_report.dart';
import 'package:api_workbench/services/load_test.dart';
import 'package:flutter_test/flutter_test.dart';

/// A tiny API: /login issues a token, /me requires it, /boom always fails.
Future<HttpServer> _fixture() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var counter = 0;
  server.listen((req) async {
    final res = req.response..headers.contentType = ContentType.json;
    switch (req.uri.path) {
      case '/login':
        await utf8.decoder.bind(req).join();
        res.write(
          jsonEncode({
            'data': {'token': 'tok-${++counter}'},
          }),
        );
      case '/me':
        final auth = req.headers.value('authorization') ?? '';
        if (auth.startsWith('Bearer tok-')) {
          res.write(jsonEncode({'vu': req.uri.queryParameters['vu']}));
        } else {
          res.statusCode = 401;
          res.write('{"error":"no token"}');
        }
      default:
        res.statusCode = 500;
        res.write('{}');
    }
    await res.close();
  });
  return server;
}

void main() {
  late HttpServer server;
  late String base;

  setUp(() async {
    server = await _fixture();
    base = 'http://127.0.0.1:${server.port}';
  });
  tearDown(() => server.close(force: true));

  test('histogram percentiles are close to exact', () {
    final h = LatencyHistogram();
    for (var i = 1; i <= 1000; i++) {
      h.record(i);
    }
    expect(h.percentile(50), inInclusiveRange(495, 505));
    expect(h.percentile(99), inInclusiveRange(985, 1000));
  });

  test('sequential users chain an extracted token into later steps', () async {
    final svc = LoadTestService(AppSettings());
    final plan = [
      LoadStep(
        RequestModel(name: 'Login', method: 'POST', url: '$base/login'),
        extract: {'token': 'body.data.token'},
      ),
      LoadStep(
        RequestModel(
          name: 'Me',
          url: '$base/me?vu={{vu}}',
          authType: AuthType.bearer,
          bearerToken: '{{token}}',
          assertions: [AssertionModel(expected: '200')],
        ),
      ),
    ];
    await svc.start(
      plan: plan,
      config: LoadTestConfig(virtualUsers: 5, iterations: 4),
      vars: const {},
    );
    expect(svc.running, isFalse);
    expect(svc.total.count, 5 * 4 * 2);
    expect(svc.failed, 0);
    expect(svc.iterationsDone, 20);
    expect(svc.steps[1].statusCounts, {200: 20});
    svc.dispose();
  });

  test('without the token the dependent step fails its test', () async {
    final svc = LoadTestService(AppSettings());
    await svc.start(
      plan: [
        LoadStep(
          RequestModel(
            url: '$base/me',
            assertions: [AssertionModel(expected: '200')],
          ),
        ),
      ],
      config: LoadTestConfig(virtualUsers: 2, iterations: 3),
      vars: const {},
    );
    expect(svc.failed, 6);
    expect(svc.steps.single.errors.keys.single, startsWith('Test failed'));
    svc.dispose();
  });

  test(
    'parallel mode runs every step and stop on failure is skipped',
    () async {
      final svc = LoadTestService(AppSettings());
      await svc.start(
        plan: [
          LoadStep(RequestModel(url: '$base/boom')),
          LoadStep(RequestModel(method: 'POST', url: '$base/login')),
        ],
        config: LoadTestConfig(virtualUsers: 3, iterations: 2, parallel: true),
        vars: const {},
      );
      expect(svc.total.count, 12);
      expect(svc.steps[0].failed, 6);
      expect(svc.steps[1].passed, 6);
      svc.dispose();
    },
  );

  test('stop ends a duration run promptly', () async {
    final svc = LoadTestService(AppSettings());
    final run = svc.start(
      plan: [LoadStep(RequestModel(method: 'POST', url: '$base/login'))],
      config: LoadTestConfig(virtualUsers: 3, durationSec: 30),
      vars: const {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    svc.stop();
    await run.timeout(const Duration(seconds: 5));
    expect(svc.running, isFalse);
    expect(svc.total.count, greaterThan(0));
    svc.dispose();
  });

  group('call log and reports', () {
    late Directory logDir;
    setUp(
      () async => logDir = await Directory.systemTemp.createTemp('aw_log_'),
    );
    tearDown(() => logDir.delete(recursive: true));

    test('100 parallel calls are each logged and exported', () async {
      final svc = LoadTestService(AppSettings(), logDir: logDir);
      await svc.start(
        plan: [
          LoadStep(
            RequestModel(name: 'Login', method: 'POST', url: '$base/login'),
          ),
        ],
        config: LoadTestConfig(
          virtualUsers: 100,
          iterations: 3,
          bodies: BodyCapture.all,
        ),
        vars: const {},
      );
      expect(svc.total.count, 300);
      final log = svc.log!;
      expect(log.count, 300);
      expect(log.recent.length, LoadLog.recentLimit);

      final entries = await log.entries().toList();
      expect(entries.map((e) => e.seq).toSet().length, 300);
      expect(entries.map((e) => e.vu).toSet().length, 100);
      expect(entries.map((e) => e.iteration).toSet(), {1, 2, 3});
      expect(entries.every((e) => e.pass && e.status == 200), isTrue);
      expect(entries.first.body, contains('tok-'));

      final csv = await buildLoadCsv(svc);
      expect(csv.trim().split('\r\n').length, 301); // header + one per call

      final json = jsonDecode(await buildLoadJson(svc, 'Login')) as Map;
      expect((json['calls'] as List).length, 300);
      expect(json['summary']['totals']['requests'], 300);
      expect(json['summary']['config']['virtualUsers'], 100);

      final html = await buildLoadHtml(svc, 'Login <api>');
      expect(html, contains('Login &lt;api&gt;'));
      expect(html, contains('300 calls.'));
      expect(html, contains('Saved responses'));

      final file = log.file;
      svc.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(file.existsSync(), isFalse, reason: 'log removed on dispose');
    });

    test('failures-only keeps bodies just for failed calls', () async {
      final svc = LoadTestService(AppSettings(), logDir: logDir);
      await svc.start(
        plan: [
          LoadStep(RequestModel(url: '$base/boom')),
          LoadStep(RequestModel(method: 'POST', url: '$base/login')),
        ],
        config: LoadTestConfig(virtualUsers: 4, iterations: 2, parallel: true),
        vars: const {},
      );
      final entries = await svc.log!.entries().toList();
      expect(entries.length, 16);
      for (final e in entries) {
        expect(e.body != null, !e.pass, reason: 'call #${e.seq}');
      }
      expect(entries.where((e) => !e.pass).first.error, 'HTTP 500');
      svc.dispose();
    });

    test('logging off writes nothing', () async {
      final svc = LoadTestService(AppSettings(), logDir: logDir);
      await svc.start(
        plan: [LoadStep(RequestModel(method: 'POST', url: '$base/login'))],
        config: LoadTestConfig(
          virtualUsers: 2,
          iterations: 2,
          recordLog: false,
        ),
        vars: const {},
      );
      expect(svc.total.count, 4);
      expect(svc.log, isNull);
      expect(logDir.listSync(), isEmpty);
      svc.dispose();
    });

    test('until-stopped keeps repeating past the iteration count', () async {
      final svc = LoadTestService(AppSettings(), logDir: logDir);
      final run = svc.start(
        plan: [LoadStep(RequestModel(method: 'POST', url: '$base/login'))],
        config: LoadTestConfig(
          virtualUsers: 5,
          iterations: 1,
          untilStopped: true,
        ),
        vars: const {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(svc.running, isTrue);
      expect(svc.progress, isNull);
      svc.stop();
      await run.timeout(const Duration(seconds: 5));
      expect(svc.total.count, greaterThan(5));
      expect(svc.log!.count, svc.total.count);
      svc.dispose();
    });
  });
}
