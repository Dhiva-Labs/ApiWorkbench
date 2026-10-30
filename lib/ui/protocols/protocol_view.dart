import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../state/app_state.dart';
import 'grpc_view.dart';
import 'mqtt_view.dart';
import 'socketio_view.dart';
import 'sse_view.dart';
import 'websocket_view.dart';

/// Upper pane of a non-HTTP tab: connection settings and composer.
class ProtocolEditor extends StatelessWidget {
  const ProtocolEditor({super.key, required this.tab});

  final RequestTab tab;

  @override
  Widget build(BuildContext context) => switch (tab.request.kind) {
    RequestKind.websocket => WebSocketEditor(tab: tab),
    RequestKind.socketio => SocketIoEditor(tab: tab),
    RequestKind.mqtt => MqttEditor(tab: tab),
    RequestKind.sse => SseEditor(tab: tab),
    RequestKind.grpc => GrpcEditor(tab: tab),
    RequestKind.http => const SizedBox.shrink(),
  };
}

/// Lower pane of a non-HTTP tab: the live message log.
class ProtocolMessages extends StatelessWidget {
  const ProtocolMessages({super.key, required this.tab});

  final RequestTab tab;

  @override
  Widget build(BuildContext context) => switch (tab.request.kind) {
    RequestKind.websocket => WebSocketMessages(tab: tab),
    RequestKind.socketio => SocketIoMessages(tab: tab),
    RequestKind.mqtt => MqttMessages(tab: tab),
    RequestKind.sse => SseMessages(tab: tab),
    RequestKind.grpc => GrpcMessages(tab: tab),
    RequestKind.http => const SizedBox.shrink(),
  };
}

/// A new, unsaved request of [kind] with a sensible starting point.
RequestModel newRequestOfKind(RequestKind kind) => switch (kind) {
  RequestKind.http => RequestModel(),
  RequestKind.websocket => RequestModel(
    kind: kind,
    name: 'New WebSocket',
    url: 'wss://',
  ),
  RequestKind.socketio => RequestModel(
    kind: kind,
    name: 'New Socket.IO',
    url: 'http://localhost:3000',
  ),
  RequestKind.mqtt => RequestModel(
    kind: kind,
    name: 'New MQTT',
    url: 'mqtt://localhost:1883',
  ),
  RequestKind.sse => RequestModel(kind: kind, name: 'New SSE', url: 'https://'),
  RequestKind.grpc => RequestModel(
    kind: kind,
    name: 'New gRPC',
    url: 'localhost:50051',
  ),
};
