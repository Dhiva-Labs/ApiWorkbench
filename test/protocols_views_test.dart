import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/protocols/mqtt_connection.dart';
import 'package:api_workbench/services/protocols/socketio_connection.dart';
import 'package:api_workbench/services/protocols/sse_connection.dart';
import 'package:api_workbench/services/protocols/live_connection.dart';
import 'package:api_workbench/services/protocols/websocket_connection.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/theme.dart';
import 'package:api_workbench/ui/protocols/protocol_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// Opens [request] in a tab of a fresh [AppState] and shows its editor and
/// message log side by side at [size], like the desktop layout.
Future<(AppState, RequestTab)> pump(
  WidgetTester tester,
  RequestModel request,
  Size size, {
  bool logOnly = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late Directory dir;
  await tester.runAsync(() async {
    dir = await Directory.systemTemp.createTemp('aw_proto_');
  });
  final state = AppState(storage: Storage(overrideDir: dir));
  state.newTab(request);
  final tab = state.activeTab!;
  addTearDown(() async {
    (tab.session as TabSession?)?.close();
    await tester.runAsync(() => dir.delete(recursive: true));
  });
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: logOnly
              ? ProtocolMessages(key: ValueKey('${tab.id}-log'), tab: tab)
              : ProtocolEditor(key: ValueKey(tab.id), tab: tab),
        ),
      ),
    ),
  );
  await tester.pump();
  return (state, tab);
}

void main() {
  group('saved with the request', () {
    test('every protocol keeps its settings through JSON', () {
      final configs = {
        RequestKind.websocket: WebSocketSettings(
          subprotocols: 'chat',
          pingSeconds: 10,
          autoReconnect: true,
          draft: 'hi',
          messages: [SavedMessage(name: 'a', body: 'b')],
        ).toJson(),
        RequestKind.socketio: SocketIoSettings(
          path: '/io',
          auth: '{"t":1}',
          catchAll: false,
          emitEvent: 'ev',
          listeners: [SocketListener(event: 'x', enabled: false)],
        ).toJson(),
        RequestKind.mqtt: MqttSettings(
          clientId: 'id',
          willEnabled: true,
          willTopic: 't',
          subscriptions: [MqttSubscription(topic: 'a/#', qos: 2)],
        ).toJson(),
        RequestKind.sse: SseSettings(defaultRetryMs: 99).toJson(),
      };
      for (final e in configs.entries) {
        final r = RequestModel(
          kind: e.key,
          url: 'x://y',
          protocolConfig: Map.of(e.value),
        );
        final back = RequestModel.fromJson(
          jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>,
        );
        expect(back.kind, e.key);
        expect(back.protocolConfig, e.value, reason: e.key.name);
        expect(r.clone().protocolConfig, e.value, reason: e.key.name);
      }
    });
  });

  final kinds = {
    RequestKind.websocket: ['Message', 'Params', 'Headers', 'Settings'],
    RequestKind.socketio: ['Emit', 'Listen', 'Handshake', 'Params', 'Headers'],
    RequestKind.mqtt: [
      'Connection',
      'Subscribe',
      'Publish',
      'Last will',
      'Headers',
    ],
    RequestKind.sse: ['Params', 'Headers', 'Body', 'Settings'],
  };
  final sizes = {
    '320x568': const Size(320, 568),
    '360x640': const Size(360, 640),
    '1280x800': const Size(1280, 800),
  };

  // Editors with plenty of saved content, long text and every optional
  // section switched on.
  final long = 'A fairly long value that has to wrap or be cut: ' * 4;
  final busy = <RequestKind, Map<String, dynamic>>{
    RequestKind.websocket: WebSocketSettings(
      subprotocols: long,
      pingSeconds: 30,
      autoReconnect: true,
      compose: PayloadKind.json,
      draft: '{"a": 1}\n' * 12,
      messages: [
        for (var i = 0; i < 4; i++)
          SavedMessage(name: 'Saved message number $i $long', body: long),
      ],
    ).toJson(),
    RequestKind.socketio: SocketIoSettings(
      auth: '{"token": "$long"}',
      catchAll: false,
      emitEvent: 'event $long',
      wantAck: true,
      listeners: [
        for (var i = 0; i < 4; i++)
          SocketListener(event: 'listener $i $long', enabled: i.isEven),
      ],
      args: [
        for (var i = 0; i < 3; i++)
          SocketArg(
            kind: i == 1 ? SocketArgKind.text : SocketArgKind.json,
            body: '{"n": $i}\n' * 5,
          ),
      ],
    ).toJson(),
    RequestKind.mqtt: MqttSettings(
      clientId: long,
      username: long,
      willEnabled: true,
      willTopic: long,
      willPayload: long,
      pubTopic: long,
      pubPayload: long,
      subscriptions: [
        for (var i = 0; i < 4; i++)
          MqttSubscription(topic: 'sensors/$i/$long', qos: i % 3),
      ],
    ).toJson(),
    RequestKind.sse: SseSettings(showComments: true).toJson(),
  };
  for (final kind in busy.keys) {
    for (final entry in sizes.entries) {
      testWidgets('${kind.label} editor with content fits at ${entry.key}', (
        tester,
      ) async {
        final req = newRequestOfKind(kind)
          ..method = kind == RequestKind.sse ? 'POST' : 'GET'
          ..body = long
          ..headers = [KV(key: 'X-Long-Header-Name-$long', value: long)]
          ..params = [KV(key: 'param-$long', value: long)]
          ..protocolConfig = Map.of(busy[kind]!);
        await pump(tester, req, entry.value);
        for (final label in kinds[kind]!) {
          final tabFinder = find.descendant(
            of: find.byType(TabBar),
            matching: find.textContaining(label),
          );
          await tester.ensureVisible(tabFinder.first);
          await tester.pumpAndSettle();
          await tester.tap(tabFinder.first);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'tab $label');
        }
      });
    }
  }

  for (final kind in kinds.keys) {
    for (final entry in sizes.entries) {
      testWidgets('${kind.label} editor fits at ${entry.key}', (tester) async {
        await pump(tester, newRequestOfKind(kind), entry.value);
        for (final label in kinds[kind]!) {
          final tabFinder = find.descendant(
            of: find.byType(TabBar),
            matching: find.textContaining(label),
          );
          expect(tabFinder, findsWidgets, reason: 'tab $label');
          await tester.ensureVisible(tabFinder.first);
          await tester.pumpAndSettle();
          await tester.tap(tabFinder.first);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'tab $label');
        }
      });

      testWidgets('${kind.label} log fits at ${entry.key}', (tester) async {
        final (_, tab) = await pump(
          tester,
          newRequestOfKind(kind),
          entry.value,
          logOnly: true,
        );
        expect(tab.session, isNotNull);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
