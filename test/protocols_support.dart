import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
