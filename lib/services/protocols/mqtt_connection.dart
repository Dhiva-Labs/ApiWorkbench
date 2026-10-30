import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../../models/models.dart';
import '../request_builder.dart';
import 'live_connection.dart';

/// Where an MQTT broker is and how to reach it.
class MqttEndpoint {
  MqttEndpoint({
    required this.scheme,
    required this.host,
    required this.port,
    this.path = '',
  });

  /// `tcp`, `ssl`, `ws` or `wss`.
  final String scheme;
  final String host;
  final int port;

  /// Path and query of a WebSocket broker, such as `/mqtt?token=1`.
  final String path;

  bool get secure => scheme == 'ssl' || scheme == 'wss';
  bool get websocket => scheme == 'ws' || scheme == 'wss';

  /// The address as shown in the log.
  String get display => websocket
      ? '$scheme://$host:$port${path.isEmpty ? '' : path}'
      : '$scheme://$host:$port';

  /// What the client library wants as the server of a WebSocket broker.
  String get websocketUrl => '$scheme://$host$path';

  /// Reads a broker URL. Accepts `tcp://` and `mqtt://` (plain),
  /// `ssl://`, `mqtts://` and `tls://` (TLS), `ws://` and `wss://`, or a
  /// bare `host:port`. Throws a [FormatException] with a readable message.
  static MqttEndpoint parse(String input) {
    final raw = input.trim();
    if (raw.isEmpty) {
      throw const FormatException(
        'Enter the broker URL, such as mqtt://localhost:1883.',
      );
    }
    final withScheme = raw.contains('://') ? raw : 'mqtt://$raw';
    final Uri uri;
    try {
      uri = Uri.parse(withScheme);
    } on FormatException catch (e) {
      throw FormatException('The broker URL is not valid: ${e.message}');
    }
    return fromUri(uri);
  }

  /// Reads an already parsed broker URL; see [parse].
  static MqttEndpoint fromUri(Uri uri) {
    final scheme = switch (uri.scheme.toLowerCase()) {
      'mqtt' || 'tcp' => 'tcp',
      'mqtts' || 'ssl' || 'tls' => 'ssl',
      'ws' => 'ws',
      'wss' => 'wss',
      final other => throw FormatException(
        'The broker URL starts with "$other://". Use tcp:// (or mqtt://), '
        'ssl:// (or mqtts://), ws:// or wss://.',
      ),
    };
    if (uri.host.isEmpty) {
      throw const FormatException('The broker URL has no host name.');
    }
    final port = uri.hasPort && uri.port > 0
        ? uri.port
        : switch (scheme) {
            'tcp' => 1883,
            'ssl' => 8883,
            'ws' => 80,
            _ => 443,
          };
    var path = '';
    if (scheme == 'ws' || scheme == 'wss') {
      path = uri.path + (uri.hasQuery ? '?${uri.query}' : '');
    }
    return MqttEndpoint(scheme: scheme, host: uri.host, port: port, path: path);
  }
}

/// A topic filter to subscribe to.
class MqttSubscription {
  MqttSubscription({this.topic = '', this.qos = 0, this.enabled = true});

  String topic;
  int qos;

  /// Subscribed while connected; switch off to unsubscribe.
  bool enabled;

  Map<String, dynamic> toJson() => {
    'topic': topic,
    'qos': qos,
    'enabled': enabled,
  };

  factory MqttSubscription.fromJson(Map<String, dynamic> j) => MqttSubscription(
    topic: jsonString(j['topic']),
    qos: jsonInt(j['qos'], 0).clamp(0, 2),
    enabled: jsonBool(j['enabled'], true),
  );
}

/// What an MQTT request keeps in [RequestModel.protocolConfig].
class MqttSettings {
  MqttSettings({
    this.clientId = '',
    this.username = '',
    this.password = '',
    this.keepAlive = 60,
    this.cleanSession = true,
    this.autoReconnect = false,
    this.willEnabled = false,
    this.willTopic = '',
    this.willPayload = '',
    this.willQos = 0,
    this.willRetain = false,
    this.pubTopic = '',
    this.pubPayload = '',
    this.pubKind = PayloadKind.text,
    this.pubQos = 0,
    this.pubRetain = false,
    List<MqttSubscription>? subscriptions,
  }) : subscriptions = subscriptions ?? [];

  /// Empty means a random id is made for each connection.
  String clientId;
  String username;
  String password;

  /// Seconds between keep-alive pings; 0 turns them off.
  int keepAlive;
  bool cleanSession;
  bool autoReconnect;

