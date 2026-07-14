import 'package:flutter_test/flutter_test.dart';
import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/curl.dart';
import 'package:api_workbench/services/http_service.dart';

void main() {
  test('variable substitution replaces known vars and keeps unknown ones', () {
    final vars = {'base': 'https://api.dev', 'id': '42'};
    expect(substituteVars('{{base}}/users/{{id}}/{{nope}}', vars),
        'https://api.dev/users/42/{{nope}}');
  });

  test('cURL import parses method, headers, data and url', () {
    final r = fromCurl(
        "curl -X POST 'https://api.example.com/login' -H 'Content-Type: application/json' -d '{\"user\":\"a\"}'");
    expect(r, isNotNull);
    expect(r!.method, 'POST');
    expect(r.url, 'https://api.example.com/login');
    expect(r.headers.single.key, 'Content-Type');
    expect(r.bodyType, BodyType.json);
    expect(r.body, '{"user":"a"}');
  });

  test('cURL round trip keeps url and bearer auth', () {
    final r = RequestModel(
      method: 'GET',
      url: 'https://api.example.com/me',
      authType: AuthType.bearer,
      bearerToken: 'tok123',
    );
    final cmd = toCurl(r);
    expect(cmd, contains("'https://api.example.com/me'"));
    expect(cmd, contains('Authorization: Bearer tok123'));
  });

  test('request JSON round trip preserves fields', () {
    final r = RequestModel(
      name: 'Create user',
      method: 'POST',
      url: 'https://x.dev/u',
      params: [KV(key: 'a', value: '1')],
      bodyType: BodyType.json,
      body: '{}',
    );
    final back = RequestModel.fromJson(r.toJson());
    expect(back.name, r.name);
    expect(back.method, 'POST');
    expect(back.params.single.key, 'a');
    expect(back.bodyType, BodyType.json);
  });
}
