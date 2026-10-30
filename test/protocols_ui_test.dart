import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/protocols/live_connection.dart';
import 'package:api_workbench/services/protocols/mqtt_connection.dart';
import 'package:api_workbench/services/protocols/socketio_connection.dart';
import 'package:api_workbench/services/protocols/sse_connection.dart';
import 'package:api_workbench/services/protocols/websocket_connection.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/theme.dart';
import 'package:api_workbench/ui/protocols/protocol_view.dart';
import 'package:api_workbench/ui/protocols/protocol_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'protocols_support.dart';

/// The editor above the log, like the desktop layout.
Future<(AppState, RequestTab)> pumpPair(
  WidgetTester tester,
  RequestModel request, {
  Size size = const Size(1100, 1000),
  String? collection,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late Directory dir;
  await tester.runAsync(() async {
    dir = await Directory.systemTemp.createTemp('aw_proto_ui_');
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
          body: Column(
            children: [
              Expanded(
                flex: 3,
                child: ProtocolEditor(key: ValueKey(tab.id), tab: tab),
              ),
              Divider(height: 1, color: Palette.border),
              Expanded(
                flex: 2,
                child: ProtocolMessages(
                  key: ValueKey('${tab.id}-log'),
                  tab: tab,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return (state, tab);
}

/// Lets real I/O happen until [done] holds.
Future<void> until(
  WidgetTester tester,
  bool Function() done, {
  String? reason,
}) async {
  for (var i = 0; i < 200; i++) {
    if (done()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  fail(reason ?? 'condition not met in time');
}

Finder field(String label) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == label,
);

/// Log text, not the text fields that may hold the same characters.
Finder logText(String text) =>
    find.byWidgetPredicate((w) => w is Text && w.data == text);

Finder button(String label) => find.ancestor(
  of: find.text(label),
  matching: find.bySubtype<ButtonStyleButton>(),
);

/// Closes the tab's connection and lets the timers it started run out.
Future<void> finish(WidgetTester tester, RequestTab tab) async {
  (tab.session as TabSession?)?.close();
  await tester.pump(const Duration(minutes: 2));
}

Future<void> openTab(WidgetTester tester, String label) async {
  final t = find.descendant(
    of: find.byType(TabBar),
    matching: find.textContaining(label),
  );
  await tester.ensureVisible(t.first);
  await tester.tap(t.first);
  await tester.pumpAndSettle();
}

void main() {
  // The widget test binding answers every HttpClient request with a mock 400;
  // these tests talk to real local servers.
  setUp(() => HttpOverrides.global = null);

  group('WebSocket tab', () {
    late HttpServer server;
    final closedByClient = <int?>[];

    setUp(() async {
      closedByClient.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final ws = await WebSocketTransformer.upgrade(req);
        ws.listen(ws.add, onDone: () => closedByClient.add(ws.closeCode));
      });
    });
    tearDown(() => server.close(force: true));

    testWidgets('connects, sends JSON, shows it indented and saves settings', (
      tester,
    ) async {
      final req = RequestModel(
        kind: RequestKind.websocket,
        url: 'ws://127.0.0.1:${server.port}/{{path}}',
      );
      final (state, tab) = await pumpPair(tester, req);
      state.sessionVars['path'] = 'echo';
      final session = tab.session as LiveSession<WebSocketConnection>;

      // Send is off until connected.
      expect(
        tester.widget<ButtonStyleButton>(button('Send')).onPressed,
        isNull,
      );
      await tester.tap(button('Connect'));
      await until(tester, () => session.connection.isConnected);
      expect(find.text('Connected'), findsWidgets);
      expect(button('Disconnect'), findsOneWidget);

      await tester.tap(find.text('JSON'));
      await tester.pump();
      await tester.enterText(field('Message'), '{"hello":"world","n":[1,2]}');
      await tester.pump();
      expect(req.protocolConfig['draft'], '{"hello":"world","n":[1,2]}');
      expect(req.protocolConfig['compose'], 'json');
      expect(tab.dirty, isTrue);

      await tester.tap(button('Send'));
      await until(
        tester,
        () =>
            session.connection.log.entries
                .where((e) => e.label == 'text')
                .length >=
            2,
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(logText('{"hello":"world","n":[1,2]}'), findsNWidgets(2));

      // Open the received message.
      await tester.tap(logText('{"hello":"world","n":[1,2]}').first);
      await tester.pump();
      expect(find.textContaining('  "hello": "world",'), findsOneWidget);

      // Search and clear.
      await tester.enterText(
        find.widgetWithText(TextField, 'Search messages'),
        'zzz',
      );
      await tester.pump();
      expect(find.textContaining('No messages match'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Search messages'),
        '',
      );
      await tester.pump();

      // Disconnect.
      await tester.tap(button('Disconnect'));
      await until(tester, () => session.connection.state == LinkState.idle);
      await tester.pump(const Duration(milliseconds: 200));
      expect(closedByClient, [1000]);

      await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
      await tester.pump();
      expect(session.connection.log.isEmpty, isTrue);
      await finish(tester, tab);
    });

    testWidgets('saved messages keep their name and can be sent', (
      tester,
    ) async {
      final req = RequestModel(
        kind: RequestKind.websocket,
        url: 'ws://127.0.0.1:${server.port}/',
      );
      final (_, tab) = await pumpPair(tester, req);
      final session = tab.session as LiveSession<WebSocketConnection>;

      await tester.enterText(field('Message'), 'ping please');
      await tester.pump();
      await tester.tap(button('Save message'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Ping');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('Ping'), findsOneWidget);
      final saved = req.protocolConfig['messages'] as List;
      expect((saved.single as Map)['name'], 'Ping');
      expect((saved.single as Map)['body'], 'ping please');

      await tester.tap(button('Connect'));
      await until(tester, () => session.connection.isConnected);
      await tester.tap(find.byIcon(Icons.send).last); // the saved row's Send
      await until(
        tester,
        () => session.connection.log.entries.any(
          (e) => e.direction == Direction.received,
        ),
      );
      expect(
        session.connection.log.entries
            .where((e) => e.label == 'text')
            .map((e) => e.text),
        ['ping please', 'ping please'],
      );
      await finish(tester, tab);
    });

    testWidgets('a bad URL and bad base64 are reported, not thrown', (
      tester,
    ) async {
      final req = RequestModel(kind: RequestKind.websocket, url: 'ftp://nope');
      final (_, tab) = await pumpPair(tester, req);
      final session = tab.session as LiveSession<WebSocketConnection>;
      await tester.tap(button('Connect'));
      await tester.pump();
      expect(find.textContaining('WebSocket URLs start with'), findsWidgets);
      expect(session.connection.state, LinkState.idle);
      expect(session.connection.log.entries.last.isError, isTrue);
      await finish(tester, tab);
    });

    testWidgets('closing the tab closes the connection', (tester) async {
      final req = RequestModel(
        kind: RequestKind.websocket,
        url: 'ws://127.0.0.1:${server.port}/',
      );
      final (state, tab) = await pumpPair(tester, req);
      final session = tab.session as LiveSession<WebSocketConnection>;
      await tester.tap(button('Connect'));
      await until(tester, () => session.connection.isConnected);
      state.closeTab(0);
      expect(session.isClosed, isTrue);
      expect(session.connection.isClosed, isTrue);
      await until(tester, () => closedByClient.isNotEmpty);
      // dart:io waits up to 5 s for the server's close frame.
      await tester.pump(const Duration(seconds: 6));
    });
  });

  group('SSE tab', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final res = req.response;
        res.headers.contentType = ContentType('text', 'event-stream');
        res.bufferOutput = false;
        res.write('id: 5\nevent: price\ndata: {"sym":"ACME","px":12.5}\n\n');
        await res.flush();
        await Future<void>.delayed(const Duration(seconds: 30));
      });
    });
    tearDown(() => server.close(force: true));

    testWidgets('starts a stream, shows the event and stops', (tester) async {
      final req = RequestModel(
        kind: RequestKind.sse,
        url: 'http://127.0.0.1:${server.port}/events',
      );
      final (_, tab) = await pumpPair(tester, req);
      final session = tab.session as LiveSession<SseConnection>;
      expect(find.text('Stopped'), findsWidgets);
      await tester.tap(button('Start'));
      await until(
        tester,
        () => session.connection.log.entries.any((e) => e.label == 'price'),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('price'), findsOneWidget);
      expect(find.text('id 5'), findsOneWidget);
      expect(find.textContaining('last id 5'), findsOneWidget);
      await tester.tap(button('Stop'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(session.connection.state, LinkState.idle);
      expect(find.text('Stopped'), findsWidgets);
      await finish(tester, tab);
    });

    testWidgets('POST shows the body tab and keeps the method', (tester) async {
      final req = RequestModel(
        kind: RequestKind.sse,
        url: 'http://127.0.0.1:${server.port}/events',
      );
      final (_, tab) = await pumpPair(tester, req);
      await openTab(tester, 'Body');
      expect(find.text('Use POST'), findsOneWidget);
      await tester.tap(find.text('Use POST'));
      await tester.pumpAndSettle();
      expect(req.method, 'POST');
      expect(find.text('Use POST'), findsNothing);
      await tester.enterText(field('Body'), '{"stream":true}');
      await tester.pump();
      expect(req.body, '{"stream":true}');
      await finish(tester, tab);
    });
  });

  group('Socket.IO tab', () {
    late MockSocketIoServer server;
    setUp(() async => server = await MockSocketIoServer.start());
    tearDown(() => server.close());

    testWidgets('connects with auth, emits with an ack and listens', (
      tester,
    ) async {
      final req = RequestModel(
        kind: RequestKind.socketio,
        url: 'http://127.0.0.1:${server.port}',
        protocolConfig: {
          'auth': '{"token":"t-1"}',
          'emitEvent': 'save',
          'wantAck': true,
          'args': [
            {'kind': 'json', 'body': '{"id":5}'},
            {'kind': 'text', 'body': 'note'},
          ],
        },
      );
      final (_, tab) = await pumpPair(tester, req);
      final session = tab.session as LiveSession<SocketIoConnection>;
      await tester.tap(button('Connect'));
      await until(tester, () => session.connection.isConnected);
      expect(server.connects.single.auth, {'token': 't-1'});

      await tester.tap(button('Emit'));
      await until(
        tester,
        () => session.connection.log.entries.any((e) => e.label == 'ack'),
      );
      expect(server.events.single.event, 'save');
      expect(server.events.single.args, [
        {'id': 5},
        'note',
      ]);
      await tester.pump(const Duration(milliseconds: 200));
      expect(logText('save'), findsNWidgets(2)); // the emit and its ack
      expect(
        find.text('ack #0'),
        findsNWidgets(2),
      ); // on the emit and the reply

      // Turn the catch-all off and listen to one event only.
      await openTab(tester, 'Listen');
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(req.protocolConfig['catchAll'], false);
      await tester.tap(find.text('Add listener'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Event name'), 'news');
      await tester.pump();
      server.emit('other', ['x']);
      server.emit('news', ['y']);
      await until(
        tester,
        () => session.connection.log.entries.any((e) => e.title == 'news'),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        session.connection.log.entries.any((e) => e.title == 'other'),
        isFalse,
      );
      await finish(tester, tab);
    });

    testWidgets('a bad argument is reported', (tester) async {
      final req = RequestModel(
        kind: RequestKind.socketio,
        url: 'http://127.0.0.1:${server.port}',
        protocolConfig: {
          'emitEvent': 'x',
          'args': [
            {'kind': 'json', 'body': '{nope'},
          ],
        },
      );
      final (_, tab) = await pumpPair(tester, req);
      final session = tab.session as LiveSession<SocketIoConnection>;
      await tester.tap(button('Connect'));
      await until(tester, () => session.connection.isConnected);
      await tester.tap(button('Emit'));
      await tester.pump();
      expect(find.textContaining('Argument 1 is not valid JSON'), findsWidgets);
      expect(server.events, isEmpty);
      await finish(tester, tab);
    });
  });

  group('MQTT tab', () {
    late MockMqttBroker broker;
    setUp(() async => broker = await MockMqttBroker.start());
    tearDown(() => broker.close());

    testWidgets('connects, subscribes, publishes and shows QoS and retain', (
      tester,
    ) async {
      final req = RequestModel(
        kind: RequestKind.mqtt,
        url: 'mqtt://127.0.0.1:${broker.tcpPort}',
        protocolConfig: {
          'clientId': 'ui-test',
          'username': 'me',
          'password': 'pw',
          'pubTopic': 'home/light',
          'pubPayload': '{"state":"on"}',
          'pubKind': 'json',
          'pubQos': 1,
          'pubRetain': true,
          'subscriptions': [
            {'topic': 'home/#', 'qos': 1, 'enabled': true},
          ],
        },
      );
      final (_, tab) = await pumpPair(tester, req);
      final session = tab.session as LiveSession<MqttConnection>;
      await tester.tap(button('Connect'));
      await until(tester, () => session.connection.isConnected);
      expect(broker.connects.single.clientId, 'ui-test');
      expect(broker.connects.single.user, 'me');
      await until(tester, () => broker.subscribed.isNotEmpty);

      await openTab(tester, 'Publish');
      await tester.tap(button('Publish'));
      await until(
        tester,
        () => session.connection.log.entries.any(
          (e) => e.direction == Direction.received,
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(broker.published.single.topic, 'home/light');
      expect(broker.published.single.qos, 1);
      expect(broker.published.single.retain, isTrue);
      expect(logText('home/light'), findsNWidgets(2));
      expect(
        find.text('QoS 1'),
        findsNWidgets(3),
      ); // subscribe note, sent, received
      expect(find.text('retain true'), findsOneWidget); // the one we sent
      expect(find.text('retain false'), findsOneWidget); // as delivered

      // Switch the subscription off while connected.
      await openTab(tester, 'Subscribe');
      await tester.tap(find.byType(Switch).first);
      await until(tester, () => broker.unsubscribed.isNotEmpty);
      expect(broker.unsubscribed.single, 'home/#');
      expect(
        (req.protocolConfig['subscriptions'] as List).single['enabled'],
        false,
      );
      await finish(tester, tab);
    });

    testWidgets('Generate fills in a client id', (tester) async {
      final req = RequestModel(
        kind: RequestKind.mqtt,
        url: 'mqtt://127.0.0.1:${broker.tcpPort}',
      );
      await pumpPair(tester, req);
      expect(req.protocolConfig['clientId'], isNull);
      await tester.tap(find.byIcon(Icons.autorenew));
      await tester.pump();
      expect(req.protocolConfig['clientId'], startsWith('apiworkbench-'));
      expect(
        tester.widget<TextField>(field('Client ID')).controller!.text,
        req.protocolConfig['clientId'],
      );
    });

    testWidgets('a bad publish topic is reported', (tester) async {
      final req = RequestModel(
        kind: RequestKind.mqtt,
        url: 'mqtt://127.0.0.1:${broker.tcpPort}',
        protocolConfig: {'pubTopic': 'a/#', 'pubPayload': 'x'},
      );
      final (_, tab) = await pumpPair(tester, req);
      final session = tab.session as LiveSession<MqttConnection>;
      await tester.tap(button('Connect'));
      await until(tester, () => session.connection.isConnected);
      await openTab(tester, 'Publish');
      await tester.tap(button('Publish'));
      await tester.pump();
      expect(find.textContaining('cannot contain the wildcards'), findsWidgets);
      expect(broker.published, isEmpty);
      await finish(tester, tab);
    });
  });

  testWidgets('settings survive reopening the editor', (tester) async {
    final req = RequestModel(kind: RequestKind.websocket, url: 'ws://x.test');
    final (state, tab) = await pumpPair(tester, req);
    await openTab(tester, 'Settings');
    await tester.enterText(field('Subprotocols'), 'chat, v2');
    await tester.enterText(field('Ping interval (seconds)'), '25');
    await tester.pump();
    expect(req.protocolConfig['subprotocols'], 'chat, v2');
    expect(req.protocolConfig['pingSeconds'], 25);

    // Saved with the request, and read back by a fresh editor.
    final copy = req.clone(sameId: true);
    expect(jsonEncode(copy.toJson()), contains('"pingSeconds":25'));
    final fresh = WebSocketSettings.fromJson(copy.protocolConfig);
    expect(fresh.protocolList, ['chat', 'v2']);
    expect(fresh.pingSeconds, 25);
    expect(state.activeTab, tab);
  });
}
