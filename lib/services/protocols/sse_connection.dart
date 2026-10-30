import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/models.dart';
import '../request_builder.dart';
import 'live_connection.dart';

/// One event of a `text/event-stream`.
class SseEvent {
  SseEvent({required this.data, this.event = 'message', this.id, this.retry});

  /// The `data` lines joined with newlines.
  final String data;

  /// The `event` field; `message` when the stream did not name one.
  final String event;

  /// The `id` field, when this event carried one.
  final String? id;

  /// The `retry` field (milliseconds), when this event carried one.
  final int? retry;

  @override
  String toString() => 'SseEvent($event, id: $id, retry: $retry, data: $data)';
}

/// Incremental parser for the `text/event-stream` format. Feed it text as it
/// arrives, in chunks of any size; it splits lines on CRLF, LF or CR and
/// returns the events completed by each chunk.
class SseParser {
  SseParser({this.onComment, this.onRetry});

  /// Called for each `:` comment line (often a keep-alive).
  final void Function(String comment)? onComment;

  /// Called when the server sets the reconnection time with `retry:`.
  final void Function(Duration retry)? onRetry;

  final StringBuffer _line = StringBuffer();
  bool _pendingCr = false;
  bool _first = true;

  final List<String> _data = [];
  String? _event;
  String? _id;
  int? _retry;

  /// The id of the last event that carried one, for `Last-Event-ID`.
  String? lastEventId;

  /// Parses [chunk] and returns the events it completed.
  List<SseEvent> add(String chunk) {
    var text = chunk;
    if (_first && text.isNotEmpty) {
      _first = false;
      if (text.codeUnitAt(0) == 0xFEFF) text = text.substring(1);
    }
    final out = <SseEvent>[];
    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (_pendingCr) {
        _pendingCr = false;
        if (c == '\n') continue; // the LF of a CRLF pair
      }
      if (c == '\n' || c == '\r') {
        _pendingCr = c == '\r';
        final event = _endLine(_line.toString());
        _line.clear();
        if (event != null) out.add(event);
      } else {
        _line.write(c);
      }
    }
    return out;
  }

  SseEvent? _endLine(String line) {
    if (line.isEmpty) return _dispatch();
    if (line.startsWith(':')) {
      onComment?.call(line.substring(1).trimLeft());
      return null;
    }
    final colon = line.indexOf(':');
    final String field;
    var value = '';
    if (colon < 0) {
      field = line;
    } else {
      field = line.substring(0, colon);
      value = line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
    }
    switch (field) {
      case 'data':
        _data.add(value);
      case 'event':
        _event = value;
      case 'id':
        if (!value.contains('\u0000')) {
          _id = value;
          lastEventId = value;
        }
      case 'retry':
        if (RegExp(r'^\d+$').hasMatch(value)) {
          _retry = int.parse(value);
          onRetry?.call(Duration(milliseconds: _retry!));
        }
    }
    return null;
  }

  SseEvent? _dispatch() {
    SseEvent? event;
    if (_data.isNotEmpty) {
      event = SseEvent(
        data: _data.join('\n'),
        event: (_event == null || _event!.isEmpty) ? 'message' : _event!,
        id: _id,
        retry: _retry,
      );
    }
    _data.clear();
    _event = null;
    _id = null;
    _retry = null;
    return event;
  }
}

/// What an SSE request keeps in [RequestModel.protocolConfig].
class SseSettings {
  SseSettings({
    this.autoReconnect = true,
    this.defaultRetryMs = 3000,
    this.maxReconnects = 0,
    this.showComments = false,
  });

  /// Reconnect when the stream ends or fails.
  bool autoReconnect;

  /// Wait before reconnecting when the server has not set `retry:`.
  int defaultRetryMs;

  /// Reconnects in a row before giving up; 0 means keep trying.
  int maxReconnects;

  /// Log `:` comment lines such as keep-alives.
  bool showComments;

  Map<String, dynamic> toJson() => {
    'autoReconnect': autoReconnect,
    'defaultRetryMs': defaultRetryMs,
    'maxReconnects': maxReconnects,
    'showComments': showComments,
  };

  factory SseSettings.fromJson(Map<String, dynamic> j) => SseSettings(
    autoReconnect: jsonBool(j['autoReconnect'], true),
    defaultRetryMs: jsonInt(j['defaultRetryMs'], 3000).clamp(0, 3600000),
    maxReconnects: jsonInt(j['maxReconnects'], 0).clamp(0, 1000),
    showComments: jsonBool(j['showComments'], false),
  );
}

