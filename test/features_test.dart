import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/curl.dart';
import 'package:api_workbench/services/doc_export.dart';
import 'package:api_workbench/services/runner.dart';
import 'package:api_workbench/services/workspace.dart';

void main() {
  group('workspace export/import', () {
    test('round trip preserves collections and environments', () {
      final col = CollectionModel(name: 'API', requests: [
        RequestModel(name: 'r1', url: 'https://x', method: 'POST'),
      ]);
      final env = EnvironmentModel(
          name: 'Dev', variables: [KV(key: 'base', value: 'https://x')]);
      final json = buildWorkspaceJson([col], [env]);
      final ws = parseWorkspaceJson(json);
      expect(ws.collections.single.name, 'API');
      expect(ws.collections.single.requests.single.method, 'POST');
      expect(ws.environments.single.variables.single.key, 'base');
      // Ids survive so re-imports replace instead of duplicating.
      expect(ws.collections.single.id, col.id);
    });

    test('rejects non-workspace files with a readable error', () {
      expect(() => parseWorkspaceJson('{"foo": 1}'),
          throwsA(isA<FormatException>()));
      expect(() => parseWorkspaceJson('not json'),
          throwsA(isA<FormatException>()));
    });
  });

  group('markdown doc export', () {
    test('contains request line, response body, and masks secrets', () {
      final r = RequestModel(
        name: 'Login',
        method: 'POST',
        url: 'https://api.x.dev/login',
        authType: AuthType.bearer,
        bearerToken: 'super-secret-token',
        headers: [KV(key: 'X-Api-Key', value: 'also-secret')],
        bodyType: BodyType.json,
        body: '{"user":"a"}',
      );
      final res = ResponseData(
        statusCode: 200,
        statusMessage: 'OK',
        headers: const {
          'content-type': ['application/json']
        },
        bodyBytes: utf8.encode('{"token":"xyz"}'),
        durationMs: 88,
      );
      final md = buildMarkdownDoc(r, res);
      expect(md, contains('# Login'));
      expect(md, contains('**POST** `https://api.x.dev/login`'));
      expect(md, contains('`200 OK`'));
      expect(md, contains('"token": "xyz"'));
      expect(md, isNot(contains('super-secret-token')));
      expect(md, isNot(contains('also-secret')));
      expect(md, contains('••••••'));
    });
  });

  group('data rows parsing', () {
    test('valid JSON array of objects', () {
      final rows = parseDataRows('[{"id": 1, "name": "a"}, {"id": 2}]');
      expect(rows, hasLength(2));
      expect(rows![0]['id'], '1');
      expect(rows[0]['name'], 'a');
    });

    test('invalid inputs return null', () {
      expect(parseDataRows(''), isNull);
      expect(parseDataRows('{"id":1}'), isNull);
      expect(parseDataRows('[1,2]'), isNull);
      expect(parseDataRows('nope'), isNull);
    });
  });

  group('graphql', () {
    test('curl export wraps query and variables in JSON envelope', () {
      final r = RequestModel(
        method: 'POST',
        url: 'https://x/graphql',
        bodyType: BodyType.graphql,
        body: 'query { users { id } }',
        graphqlVariables: '{"limit": 5}',
      );
      final cmd = toCurl(r);
      expect(cmd, contains('"query":"query { users { id } }"'));
      expect(cmd, contains('"variables":{"limit":5}'));
    });

    test('graphql fields survive JSON round trip', () {
      final r = RequestModel(
          bodyType: BodyType.graphql,
          body: 'query {}',
          graphqlVariables: '{"a":1}');
      final back = RequestModel.fromJson(r.toJson());
      expect(back.bodyType, BodyType.graphql);
      expect(back.graphqlVariables, '{"a":1}');
    });
  });

  group('settings', () {
    test('settings JSON round trip', () {
      final s = AppSettings(
          verifySsl: false, connectTimeoutS: 10, receiveTimeoutS: 20);
      final back = AppSettings.fromJson(s.toJson());
      expect(back.verifySsl, isFalse);
      expect(back.connectTimeoutS, 10);
      expect(back.receiveTimeoutS, 20);
    });
  });
}
