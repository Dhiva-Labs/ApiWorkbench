import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/http_service.dart';
import 'package:api_workbench/services/runner.dart';

void main() {
  test('live GET with env vars, params and headers', () async {
    final svc = HttpService();
    final req = RequestModel(
      method: 'GET',
      url: '{{base}}/get',
      params: [KV(key: 'q', value: '{{term}}')],
      headers: [KV(key: 'X-Client', value: 'restflow')],
      authType: AuthType.bearer,
      bearerToken: 'abc',
    );
    final res = await svc.send(req,
        {'base': 'https://postman-echo.com', 'term': 'hello'},
        tabId: 't1');
    expect(res.error, isNull);
    expect(res.statusCode, 200);
    final body = jsonDecode(res.bodyText) as Map<String, dynamic>;
    expect(body['args']['q'], 'hello');
    expect(body['headers']['x-client'], 'restflow');
    expect(body['headers']['authorization'], 'Bearer abc');
  });

  test('live POST json body', () async {
    final svc = HttpService();
    final req = RequestModel(
      method: 'POST',
      url: 'https://postman-echo.com/post',
      bodyType: BodyType.json,
      body: '{"name":"dhiva"}',
    );
    final res = await svc.send(req, {}, tabId: 't2');
    expect(res.statusCode, 200);
    final body = jsonDecode(res.bodyText) as Map<String, dynamic>;
    expect(body['data']['name'], 'dhiva');
  });

  test('connection error is reported, not thrown', () async {
    final svc = HttpService();
    final req = RequestModel(url: 'https://nope.invalid.restflow.test/x');
    final res = await svc.send(req, {}, tabId: 't3');
    expect(res.error, isNotNull);
  });

  test('runner: 2 iterations with assertions, stats populated', () async {
    final runner = RunnerService(HttpService());
    final req = RequestModel(
      name: 'echo',
      url: 'https://postman-echo.com/get',
      params: [KV(key: 'v', value: '1')],
      assertions: [
        AssertionModel(kind: AssertKind.statusEquals, expected: '200'),
        AssertionModel(
            kind: AssertKind.jsonEquals, target: 'args.v', expected: '1'),
      ],
    );
    await runner.start(requests: [req], vars: {}, iterations: 2);
    expect(runner.results.length, 2);
    expect(runner.passed, 2);
    expect(runner.failed, 0);
    expect(runner.results.last.iteration, 2);
    expect(runner.avgMs, greaterThan(0));
    expect(runner.maxMs, greaterThanOrEqualTo(runner.minMs));
  });

  test('runner: recurring mode repeats until stopped', () async {
    final runner = RunnerService(HttpService());
    final req = RequestModel(url: 'https://postman-echo.com/get');
    final done = runner.start(
      requests: [req],
      vars: {},
      repeatEvery: const Duration(seconds: 1),
    );
    // Let it finish at least one pass, then stop during the wait.
    while (runner.results.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    runner.stop();
    await done;
    expect(runner.running, isFalse);
    expect(runner.results, isNotEmpty);
    expect(runner.results.first.pass, isTrue);
  });

  test('runner: data-driven run substitutes one row per iteration', () async {
    final runner = RunnerService(HttpService());
    final req = RequestModel(
      name: 'data',
      url: 'https://postman-echo.com/get',
      params: [KV(key: 'rid', value: '{{rid}}')],
      assertions: [
        AssertionModel(kind: AssertKind.statusEquals, expected: '200'),
      ],
    );
    await runner.start(
      requests: [req],
      vars: {},
      dataRows: [
        {'rid': 'alpha'},
        {'rid': 'beta'},
      ],
    );
    expect(runner.results.length, 2); // iterations follow the data rows
    expect(runner.passed, 2);
    expect(runner.results[0].response.bodyText, contains('alpha'));
    expect(runner.results[1].response.bodyText, contains('beta'));
  });

  test('live GraphQL body posts query + variables JSON envelope', () async {
    final svc = HttpService();
    final req = RequestModel(
      method: 'POST',
      url: 'https://postman-echo.com/post',
      bodyType: BodyType.graphql,
      body: 'query Users(\$limit: Int) { users(limit: \$limit) { id } }',
      graphqlVariables: '{"limit": {{n}}}',
    );
    final res = await svc.send(req, {'n': '7'}, tabId: 'gql');
    expect(res.statusCode, 200);
    final body = jsonDecode(res.bodyText) as Map<String, dynamic>;
    final echoed = body['json'] as Map<String, dynamic>;
    expect(echoed['query'], contains('users(limit:'));
    expect(echoed['variables'], {'limit': 7});
  });

  test('invalid GraphQL variables produce a readable error, no crash',
      () async {
    final svc = HttpService();
    final req = RequestModel(
      method: 'POST',
      url: 'https://postman-echo.com/post',
      bodyType: BodyType.graphql,
      body: 'query {}',
      graphqlVariables: '{not json',
    );
    final res = await svc.send(req, {}, tabId: 'gql2');
    expect(res.error, contains('GraphQL variables'));
  });
}