  bool willEnabled;
  String willTopic;
  String willPayload;
  int willQos;
  bool willRetain;

  /// The publish composer.
  String pubTopic;
  String pubPayload;
  PayloadKind pubKind;
  int pubQos;
  bool pubRetain;

  List<MqttSubscription> subscriptions;

  Map<String, dynamic> toJson() => {
    'clientId': clientId,
    'username': username,
    'password': password,
    'keepAlive': keepAlive,
    'cleanSession': cleanSession,
    'autoReconnect': autoReconnect,
    'willEnabled': willEnabled,
    'willTopic': willTopic,
    'willPayload': willPayload,
    'willQos': willQos,
    'willRetain': willRetain,
    'pubTopic': pubTopic,
    'pubPayload': pubPayload,
    'pubKind': pubKind.name,
    'pubQos': pubQos,
    'pubRetain': pubRetain,
    'subscriptions': subscriptions.map((s) => s.toJson()).toList(),
  };

  factory MqttSettings.fromJson(Map<String, dynamic> j) => MqttSettings(
    clientId: jsonString(j['clientId']),
    username: jsonString(j['username']),
    password: jsonString(j['password']),
    keepAlive: jsonInt(j['keepAlive'], 60).clamp(0, 65535),
    cleanSession: jsonBool(j['cleanSession'], true),
    autoReconnect: jsonBool(j['autoReconnect'], false),
    willEnabled: jsonBool(j['willEnabled'], false),
    willTopic: jsonString(j['willTopic']),
    willPayload: jsonString(j['willPayload']),
    willQos: jsonInt(j['willQos'], 0).clamp(0, 2),
    willRetain: jsonBool(j['willRetain'], false),
    pubTopic: jsonString(j['pubTopic']),
    pubPayload: jsonString(j['pubPayload']),
    pubKind: PayloadKind.values.asNameMap()[j['pubKind']] ?? PayloadKind.text,
    pubQos: jsonInt(j['pubQos'], 0).clamp(0, 2),
    pubRetain: jsonBool(j['pubRetain'], false),
    subscriptions: [
      for (final s in jsonMaps(j['subscriptions']))
        MqttSubscription.fromJson(s),
    ],
  );
}

/// Why [topic] cannot be published to, or null when it can.
String? validatePublishTopic(String topic) {
  if (topic.isEmpty) return 'Enter a topic to publish to.';
  if (topic.contains('\u0000')) {
    return 'A topic cannot contain a null character.';
  }
  if (topic.contains('+') || topic.contains('#')) {
    return 'A publish topic cannot contain the wildcards + or #.';
  }
  if (utf8.encode(topic).length > 65535) return 'The topic is too long.';
  return null;
}

/// Why [filter] cannot be subscribed to, or null when it can.
String? validateSubscribeFilter(String filter) {
  if (filter.isEmpty) return 'Enter a topic filter to subscribe to.';
  if (filter.contains('\u0000')) {
    return 'A topic cannot contain a null character.';
  }
  if (utf8.encode(filter).length > 65535) return 'The topic is too long.';
  final levels = filter.split('/');
  for (var i = 0; i < levels.length; i++) {
    final l = levels[i];
    if (l.contains('#') && (l != '#' || i != levels.length - 1)) {
      return 'The wildcard # must be a whole level at the end, such as a/#.';
    }
    if (l.contains('+') && l != '+') {
      return 'The wildcard + must be a whole level, such as a/+/c.';
    }
  }
  return null;
}

/// Whether the subscription [filter] receives messages published to [topic],
/// with MQTT's `+` and `#` wildcards. Topics starting with `$` need a filter
/// that starts with `$` too.
bool topicMatches(String filter, String topic) {
  final f = filter.split('/');
  final t = topic.split('/');
  if (topic.startsWith(r'$') && (f.first == '#' || f.first == '+')) {
    return false;
  }
  for (var i = 0; i < f.length; i++) {
    if (f[i] == '#') return true;
    if (i >= t.length) return false;
    if (f[i] != '+' && f[i] != t[i]) return false;
  }
  return f.length == t.length;
}

/// Everything an MQTT connection needs, with variables filled in.
class MqttConfig {
  MqttConfig({
    required this.endpoint,
    required this.clientId,
    this.username = '',
    this.password = '',
    this.keepAlive = 60,
    this.cleanSession = true,
    this.autoReconnect = false,
    this.willTopic,
    this.willPayload = '',
    this.willQos = 0,
    this.willRetain = false,
    this.headers = const {},
    this.subscriptions = const [],
    this.verifySsl = true,
    this.securityContext,
    this.connectTimeout = const Duration(seconds: 10),
  });

