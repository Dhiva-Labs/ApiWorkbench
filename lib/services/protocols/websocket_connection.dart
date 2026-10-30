import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../models/models.dart';
import 'live_connection.dart';

/// What a WebSocket request keeps in [RequestModel.protocolConfig].
class WebSocketSettings {
  WebSocketSettings({
    this.subprotocols = '',
    this.pingSeconds = 0,
    this.autoReconnect = false,
    this.maxAttempts = 5,
    this.backoffMs = 1000,
    this.backoffMaxMs = 30000,
    this.compose = PayloadKind.text,
    this.draft = '',
    List<SavedMessage>? messages,
  }) : messages = messages ?? [];

  /// Subprotocols to offer, separated by commas or spaces.
  String subprotocols;

  /// Seconds between WebSocket pings; 0 turns pings off.
  int pingSeconds;
  bool autoReconnect;

  /// Reconnect attempts before giving up; 0 means keep trying.
  int maxAttempts;

  /// First wait before reconnecting; it doubles on every attempt.
  int backoffMs;

  /// Longest wait between attempts.
  int backoffMaxMs;

  /// Kind of the message in the composer.
  PayloadKind compose;

  /// The message in the composer.
  String draft;
  List<SavedMessage> messages;

  List<String> get protocolList =>
      subprotocols.split(RegExp(r'[,\s]+')).where((s) => s.isNotEmpty).toList();

  Map<String, dynamic> toJson() => {
    'subprotocols': subprotocols,
    'pingSeconds': pingSeconds,
    'autoReconnect': autoReconnect,
    'maxAttempts': maxAttempts,
    'backoffMs': backoffMs,
    'backoffMaxMs': backoffMaxMs,
    'compose': compose.name,
    'draft': draft,
    'messages': messages.map((m) => m.toJson()).toList(),
  };

  factory WebSocketSettings.fromJson(Map<String, dynamic> j) =>
      WebSocketSettings(
        subprotocols: jsonString(j['subprotocols']),
        pingSeconds: jsonInt(j['pingSeconds'], 0).clamp(0, 86400),
        autoReconnect: jsonBool(j['autoReconnect'], false),
        maxAttempts: jsonInt(j['maxAttempts'], 5).clamp(0, 1000),
        backoffMs: jsonInt(j['backoffMs'], 1000).clamp(50, 600000),
        backoffMaxMs: jsonInt(j['backoffMaxMs'], 30000).clamp(50, 3600000),
        compose:
            PayloadKind.values.asNameMap()[j['compose']] ?? PayloadKind.text,
        draft: jsonString(j['draft']),
        messages: [
          for (final m in jsonMaps(j['messages'])) SavedMessage.fromJson(m),
        ],
      );
}

/// Everything a connection attempt needs, with variables already filled in.
class WebSocketConfig {
  WebSocketConfig({
    required this.url,
    this.headers = const [],
    this.protocols = const [],
    this.pingInterval,
    this.autoReconnect = false,
    this.maxAttempts = 5,
    this.backoffBase = const Duration(seconds: 1),
    this.backoffMax = const Duration(seconds: 30),
    this.connectTimeout = const Duration(seconds: 20),
    this.clientFactory,
  });

  final Uri url;
  final List<MapEntry<String, String>> headers;
  final List<String> protocols;
  final Duration? pingInterval;
  final bool autoReconnect;
  final int maxAttempts;
  final Duration backoffBase;
  final Duration backoffMax;
  final Duration connectTimeout;

  /// Builds the HTTP client the upgrade request goes through (proxy, TLS).
  final ClientFactory? clientFactory;

  /// The config for request [r]. Throws `RequestBuildException` when the
  /// URL is unusable.
  factory WebSocketConfig.fromRequest(
    RequestModel r,
    Map<String, String> vars, {
    ClientFactory? clientFactory,
  }) {
    final s = WebSocketSettings.fromJson(r.protocolConfig);
    return WebSocketConfig(
      url: resolveUrl(
        r,
        vars,
        plain: 'ws',
        secure: 'wss',
        allowed: const {'ws', 'wss'},
        map: const {'http': 'ws', 'https': 'wss'},
        what: 'WebSocket',
      ),
      headers: resolveHeaders(r, vars),
      protocols: s.protocolList,
      pingInterval: s.pingSeconds > 0 ? Duration(seconds: s.pingSeconds) : null,
      autoReconnect: s.autoReconnect,
      maxAttempts: s.maxAttempts,
      backoffBase: Duration(milliseconds: s.backoffMs),
      backoffMax: Duration(milliseconds: s.backoffMaxMs),
      clientFactory: clientFactory,
    );
  }
}

/// A WebSocket client connection with optional ping and reconnect.
class WebSocketConnection extends LiveConnection {
  WebSocketConnection({super.logCapacity});

  WebSocket? _socket;
  HttpClient? _client;
  StreamSubscription<dynamic>? _sub;
  Timer? _retryTimer;
  WebSocketConfig? _config;
  bool _wanted = false;
  int _generation = 0;
  int _attempt = 0;

  /// Close code of the last connection that ended, if any.
  int? closeCode;
  String? closeReason;

  /// The subprotocol the server picked, while connected.
  String? protocol;

  /// Opens the connection. Completes once it is open or has failed; failures
  /// are logged, not thrown.
  Future<void> connect(WebSocketConfig config) async {
    if (isClosed || state != LinkState.idle) return;
    _config = config;
    _wanted = true;
    _attempt = 0;
    await _open();
  }

