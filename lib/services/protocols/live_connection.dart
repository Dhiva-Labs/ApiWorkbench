import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../models/models.dart';
import '../request_builder.dart';
import 'message_log.dart';

export 'message_log.dart';

/// Where a connection stands.
enum LinkState {
  /// Not connected and not trying to be.
  idle,

  /// The first connection attempt is in progress.
  connecting,

  /// Open and ready.
  connected,

  /// Lost and waiting to try again, or trying again.
  reconnecting,
}

/// Creates the HTTP client a transport should use, so it follows the app's
/// proxy and TLS settings.
typedef ClientFactory = HttpClient Function();

/// Base of every live protocol connection: a [state], a [log] of what
/// happened, and change notifications for the UI.
abstract class LiveConnection with ChangeSignal {
  LiveConnection({int logCapacity = 2000})
    : log = MessageLog(capacity: logCapacity) {
    log.addListener(notify);
  }

  /// Everything sent, received and noted on this connection.
  final MessageLog log;

  LinkState _state = LinkState.idle;
  String _detail = '';
  bool _closed = false;

  LinkState get state => _state;

  /// Extra words for the status, such as "attempt 2, retrying in 4 s".
  String get detail => _detail;

  bool get isConnected => _state == LinkState.connected;

  /// True while connecting, connected or waiting to reconnect.
  bool get isActive => _state != LinkState.idle;

  /// True once [close] ran; nothing more is reported afterwards.
  bool get isClosed => _closed;

  /// Ends the connection for good, when its tab closes. Safe to call twice.
  void close();

  /// Moves to [next] and tells listeners.
  void setLinkState(LinkState next, {String detail = ''}) {
    if (_closed) return;
    _state = next;
    _detail = detail;
    notify();
  }

  /// Marks the connection finished: no further notifications.
  void markClosed() => _closed = true;

  @override
  void notify() {
    if (_closed) return;
    super.notify();
  }

  /// Adds a system entry (connected, closed, error).
  LogEntry note(String text, {bool error = false, Map<String, String>? meta}) {
    if (_closed) return LogEntry(seq: 0, direction: Direction.system);
    return log.add(
      Direction.system,
      label: error ? 'error' : '',
      text: text,
      meta: meta,
      isError: error,
    );
  }
}

/// What a message body is.
enum PayloadKind { text, json, binary }

extension PayloadKindLabel on PayloadKind {
  String get label => switch (this) {
    PayloadKind.text => 'Text',
    PayloadKind.json => 'JSON',
    PayloadKind.binary => 'Binary (base64)',
  };
}

/// A named message kept with the request.
class SavedMessage {
  SavedMessage({this.name = '', this.kind = PayloadKind.text, this.body = ''});

  String name;
  PayloadKind kind;
  String body;

  Map<String, dynamic> toJson() => {
    'name': name,
    'kind': kind.name,
    'body': body,
  };

  factory SavedMessage.fromJson(Map<String, dynamic> j) => SavedMessage(
    name: jsonString(j['name']),
    kind: PayloadKind.values.asNameMap()[j['kind']] ?? PayloadKind.text,
    body: jsonString(j['body']),
  );

  SavedMessage clone() => SavedMessage(name: name, kind: kind, body: body);
}

/// A body ready to send: text, or bytes for a binary message.
class Payload {
  const Payload.text(String this.text) : bytes = null;
  const Payload.binary(Uint8List this.bytes) : text = null;

  final String? text;
  final Uint8List? bytes;

  bool get isBinary => bytes != null;
}

/// Turns what the user typed into a [Payload]. JSON is checked but sent as
/// typed; binary is decoded from base64. Throws a [FormatException] whose
/// message is fit to show.
Payload buildPayload(PayloadKind kind, String body) {
  switch (kind) {
    case PayloadKind.text:
      return Payload.text(body);
    case PayloadKind.json:
      try {
        jsonDecode(body);
      } on FormatException catch (e) {
        throw FormatException('The message is not valid JSON: ${e.message}');
      }
      return Payload.text(body);
    case PayloadKind.binary:
      return Payload.binary(decodeBase64Input(body));
  }
}

/// Decodes base64 typed by hand: whitespace, missing padding, a leading
/// `base64:` and the URL-safe alphabet are all accepted.
Uint8List decodeBase64Input(String input) {
  var s = input.trim();
  if (s.toLowerCase().startsWith('base64:')) s = s.substring(7);
  s = s
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll('-', '+')
      .replaceAll('_', '/');
  s = s.replaceAll(RegExp(r'=+$'), '');
  if (RegExp(r'[^A-Za-z0-9+/]').hasMatch(s)) {
    throw const FormatException(
      'The binary message is not valid base64 (use letters, digits, + and /).',
    );
  }
  if (s.length % 4 == 1) {
    throw const FormatException('The base64 text has an impossible length.');
  }
  s = s.padRight((s.length + 3) ~/ 4 * 4, '=');
  return base64.decode(s);
}

