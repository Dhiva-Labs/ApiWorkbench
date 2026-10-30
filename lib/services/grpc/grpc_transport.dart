/// gRPC calls on raw bytes with `package:grpc`, so any method of a
/// dynamically loaded schema can be called: unary, server streaming,
/// client streaming and bidirectional streaming.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:grpc/grpc.dart';

import 'descriptors.dart';
import 'proto_json.dart';
import 'wire.dart';

/// `host:port` of a server, from what the user typed.
class GrpcTarget {
  const GrpcTarget(this.host, this.port, {this.tls});

  final String host;
  final int port;

  /// TLS implied by a scheme (`grpcs://`, `https://` → on; `http://` →
  /// off); null when the address has none.
  final bool? tls;

  /// Parses `localhost:50051`, `grpcs://api.example.com`, `[::1]:8443` and
  /// similar. Without a port, TLS addresses use 443 and others 80.
  ///
  /// Throws [FormatException] with a readable message.
  static GrpcTarget parse(String address, {bool tlsDefault = false}) {
    var a = address.trim();
    if (a.isEmpty) {
      throw const FormatException(
        'Enter the server address, such as localhost:50051.',
      );
    }
    bool? tls;
    final scheme = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*)://').firstMatch(a);
    if (scheme != null) {
      tls = switch (scheme.group(1)!.toLowerCase()) {
        'grpcs' || 'https' => true,
        'http' => false,
        'grpc' => null,
        final s => throw FormatException(
          'Unsupported scheme "$s://". Use host:port, grpc:// or grpcs://.',
        ),
      };
      a = a.substring(scheme.end);
    }
    final slash = a.indexOf('/');
    if (slash >= 0) a = a.substring(0, slash);
    String host;
    String? portText;
    if (a.startsWith('[')) {
      final close = a.indexOf(']');
      if (close < 0) {
        throw FormatException('"$address" has an unclosed IPv6 "[".');
      }
      host = a.substring(1, close);
      final rest = a.substring(close + 1);
      if (rest.startsWith(':')) portText = rest.substring(1);
    } else {
      final colon = a.lastIndexOf(':');
      if (colon >= 0 && a.indexOf(':') == colon) {
        host = a.substring(0, colon);
        portText = a.substring(colon + 1);
      } else {
        host = a;
      }
    }
    if (host.isEmpty) throw FormatException('"$address" has no host name.');
    final useTls = tls ?? tlsDefault;
    var port = useTls ? 443 : 80;
    if (portText != null && portText.isNotEmpty) {
      final p = int.tryParse(portText);
      if (p == null || p < 1 || p > 65535) {
        throw FormatException('"$portText" is not a valid port (1 to 65535).');
      }
      port = p;
    }
    return GrpcTarget(host, port, tls: tls);
  }

  @override
  String toString() => host.contains(':') ? '[$host]:$port' : '$host:$port';
}

List<int> _identity(List<int> b) => b;

/// One HTTP/2 channel to a server.
class GrpcConnection {
  GrpcConnection(
    this.target, {
    required this.tls,
    this.verify = true,
    Duration connectTimeout = const Duration(seconds: 15),
  }) : channel = ClientChannel(
         target.host,
         port: target.port,
         options: ChannelOptions(
           credentials: tls
               ? ChannelCredentials.secure(
                   onBadCertificate: verify ? null : allowBadCertificates,
                 )
               : const ChannelCredentials.insecure(),
           connectTimeout: connectTimeout,
           idleTimeout: const Duration(minutes: 5),
         ),
       );

  final GrpcTarget target;
  final bool tls;
  final bool verify;
  final ClientChannel channel;

  /// Whether this connection was made for the same server and settings.
  bool matches(GrpcTarget t, {required bool tls, required bool verify}) =>
      t.host == target.host &&
      t.port == target.port &&
      tls == this.tls &&
      verify == this.verify;

  /// Starts a call to [path] (`/pkg.Service/Method`). Messages are sent
  /// with [RawGrpcCall.send] until [RawGrpcCall.closeSend].
  RawGrpcCall call(
    String path, {
    Map<String, String> metadata = const {},
    Duration? timeout,
  }) => RawGrpcCall._(
    channel,
    path,
    CallOptions(metadata: metadata, timeout: timeout),
  );

