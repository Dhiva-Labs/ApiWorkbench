import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/assertions.dart';

ResponseData _resp({
  int status = 200,
  String body = '',
  Map<String, List<String>> headers = const {},
  int ms = 100,
}) =>
    ResponseData(
        statusCode: status,
        headers: headers,
        bodyBytes: utf8.encode(body),
        durationMs: ms);

RequestModel _req(List<AssertionModel> asserts) =>
    RequestModel(url: 'https://x', assertions: asserts);

void main() {
  test('jsonAtPath walks maps and lists', () {
    final root = jsonDecode('{"data":{"items":[{"id":7},{"id":8}]}}');
    expect(jsonAtPath(root, 'data.items[1].id'), 8);
    expect(jsonPathFound(jsonAtPath(root, 'data.missing')), isFalse);
    expect(jsonPathFound(jsonAtPath(root, 'data.items[5]')), isFalse);
  });

  test('statusEquals pass and fail', () {
    final r = _req([
      AssertionModel(kind: AssertKind.statusEquals, expected: '200'),
      AssertionModel(kind: AssertKind.statusEquals, expected: '404'),
    ]);
    final out = evaluateAssertions(r, _resp(status: 200));
    expect(out[0].pass, isTrue);
    expect(out[1].pass, isFalse);
  });

  test('bodyContains and jsonEquals', () {
    final r = _req([
      AssertionModel(kind: AssertKind.bodyContains, expected: 'dhiva'),
      AssertionModel(
          kind: AssertKind.jsonEquals, target: 'user.name', expected: 'dhiva'),
      AssertionModel(
          kind: AssertKind.jsonEquals, target: 'user.age', expected: '30'),
    ]);
    final out =
        evaluateAssertions(r, _resp(body: '{"user":{"name":"dhiva","age":30}}'));
    expect(out.map((o) => o.pass), everyElement(isTrue));
  });

  test('headerContains: presence and value match, case-insensitive', () {
    final r = _req([
      AssertionModel(kind: AssertKind.headerContains, target: 'Content-Type'),
      AssertionModel(
          kind: AssertKind.headerContains,
          target: 'content-type',
          expected: 'JSON'),
      AssertionModel(kind: AssertKind.headerContains, target: 'X-Nope'),
    ]);
    final out = evaluateAssertions(
        r,
        _resp(headers: {
          'content-type': ['application/json']
        }));
    expect(out[0].pass, isTrue);
    expect(out[1].pass, isTrue);
    expect(out[2].pass, isFalse);
  });

  test('timeBelow and disabled assertions are skipped', () {
    final r = _req([
      AssertionModel(kind: AssertKind.timeBelow, expected: '500'),
      AssertionModel(
          kind: AssertKind.statusEquals, expected: '500', enabled: false),
    ]);
    final out = evaluateAssertions(r, _resp(ms: 120));
    expect(out.length, 1);
    expect(out.single.pass, isTrue);
  });

  test('transport error fails every assertion', () {
    final r = _req([
      AssertionModel(kind: AssertKind.statusEquals, expected: '200'),
    ]);
    final out = evaluateAssertions(r, ResponseData(error: 'dns failure'));
    expect(out.single.pass, isFalse);
  });

  test('assertions survive JSON round trip', () {
    final r = _req([
      AssertionModel(
          kind: AssertKind.jsonEquals, target: 'a.b', expected: '1'),
    ]);
    final back = RequestModel.fromJson(r.toJson());
    expect(back.assertions.single.kind, AssertKind.jsonEquals);
    expect(back.assertions.single.target, 'a.b');
  });
}
