import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/services/grpc/grpc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';

const _echoProto = '''
syntax = "proto3";
package echo;

import "google/protobuf/timestamp.proto";

message EchoRequest {
  string text = 1;
  int32 times = 2;
}

message EchoReply {
  string text = 1;
  int32 index = 2;
  google.protobuf.Timestamp at = 3;
}

service Echo {
  rpc Say(EchoRequest) returns (EchoReply);
  rpc Repeat(EchoRequest) returns (stream EchoReply);
  rpc Collect(stream EchoRequest) returns (EchoReply);
  rpc Chat(stream EchoRequest) returns (stream EchoReply);
  rpc Fail(EchoRequest) returns (EchoReply);
  rpc Slow(EchoRequest) returns (EchoReply);
}
''';

List<int> _id(List<int> b) => b;

/// The echo service on raw bytes: requests and replies go through our
/// codec, as the server side of a schema it only knows dynamically.
class _EchoService extends Service {
  _EchoService(this.pool) {
    void add(
      String name,
      Function handler,
      bool clientStream,
      bool serverStream,
    ) => $addMethod(
      ServiceMethod<List<int>, List<int>>(
        name,
        handler,
        clientStream,
        serverStream,
        _id,
        _id,
      ),
    );
    add('Say', _say, false, false);
    add('Repeat', _repeat, false, true);
    add('Collect', _collect, true, false);
    add('Chat', _chat, true, true);
    add('Fail', _fail, false, false);
    add('Slow', _slow, false, false);
  }

  final DescriptorPool pool;
  late final ProtoJsonCodec codec = ProtoJsonCodec(pool);
  late final MessageDescriptor request = pool.findMessage('echo.EchoRequest')!;
  late final MessageDescriptor reply = pool.findMessage('echo.EchoReply')!;

  @override
  String get $name => 'echo.Echo';

  Map<String, Object?> _decode(List<int> bytes) =>
      codec.decode(request, bytes) as Map<String, Object?>;

  Future<List<int>> _say(ServiceCall call, Future<List<int>> req) async {
    final r = _decode(await req);
    call.headers!['x-echo'] = call.clientMetadata!['x-token'] ?? '-';
    call.trailers!['x-done'] = 'yes';
    return codec.encode(reply, {
      'text': 'hello ${r['text']}',
      'at': '2026-10-31T12:00:00Z',
    });
  }

  Stream<List<int>> _repeat(ServiceCall call, Future<List<int>> req) async* {
    final r = _decode(await req);
    final times = r['times'] as int? ?? 1;
    for (var i = 0; i < times; i++) {
      yield codec.encode(reply, {'text': r['text'], 'index': i});
    }
  }

  Future<List<int>> _collect(ServiceCall call, Stream<List<int>> reqs) async {
    final texts = [await for (final b in reqs) _decode(b)['text']];
    return codec.encode(reply, {
      'text': texts.join('+'),
      'index': texts.length,
    });
  }

  Stream<List<int>> _chat(ServiceCall call, Stream<List<int>> reqs) async* {
    var i = 0;
    await for (final b in reqs) {
      yield codec.encode(reply, {
        'text': 're: ${_decode(b)['text']}',
        'index': i++,
      });
    }
  }

  Future<List<int>> _fail(ServiceCall call, Future<List<int>> req) async {
    await req;
    throw const GrpcError.notFound('no such thing');
  }

  Future<List<int>> _slow(ServiceCall call, Future<List<int>> req) async {
    await req;
    await Future<void>.delayed(const Duration(seconds: 3));
    return codec.encode(reply, {});
  }
}

/// A reflection service built with our codec. It sends only the file that
/// defines a symbol, so the client must ask for imports by file name.
class _FakeReflection extends Service {
  _FakeReflection(this.version, Map<String, ProtoFile> files) : _files = files {
    final schema = buildPool({
      'r.proto': builtInProtos['grpc/reflection/$version/reflection.proto']!,
      'd.proto': builtInProtos['google/protobuf/descriptor.proto']!,
    });
    codec = ProtoJsonCodec(schema);
    requestType = schema.findMessage(
      'grpc.reflection.$version.ServerReflectionRequest',
    )!;
    responseType = schema.findMessage(
      'grpc.reflection.$version.ServerReflectionResponse',
    )!;
    fileType = schema.findMessage('google.protobuf.FileDescriptorProto')!;
    $addMethod(
      ServiceMethod<List<int>, List<int>>(
        'ServerReflectionInfo',
        _info,
        true,
        true,
        _id,
        _id,
      ),
    );
  }

  final String version;
  final Map<String, ProtoFile> _files;
  late final ProtoJsonCodec codec;
  late final MessageDescriptor requestType;
  late final MessageDescriptor responseType;
  late final MessageDescriptor fileType;
  final requests = <String>[];

  @override
  String get $name => 'grpc.reflection.$version.ServerReflection';

  String _descriptor(ProtoFile f) =>
      base64Encode(codec.encode(fileType, protoFileToDescriptor(f)));

