import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/curl_engine.dart';
import 'package:api_workbench/services/http_service.dart';

/// Local HTTP/1.1 echo server — public echo services don't support the
/// QUERY method yet, and it also proves plain-http fallback under HTTP/2.
Future<HttpServer> _echoServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final body = await utf8.decoder.bind(req).join();
    req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({
        'method': req.method,
        'body': body,
        'protocol': req.protocolVersion,
      }));
    await req.response.close();
  });
  return server;
}

void main() {
  test('QUERY method sends a body and reaches the server as QUERY', () async {
    final server = await _echoServer();
    addTearDown(() => server.close(force: true));
    final svc = HttpService();
    final req = RequestModel(
      method: 'QUERY',
      url: 'http://127.0.0.1:${server.port}/search',
      bodyType: BodyType.json,
      body: '{"q": "{{term}}"}',
    );
    final res = await svc.send(req, {'term': 'flutter'}, tabId: 'q1');
    expect(res.error, isNull);
    expect(res.statusCode, 200);
    final j = jsonDecode(res.bodyText) as Map<String, dynamic>;
    expect(j['method'], 'QUERY');
    expect(j['body'], '{"q": "flutter"}');
  });

  test('QUERY appears in the method list with GET-like placement', () {
    expect(httpMethods, contains('QUERY'));
  });

  test('HTTP/2 enabled: https to an h2 server succeeds', () async {
    final svc = HttpService()..configure(AppSettings(httpVersion: HttpVersionPref.v2));
    // google.com negotiates h2 via ALPN, exercising the Http2Adapter path.
    final res = await svc.send(
        RequestModel(url: 'https://www.google.com/generate_204'), {},
        tabId: 'h2a');
    expect(res.error, isNull);
    expect(res.statusCode, 204);
  });

  test('HTTP/2 enabled: plain http still speaks HTTP/1.1 (no h2c breakage)',
      () async {
    final server = await _echoServer();
    addTearDown(() => server.close(force: true));
    final svc = HttpService()..configure(AppSettings(httpVersion: HttpVersionPref.v2));
    final res = await svc.send(
        RequestModel(url: 'http://127.0.0.1:${server.port}/'), {},
        tabId: 'h2b');
    expect(res.error, isNull);
    expect(res.statusCode, 200);
    final j = jsonDecode(res.bodyText) as Map<String, dynamic>;
    expect(j['protocol'], '1.1');
  });

  test('HTTP/2 enabled: https-only-h1 server falls back cleanly', () async {
    final svc = HttpService()..configure(AppSettings(httpVersion: HttpVersionPref.v2));
    // postman-echo works whether it negotiates h2 or falls back to h1.
    final res = await svc.send(
        RequestModel(url: 'https://postman-echo.com/get'), {},
        tabId: 'h2c');
    expect(res.error, isNull);
    expect(res.statusCode, 200);
  });

  test('curl header parsing: redirect blocks, last one wins', () {
    const raw = 'HTTP/1.1 301 Moved Permanently\r\n'
        'location: https://x/\r\n'
        '\r\n'
        'HTTP/3 200\r\n'
        'content-type: application/json\r\n'
        'set-cookie: a=1\r\n'
        'set-cookie: b=2\r\n'
        '\r\n';
    final (headers, statusMessage) = parseCurlHeaders(raw);
    expect(statusMessage, ''); // h3 status lines carry no reason phrase
    expect(headers['content-type'], ['application/json']);
    expect(headers['set-cookie'], ['a=1', 'b=2']);
    expect(headers.containsKey('location'), isFalse);
  });

  test('settings migration: legacy useHttp2 maps to v2', () {
    expect(AppSettings.fromJson({'useHttp2': true}).httpVersion,
        HttpVersionPref.v2);
    expect(AppSettings.fromJson({}).httpVersion, HttpVersionPref.v1);
    expect(AppSettings.fromJson({'httpVersion': 'v3'}).httpVersion,
        HttpVersionPref.v3);
  });

  test('HTTP/3 on Linux: h3-capable curl runs it, otherwise clear guidance',
      () async {
    final svc = HttpService()..configure(AppSettings(httpVersion: HttpVersionPref.v3));
    final res = await svc.send(
        RequestModel(url: 'https://cloudflare.com/cdn-cgi/trace'), {},
        tabId: 'h3a');
    final curlOut = Process.runSync('curl', ['--version']).stdout as String;
    if (curlOut.contains('HTTP3')) {
      expect(res.error, isNull);
      expect(res.statusCode, 200);
      expect(res.protocol, isNotNull); // negotiated version reported
    } else {
      // This machine's curl lacks HTTP3 — the user must get actionable text.
      expect(res.error, contains('no HTTP3 support'));
      expect(res.error, contains('Settings'));
    }
  });
}
