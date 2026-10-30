import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Polls [condition] until it holds, failing after [timeout].
Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  String? reason,
}) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException(reason ?? 'condition not met', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A tiny Socket.IO v4 server over the Engine.IO WebSocket transport, enough
/// to exercise the client end to end.
class MockSocketIoServer {
  MockSocketIoServer._(this.server);

  final HttpServer server;
  int get port => server.port;

  /// One entry per WebSocket handshake.
  final List<HttpRequest> handshakes = [];

  /// Namespaces and auth payloads of CONNECT packets, as received.
  final List<({String nsp, Object? auth})> connects = [];

  /// Events received from the client: `(namespace, event, args, ackId)`.
  final List<({String nsp, String event, List<dynamic> args, int? ackId})>
  events = [];

  int disconnects = 0;
  final List<WebSocket> sockets = [];
  final Map<WebSocket, String> _namespaces = {};

  static Future<MockSocketIoServer> start({String path = '/socket.io'}) async {
    final s = MockSocketIoServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    s.server.listen((req) async {
      if (!req.uri.path.startsWith(path) ||
          !WebSocketTransformer.isUpgradeRequest(req)) {
        req.response.statusCode = 400;
        await req.response.close();
        return;
      }
      s.handshakes.add(req);
      final ws = await WebSocketTransformer.upgrade(req);
      s.sockets.add(ws);
      ws.add(
        '0{"sid":"engsid","upgrades":[],"pingInterval":25000,'
        '"pingTimeout":20000,"maxPayload":1000000}',
      );
      ws.listen((data) {
        if (data is String) s._onPacket(ws, data);
      });
    });
    return s;
  }

  /// Splits `[nsp,][id]payload` after the packet type digit(s).
  static ({String nsp, int? id, String rest}) _split(String s) {
    var nsp = '/';
    var rest = s;
    if (rest.startsWith('/')) {
      final comma = rest.indexOf(',');
      nsp = rest.substring(0, comma);
      rest = rest.substring(comma + 1);
    }
    final m = RegExp(r'^(\d+)').firstMatch(rest);
    int? id;
    if (m != null && !rest.startsWith('[') && !rest.startsWith('{')) {
      id = int.parse(m.group(1)!);
      rest = rest.substring(m.group(1)!.length);
    }
    return (nsp: nsp, id: id, rest: rest);
  }

  void _onPacket(WebSocket ws, String raw) {
    if (raw == '3') return; // pong
    if (raw.startsWith('40')) {
      final p = _split(raw.substring(2));
      final auth = p.rest.isEmpty ? null : jsonDecode(p.rest);
      connects.add((nsp: p.nsp, auth: auth));
      _namespaces[ws] = p.nsp;
      final prefix = p.nsp == '/' ? '' : '${p.nsp},';
      if (auth is Map && auth['deny'] == true) {
        ws.add('44$prefix{"message":"denied","data":{"code":7}}');
        return;
      }
      ws.add('40$prefix{"sid":"sio-${connects.length}"}');
    } else if (raw.startsWith('41')) {
      disconnects++;
    } else if (raw.startsWith('42')) {
      final p = _split(raw.substring(2));
      final list = jsonDecode(p.rest) as List<dynamic>;
      final event = list.first as String;
      final args = list.sublist(1);
      events.add((nsp: p.nsp, event: event, args: args, ackId: p.id));
      final prefix = p.nsp == '/' ? '' : '${p.nsp},';
      if (event == 'echo') {
        ws.add('42$prefix${jsonEncode(['echo', ...args])}');
      }
      if (p.id != null && event != 'no-ack') {
        ws.add('43$prefix${p.id}${jsonEncode(['ok', ...args])}');
      }
    }
  }

  /// Pushes an event to every connected client.
  void emit(String event, List<dynamic> args, {int? ackId, String nsp = '/'}) {
    final prefix = nsp == '/' ? '' : '$nsp,';
    for (final ws in sockets) {
      ws.add('42$prefix${ackId ?? ''}${jsonEncode([event, ...args])}');
    }
  }

  /// Tells every client the server is disconnecting its socket.
  void disconnectClients({String nsp = '/'}) {
    final prefix = nsp == '/' ? '' : '$nsp,';
    for (final ws in sockets) {
      ws.add('41$prefix');
    }
  }

  Future<void> close() => server.close(force: true);
}

/// A tiny MQTT 3.1.1 broker, over TCP and WebSocket, with QoS 0 to 2,
/// retained messages and wildcard subscriptions.
class MockMqttBroker {
  MockMqttBroker._();

  late final ServerSocket _tcp;
  late final HttpServer _ws;
  int get tcpPort => _tcp.port;
  int get wsPort => _ws.port;

  /// CONNECT packets, as `(clientId, user, password, keepAlive, clean, will)`.
  final List<
    ({
      String clientId,
      String? user,
      String? password,
      int keepAlive,
      bool clean,
      ({String topic, String message, int qos, bool retain})? will,
    })
  >
  connects = [];

  /// Upgrade requests received over WebSocket.
  final List<HttpRequest> upgrades = [];

  /// Messages published by clients.
  final List<({String topic, List<int> payload, int qos, bool retain})>
  published = [];

  /// Subscriptions received, as `(filter, qos)`.
  final List<({String filter, int qos})> subscribed = [];
  final List<String> unsubscribed = [];
  int disconnects = 0;
  final Map<String, ({List<int> payload, int qos})> retained = {};
  final List<_BrokerClient> _clients = [];

  static Future<MockMqttBroker> start() async {
    final b = MockMqttBroker._();
    b._tcp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    b._tcp.listen((socket) {
      final c = _BrokerClient(b, (bytes) => socket.add(bytes), socket.destroy);
      b._clients.add(c);
      socket.listen(
        c.feed,
        onDone: () => b._clients.remove(c),
        onError: (_) {},
      );
    });
    b._ws = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    b._ws.listen((req) async {
      b.upgrades.add(req);
      final ws = await WebSocketTransformer.upgrade(
        req,
        protocolSelector: (p) => p.contains('mqtt') ? 'mqtt' : p.first,
      );
      final c = _BrokerClient(b, ws.add, () => ws.close());
      b._clients.add(c);
      ws.listen(
        (d) => c.feed(d as List<int>),
        onDone: () => b._clients.remove(c),
        onError: (_) {},
      );
    });
    return b;
  }

  /// Publishes to subscribers as if another client had.
  void inject(
    String topic,
    List<int> payload, {
    int qos = 0,
    bool retain = false,
  }) {
    if (retain) retained[topic] = (payload: payload, qos: qos);
    for (final c in List.of(_clients)) {
      c.deliver(topic, payload, qos, false);
    }
  }

  /// Drops every client connection without a DISCONNECT.
  void dropClients() {
    for (final c in List.of(_clients)) {
      c.kill();
    }
  }

  Future<void> close() async {
    dropClients();
    await _tcp.close();
    await _ws.close(force: true);
  }
}

class _BrokerClient {
  _BrokerClient(this.broker, this._send, this.kill);

  final MockMqttBroker broker;
  final void Function(List<int>) _send;
  final void Function() kill;
  final List<int> _buf = [];
  final List<({String filter, int qos})> subs = [];
  int _nextId = 1;

  void feed(List<int> data) {
    _buf.addAll(data);
    while (true) {
      if (_buf.length < 2) return;
      var mult = 1;
      var len = 0;
      var i = 1;
      int digit;
      do {
        if (i >= _buf.length) return;
        digit = _buf[i++];
        len += (digit & 127) * mult;
        mult *= 128;
      } while (digit & 128 != 0);
      if (_buf.length < i + len) return;
      final first = _buf[0];
      final body = Uint8List.fromList(_buf.sublist(i, i + len));
      _buf.removeRange(0, i + len);
      _handle(first >> 4, first & 15, body);
    }
  }

  static String _str(Uint8List b, int at) {
    final n = (b[at] << 8) | b[at + 1];
    return utf8.decode(b.sublist(at + 2, at + 2 + n));
  }

  void _handle(int type, int flags, Uint8List b) {
    switch (type) {
      case 1: // CONNECT
        var p = 0;
        final nameLen = (b[0] << 8) | b[1];
        p = 2 + nameLen;
        p++; // level
        final cf = b[p++];
        final keep = (b[p] << 8) | b[p + 1];
        p += 2;
        final id = _str(b, p);
        p += 2 + ((b[p] << 8) | b[p + 1]);
        ({String topic, String message, int qos, bool retain})? will;
        if (cf & 4 != 0) {
          final t = _str(b, p);
          p += 2 + ((b[p] << 8) | b[p + 1]);
          final mlen = (b[p] << 8) | b[p + 1];
          final m = utf8.decode(b.sublist(p + 2, p + 2 + mlen));
          p += 2 + mlen;
          will = (
            topic: t,
            message: m,
            qos: (cf >> 3) & 3,
            retain: cf & 32 != 0,
          );
        }
        String? user;
        String? pass;
        if (cf & 128 != 0) {
          user = _str(b, p);
          p += 2 + ((b[p] << 8) | b[p + 1]);
        }
        if (cf & 64 != 0) pass = _str(b, p);
        broker.connects.add((
          clientId: id,
          user: user,
          password: pass,
          keepAlive: keep,
          clean: cf & 2 != 0,
          will: will,
        ));
        _send([0x20, 2, 0, user == 'bad' ? 4 : 0]);
        if (user == 'bad') Timer(const Duration(milliseconds: 20), kill);
      case 8: // SUBSCRIBE
        final id = (b[0] << 8) | b[1];
        var p = 2;
        final granted = <int>[];
        final added = <({String filter, int qos})>[];
        while (p < b.length) {
          final f = _str(b, p);
          p += 2 + ((b[p] << 8) | b[p + 1]);
          final q = b[p++];
          subs.add((filter: f, qos: q));
          broker.subscribed.add((filter: f, qos: q));
          added.add((filter: f, qos: q));
          granted.add(q);
        }
        _send([0x90, 2 + granted.length, id >> 8, id & 255, ...granted]);
        for (final s in added) {
          for (final e in broker.retained.entries) {
            if (_matches(s.filter, e.key)) {
              _publish(
                e.key,
                e.value.payload,
                s.qos < e.value.qos ? s.qos : e.value.qos,
                true,
              );
            }
          }
        }
      case 10: // UNSUBSCRIBE
        final id = (b[0] << 8) | b[1];
        var p = 2;
        while (p < b.length) {
          final f = _str(b, p);
          p += 2 + ((b[p] << 8) | b[p + 1]);
          subs.removeWhere((s) => s.filter == f);
          broker.unsubscribed.add(f);
        }
        _send([0xB0, 2, id >> 8, id & 255]);
      case 3: // PUBLISH
        final qos = (flags >> 1) & 3;
        final retain = flags & 1 != 0;
        final topic = _str(b, 0);
        var p = 2 + ((b[0] << 8) | b[1]);
        int? id;
        if (qos > 0) {
          id = (b[p] << 8) | b[p + 1];
          p += 2;
        }
        final payload = b.sublist(p);
        broker.published.add((
          topic: topic,
          payload: payload,
          qos: qos,
          retain: retain,
        ));
        if (retain) broker.retained[topic] = (payload: payload, qos: qos);
        if (qos == 1) _send([0x40, 2, id! >> 8, id & 255]);
        if (qos == 2) _send([0x50, 2, id! >> 8, id & 255]);
        for (final c in List.of(broker._clients)) {
          c.deliver(topic, payload, qos, false);
        }
      case 6: // PUBREL
        _send([0x70, 2, b[0], b[1]]);
      case 5: // PUBREC from the client
        _send([0x62, 2, b[0], b[1]]);
      case 12: // PINGREQ
        _send([0xD0, 0]);
      case 14: // DISCONNECT
        broker.disconnects++;
        kill();
    }
  }

  static bool _matches(String filter, String topic) {
    final f = filter.split('/');
    final t = topic.split('/');
    for (var i = 0; i < f.length; i++) {
      if (f[i] == '#') return true;
      if (i >= t.length) return false;
      if (f[i] != '+' && f[i] != t[i]) return false;
    }
    return f.length == t.length;
  }

  void deliver(String topic, List<int> payload, int qos, bool retain) {
    for (final s in subs) {
      if (_matches(s.filter, topic)) {
        _publish(topic, payload, qos < s.qos ? qos : s.qos, retain);
        return;
      }
    }
  }

  void _publish(String topic, List<int> payload, int qos, bool retain) {
    final t = utf8.encode(topic);
    final id = qos > 0 ? _nextId++ : null;
    final body = [
      t.length >> 8,
      t.length & 255,
      ...t,
      if (id != null) ...[id >> 8, id & 255],
      ...payload,
    ];
    final header = <int>[0x30 | (qos << 1) | (retain ? 1 : 0)];
    var n = body.length;
    do {
      var d = n % 128;
      n ~/= 128;
      if (n > 0) d |= 128;
      header.add(d);
    } while (n > 0);
    _send([...header, ...body]);
  }
}