  Stream<List<int>> _info(ServiceCall call, Stream<List<int>> reqs) async* {
    await for (final bytes in reqs) {
      final r = codec.decode(requestType, bytes, protoNames: true) as Map;
      Map<String, Object?> answer;
      if (r.containsKey('list_services')) {
        requests.add('list_services');
        answer = {
          'list_services_response': {
            'service': [
              {'name': 'echo.Echo'},
              {'name': 'grpc.reflection.$version.ServerReflection'},
            ],
          },
        };
      } else if (r['file_containing_symbol'] case final String symbol) {
        requests.add('symbol:$symbol');
        final file = _files.values.firstWhere(
          (f) => f.services.any((s) => s.fullName == symbol),
        );
        answer = {
          'file_descriptor_response': {
            'file_descriptor_proto': [_descriptor(file)],
          },
        };
      } else if (r['file_by_filename'] case final String name) {
        requests.add('file:$name');
        final file = _files[name];
        answer = file == null
            ? {
                'error_response': {
                  'error_code': 5,
                  'error_message': '$name not found',
                },
              }
            : {
                'file_descriptor_response': {
                  'file_descriptor_proto': [_descriptor(file)],
                },
              };
      } else {
        answer = {
          'error_response': {'error_code': 12, 'error_message': 'unsupported'},
        };
      }
      yield codec.encode(responseType, {'original_request': r, ...answer});
    }
  }
}