  final MqttEndpoint endpoint;
  final String clientId;
  final String username;
  final String password;
  final int keepAlive;
  final bool cleanSession;
  final bool autoReconnect;

  /// Null when no last will is set.
  final String? willTopic;
  final String willPayload;
  final int willQos;
  final bool willRetain;

  /// HTTP headers of the WebSocket upgrade (ws and wss brokers only).
  final Map<String, Object> headers;

  /// Subscribed right after connecting.
  final List<MqttSubscription> subscriptions;
  final bool verifySsl;

  /// Trusted certificates for ssl brokers.
  final SecurityContext? securityContext;
  final Duration connectTimeout;

  /// The config for request [r]. Throws `RequestBuildException` for an
  /// unusable URL and [FormatException] for bad settings.
  factory MqttConfig.fromRequest(
    RequestModel r,
    Map<String, String> vars, {
    bool verifySsl = true,
    SecurityContext? securityContext,
  }) {
    final s = MqttSettings.fromJson(r.protocolConfig);
    final uri = resolveUrl(
      r,
      vars,
      plain: 'mqtt',
      secure: 'mqtts',
      allowed: const {'mqtt', 'tcp', 'mqtts', 'ssl', 'tls', 'ws', 'wss'},
      what: 'MQTT broker',
    );
    final endpoint = MqttEndpoint.fromUri(uri);
    final id = substituteVars(s.clientId, vars).trim();
    final willTopic = substituteVars(s.willTopic, vars).trim();
    if (s.willEnabled && willTopic.isNotEmpty) {
      final problem = validatePublishTopic(willTopic);
      if (problem != null) throw FormatException('Last will: $problem');
    }
    return MqttConfig(
      endpoint: endpoint,
      clientId: id.isEmpty ? randomClientId() : id,
      username: substituteVars(s.username, vars),
      password: substituteVars(s.password, vars),
      keepAlive: s.keepAlive,
      cleanSession: s.cleanSession,
      autoReconnect: s.autoReconnect,
      willTopic: s.willEnabled && willTopic.isNotEmpty ? willTopic : null,
      willPayload: substituteVars(s.willPayload, vars),
      willQos: s.willQos,
      willRetain: s.willRetain,
      headers: headerMap(resolveHeaders(r, vars)),
      subscriptions: [
        for (final sub in s.subscriptions)
          if (sub.enabled && sub.topic.trim().isNotEmpty)
            MqttSubscription(
              topic: substituteVars(sub.topic, vars).trim(),
              qos: sub.qos,
            ),
      ],
      verifySsl: verifySsl,
      securityContext: securityContext,
    );
  }
}

/// A security context trusting the system roots plus the PEM file at
/// [caPath], or null when none is set or it cannot be read.
SecurityContext? securityContextFor(String caPath) {
  if (caPath.trim().isEmpty) return null;
  try {
    return SecurityContext(withTrustedRoots: true)
      ..setTrustedCertificates(caPath.trim());
  } on Object {
    return null;
  }
}

/// An MQTT 3.1.1 client connection with subscriptions and publishing.
class MqttConnection extends LiveConnection {
  MqttConnection({super.logCapacity});

  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updates;
  MqttConfig? _config;
  final Map<String, int> _active = {};

  /// Messages received per subscribed filter, counted since connecting.
  final Map<String, int> counts = {};

  /// Filters currently subscribed on the broker.
  Set<String> get subscribedTopics => Set.unmodifiable(_active.keys);

  /// The client id used for the current or last connection.
  String? get clientId => _config?.clientId;