/// Everything an SSE connection needs, with variables already filled in.
class SseConfig {
  SseConfig({
    required this.url,
    this.method = 'GET',
    this.headers = const [],
    this.body = '',
    this.autoReconnect = true,
    this.defaultRetry = const Duration(seconds: 3),
    this.maxReconnects = 0,
    this.showComments = false,
    this.connectTimeout = const Duration(seconds: 30),
    this.clientFactory,
  });

  final Uri url;

  /// `GET`, or `POST` for APIs that stream a reply to a request body.
  final String method;
  final List<MapEntry<String, String>> headers;
  final String body;
  final bool autoReconnect;
  final Duration defaultRetry;
  final int maxReconnects;
  final bool showComments;
  final Duration connectTimeout;
  final ClientFactory? clientFactory;

  /// The config for request [r]. Throws `RequestBuildException` when the
  /// URL is unusable.
  factory SseConfig.fromRequest(
    RequestModel r,
    Map<String, String> vars, {
    ClientFactory? clientFactory,
  }) {
    final s = SseSettings.fromJson(r.protocolConfig);
    final method = r.method.toUpperCase() == 'POST' ? 'POST' : 'GET';
    return SseConfig(
      url: resolveUrl(
        r,
        vars,
        plain: 'http',
        secure: 'https',
        allowed: const {'http', 'https'},
        what: 'Server-Sent Events',
      ),
      method: method,
      headers: resolveHeaders(r, vars),
      body: method == 'POST' ? substituteVars(r.body, vars) : '',
      autoReconnect: s.autoReconnect,
      defaultRetry: Duration(milliseconds: s.defaultRetryMs),
      maxReconnects: s.maxReconnects,
      showComments: s.showComments,
      clientFactory: clientFactory,
    );
  }
}

/// A live `text/event-stream` connection that reconnects with
/// `Last-Event-ID`.
class SseConnection extends LiveConnection {
  SseConnection({super.logCapacity});

  HttpClient? _client;
  StreamSubscription<String>? _sub;
  Timer? _retryTimer;
  SseConfig? _config;
  bool _wanted = false;
  int _generation = 0;
  int _reconnects = 0;
  Duration? _serverRetry;

  /// The id of the last event received; sent as `Last-Event-ID` on reconnect.
  String? lastEventId;

  /// HTTP status of the latest response.
  int? statusCode;

  /// How long the next reconnect will wait.
  Duration get retry =>
      _serverRetry ?? _config?.defaultRetry ?? const Duration(seconds: 3);

  /// Starts streaming. Completes when the first response has started or
  /// failed; the stream itself keeps running.
  Future<void> start(SseConfig config) async {
    if (isClosed || state != LinkState.idle) return;
    _config = config;
    _wanted = true;
    _reconnects = 0;
    _serverRetry = null;
    lastEventId = null; // a fresh start; only reconnects resume
    await _open();
  }