  Future<void> _open() async {
    final config = _config!;
    final gen = ++_generation;
    setLinkState(
      _attempt == 0 ? LinkState.connecting : LinkState.reconnecting,
      detail: _attempt == 0 ? '' : 'attempt $_attempt',
    );
    note('Connecting to ${config.url}');
    HttpClient? client;
    try {
      client = config.clientFactory?.call();
      final attempt = WebSocket.connect(
        config.url.toString(),
        headers: headerMap(config.headers),
        protocols: config.protocols.isEmpty ? null : config.protocols,
        customClient: client,
      );
      final socket = await attempt.timeout(
        config.connectTimeout,
        onTimeout: () {
          attempt.then((s) => s.close(), onError: (_) => null);
          throw TimeoutException(
            'No answer within ${config.connectTimeout.inSeconds} s',
          );
        },
      );
      if (gen != _generation || !_wanted || isClosed) {
        unawaited(socket.close().catchError((_) => null));
        client?.close(force: true);
        return;
      }
      _socket = socket;
      _client = client;
      socket.pingInterval = config.pingInterval;
      protocol = socket.protocol;
      _attempt = 0;
      setLinkState(LinkState.connected);
      note(
        'Connected',
        meta: {
          if (socket.protocol != null) 'subprotocol': socket.protocol!,
          if (config.pingInterval != null)
            'ping': '${config.pingInterval!.inSeconds} s',
        },
      );
      _sub = socket.listen(
        _onData,
        onError: (Object e) => note('Error: ${describeError(e)}', error: true),
        onDone: () => _onDone(gen, socket),
      );
    } catch (e) {
      client?.close(force: true);
      if (gen != _generation || isClosed) return;
      note('Could not connect: ${describeError(e)}', error: true);
      _afterLoss();
    }
  }

  void _onData(dynamic data) {
    if (data is String) {
      log.add(Direction.received, label: 'text', text: data);
    } else if (data is List<int>) {
      log.add(
        Direction.received,
        label: 'binary',
        bytes: data is Uint8List ? data : Uint8List.fromList(data),
      );
    }
  }

  void _onDone(int gen, WebSocket socket) {
    if (gen != _generation || _socket != socket) return;
    closeCode = socket.closeCode;
    closeReason = socket.closeReason;
    final code = closeCode;
    final reason = closeReason;
    note(
      code == null
          ? 'Connection closed'
          : 'Connection closed (code $code'
                '${reason == null || reason.isEmpty ? '' : ': $reason'})',
      error: _wanted && code != 1000 && code != 1001,
    );
    _sub = null;
    _socket = null;
    protocol = null;
    _client?.close(force: true);
    _client = null;
    _afterLoss();
  }

  /// Decides what follows a failed attempt or a lost connection.
  void _afterLoss() {
    final config = _config!;
    if (!_wanted || !config.autoReconnect) {
      _wanted = false;
      setLinkState(LinkState.idle);
      return;
    }
    _attempt++;
    if (config.maxAttempts > 0 && _attempt > config.maxAttempts) {
      note(
        'Gave up after ${config.maxAttempts} reconnect attempts',
        error: true,
      );
      _wanted = false;
      setLinkState(LinkState.idle);
      return;
    }
    final wait = reconnectDelay(
      _attempt,
      config.backoffBase,
      config.backoffMax,
    );
    final seconds = (wait.inMilliseconds / 1000).toStringAsFixed(
      wait.inMilliseconds % 1000 == 0 ? 0 : 1,
    );
    setLinkState(
      LinkState.reconnecting,
      detail: 'attempt $_attempt in $seconds s',
    );
    note('Reconnecting in $seconds s (attempt $_attempt)');
    _retryTimer?.cancel();
    _retryTimer = Timer(wait, () {
      if (_wanted && !isClosed) _open();
    });
  }

  /// Sends a text frame. Throws a [StateError] when not connected.
  void sendText(String text) {
    final s = _socket;
    if (s == null || !isConnected) throw StateError('Not connected');
    s.add(text);
    log.add(Direction.sent, label: 'text', text: text);
  }

  /// Sends a binary frame. Throws a [StateError] when not connected.
  void sendBytes(Uint8List bytes) {
    final s = _socket;
    if (s == null || !isConnected) throw StateError('Not connected');
    s.add(bytes);
    log.add(Direction.sent, label: 'binary', bytes: bytes);
  }

  /// Sends [payload] as a text or binary frame.
  void send(Payload payload) =>
      payload.isBinary ? sendBytes(payload.bytes!) : sendText(payload.text!);

  /// Closes the connection and stops reconnecting.
  Future<void> disconnect() async {
    _wanted = false;
    _retryTimer?.cancel();
    final socket = _socket;
    if (socket != null) {
      note('Disconnecting');
      await socket.close(WebSocketStatus.normalClosure);
      return;
    }
    if (state != LinkState.idle) {
      _generation++;
      note('Connection attempt cancelled');
      setLinkState(LinkState.idle);
    }
  }

  @override
  void close() {
    if (isClosed) return;
    _wanted = false;
    _generation++;
    _retryTimer?.cancel();
    _sub?.cancel();
    _socket?.close(WebSocketStatus.goingAway).catchError((_) => null);
    _client?.close(force: true);
    _socket = null;
    markClosed();
  }
}