  /// Connects. Failures are logged, not thrown.
  Future<void> connect(MqttConfig config) async {
    if (isClosed || state != LinkState.idle) return;
    _config = config;
    _active.clear();
    counts.clear();
    final ep = config.endpoint;
    setLinkState(LinkState.connecting);
    note(
      'Connecting to ${ep.display} as "${config.clientId}"',
      meta: {
        'keep-alive': '${config.keepAlive} s',
        'clean session': config.cleanSession ? 'yes' : 'no',
        if (config.username.isNotEmpty) 'user': config.username,
      },
    );
    final client = MqttServerClient.withPort(
      ep.websocket ? ep.websocketUrl : ep.host,
      config.clientId,
      ep.port,
      maxConnectionAttempts: 1,
    );
    _client = client;
    client
      ..logging(on: false)
      ..keepAlivePeriod = config.keepAlive
      ..connectTimeoutPeriod = config.connectTimeout.inMilliseconds
      ..connectionTimeout = config.connectTimeout.inMilliseconds
      ..autoReconnect = config.autoReconnect
      ..useWebSocket = ep.websocket
      ..secure = ep.secure && !ep.websocket
      ..setProtocolV311();
    if (!config.verifySsl && ep.secure) client.onBadCertificate = (_) => true;
    final context = config.securityContext;
    if (context != null && ep.secure && !ep.websocket) {
      client.securityContext = context;
    }
    if (ep.websocket && config.headers.isNotEmpty) {
      client.websocketHeader = Map<String, dynamic>.of(config.headers);
    }
    final will = config.willTopic;
    final message = MqttConnectMessage().withClientIdentifier(config.clientId);
    if (config.cleanSession) message.startClean();
    if (will != null) {
      message
          .withWillTopic(will)
          .withWillMessage(config.willPayload)
          .withWillQos(_qos(config.willQos));
      if (config.willRetain) message.withWillRetain();
    }
    if (config.username.isNotEmpty) {
      message.authenticateAs(config.username, config.password);
    }
    client.connectionMessage = message;
    client.onDisconnected = () => _onDisconnected(client);
    client.onAutoReconnect = () {
      if (_client != client) return;
      setLinkState(LinkState.reconnecting);
      note('Connection lost, reconnecting');
    };
    client.onAutoReconnected = () {
      if (_client != client) return;
      setLinkState(LinkState.connected);
      note('Reconnected');
    };
    client.onSubscribed = (topic) {
      if (_client != client) return;
      note('Subscribed to $topic');
    };
    client.onSubscribeFail = (topic) {
      if (_client != client) return;
      _active.remove(topic);
      note('The broker refused the subscription to $topic', error: true);
      notify();
    };
    client.onUnsubscribed = (topic) {
      if (_client != client) return;
      note('Unsubscribed from ${topic ?? ''}');
    };
    try {
      final status = await client.connect();
      if (_client != client || isClosed) return;
      if (status?.state == MqttConnectionState.connected) {
        _onConnected(client, config);
      } else {
        note(
          'The broker refused the connection: '
          '${_returnCodeText(status?.returnCode)}',
          error: true,
        );
        _drop(client);
        setLinkState(LinkState.idle);
      }
    } catch (e) {
      if (_client != client || isClosed) return;
      note('Could not connect: ${_connectError(e, client)}', error: true);
      _drop(client);
      setLinkState(LinkState.idle);
    }
  }

  void _onConnected(MqttServerClient client, MqttConfig config) {
    setLinkState(LinkState.connected);
    note('Connected');
    _updates = client.updates?.listen(_onUpdates);
    for (final s in config.subscriptions) {
      try {
        subscribe(s.topic, s.qos);
      } on FormatException catch (e) {
        note('Skipped subscription "${s.topic}": ${e.message}', error: true);
      }
    }
  }

  void _onUpdates(List<MqttReceivedMessage<MqttMessage>> events) {
    for (final e in events) {
      final m = e.payload;
      if (m is! MqttPublishMessage) continue;
      final bytes = Uint8List.fromList(m.payload.message);
      final text = _asText(bytes);
      final topic = e.topic;
      for (final filter in _active.keys) {
        if (topicMatches(filter, topic)) {
          counts[filter] = (counts[filter] ?? 0) + 1;
        }
      }
      log.add(
        Direction.received,
        label: text == null ? 'binary' : 'message',
        title: topic,
        text: text ?? '',
        bytes: text == null ? bytes : null,
        meta: {
          'QoS': '${m.header?.qos.index ?? 0}',
          'retain': '${m.header?.retain ?? false}',
          if (m.header?.duplicate ?? false) 'dup': 'true',
        },
      );
    }
  }

  /// Subscribes to [filter]. Throws a [FormatException] for a bad filter and
  /// a [StateError] when not connected.
  void subscribe(String filter, int qos) {
    final client = _client;
    if (client == null || !isConnected) throw StateError('Not connected');
    final topic = filter.trim();
    final problem = validateSubscribeFilter(topic);
    if (problem != null) throw FormatException(problem);
    if (_active.containsKey(topic)) return;
    _active[topic] = qos;
    counts.putIfAbsent(topic, () => 0);
    client.subscribe(topic, _qos(qos));
    note('Subscribing to $topic', meta: {'QoS': '$qos'});
  }