  /// Closes the channel; calls in flight are cancelled.
  Future<void> close() => channel.terminate();
}

/// A call whose messages are already-encoded protobuf bytes.
class RawGrpcCall {
  RawGrpcCall._(ClientChannel channel, String path, CallOptions options) {
    _call = channel.createCall(
      ClientMethod<List<int>, List<int>>(path, _identity, _identity),
      _requests.stream,
      options,
    );
  }

  final _requests = StreamController<List<int>>();
  late final ClientCall<List<int>, List<int>> _call;

  /// Response messages; ends with a [GrpcError] unless the status is OK.
  Stream<List<int>> get responses => _call.response;
  Future<Map<String, String>> get headers => _call.headers;
  Future<Map<String, String>> get trailers => _call.trailers;

  bool get canSend => !_requests.isClosed;

  void send(List<int> message) {
    if (_requests.isClosed) {
      throw StateError('The request stream is already closed.');
    }
    _requests.add(message);
  }

  /// Half-closes the call: the server sees the end of the request stream.
  void closeSend() {
    if (!_requests.isClosed) unawaited(_requests.close());
  }

  Future<void> cancel() {
    closeSend();
    return _call.cancel();
  }
}

/// Names of the gRPC status codes, by number.
const grpcStatusNames = [
  'OK',
  'CANCELLED',
  'UNKNOWN',
  'INVALID_ARGUMENT',
  'DEADLINE_EXCEEDED',
  'NOT_FOUND',
  'ALREADY_EXISTS',
  'PERMISSION_DENIED',
  'RESOURCE_EXHAUSTED',
  'FAILED_PRECONDITION',
  'ABORTED',
  'OUT_OF_RANGE',
  'UNIMPLEMENTED',
  'INTERNAL',
  'UNAVAILABLE',
  'DATA_LOSS',
  'UNAUTHENTICATED',
];

/// The status a call ended with.
class GrpcStatus {
  const GrpcStatus(this.code, [this.message = '']);

  final int code;
  final String message;

  bool get ok => code == 0;
  String get name => code >= 0 && code < grpcStatusNames.length
      ? grpcStatusNames[code]
      : 'CODE_$code';

  @override
  String toString() =>
      message.isEmpty ? '$code $name' : '$code $name: $message';
}

enum GrpcEventKind { info, sent, received, headers, trailers, status, error }

/// One entry of a call's timeline.
class GrpcEvent {
  GrpcEvent(
    this.kind,
    this.title, {
    this.body,
    this.size,
    this.status,
    required this.elapsed,
    DateTime? at,
  }) : at = at ?? DateTime.now();

  final GrpcEventKind kind;
  final String title;

  /// Indented JSON of a message, or `key: value` lines of metadata.
  final String? body;

  /// Encoded size of a message, in bytes.
  final int? size;
  final GrpcStatus? status;

  /// Time since the call started.
  final Duration elapsed;
  final DateTime at;
}

const _pretty = JsonEncoder.withIndent('  ');

String _metadataText(Map<String, String> m) =>
    m.entries.map((e) => '${e.key}: ${e.value}').join('\n');

/// A running call of [method]: encodes JSON requests, decodes responses
/// and reports everything to [onEvent] in order.
class GrpcInvocation {
  GrpcInvocation._(
    this.method,
    this._codec,
    this._raw,
    this._onEvent,
    this.emitDefaults,
  );

  /// Starts [method] on [connection]. Nothing is sent until [send].
  factory GrpcInvocation.start({
    required GrpcConnection connection,
    required MethodDescriptor method,
    required ProtoJsonCodec codec,
    required void Function(GrpcEvent event) onEvent,
    Map<String, String> metadata = const {},
    Duration? deadline,
    bool emitDefaults = true,
  }) {
    final raw = connection.call(
      method.path,
      metadata: metadata,
      timeout: deadline,
    );
    return GrpcInvocation._(method, codec, raw, onEvent, emitDefaults)
      .._listen();
  }

  final MethodDescriptor method;
  final ProtoJsonCodec _codec;
  final RawGrpcCall _raw;
  final void Function(GrpcEvent) _onEvent;

