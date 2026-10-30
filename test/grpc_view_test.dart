import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/grpc/grpc.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/theme.dart';
import 'package:api_workbench/ui/home_screen.dart';
import 'package:api_workbench/ui/protocols/grpc_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:provider/provider.dart';

const _proto = '''
syntax = "proto3";
package demo;

message HelloRequest {
  string name = 1;
  repeated string tags = 2;
  map<string, int64> scores = 3;
}

message HelloReply { string message = 1; }

service Greeter {
  rpc SayHello(HelloRequest) returns (HelloReply);
  rpc Chat(stream HelloRequest) returns (stream HelloReply);
}
''';

List<int> _id(List<int> b) => b;

class _Greeter extends Service {
  _Greeter(DescriptorPool pool)
    : codec = ProtoJsonCodec(pool),
      request = pool.findMessage('demo.HelloRequest')!,
      reply = pool.findMessage('demo.HelloReply')! {
    $addMethod(
      ServiceMethod<List<int>, List<int>>(
        'SayHello',
        _say,
        false,
        false,
        _id,
        _id,
      ),
    );
  }

  final ProtoJsonCodec codec;
  final MessageDescriptor request;
  final MessageDescriptor reply;

  @override
  String get $name => 'demo.Greeter';

  Future<List<int>> _say(ServiceCall call, Future<List<int>> req) async {
    final r = codec.decode(request, await req) as Map;
    return codec.encode(reply, {
      'message': 'Hi ${r['name']} (${call.clientMetadata!['x-user']})',
    });
  }
}

RequestModel _grpcRequest(String url) => RequestModel(
  kind: RequestKind.grpc,
  name: 'Greeter',
  url: url,
  protocolConfig: GrpcConfig(
    source: GrpcSchemaSource.protoFiles,
    protoText: _proto,
    service: 'demo.Greeter',
    method: 'SayHello',
    message: '{"name": "{{who}}"}',
    metadata: [KV(key: 'X-User', value: '{{who}}')],
  ).toJson(),
);

void main() {
  test('config round-trips through protocolConfig as JSON', () {
    final cfg = GrpcConfig(
      service: 's',
      method: 'm',
      source: GrpcSchemaSource.protoFiles,
      protoPaths: ['/a.proto'],
      importPaths: ['/inc'],
      protoText: 'syntax = "proto3";',
      metadata: [KV(key: 'k', value: 'v', enabled: false)],
      message: '{"a": 1}',
      tls: true,
      verify: false,
      deadlineMs: 2500,
      emitDefaults: false,
    );
    final r = RequestModel(kind: RequestKind.grpc);
    cfg.saveTo(r);
    final back = GrpcConfig.of(RequestModel.fromJson(r.clone().toJson()));
    expect(back.toJson(), cfg.toJson());
    expect(back.metadata.single.enabled, isFalse);
    expect(GrpcConfig.of(RequestModel()).source, GrpcSchemaSource.reflection);
  });

  test('the tab session invokes, substitutes variables and closes', () async {
    final pool = buildPool({'demo.proto': _proto});
    final server = Server.create(services: [_Greeter(pool)]);
    await server.serve(address: InternetAddress.loopbackIPv4, port: 0);
    final session = GrpcTabSession();
    try {
      final req = _grpcRequest('{{host}}');
      final cfg = GrpcConfig.of(req);
      final vars = {'host': '127.0.0.1:${server.port}', 'who': 'Ada'};
      await session.invoke(req, cfg, vars);
      final status = await session.call!.done;
      expect(status.ok, isTrue);
      expect(session.status?.ok, isTrue);
      final received = session.events.firstWhere(
        (e) => e.kind == GrpcEventKind.received,
      );
      expect(received.body, contains('Hi Ada (Ada)'));
      expect(
        session.events.map((e) => e.title),
        containsAllInOrder(['Unary call', 'Request metadata', 'Sent']),
      );

      // A message that does not fit stops before anything is sent.
      cfg.message = '{"nme": "x"}';
      await session.invoke(req, cfg, vars);
      expect(session.call, isNull);
      expect(session.events.last.kind, GrpcEventKind.error);
      expect(session.events.last.body, contains('Unknown field "nme"'));
    } finally {
      session.close();
      await server.shutdown();
    }
  });

  for (final width in [320.0, 390.0, 1100.0]) {
    testWidgets('the gRPC tab fits a $width pixel viewport', (tester) async {
      tester.view.physicalSize = Size(width, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late Directory dir;
      late AppState state;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('grpc_view_test');
        state = AppState(storage: Storage(overrideDir: dir));
        while (!state.loaded) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      state.newTab(_grpcRequest('localhost:50051'));
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(theme: buildTheme(), home: const HomeScreen()),
        ),
      );
      // The pasted definition loads right after the first frame, without
      // touching the network.
      await tester.pump();
      await tester.pumpAndSettle();
      final session = GrpcTabSession.of(state.activeTab!);
      expect(session.schemaError, isNull);
      expect(session.pool, isNotNull);
      expect(tester.takeException(), isNull);
      expect(find.text('Invoke'), findsOneWidget);
      expect(find.text('Use reflection'), findsOneWidget);
      expect(find.text('demo.Greeter'), findsOneWidget);
      expect(find.textContaining('SayHello'), findsOneWidget);

      await tester.tap(find.text('Generate example message'));
      await tester.pumpAndSettle();
      final cfg = GrpcConfig.of(state.activeTab!.request);
      expect(cfg.message, contains('"tags": ['));
      expect(cfg.message, contains('"scores": {'));

      for (final tab in ['Metadata (1)', 'Proto', 'Settings', 'Message']) {
        final label = find.descendant(
          of: find.byType(TabBar),
          matching: find.text(tab),
        );
        await tester.ensureVisible(label);
        await tester.pumpAndSettle();
        await tester.tap(label);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: tab);
      }

      // The method picker lists both methods with their call kind.
      await tester.tap(find.textContaining('SayHello'));
      await tester.pumpAndSettle();
      expect(find.text('Chat'), findsOneWidget);
      expect(find.textContaining('Bidirectional streaming'), findsOneWidget);
      await tester.tap(find.text('Chat'));
      await tester.pumpAndSettle();
      expect(GrpcConfig.of(state.activeTab!.request).method, 'Chat');
      expect(find.textContaining('Invoke opens the stream'), findsOneWidget);
      expect(tester.takeException(), isNull);

      if (width < 600) {
        await tester.tap(find.text('Response'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Invoke a method'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } else {
        expect(find.textContaining('Invoke a method'), findsOneWidget);
      }

      await tester.pumpWidget(const SizedBox());
      state.dispose();
      await tester.runAsync(() => dir.delete(recursive: true));
    });
  }
}