  /// Unsubscribes from [filter], if subscribed.
  void unsubscribe(String filter) {
    final client = _client;
    if (client == null || !isConnected) throw StateError('Not connected');
    final topic = filter.trim();
    if (_active.remove(topic) == null) return;
    client.unsubscribe(topic);
    notify();
  }

  /// Publishes [payload] to [topic]. Throws a [FormatException] for a bad
  /// topic and a [StateError] when not connected.
  void publish(
    String topic,
    Payload payload, {
    int qos = 0,
    bool retain = false,
  }) {
    final client = _client;
    if (client == null || !isConnected) throw StateError('Not connected');
    final problem = validatePublishTopic(topic);
    if (problem != null) throw FormatException(problem);
    final builder = MqttClientPayloadBuilder();
    if (payload.isBinary) {
      for (final b in payload.bytes!) {
        builder.addByte(b);
      }
    } else {
      for (final b in utf8.encode(payload.text!)) {
        builder.addByte(b);
      }
    }
    client.publishMessage(topic, _qos(qos), builder.payload!, retain: retain);
    log.add(
      Direction.sent,
      label: payload.isBinary ? 'binary' : 'message',
      title: topic,
      text: payload.text ?? '',
      bytes: payload.bytes,
      meta: {'QoS': '$qos', 'retain': '$retain'},
    );
  }

  void _onDisconnected(MqttServerClient client) {
    if (_client != client) return;
    final origin = client.connectionStatus?.disconnectionOrigin;
    note(
      origin == MqttDisconnectionOrigin.solicited
          ? 'Disconnected'
          : 'The broker closed the connection',
      error: origin != MqttDisconnectionOrigin.solicited,
    );
    _drop(client);
    setLinkState(LinkState.idle);
  }

  void _drop(MqttServerClient client) {
    _updates?.cancel();
    _updates = null;
    _active.clear();
    if (_client == client) _client = null;
  }

  /// Disconnects from the broker.
  void disconnect() {
    final client = _client;
    if (client == null) return;
    if (!isConnected && state != LinkState.reconnecting) {
      // Still connecting: abandon the attempt.
      _drop(client);
      try {
        client.disconnect();
      } catch (_) {}
      note('Connection attempt cancelled');
      setLinkState(LinkState.idle);
      return;
    }
    // _onDisconnected logs it and returns to idle.
    client.disconnect();
  }

  @override
  void close() {
    if (isClosed) return;
    final client = _client;
    _updates?.cancel();
    _client = null;
    markClosed();
    try {
      client?.onDisconnected = null;
      client?.autoReconnect = false;
      client?.disconnect();
    } catch (_) {
      // The connection was already gone.
    }
  }
}

MqttQos _qos(int level) => switch (level) {
  1 => MqttQos.atLeastOnce,
  2 => MqttQos.exactlyOnce,
  _ => MqttQos.atMostOnce,
};

/// The payload as text when it is UTF-8 without control characters, else null.
String? _asText(Uint8List bytes) {
  try {
    final text = utf8.decode(bytes);
    for (final unit in text.codeUnits) {
      if (unit < 0x20 && unit != 0x09 && unit != 0x0a && unit != 0x0d) {
        return null;
      }
    }
    return text;
  } on FormatException {
    return null;
  }
}

String _returnCodeText(MqttConnectReturnCode? code) => switch (code) {
  MqttConnectReturnCode.unacceptedProtocolVersion =>
    'the broker does not support MQTT 3.1.1',
  MqttConnectReturnCode.identifierRejected => 'the client id was rejected',
  MqttConnectReturnCode.brokerUnavailable => 'the broker is unavailable',
  MqttConnectReturnCode.badUsernameOrPassword => 'bad user name or password',
  MqttConnectReturnCode.notAuthorized => 'not authorized',
  null => 'no answer',
  final other => other.name,
};

String _connectError(Object e, MqttServerClient client) {
  final code = client.connectionStatus?.returnCode;
  if (code != null &&
      code != MqttConnectReturnCode.connectionAccepted &&
      code != MqttConnectReturnCode.noneSpecified) {
    return _returnCodeText(code);
  }
  if (e is NoConnectionException) {
    final m = e.toString();
    return m.contains('Connection refused')
        ? 'connection refused'
        : m.replaceFirst('mqtt-client::', '').trim();
  }
  return describeError(e);
}
