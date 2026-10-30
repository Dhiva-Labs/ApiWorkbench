import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/prepared_request.dart';
import 'package:api_workbench/services/protocols/live_connection.dart';
import 'package:api_workbench/services/protocols/websocket_connection.dart';
import 'package:flutter_test/flutter_test.dart';

import 'protocols_support.dart';

void main() {
  group('WebSocket against a local echo server', () {
    late HttpServer server;
    late int port;
    final handshakes = <HttpRequest>[];
    var flakyConnections = 0;
    final sockets = <WebSocket>[];

    setUp(() async {
      handshakes.clear();
      sockets.clear();
      flakyConnections = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      port = server.port;
      server.listen((req) async {
        handshakes.add(req);
        final ws = await WebSocketTransformer.upgrade(
          req,
          protocolSelector: (offered) => offered.isEmpty ? null : offered.first,
        );
        sockets.add(ws);
        if (req.uri.path == '/flaky') {
          flakyConnections++;
          if (flakyConnections == 1) {
            // Drop the first connection right away.
            await ws.close(4001, 'try again');
            return;
          }
        }
        if (req.uri.path == '/hello') ws.add('hello');
        ws.listen((data) {
          if (data == 'close-me') {
            ws.close(4000, 'bye');
          } else {
            ws.add(data);
          }
        });
      });
    });

    tearDown(() => server.close(force: true));

    WebSocketConfig config(
      String path, {
      bool auto = false,
      int attempts = 5,
      List<MapEntry<String, String>> headers = const [],
      List<String> protocols = const [],
    }) => WebSocketConfig(
      url: Uri.parse('ws://127.0.0.1:$port$path'),
      headers: headers,
      protocols: protocols,
      autoReconnect: auto,
      maxAttempts: attempts,
      backoffBase: const Duration(milliseconds: 20),
      backoffMax: const Duration(milliseconds: 80),
    );

    test('connects, echoes text and disconnects', () async {
      final c = WebSocketConnection();
      expect(c.state, LinkState.idle);
      await c.connect(config('/echo'));
      expect(c.state, LinkState.connected);

      c.sendText('{"a":1}');
      await waitFor(
        () => c.log.entries.any((e) => e.direction == Direction.received),
      );
      final sent = c.log.entries.firstWhere(
        (e) => e.direction == Direction.sent,
      );
      final got = c.log.entries.firstWhere(
        (e) => e.direction == Direction.received,
      );
      expect(sent.text, '{"a":1}');
      expect(got.text, '{"a":1}');
      expect(got.prettyText, contains('"a": 1'));
      expect(got.size, 7);

      await c.disconnect();
      await waitFor(() => c.state == LinkState.idle);
      expect(c.closeCode, 1000);
      expect(
        c.log.entries.where((e) => e.direction == Direction.system).length,
        greaterThanOrEqualTo(3),
      );
      c.close();
    });

    test('sends and receives binary frames', () async {
      final c = WebSocketConnection();
      await c.connect(config('/echo'));
      c.sendBytes(Uint8List.fromList([0, 1, 2, 250, 255]));
      await waitFor(
        () => c.log.entries.any(
          (e) => e.direction == Direction.received && e.isBinary,
        ),
      );
      final got = c.log.entries.lastWhere((e) => e.isBinary);
      expect(got.bytes, [0, 1, 2, 250, 255]);
      expect(got.body(BinaryFormat.base64), 'AAEC+v8=');
      expect(got.body(BinaryFormat.hex), contains('00 01 02 fa ff'));
      c.close();
    });

    test('receives a message the server pushes on connect', () async {
      final c = WebSocketConnection();
      await c.connect(config('/hello'));
      await waitFor(
        () => c.log.entries.any((e) => e.text == 'hello'),
        reason: 'greeting',
      );
      c.close();
    });

    test('sends headers, query and subprotocols', () async {
      final c = WebSocketConnection();
      final r = RequestModel(
        kind: RequestKind.websocket,
        url: 'ws://127.0.0.1:$port/echo',
        params: [
          KV(key: 'room', value: '{{room}}'),
          KV(key: 'off', enabled: false),
        ],
        headers: [KV(key: 'X-Token', value: 'tok-{{id}}')],
        protocolConfig: {'subprotocols': 'chat, v2', 'pingSeconds': 20},
      );
      final cfg = WebSocketConfig.fromRequest(r, {'room': 'blue', 'id': '7'});
      expect(cfg.url.queryParameters, {'room': 'blue'});
      expect(cfg.pingInterval, const Duration(seconds: 20));
      await c.connect(cfg);
      expect(c.state, LinkState.connected);
      final req = handshakes.single;
      expect(req.uri.queryParameters['room'], 'blue');
      expect(req.headers.value('x-token'), 'tok-7');
      expect(c.protocol, 'chat');
      c.close();
    });

    test('shows the close code and reason when the server closes', () async {
      final c = WebSocketConnection();
      await c.connect(config('/echo'));
      c.sendText('close-me');
      await waitFor(() => c.state == LinkState.idle);
      expect(c.closeCode, 4000);
      expect(c.closeReason, 'bye');
      expect(
        c.log.entries.any((e) => e.text.contains('code 4000: bye')),
        isTrue,
      );
      c.close();
    });

    test('reconnects with backoff after the connection drops', () async {
      final c = WebSocketConnection();
      await c.connect(config('/flaky', auto: true));
      await waitFor(
        () => flakyConnections >= 2 && c.state == LinkState.connected,
        reason: 'second connection',
      );
      expect(
        c.log.entries.any((e) => e.text.startsWith('Reconnecting in')),
        isTrue,
      );
      c.sendText('again');
      await waitFor(
        () => c.log.entries.any(
          (e) => e.text == 'again' && e.direction == Direction.received,
        ),
      );
      c.close();
    });

    test('does not reconnect after a user disconnect', () async {
      final c = WebSocketConnection();
      await c.connect(config('/flaky', auto: true));
      await waitFor(() => c.state == LinkState.connected);
      await c.disconnect();
      await waitFor(() => c.state == LinkState.idle);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(c.state, LinkState.idle);
      c.close();
    });

    test('gives up after the allowed number of attempts', () async {
      final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = dead.port;
      await dead.close(force: true);
      final c = WebSocketConnection();
      await c.connect(
        WebSocketConfig(
          url: Uri.parse('ws://127.0.0.1:$deadPort/'),
          autoReconnect: true,
          maxAttempts: 2,
          backoffBase: const Duration(milliseconds: 10),
          backoffMax: const Duration(milliseconds: 20),
        ),
      );
      await waitFor(
        () =>
            c.state == LinkState.idle &&
            c.log.entries.any((e) => e.text.startsWith('Gave up')),
      );
      expect(
        c.log.entries
            .where((e) => e.text.startsWith('Could not connect'))
            .length,
        3,
      );
      c.close();
    });

    test('sending while disconnected throws', () {
      final c = WebSocketConnection();
      expect(() => c.sendText('x'), throwsStateError);
      c.close();
    });

    test('a connection failure is logged, not thrown', () async {
      final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = dead.port;
      await dead.close(force: true);
      final c = WebSocketConnection();
      await c.connect(
        WebSocketConfig(url: Uri.parse('ws://127.0.0.1:$deadPort/')),
      );
      expect(c.state, LinkState.idle);
      expect(c.log.entries.last.isError, isTrue);
      c.close();
    });

    test('closing the session stops everything', () async {
      final c = WebSocketConnection();
      await c.connect(config('/echo'));
      c.close();
      expect(c.isClosed, isTrue);
      await waitFor(() => sockets.every((s) => s.closeCode != null));
    });
  });

  group('WebSocket config', () {
    test('maps http schemes and rejects others', () {
      WebSocketConfig of(String url) => WebSocketConfig.fromRequest(
        RequestModel(kind: RequestKind.websocket, url: url),
        {},
      );
      expect(of('https://x.test/ws').url.scheme, 'wss');
      expect(of('http://x.test/ws').url.scheme, 'ws');
      expect(of('localhost:8080/ws').url.toString(), 'ws://localhost:8080/ws');
      expect(of('echo.example.com/ws').url.scheme, 'wss');
      expect(() => of('ftp://x.test'), throwsA(isA<RequestBuildException>()));
      expect(() => of(''), throwsA(isA<RequestBuildException>()));
    });

    test('keeps repeated header names', () {
      final cfg = WebSocketConfig.fromRequest(
        RequestModel(
          kind: RequestKind.websocket,
          url: 'ws://h.test',
          headers: [
            KV(key: 'X-A', value: '1'),
            KV(key: 'X-A', value: '2'),
            KV(key: 'Off', value: 'x', enabled: false),
          ],
        ),
        {},
      );
      expect(headerMap(cfg.headers), {
        'X-A': ['1', '2'],
      });
    });

    test('settings survive a JSON round trip and bad input', () {
      final s = WebSocketSettings(
        subprotocols: 'a, b c',
        pingSeconds: 15,
        autoReconnect: true,
        maxAttempts: 0,
        compose: PayloadKind.json,
        draft: '{"x":1}',
        messages: [
          SavedMessage(name: 'hi', kind: PayloadKind.binary, body: 'AAE='),
        ],
      );
      final back = WebSocketSettings.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>,
      );
      expect(back.protocolList, ['a', 'b', 'c']);
      expect(back.pingSeconds, 15);
      expect(back.autoReconnect, isTrue);
      expect(back.maxAttempts, 0);
      expect(back.compose, PayloadKind.json);
      expect(back.messages.single.name, 'hi');
      expect(back.messages.single.kind, PayloadKind.binary);

      final junk = WebSocketSettings.fromJson({
        'pingSeconds': 'abc',
        'messages': [
          1,
          'x',
          {'name': 5},
        ],
        'compose': 'nope',
      });
      expect(junk.pingSeconds, 0);
      expect(junk.compose, PayloadKind.text);
      expect(junk.messages.single.name, '');
    });

    test('reconnect delay doubles up to the maximum', () {
      const base = Duration(seconds: 1);
      const max = Duration(seconds: 10);
      expect(
        [for (var i = 1; i <= 6; i++) reconnectDelay(i, base, max).inSeconds],
        [1, 2, 4, 8, 10, 10],
      );
      expect(reconnectDelay(100, base, max), max);
    });
  });

  group('payloads', () {
    test('base64 input is forgiving', () {
      expect(decodeBase64Input('AAEC+v8='), [0, 1, 2, 250, 255]);
      expect(decodeBase64Input('AAEC+v8'), [0, 1, 2, 250, 255]);
      expect(decodeBase64Input('base64: AAEC\n+v8='), [0, 1, 2, 250, 255]);
      expect(decodeBase64Input('AAEC-v8='), [0, 1, 2, 250, 255]);
      expect(() => decodeBase64Input('not base64!'), throwsFormatException);
      expect(() => decodeBase64Input('A'), throwsFormatException);
      expect(decodeBase64Input(''), isEmpty);
    });

    test('JSON is checked but sent as typed', () {
      final p = buildPayload(PayloadKind.json, '{ "a" :  1 }');
      expect(p.text, '{ "a" :  1 }');
      expect(
        () => buildPayload(PayloadKind.json, '{oops'),
        throwsFormatException,
      );
      expect(buildPayload(PayloadKind.binary, 'AAE=').isBinary, isTrue);
      expect(buildPayload(PayloadKind.text, 'x y').text, 'x y');
    });
  });
}
