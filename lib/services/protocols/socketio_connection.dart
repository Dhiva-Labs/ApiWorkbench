import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:socket_io_client/socket_io_client.dart' as sio;
// The client library's own WebSocket type; it is one of its dependencies.
// ignore: depend_on_referenced_packages
import 'package:web_socket/io_web_socket.dart' show IOWebSocket;

import '../../models/models.dart';
import '../request_builder.dart';
import 'live_connection.dart';

/// How an emitted argument is read.
enum SocketArgKind { json, text }

/// One argument of an emitted event.
class SocketArg {
  SocketArg({this.kind = SocketArgKind.json, this.body = ''});

  SocketArgKind kind;
  String body;

  Map<String, dynamic> toJson() => {'kind': kind.name, 'body': body};

  factory SocketArg.fromJson(Map<String, dynamic> j) => SocketArg(
    kind: SocketArgKind.values.asNameMap()[j['kind']] ?? SocketArgKind.json,
    body: jsonString(j['body']),
  );
}

/// An event name to listen for.
class SocketListener {
  SocketListener({this.event = '', this.enabled = true});

  String event;
  bool enabled;

  Map<String, dynamic> toJson() => {'event': event, 'enabled': enabled};

  factory SocketListener.fromJson(Map<String, dynamic> j) => SocketListener(
    event: jsonString(j['event']),
    enabled: jsonBool(j['enabled'], true),
  );
}

/// Which transports the handshake may use.
enum SocketTransports { websocket, polling, both }

extension SocketTransportsInfo on SocketTransports {
  String get label => switch (this) {
    SocketTransports.websocket => 'WebSocket',
    SocketTransports.polling => 'Long polling',
    SocketTransports.both => 'Polling, then upgrade',
  };

  /// The transports as the Socket.IO options name them.
  List<String> get names => switch (this) {
    SocketTransports.websocket => const ['websocket'],
    SocketTransports.polling => const ['polling'],
    SocketTransports.both => const ['polling', 'websocket'],
  };
}

/// The transports the client library can use on desktop and mobile: it speaks
/// WebSocket only, so a request for polling is answered with WebSocket.
const usableTransports = ['websocket'];

/// What a Socket.IO request keeps in [RequestModel.protocolConfig].
class SocketIoSettings {
  SocketIoSettings({
    this.path = '/socket.io',
    this.auth = '',
    this.transports = SocketTransports.websocket,
    this.reconnection = false,
    this.ackTimeoutSec = 10,
    this.catchAll = true,
    this.emitEvent = '',
    this.wantAck = false,
    List<SocketListener>? listeners,
    List<SocketArg>? args,
  }) : listeners = listeners ?? [],
       args = args ?? [SocketArg()];

  /// The handshake path on the server.
  String path;

  /// JSON object sent as the `auth` payload of the CONNECT packet.
  String auth;
  SocketTransports transports;
  bool reconnection;

  /// How long to wait for an acknowledgement before noting a timeout.
  int ackTimeoutSec;

  /// Log every incoming event, whatever the listener list says.
  bool catchAll;
  List<SocketListener> listeners;

  /// The composer: event name, arguments and whether to ask for an ack.
  String emitEvent;
  List<SocketArg> args;
  bool wantAck;

  Map<String, dynamic> toJson() => {
    'path': path,
    'auth': auth,
    'transports': transports.name,
    'reconnection': reconnection,
    'ackTimeoutSec': ackTimeoutSec,
    'catchAll': catchAll,
    'listeners': listeners.map((l) => l.toJson()).toList(),
    'emitEvent': emitEvent,
    'args': args.map((a) => a.toJson()).toList(),
    'wantAck': wantAck,
  };

  factory SocketIoSettings.fromJson(Map<String, dynamic> j) {
    final args = [for (final a in jsonMaps(j['args'])) SocketArg.fromJson(a)];
    return SocketIoSettings(
      path: jsonString(j['path'], '/socket.io').trim().isEmpty
          ? '/socket.io'
          : jsonString(j['path'], '/socket.io'),
      auth: jsonString(j['auth']),
      transports:
          SocketTransports.values.asNameMap()[j['transports']] ??
          SocketTransports.websocket,
      reconnection: jsonBool(j['reconnection'], false),
      ackTimeoutSec: jsonInt(j['ackTimeoutSec'], 10).clamp(1, 600),
      catchAll: jsonBool(j['catchAll'], true),
      listeners: [
        for (final l in jsonMaps(j['listeners'])) SocketListener.fromJson(l),
      ],
      emitEvent: jsonString(j['emitEvent']),
      args: args.isEmpty ? null : args,
      wantAck: jsonBool(j['wantAck'], false),
    );
  }
}