  /// Include default-valued fields in decoded responses.
  final bool emitDefaults;
  final Stopwatch _clock = Stopwatch()..start();
  final Completer<GrpcStatus> _done = Completer<GrpcStatus>();
  int _sent = 0;
  int _received = 0;
  Map<String, String>? _headers;

  /// Completes with the final status; never with an error.
  Future<GrpcStatus> get done => _done.future;
  bool get finished => _done.isCompleted;

  /// Whether more request messages can be sent.
  bool get canSend => !finished && _raw.canSend;
  int get sentCount => _sent;
  int get receivedCount => _received;

  void _emit(
    GrpcEventKind kind,
    String title, {
    String? body,
    int? size,
    GrpcStatus? status,
  }) => _onEvent(
    GrpcEvent(
      kind,
      title,
      body: body,
      size: size,
      status: status,
      elapsed: _clock.elapsed,
    ),
  );

  static const _statusKeys = {'grpc-status', 'grpc-message'};

  Map<String, String> _visible(Map<String, String> m) => {
    for (final e in m.entries)
      if (!_statusKeys.contains(e.key) && !e.key.startsWith(':'))
        e.key: e.value,
  };

  void _listen() {
    _raw.headers.then((h) {
      if (finished && h.isEmpty) return;
      _headers = h;
      final shown = _visible(h);
      if (shown.isNotEmpty) {
        _emit(
          GrpcEventKind.headers,
          'Response headers',
          body: _metadataText(shown),
        );
      }
    }, onError: (_) {});
    _raw.responses.listen(
      (bytes) {
        _received++;
        try {
          final json = _codec.decode(
            method.output,
            bytes,
            emitDefaults: emitDefaults,
          );
          _emit(
            GrpcEventKind.received,
            method.serverStreaming ? 'Received #$_received' : 'Received',
            body: _pretty.convert(json),
            size: bytes.length,
          );
        } on ProtoDecodeException catch (e) {
          _emit(
            GrpcEventKind.error,
            'Could not decode response #$_received',
            body: '$e\n\nRaw bytes (base64): ${base64Encode(bytes)}',
            size: bytes.length,
          );
        }
      },
      onError: (Object e) => _finish(
        e is GrpcError
            ? GrpcStatus(e.code, e.message ?? '')
            : GrpcStatus(2, '$e'),
        e is GrpcError ? e.trailers : null,
      ),
      onDone: () => _finish(const GrpcStatus(0), null),
      cancelOnError: true,
    );
  }

  Future<void> _finish(
    GrpcStatus status,
    Map<String, String>? fromError,
  ) async {
    if (finished) return;
    Map<String, String> trailers = fromError ?? const {};
    if (trailers.isEmpty) {
      try {
        trailers = await _raw.trailers.timeout(const Duration(seconds: 1));
      } catch (_) {}
    }
    if (finished) return;
    final shown = _visible(trailers);
    // A trailers-only response repeats its headers as trailers.
    final repeat = _headers != null && _sameMap(_visible(_headers!), shown);
    if (shown.isNotEmpty && !repeat) {
      _emit(GrpcEventKind.trailers, 'Trailers', body: _metadataText(shown));
    }
    _raw.closeSend();
    _emit(
      GrpcEventKind.status,
      'Status ${status.code} ${status.name}',
      body: status.message.isEmpty ? null : status.message,
      status: status,
    );
    _clock.stop();
    _done.complete(status);
  }

  static bool _sameMap(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  /// Encodes [json] and sends it. Throws [ProtoJsonException] when it
  /// does not fit the request type, or [StateError] once sending ended.
  Uint8List send(Object? json) {
    if (!canSend) throw StateError('This call no longer accepts messages.');
    final bytes = _codec.encode(method.input, json);
    _raw.send(bytes);
    _sent++;
    _emit(
      GrpcEventKind.sent,
      method.clientStreaming ? 'Sent #$_sent' : 'Sent',
      body: _pretty.convert(json),
      size: bytes.length,
    );
    return bytes;
  }

  /// Ends the request stream (client and bidirectional streaming).
  void end() {
    if (!_raw.canSend || finished) return;
    _raw.closeSend();
    if (method.clientStreaming) {
      _emit(GrpcEventKind.info, 'Request stream ended');
    }
  }

  Future<void> cancel() async {
    if (finished) return;
    await _raw.cancel();
  }
}
