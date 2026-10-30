import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/prepared_request.dart';
import 'package:api_workbench/services/protocols/live_connection.dart';
import 'package:api_workbench/services/protocols/socketio_connection.dart';
import 'package:flutter_test/flutter_test.dart';

import 'protocols_support.dart';

void main() {
  group('Socket.IO against a local server', () {
    late MockSocketIoServer server;

    setUp(() async => server = await MockSocketIoServer.start());
    tearDown(() => server.close());

    SocketIoConfig config({
      String namespace = '/',
      String path = '/socket.io',
      Map<String, dynamic>? auth,
      Map<String, String> query = const {},
      Map<String, String> headers = const {},
      bool catchAll = true,
      Set<String> events = const {},
      Duration ackTimeout = const Duration(seconds: 5),
    }) => SocketIoConfig(
      origin: 'http://127.0.0.1:${server.port}',
      namespace: namespace,
      path: path,
      auth: auth,
      query: query,
      headers: headers,
      catchAll: catchAll,
      events: events,
      ackTimeout: ackTimeout,
    );

    Future<SocketIoConnection> connected(SocketIoConfig c) async {
      final conn = SocketIoConnection();
      await conn.connect(c);
      await waitFor(
        () => conn.state == LinkState.connected,
        reason: 'connected, log: ${conn.log.entries.map((e) => e.text)}',
      );
      return conn;
    }

    test('connects with auth, query and headers', () async {
      final c = await connected(
        config(
          auth: {'token': 'abc'},
          query: {'room': 'blue'},
          headers: {'X-Client': 'aw'},
        ),
      );
      expect(server.connects.single.auth, {'token': 'abc'});
      expect(server.connects.single.nsp, '/');
      final req = server.handshakes.single;
      expect(req.uri.queryParameters['room'], 'blue');
      expect(req.uri.queryParameters['EIO'], '4');
      expect(req.uri.queryParameters['transport'], 'websocket');
      expect(req.headers.value('x-client'), 'aw');
      expect(c.socketId, 'sio-1');
      expect(
        c.log.entries.any(
          (e) => e.text == 'Connected' && e.meta['sid'] == 'sio-1',
        ),
        isTrue,
      );
      c.close();
    });

    test('connects through the client the app provides', () async {
      var built = 0;
      final c = SocketIoConnection();
      await c.connect(
        SocketIoConfig(
          origin: 'http://127.0.0.1:${server.port}',
          clientFactory: () {
            built++;
            return HttpClient();
          },
        ),
      );
      await waitFor(() => c.state == LinkState.connected);
      expect(built, 1);
      c.close();
    });

    test('long polling falls back to WebSocket with a note', () async {
      final c = SocketIoConnection();
      await c.connect(
        SocketIoConfig(
          origin: 'http://127.0.0.1:${server.port}',
          transports: SocketTransports.both.names,
        ),
      );
      await waitFor(() => c.state == LinkState.connected);
      expect(
        server.handshakes.single.uri.queryParameters['transport'],
        'websocket',
      );
      expect(
        c.log.entries.any(
          (e) => e.text.startsWith('Long polling is not available'),
        ),
        isTrue,
      );
      c.close();
    });

    test('uses a custom handshake path and a namespace', () async {
      await server.close();
      server = await MockSocketIoServer.start(path: '/ws/io');
      final c = await connected(config(path: '/ws/io', namespace: '/admin'));
      expect(server.handshakes.single.uri.path, startsWith('/ws/io'));
      expect(server.connects.single.nsp, '/admin');
      c.emit('ping', ['x']);
      await waitFor(() => server.events.isNotEmpty);
      expect(server.events.single.nsp, '/admin');
      c.close();
    });

    test('emits an event with several JSON arguments', () async {
      final c = await connected(config());
      c.emit('chat', [
        'hi',
        {'a': 1},
        [1, 2],
      ]);
      await waitFor(() => server.events.isNotEmpty);
      expect(server.events.single.event, 'chat');
      expect(server.events.single.args, [
        'hi',
        {'a': 1},
        [1, 2],
      ]);
      expect(server.events.single.ackId, isNull);
      final sent = c.log.entries.last;
      expect(sent.direction, Direction.sent);
      expect(sent.title, 'chat');
      expect(sent.text, '["hi",{"a":1},[1,2]]');
      expect(sent.meta['args'], '3');
      c.close();
    });

    test('logs events from the server with their arguments', () async {
      final c = await connected(config());
      server.emit('news', [
        {'headline': 'x'},
      ]);
      server.emit('multi', [
        1,
        {'y': 2},
      ]);
      server.emit('empty', []);
      await waitFor(
        () =>
            c.log.entries
                .where((e) => e.direction == Direction.received)
                .length >=
            3,
      );
      final got = c.log.entries
          .where((e) => e.direction == Direction.received)
          .toList();
      expect(got[0].title, 'news');
      expect(got[0].text, '{"headline":"x"}');
      expect(got[0].prettyText, contains('"headline": "x"'));
      expect(got[1].text, '[1,{"y":2}]');
      expect(got[1].meta['args'], '2');
      expect(got[2].text, '');
      c.close();
    });

    test('shows the acknowledgement of an emit', () async {
      final c = await connected(config());
      c.emit('save', [
        {'id': 5},
      ], ack: true);
      await waitFor(() => c.log.entries.any((e) => e.label == 'ack'));
      expect(server.events.single.ackId, 0);
      final ack = c.log.entries.firstWhere((e) => e.label == 'ack');
      expect(ack.title, 'save');
      expect(ack.text, '["ok",{"id":5}]');
      expect(ack.meta['ack'], '#0');
      expect(ack.meta['after'], endsWith(' ms'));

      c.emit('again', [], ack: true);
      await waitFor(
        () => c.log.entries.where((e) => e.label == 'ack').length == 2,
      );
      expect(server.events.last.ackId, 1);
      c.close();
    });

    test('notes an acknowledgement that never arrives', () async {
      final c = await connected(
        config(ackTimeout: const Duration(milliseconds: 150)),
      );
      c.emit('no-ack', [], ack: true);
      await waitFor(
        () => c.log.entries.any((e) => e.text.startsWith('No acknowledgement')),
      );
      c.close();
    });

    test('echo round trip goes through the listener filter', () async {
      final c = await connected(config(catchAll: false, events: {'echo'}));
      c.emit('echo', ['one']);
      c.emit('other', ['two']);
      server.emit('hidden', ['x']);
      await waitFor(
        () => c.log.entries.any((e) => e.direction == Direction.received),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final got = c.log.entries
          .where((e) => e.direction == Direction.received)
          .toList();
      expect(got.map((e) => e.title), ['echo']);

      // Turn a listener on while connected.
      c.setListening(catchAll: false, events: {'echo', 'hidden'});
      server.emit('hidden', ['y']);
      await waitFor(() => c.log.entries.any((e) => e.title == 'hidden'));
      // And the catch-all.
      c.setListening(catchAll: true, events: {});
      server.emit('anything', []);
      await waitFor(() => c.log.entries.any((e) => e.title == 'anything'));
      c.close();
    });

    test('notes that the server wants an acknowledgement', () async {
      final c = await connected(config());
      server.emit('question', ['?'], ackId: 12);
      await waitFor(() => c.log.entries.any((e) => e.title == 'question'));
      expect(c.log.entries.last.meta['wants ack'], '#12');
      c.close();
    });

    test('reports a refused connection', () async {
      final c = SocketIoConnection();
      await c.connect(config(auth: {'deny': true}));
      await waitFor(() => c.state == LinkState.idle);
      final err = c.log.entries.lastWhere((e) => e.isError);
      expect(err.text, contains('denied'));
      expect(err.text, contains('"code":7'));
      c.close();
    });

    test('disconnects on request and when the server does', () async {
      final c = await connected(config());
      c.disconnect();
      expect(c.state, LinkState.idle);
      await waitFor(() => server.disconnects == 1);

      // The same connection can connect again.
      await c.connect(config());
      await waitFor(() => c.state == LinkState.connected);
      server.disconnectClients();
      await waitFor(() => c.state == LinkState.idle);
      expect(
        c.log.entries.any(
          (e) => e.text == 'Disconnected: io server disconnect',
        ),
        isTrue,
      );
      c.close();
    });

    test('a refused port is reported as an error', () async {
      final dead = await MockSocketIoServer.start();
      final port = dead.port;
      await dead.close();
      final c = SocketIoConnection();
      await c.connect(SocketIoConfig(origin: 'http://127.0.0.1:$port'));
      await waitFor(() => c.state == LinkState.idle);
      expect(c.log.entries.any((e) => e.isError), isTrue);
      c.close();
    });

    test('emit checks the connection and the event name', () async {
      final c = SocketIoConnection();
      expect(() => c.emit('x', []), throwsStateError);
      c.close();
      final live = await connected(config());
      expect(() => live.emit('', []), throwsFormatException);
      expect(() => live.emit('connect', []), throwsFormatException);
      live.close();
    });
  });

  group('Socket.IO parsing', () {
    test('emit arguments: JSON, text, empty rows and bad JSON', () {
      expect(
        parseEmitArgs(
          [
            SocketArg(body: '{"a":"{{v}}"}'),
            SocketArg(kind: SocketArgKind.text, body: 'hello {{v}}'),
            SocketArg(body: '  '),
            SocketArg(body: '[1,2]'),
          ],
          {'v': 'x'},
        ),
        [
          {'a': 'x'},
          'hello x',
          [1, 2],
        ],
      );
      expect(
        () =>
            parseEmitArgs([SocketArg(body: '1'), SocketArg(body: 'nope')], {}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Argument 2'),
          ),
        ),
      );
    });

    test('auth payload', () {
      expect(parseAuthPayload('', {}), isNull);
      expect(parseAuthPayload('{"t":"{{k}}"}', {'k': '1'}), {'t': '1'});
      expect(() => parseAuthPayload('[1]', {}), throwsFormatException);
      expect(() => parseAuthPayload('{bad', {}), throwsFormatException);
    });

    test('event arguments are shown as JSON', () {
      expect(formatEventArgs([]), '');
      expect(formatEventArgs(['a']), '"a"');
      expect(formatEventArgs([1, 2]), '[1,2]');
      expect(
        formatEventArgs([
          Uint8List.fromList([1, 2, 3]),
        ]),
        '{"\$binary":"AQID"}',
      );
    });

    test('connect errors are readable', () {
      expect(describeConnectError('timeout'), 'timeout');
      expect(
        describeConnectError({
          'message': 'no',
          'data': {'a': 1},
        }),
        'no (data: {"a":1})',
      );
      expect(describeConnectError(null), 'unknown error');
    });

    test('config comes from the request', () {
      final r = RequestModel(
        kind: RequestKind.socketio,
        url: 'ws://{{host}}:3000/admin?a=1',
        params: [KV(key: 'b', value: '2')],
        headers: [
          KV(key: 'X', value: '1'),
          KV(key: 'X', value: '2'),
        ],
        protocolConfig: {
          'path': 'custom/io',
          'auth': '{"u":"{{u}}"}',
          'transports': 'both',
          'reconnection': true,
          'ackTimeoutSec': 3,
          'catchAll': false,
          'listeners': [
            {'event': 'a', 'enabled': true},
            {'event': 'b', 'enabled': false},
            {'event': '  ', 'enabled': true},
          ],
        },
      );
      final c = SocketIoConfig.fromRequest(r, {'host': 'h.test', 'u': 'me'});
      expect(c.origin, 'http://h.test:3000');
      expect(c.namespace, '/admin');
      expect(c.target, 'http://h.test:3000/admin');
      expect(c.path, '/custom/io');
      expect(c.query, {'a': '1', 'b': '2'});
      expect(c.auth, {'u': 'me'});
      expect(c.headers, {'X': '1, 2'});
      expect(c.transports, ['polling', 'websocket']);
      expect(c.reconnection, isTrue);
      expect(c.ackTimeout, const Duration(seconds: 3));
      expect(c.catchAll, isFalse);
      expect(c.events, {'a'});
    });

    test('config defaults and errors', () {
      final c = SocketIoConfig.fromRequest(
        RequestModel(kind: RequestKind.socketio, url: 'http://localhost:3000'),
        {},
      );
      expect(c.namespace, '/');
      expect(c.target, 'http://localhost:3000');
      expect(c.path, '/socket.io');
      expect(c.transports, ['websocket']);
      expect(c.catchAll, isTrue);
      expect(
        () => SocketIoConfig.fromRequest(
          RequestModel(kind: RequestKind.socketio, url: 'ftp://x'),
          {},
        ),
        throwsA(isA<RequestBuildException>()),
      );
      expect(
        () => SocketIoConfig.fromRequest(
          RequestModel(
            kind: RequestKind.socketio,
            url: 'http://x',
            protocolConfig: {'auth': '"just a string"'},
          ),
          {},
        ),
        throwsFormatException,
      );
    });

    test('settings round trip and tolerate junk', () {
      final s = SocketIoSettings(
        path: '/io',
        auth: '{"a":1}',
        transports: SocketTransports.both,
        reconnection: true,
        ackTimeoutSec: 4,
        catchAll: false,
        emitEvent: 'hello',
        wantAck: true,
        listeners: [SocketListener(event: 'x', enabled: false)],
        args: [
          SocketArg(body: '1'),
          SocketArg(kind: SocketArgKind.text, body: 't'),
        ],
      );
      final back = SocketIoSettings.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>,
      );
      expect(back.path, '/io');
      expect(back.transports, SocketTransports.both);
      expect(back.reconnection, isTrue);
      expect(back.catchAll, isFalse);
      expect(back.listeners.single.event, 'x');
      expect(back.listeners.single.enabled, isFalse);
      expect(back.args.map((a) => a.kind), [
        SocketArgKind.json,
        SocketArgKind.text,
      ]);
      expect(back.wantAck, isTrue);

      final empty = SocketIoSettings.fromJson({
        'args': 5,
        'path': ' ',
        'transports': 'x',
      });
      expect(empty.path, '/socket.io');
      expect(empty.args, hasLength(1));
      expect(empty.transports, SocketTransports.websocket);
    });
  });
}