/// Reads the arguments of an emit from the composer. JSON arguments are
/// parsed, text arguments are sent as strings; variables are filled in
/// first. Throws a [FormatException] naming the bad argument.
List<dynamic> parseEmitArgs(List<SocketArg> args, Map<String, String> vars) {
  final out = <dynamic>[];
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    final body = substituteVars(a.body, vars);
    if (a.kind == SocketArgKind.text) {
      out.add(body);
      continue;
    }
    if (body.trim().isEmpty) continue; // an empty JSON row sends nothing
    try {
      out.add(jsonDecode(body));
    } on FormatException catch (e) {
      throw FormatException(
        'Argument ${i + 1} is not valid JSON: ${e.message}. '
        'Put text in double quotes, or switch the argument to Text.',
      );
    }
  }
  return out;
}

/// Parses the `auth` payload text. Empty means none; otherwise it must be a
/// JSON object. Throws a [FormatException].
Map<String, dynamic>? parseAuthPayload(String text, Map<String, String> vars) {
  final body = substituteVars(text, vars).trim();
  if (body.isEmpty) return null;
  final Object? parsed;
  try {
    parsed = jsonDecode(body);
  } on FormatException catch (e) {
    throw FormatException('The auth payload is not valid JSON: ${e.message}');
  }
  if (parsed is! Map) {
    throw const FormatException('The auth payload must be a JSON object.');
  }
  return Map<String, dynamic>.from(parsed);
}

/// Event arguments as one display string: the value itself for a single
/// argument, a JSON array for several, empty for none. Binary values show as
/// `{"$binary": "<base64>"}`.
String formatEventArgs(List<dynamic> args) {
  if (args.isEmpty) return '';
  return jsonEncode(
    _jsonSafe(args.length == 1 ? args.first : args),
    toEncodable: (v) => v.toString(),
  );
}

Object? _jsonSafe(Object? v) {
  if (v is Uint8List) return {'\$binary': base64.encode(v)};
  if (v is ByteBuffer) return {'\$binary': base64.encode(v.asUint8List())};
  if (v is ByteData) {
    return {
      '\$binary': base64.encode(
        v.buffer.asUint8List(v.offsetInBytes, v.lengthInBytes),
      ),
    };
  }
  if (v is List) {
    return [for (final e in v) _jsonSafe(e)];
  }
  if (v is Map) {
    return {for (final e in v.entries) '${e.key}': _jsonSafe(e.value)};
  }
  return v;
}

/// A readable message for the many shapes a connect error takes.
String describeConnectError(Object? err) {
  if (err is Map) {
    final message = err['message'] ?? err['description'] ?? err['reason'];
    final data = err['data'];
    final buf = StringBuffer(message?.toString() ?? jsonEncode(err));
    if (data != null) buf.write(' (data: ${jsonEncode(data)})');
    return buf.toString();
  }
  if (err == null) return 'unknown error';
  return err is Exception ? describeError(err) : err.toString();
}

/// Everything a Socket.IO connection needs, with variables filled in.
class SocketIoConfig {
  SocketIoConfig({
    required this.origin,
    this.namespace = '/',
    this.path = '/socket.io',
    this.query = const {},
    this.auth,
    this.headers = const {},
    this.transports = const ['websocket'],
    this.reconnection = false,
    this.ackTimeout = const Duration(seconds: 10),
    this.catchAll = true,
    this.events = const {},
    this.clientFactory,
  });

  /// Scheme, host and port, such as `http://localhost:3000`.
  final String origin;

  /// The namespace, `/` unless the URL has a path.
  final String namespace;

  /// The handshake path.
  final String path;
  final Map<String, String> query;
  final Map<String, dynamic>? auth;
  final Map<String, String> headers;
  final List<String> transports;
  final bool reconnection;
  final Duration ackTimeout;
  final bool catchAll;

  /// Event names to log when [catchAll] is off.
  final Set<String> events;
  final ClientFactory? clientFactory;

  /// The URL given to the client: origin plus namespace.
  String get target => namespace == '/' ? origin : '$origin$namespace';