/// Reads a JSON value as a string, or [fallback].
String jsonString(Object? v, [String fallback = '']) =>
    v is String ? v : fallback;

/// Reads a JSON value as an int, or [fallback].
int jsonInt(Object? v, int fallback) =>
    v is num ? v.toInt() : (v is String ? int.tryParse(v) : null) ?? fallback;

/// Reads a JSON value as a bool, or [fallback].
bool jsonBool(Object? v, bool fallback) => v is bool ? v : fallback;

/// Reads a JSON value as a list of maps, skipping anything else.
List<Map<String, dynamic>> jsonMaps(Object? v) => [
  if (v is List)
    for (final e in v)
      if (e is Map) Map<String, dynamic>.from(e),
];

/// The enabled header rows of [r] with variables filled in, in order and
/// with repeated names kept.
List<MapEntry<String, String>> resolveHeaders(
  RequestModel r,
  Map<String, String> vars,
) => [
  for (final h in r.headers)
    if (h.enabled && h.key.trim().isNotEmpty)
      MapEntry(
        substituteVars(h.key.trim(), vars),
        substituteVars(h.value, vars),
      ),
];

/// Header rows as the map dart:io expects: repeated names become one entry
/// holding a list.
Map<String, Object> headerMap(Iterable<MapEntry<String, String>> rows) {
  final out = <String, Object>{};
  for (final e in rows) {
    final existing = out[e.key];
    if (existing == null) {
      out[e.key] = e.value;
    } else if (existing is List<String>) {
      existing.add(e.value);
    } else {
      out[e.key] = [existing as String, e.value];
    }
  }
  return out;
}

/// [raw] with a scheme: when it has none, `plain` for this machine and
/// private networks and `secure` for everything else.
String ensureScheme(
  String raw, {
  required String plain,
  required String secure,
}) {
  final t = raw.trim();
  if (t.contains('://')) return t;
  final host = t.startsWith('[')
      ? t.split(']').first
      : t.split(RegExp(r'[/:?#]')).first.toLowerCase();
  final local =
      host == 'localhost' ||
      host == '[::1' ||
      host.endsWith('.local') ||
      host.startsWith('127.') ||
      host.startsWith('192.168.') ||
      host.startsWith('10.');
  return '${local ? plain : secure}://$t';
}

/// The URL of [r] with variables, path variables and params applied, using
/// [scheme] rules: `http`/`https` are mapped through [map] and any other
/// scheme not in [allowed] is rejected.
Uri resolveUrl(
  RequestModel r,
  Map<String, String> vars, {
  required String plain,
  required String secure,
  required Set<String> allowed,
  Map<String, String> map = const {},
  required String what,
}) {
  final raw = ensureScheme(
    substituteVars(r.url.trim(), vars),
    plain: plain,
    secure: secure,
  );
  final probe = RequestModel(
    url: raw,
    params: r.params,
    pathVariables: r.pathVariables,
  );
  final uri = buildUrl(probe, vars);
  var scheme = uri.scheme.toLowerCase();
  scheme = map[scheme] ?? scheme;
  if (!allowed.contains(scheme)) {
    throw RequestBuildException(
      '$what URLs start with ${allowed.map((s) => '$s://').join(', ')} '
      '(found ${uri.scheme}://).',
    );
  }
  return uri.replace(scheme: scheme);
}

/// A random client id such as `apiworkbench-3fa9c1d2`.
String randomClientId([Random? random]) {
  final r = random ?? Random.secure();
  final hex = List.generate(8, (_) => r.nextInt(16).toRadixString(16)).join();
  return 'apiworkbench-$hex';
}

/// How long to wait before reconnect attempt number [attempt] (from 1): the
/// delay doubles each time, from [base] up to [max].
Duration reconnectDelay(int attempt, Duration base, Duration max) {
  final shift = (attempt - 1).clamp(0, 20);
  final ms = base.inMilliseconds * (1 << shift);
  return Duration(milliseconds: min(ms, max.inMilliseconds));
}

/// Wraps a thrown error as a short message for the log.
String describeError(Object e) {
  if (e is SocketException) {
    final os = e.osError?.message;
    return os == null || os.isEmpty
        ? e.message
        : '${e.message.isEmpty ? 'Socket error' : e.message}: $os';
  }
  if (e is WebSocketException) return e.message;
  if (e is HandshakeException) return 'TLS handshake failed: ${e.message}';
  if (e is HttpException) return e.message;
  final s = e.toString();
  return s.startsWith('Exception: ') ? s.substring(11) : s;
}