  Future<void> _open() async {
    final config = _config!;
    final gen = ++_generation;
    final reconnecting = _reconnects > 0;
    setLinkState(
      reconnecting ? LinkState.reconnecting : LinkState.connecting,
      detail: reconnecting ? 'attempt $_reconnects' : '',
    );
    note(
      '${reconnecting ? 'Reconnecting' : 'Connecting'}: '
      '${config.method} ${config.url}',
      meta: {'Last-Event-ID': ?lastEventId},
    );
    final client = config.clientFactory?.call() ?? HttpClient();
    client.connectionTimeout = config.connectTimeout;
    _client = client;
    try {
      final request = await client.openUrl(config.method, config.url);
      request.followRedirects = true;
      request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      for (final h in config.headers) {
        request.headers.set(h.key, h.value, preserveHeaderCase: true);
      }
      final lastId = lastEventId;
      if (lastId != null && lastId.isNotEmpty) {
        request.headers.set('Last-Event-ID', lastId);
      }
      if (config.method == 'POST' && config.body.isNotEmpty) {
        if (request.headers.value(HttpHeaders.contentTypeHeader) == null) {
          request.headers.set(
            HttpHeaders.contentTypeHeader,
            _isJson(config.body)
                ? 'application/json'
                : 'text/plain; charset=utf-8',
          );
        }
        request.add(utf8.encode(config.body));
      }
      final response = await request.close();
      if (gen != _generation || !_wanted || isClosed) {
        client.close(force: true);
        return;
      }
      statusCode = response.statusCode;
      final type = response.headers.contentType;
      if (response.statusCode != 200) {
        final detail = await _readSnippet(response);
        note(
          'The server answered ${response.statusCode} '
          '${response.reasonPhrase}${detail.isEmpty ? '' : '\n$detail'}',
          error: true,
        );
        client.close(force: true);
        _client = null;
        // Per the SSE spec a non-200 answer is a failure, not a lost stream.
        _wanted = false;
        setLinkState(LinkState.idle);
        return;
      }
      _reconnects = 0;
      setLinkState(LinkState.connected);
      note(
        'Connected, streaming',
        meta: {
          'status': '${response.statusCode}',
          if (type != null) 'content-type': type.mimeType,
        },
      );
      if (type != null && type.mimeType != 'text/event-stream') {
        note(
          'The response is ${type.mimeType}, not text/event-stream. '
          'Events are parsed anyway.',
          error: true,
        );
      }
      final parser = SseParser(
        onComment: (c) {
          if (config.showComments) {
            log.add(Direction.received, label: 'comment', text: c);
          }
        },
        onRetry: (d) {
          _serverRetry = d;
        },
      )..lastEventId = lastEventId;
      _sub = response
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
            (chunk) {
              for (final e in parser.add(chunk)) {
                _onEvent(e);
              }
              lastEventId = parser.lastEventId ?? lastEventId;
            },
            onError: (Object e) {
              if (gen != _generation) return;
              note('Stream error: ${describeError(e)}', error: true);
              _ended(gen);
            },
            onDone: () {
              if (gen != _generation) return;
              note('The server ended the stream');
              _ended(gen);
            },
            cancelOnError: true,
          );
    } catch (e) {
      client.close(force: true);
      if (gen != _generation || isClosed) return;
      _client = null;
      note('Could not connect: ${describeError(e)}', error: true);
      _ended(gen);
    }
  }

  Future<String> _readSnippet(HttpClientResponse r) async {
    try {
      final text = await r
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(const Duration(seconds: 3));
      final t = text.trim();
      return t.length > 400 ? '${t.substring(0, 400)}…' : t;
    } catch (_) {
      return '';
    }
  }

  void _onEvent(SseEvent e) {
    final meta = <String, String>{
      'event': e.event,
      if (e.id != null) 'id': e.id!,
      if (e.retry != null) 'retry': '${e.retry} ms',
    };
    log.add(Direction.received, label: e.event, text: e.data, meta: meta);
  }

  /// The stream is over (ended, failed or never started); reconnect or stop.
  void _ended(int gen) {
    _sub?.cancel();
    _sub = null;
    _client?.close(force: true);
    _client = null;
    final config = _config!;
    if (!_wanted || !config.autoReconnect) {
      _wanted = false;
      setLinkState(LinkState.idle);
      return;
    }
    _reconnects++;
    if (config.maxReconnects > 0 && _reconnects > config.maxReconnects) {
      note('Gave up after ${config.maxReconnects} reconnects', error: true);
      _wanted = false;
      setLinkState(LinkState.idle);
      return;
    }
    final wait = retry;
    setLinkState(
      LinkState.reconnecting,
      detail: 'attempt $_reconnects in ${wait.inMilliseconds} ms',
    );
    note('Reconnecting in ${wait.inMilliseconds} ms');
    _retryTimer?.cancel();
    _retryTimer = Timer(wait, () {
      if (_wanted && !isClosed) _open();
    });
  }

  /// Stops the stream and any pending reconnect.
  void stop() {
    if (!_wanted && state == LinkState.idle) return;
    _wanted = false;
    _generation++;
    _retryTimer?.cancel();
    _sub?.cancel();
    _sub = null;
    _client?.close(force: true);
    _client = null;
    note('Stopped');
    setLinkState(LinkState.idle);
  }

  @override
  void close() {
    if (isClosed) return;
    _wanted = false;
    _generation++;
    _retryTimer?.cancel();
    _sub?.cancel();
    _client?.close(force: true);
    markClosed();
  }
}

bool _isJson(String text) {
  try {
    jsonDecode(text);
    return true;
  } on FormatException {
    return false;
  }
}