  /// The config for request [r]. Throws `RequestBuildException` for an
  /// unusable URL and [FormatException] for a bad auth payload.
  factory SocketIoConfig.fromRequest(
    RequestModel r,
    Map<String, String> vars, {
    ClientFactory? clientFactory,
  }) {
    final s = SocketIoSettings.fromJson(r.protocolConfig);
    final uri = resolveUrl(
      r,
      vars,
      plain: 'http',
      secure: 'https',
      allowed: const {'http', 'https'},
      map: const {'ws': 'http', 'wss': 'https'},
      what: 'Socket.IO',
    );
    final origin = Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    ).toString();
    final headerRows = resolveHeaders(r, vars);
    final headers = <String, String>{};
    for (final h in headerRows) {
      headers[h.key] = headers.containsKey(h.key)
          ? '${headers[h.key]}, ${h.value}'
          : h.value;
    }
    var path = substituteVars(s.path, vars).trim();
    if (!path.startsWith('/')) path = '/$path';
    return SocketIoConfig(
      origin: origin,
      namespace: uri.path.isEmpty ? '/' : uri.path,
      path: path,
      query: uri.queryParameters,
      auth: parseAuthPayload(s.auth, vars),
      headers: headers,
      transports: s.transports.names,
      reconnection: s.reconnection,
      ackTimeout: Duration(seconds: s.ackTimeoutSec),
      catchAll: s.catchAll,
      events: {
        for (final l in s.listeners)
          if (l.enabled && l.event.trim().isNotEmpty) l.event.trim(),
      },
      clientFactory: clientFactory,
    );
  }
}

class _PendingAck {
  _PendingAck(this.event, this.timer) : sentAt = DateTime.now();
  final String event;
  final Timer timer;
  final DateTime sentAt;
}

/// A Socket.IO client connection (protocol v4, servers v3 and v4).
class SocketIoConnection extends LiveConnection {
  SocketIoConnection({super.logCapacity});

  sio.Socket? _socket;
  SocketIoConfig? _config;
  final Map<int, _PendingAck> _pending = {};
  bool _catchAll = true;
  Set<String> _events = {};

  /// The socket id the server assigned, while connected.
  String? get socketId => _socket?.id;

  /// Whether every incoming event is logged.
  bool get catchAll => _catchAll;

  /// Event names logged when the catch-all is off.
  Set<String> get events => Set.unmodifiable(_events);

  /// Changes which incoming events are logged, also while connected.
  void setListening({required bool catchAll, required Set<String> events}) {
    _catchAll = catchAll;
    _events = Set.of(events);
    notify();
  }

  bool _listening(String event) => _catchAll || _events.contains(event);

  /// Connects. Completes right away; the outcome arrives through [state] and
  /// the log.
  Future<void> connect(SocketIoConfig config) async {
    if (isClosed || state != LinkState.idle) return;
    _config = config;
    _catchAll = config.catchAll;
    _events = Set.of(config.events);
    setLinkState(LinkState.connecting);
    note(
      'Connecting to ${config.target}',
      meta: {
        'path': config.path,
        'transport': 'websocket',
        if (config.namespace != '/') 'namespace': config.namespace,
      },
    );
    if (config.transports.contains('polling')) {
      note(
        'Long polling is not available in this client on desktop and mobile; '
        'connecting over WebSocket instead.',
      );
    }
    try {
      _start(config);
    } catch (e) {
      note('Could not connect: ${describeError(e)}', error: true);
      _teardown();
      setLinkState(LinkState.idle);
    }
  }

  void _start(SocketIoConfig config) {
    final builder = sio.OptionBuilder()
        .setPath(config.path)
        .setTransports(usableTransports)
        .disableAutoConnect()
        .enableForceNew()
        .setQuery(config.query);
    if (config.reconnection) {
      builder
          .setReconnectionAttempts(10)
          .setReconnectionDelay(1000)
          .setReconnectionDelayMax(5000);
    } else {
      builder.disableReconnection();
    }
    if (config.headers.isNotEmpty) builder.setExtraHeaders(config.headers);
    final factory = config.clientFactory;
    if (factory != null) builder.setWebSocketConnector(_connector(factory));
    final auth = config.auth;
    if (auth != null) builder.setAuth(auth);
    final socket = sio.io(config.target, builder.build());
    _socket = socket;

    // Packets are read from the manager, before the socket itself sees them:
    // the socket appends its ack callback to the argument list, and its
    // listener API cannot tell several arguments from one list.
    socket.io.on('packet', _onPacket);
    socket.onConnect((_) {
      if (_socket != socket) return;
      setLinkState(LinkState.connected);
      note(
        'Connected',
        meta: {
          'sid': ?socket.id,
          'transport': ?socket.io.engine?.transport?.name,
        },
      );
    });
    socket.onConnectError((err) {
      if (_socket != socket) return;
      note('Connection error: ${describeConnectError(err)}', error: true);
      if (!config.reconnection) {
        _teardown();
        setLinkState(LinkState.idle);
      } else {
        setLinkState(LinkState.reconnecting);
      }
    });
    socket.onDisconnect((reason) {
      if (_socket != socket) return;
      _clearPending();
      note('Disconnected: $reason');
      final lost =
          reason != 'io client disconnect' && reason != 'io server disconnect';
      if (config.reconnection && lost) {
        setLinkState(LinkState.reconnecting);
      } else {
        _teardown();
        setLinkState(LinkState.idle);
      }
    });
    socket.onReconnectAttempt((n) {
      if (_socket != socket) return;
      setLinkState(LinkState.reconnecting, detail: 'attempt $n');
      note('Reconnect attempt $n');
    });
    socket.onReconnectFailed((_) {
      if (_socket != socket) return;
      note('Gave up reconnecting', error: true);
      _teardown();
      setLinkState(LinkState.idle);
    });
    socket.connect();
  }