void main() {
  late DescriptorPool pool;
  late Server server;
  late GrpcConnection connection;
  late _FakeReflection reflection;

  setUpAll(() async {
    pool = buildPool({'echo.proto': _echoProto});
    reflection = _FakeReflection('v1', pool.files);
    server = Server.create(services: [_EchoService(pool), reflection]);
    await server.serve(address: InternetAddress.loopbackIPv4, port: 0);
    connection = GrpcConnection(
      GrpcTarget('127.0.0.1', server.port!),
      tls: false,
    );
  });

  tearDownAll(() async {
    await connection.close();
    await server.shutdown();
  });

  MethodDescriptor method(String name) => pool.findMethod('echo.Echo', name)!;

  GrpcInvocation start(
    String name,
    List<GrpcEvent> events, {
    Map<String, String> metadata = const {},
    Duration? deadline,
  }) => GrpcInvocation.start(
    connection: connection,
    method: method(name),
    codec: ProtoJsonCodec(pool),
    onEvent: events.add,
    metadata: metadata,
    deadline: deadline,
    emitDefaults: false,
  );

  test('unary call with metadata, headers and trailers', () async {
    final events = <GrpcEvent>[];
    final call = start('Say', events, metadata: {'x-token': 'abc'});
    call.send({'text': 'Ada'});
    call.end();
    final status = await call.done;
    expect(status.ok, isTrue);
    expect(events.map((e) => e.kind), [
      GrpcEventKind.sent,
      GrpcEventKind.headers,
      GrpcEventKind.received,
      GrpcEventKind.trailers,
      GrpcEventKind.status,
    ]);
    expect(events[1].body, contains('x-echo: abc'));
    expect(jsonDecode(events[2].body!), {
      'text': 'hello Ada',
      'at': '2026-10-31T12:00:00Z',
    });
    expect(events[3].body, 'x-done: yes');
    expect(events.last.title, 'Status 0 OK');
  });

  test('server streaming', () async {
    final events = <GrpcEvent>[];
    final call = start('Repeat', events);
    call.send({'text': 'hi', 'times': 3});
    call.end();
    await call.done;
    final received = events.where((e) => e.kind == GrpcEventKind.received);
    expect(received.map((e) => e.title), [
      'Received #1',
      'Received #2',
      'Received #3',
    ]);
    expect(received.map((e) => jsonDecode(e.body!)['index']), [null, 1, 2]);
    expect(call.receivedCount, 3);
  });

  test('client streaming', () async {
    final events = <GrpcEvent>[];
    final call = start('Collect', events);
    for (final t in ['a', 'b', 'c']) {
      call.send({'text': t});
    }
    expect(call.canSend, isTrue);
    call.end();
    expect(call.canSend, isFalse);
    final status = await call.done;
    expect(status.ok, isTrue);
    final reply = events.firstWhere((e) => e.kind == GrpcEventKind.received);
    expect(jsonDecode(reply.body!), {'text': 'a+b+c', 'index': 3});
    expect(events.map((e) => e.title), contains('Request stream ended'));
  });

  test('bidirectional streaming', () async {
    final events = <GrpcEvent>[];
    final got = StreamController<GrpcEvent>();
    final call = GrpcInvocation.start(
      connection: connection,
      method: method('Chat'),
      codec: ProtoJsonCodec(pool),
      onEvent: (e) {
        events.add(e);
        if (e.kind == GrpcEventKind.received) got.add(e);
      },
    );
    final replies = StreamIterator(got.stream);
    call.send({'text': 'one'});
    expect(await replies.moveNext(), isTrue);
    expect(jsonDecode(replies.current.body!)['text'], 're: one');
    call.send({'text': 'two'});
    expect(await replies.moveNext(), isTrue);
    // emitDefaults is on by default: index 1 shows, and so would 0.
    expect(jsonDecode(replies.current.body!), {'text': 're: two', 'index': 1});
    call.end();
    expect((await call.done).ok, isTrue);
    await replies.cancel();
  });

  test('error status, deadline and cancel', () async {
    final failed = start('Fail', []);
    failed.send({});
    failed.end();
    final status = await failed.done;
    expect(status.code, StatusCode.notFound);
    expect(status.name, 'NOT_FOUND');
    expect(status.message, 'no such thing');

    final slow = start('Slow', [], deadline: const Duration(milliseconds: 150));
    slow.send({});
    slow.end();
    expect((await slow.done).code, StatusCode.deadlineExceeded);

    final cancelled = start('Slow', []);
    cancelled.send({});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await cancelled.cancel();
    expect((await cancelled.done).code, StatusCode.cancelled);
  });

  test('a message that does not fit the schema is not sent', () async {
    final events = <GrpcEvent>[];
    final call = start('Say', events);
    expect(() => call.send({'txt': 'x'}), throwsA(isA<ProtoJsonException>()));
    expect(call.sentCount, 0);
    await call.cancel();
  });

  group('reflection', () {
    test('v1: lists services and fetches imports by file name', () async {
      final client = ReflectionClient(connection);
      final loaded = await client.load();
      expect(client.version, 'v1');
      expect(loaded.services.map((s) => s.fullName), ['echo.Echo']);
      final say = loaded.findMethod('echo.Echo', 'Say')!;
      expect(say.kind, CallKind.unary);
      expect(
        loaded.findMethod('echo.Echo', 'Chat')!.kind,
        CallKind.bidiStreaming,
      );
      expect(
        say.output.fieldByName('at')!.messageType!.fullName,
        'google.protobuf.Timestamp',
      );
      expect(reflection.requests, [
        'list_services',
        'symbol:echo.Echo',
        'file:google/protobuf/timestamp.proto',
      ]);

      // The reflected schema drives a real call.
      final events = <GrpcEvent>[];
      final call = GrpcInvocation.start(
        connection: connection,
        method: say,
        codec: ProtoJsonCodec(loaded),
        onEvent: events.add,
      );
      call.send(exampleJson(say.input));
      call.end();
      expect((await call.done).ok, isTrue);
      final reply = events.firstWhere((e) => e.kind == GrpcEventKind.received);
      expect(jsonDecode(reply.body!)['text'], 'hello text');
    });

    test('falls back to v1alpha, and reports servers without it', () async {
      final alpha = Server.create(
        services: [_EchoService(pool), _FakeReflection('v1alpha', pool.files)],
      );
      await alpha.serve(address: InternetAddress.loopbackIPv4, port: 0);
      final bare = Server.create(services: [_EchoService(pool)]);
      await bare.serve(address: InternetAddress.loopbackIPv4, port: 0);
      final a = GrpcConnection(
        GrpcTarget('127.0.0.1', alpha.port!),
        tls: false,
      );
      final b = GrpcConnection(GrpcTarget('127.0.0.1', bare.port!), tls: false);
      try {
        final client = ReflectionClient(a);
        final loaded = await client.load();
        expect(client.version, 'v1alpha');
        expect(loaded.findService('echo.Echo'), isNotNull);

        await expectLater(
          ReflectionClient(b).load(),
          throwsA(
            isA<GrpcError>()
                .having((e) => e.code, 'code', StatusCode.unimplemented)
                .having(
                  (e) => e.message,
                  'message',
                  contains('does not support reflection'),
                ),
          ),
        );
      } finally {
        await a.close();
        await b.close();
        await alpha.shutdown();
        await bare.shutdown();
      }
    });
  });

  test('an unreachable server ends with UNAVAILABLE', () async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    final c = GrpcConnection(
      GrpcTarget('127.0.0.1', port),
      tls: false,
      connectTimeout: const Duration(seconds: 2),
    );
    final events = <GrpcEvent>[];
    final call = GrpcInvocation.start(
      connection: c,
      method: method('Say'),
      codec: ProtoJsonCodec(pool),
      onEvent: events.add,
      deadline: const Duration(seconds: 5),
    );
    call.send({'text': 'x'});
    call.end();
    expect((await call.done).code, StatusCode.unavailable);
    await c.close();
  });

  test('target parsing', () {
    GrpcTarget t(String s, {bool tls = false}) =>
        GrpcTarget.parse(s, tlsDefault: tls);
    expect(t('localhost:50051').toString(), 'localhost:50051');
    expect(t('localhost:50051').tls, isNull);
    expect(t('grpcs://api.example.com').port, 443);
    expect(t('grpcs://api.example.com').tls, isTrue);
    expect(t('http://h:8080/x').tls, isFalse);
    expect(t('h').port, 80);
    expect(t('h', tls: true).port, 443);
    expect(t('[::1]:9000').host, '::1');
    expect(t('[::1]:9000').toString(), '[::1]:9000');
    expect(
      () => t('localhost:99999'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          '"99999" is not a valid port (1 to 65535).',
        ),
      ),
    );
    expect(() => t(' '), throwsFormatException);
    expect(() => t('ftp://x:1'), throwsFormatException);
  });
}