  void _onPacket(dynamic packet) {
    if (packet is! Map || packet['nsp'] != _socket?.nsp) return;
    final type = packet['type'];
    final data = packet['data'];
    if ((type == 2 || type == 5) &&
        data is List &&
        data.isNotEmpty &&
        data.first is String) {
      final event = data.first as String;
      if (!_listening(event)) return;
      final args = List<dynamic>.of(data.skip(1));
      log.add(
        Direction.received,
        label: 'event',
        title: event,
        text: formatEventArgs(args),
        meta: {
          if (args.length > 1) 'args': '${args.length}',
          if (packet['id'] != null) 'wants ack': '#${packet['id']}',
          if (type == 5) 'binary': 'yes',
        },
      );
    } else if (type == 3 || type == 6) {
      final id = packet['id'];
      final pending = id is int ? _pending.remove(id) : null;
      pending?.timer.cancel();
      final args = data is List ? List<dynamic>.of(data) : <dynamic>[];
      log.add(
        Direction.received,
        label: 'ack',
        title: pending?.event,
        text: formatEventArgs(args),
        meta: {
          'ack': '#$id',
          if (pending != null)
            'after':
                '${DateTime.now().difference(pending.sentAt).inMilliseconds} ms',
        },
      );
    }
  }

  /// Emits [event] with [args]. With [ack], the server's acknowledgement is
  /// logged when it arrives. Throws a [StateError] when not connected and a
  /// [FormatException] for a reserved or empty event name.
  void emit(String event, List<dynamic> args, {bool ack = false}) {
    final socket = _socket;
    if (socket == null || !isConnected) throw StateError('Not connected');
    final name = event.trim();
    if (name.isEmpty) throw const FormatException('Enter an event name.');
    if (const {
      'connect',
      'connect_error',
      'disconnect',
      'disconnecting',
      'newListener',
      'removeListener',
    }.contains(name)) {
      throw FormatException('"$name" is reserved by Socket.IO.');
    }
    int? id;
    if (ack) {
      id = socket.ids.toInt();
      final timeout = _config?.ackTimeout ?? const Duration(seconds: 10);
      _pending[id] = _PendingAck(
        name,
        Timer(timeout, () {
          final p = _pending.remove(id);
          if (p == null) return;
          note(
            'No acknowledgement for "$name" (#$id) within ${timeout.inSeconds} s',
            error: true,
          );
        }),
      );
    }
    socket.emitWithAck(
      name,
      List<dynamic>.of(args),
      ack: ack ? ([Object? a, Object? b]) {} : null,
    );
    log.add(
      Direction.sent,
      label: 'event',
      title: name,
      text: formatEventArgs(args),
      meta: {
        if (args.length > 1) 'args': '${args.length}',
        if (id != null) 'ack': '#$id',
      },
    );
  }

  void _clearPending() {
    for (final p in _pending.values) {
      p.timer.cancel();
    }
    _pending.clear();
  }

  void _teardown() {
    _clearPending();
    final socket = _socket;
    _socket = null;
    if (socket == null) return;
    try {
      socket.io.off('packet', _onPacket);
      socket.dispose();
      socket.io.close();
    } catch (_) {
      // Already torn down by the client library.
    }
  }

  /// Disconnects and stops any reconnecting.
  void disconnect() {
    if (state == LinkState.idle) return;
    final wasConnected = isConnected;
    _teardown();
    note(wasConnected ? 'Disconnected' : 'Connection attempt cancelled');
    setLinkState(LinkState.idle);
  }

  @override
  void close() {
    if (isClosed) return;
    _teardown();
    markClosed();
  }
}

/// Opens the WebSocket through a client from [factory], so the connection
/// follows the app's proxy and TLS settings.
Future<IOWebSocket> Function(
  Uri uri, {
  Iterable<String>? protocols,
  Map<String, String>? headers,
})
_connector(ClientFactory factory) => (uri, {protocols, headers}) async {
  final client = factory();
  try {
    final socket = await WebSocket.connect(
      uri.toString(),
      protocols: protocols,
      headers: headers,
      customClient: client,
    );
    socket.done.whenComplete(() => client.close(force: true)).ignore();
    return IOWebSocket.fromWebSocket(socket);
  } catch (_) {
    client.close(force: true);
    rethrow;
  }
};
