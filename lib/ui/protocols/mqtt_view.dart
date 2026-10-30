import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../services/protocols/live_connection.dart';
import '../../services/protocols/mqtt_connection.dart';
import '../../services/request_builder.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../help_tip.dart';
import '../kv_editor.dart';
import 'protocol_widgets.dart';

final _tabMemory = Expando<int>('mqtt tab');

const _qosItems = {
  0: '0 · at most once',
  1: '1 · at least once',
  2: '2 · exactly once',
};

const _qosHelp =
    'Delivery guarantee. 0 sends once and does not check. 1 makes sure it '
    'arrives, possibly twice. 2 makes sure it arrives exactly once, with '
    'more messages exchanged.';

/// Connection settings and composer of a Mqtt tab (issue #25).
class MqttEditor extends StatefulWidget {
  const MqttEditor({super.key, required this.tab});

  final RequestTab tab;

  @override
  State<MqttEditor> createState() => _MqttEditorState();
}

class _MqttEditorState extends State<MqttEditor> {
  late final LiveSession<MqttConnection> _session;
  late final MqttSettings _s;

  RequestModel get req => widget.tab.request;
  MqttConnection get _conn => _session.connection;

  @override
  void initState() {
    super.initState();
    _session = sessionOf(widget.tab, MqttConnection.new);
    _s = MqttSettings.fromJson(req.protocolConfig);
  }

  void _save() {
    req.protocolConfig.addAll(_s.toJson());
    context.read<AppState>().touchActive();
  }

  void _touch() => context.read<AppState>().touchActive();

  Future<void> _connect() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final state = context.read<AppState>();
    final MqttConfig config;
    try {
      config = MqttConfig.fromRequest(
        req,
        state.varsFor(widget.tab.sourceCollectionId),
        verifySsl: verifySslFor(state, widget.tab),
        securityContext: securityContextFor(state.settings.network.caCertPath),
      );
    } on RequestBuildException catch (e) {
      reportProblem(context, _conn, e.message);
      return;
    } on FormatException catch (e) {
      reportProblem(context, _conn, e.message);
      return;
    }
    await _conn.connect(config);
  }

  /// Subscribes or unsubscribes [sub] on the open connection to match its
  /// switch.
  void _applySubscription(MqttSubscription sub) {
    if (!_conn.isConnected) return;
    final vars = context.read<AppState>().varsFor(
      widget.tab.sourceCollectionId,
    );
    final topic = substituteVars(sub.topic, vars).trim();
    try {
      if (sub.enabled) {
        _conn.subscribe(topic, sub.qos);
      } else {
        _conn.unsubscribe(topic);
      }
    } on FormatException catch (e) {
      reportProblem(context, _conn, '${e.message} ("$topic")');
    }
  }

  /// Changes the QoS of a live subscription by subscribing again.
  void _resubscribe(MqttSubscription sub) {
    if (!_conn.isConnected || !sub.enabled) return;
    final vars = context.read<AppState>().varsFor(
      widget.tab.sourceCollectionId,
    );
    final topic = substituteVars(sub.topic, vars).trim();
    if (!_conn.subscribedTopics.contains(topic)) return;
    _conn.unsubscribe(topic);
    _applySubscription(sub);
  }

  void _publish() {
    final vars = context.read<AppState>().varsFor(
      widget.tab.sourceCollectionId,
    );
    try {
      _conn.publish(
        substituteVars(_s.pubTopic, vars).trim(),
        buildPayload(_s.pubKind, substituteVars(_s.pubPayload, vars)),
        qos: _s.pubQos,
        retain: _s.pubRetain,
      );
    } on FormatException catch (e) {
      reportProblem(context, _conn, e.message);
    } on StateError {
      reportProblem(context, _conn, 'Connect first, then publish.');
    }
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppState>();
    final subs = _s.subscriptions.where((s) => s.enabled).length;
    final headers = req.headers.where((r) => r.enabled && r.key.isNotEmpty);
    return ProtocolEditorFrame(
      tab: widget.tab,
      memory: _tabMemory,
      urlBar: ProtocolUrlBar(
        tab: widget.tab,
        session: _session,
        hint: 'mqtt://broker.example.com:1883  —  {{vars}} allowed',
        urlTitle: 'Broker URL',
        urlHelp:
            'Where the MQTT broker is. mqtt:// or tcp:// is plain TCP '
            '(port 1883), mqtts:// or ssl:// is TLS (8883), ws:// and wss:// '
            'tunnel MQTT through a WebSocket. {{name}} inserts a variable.',
        urlExample: 'mqtts://broker.example.com:8883',
        connectLabel: 'Connect',
        connectHelp:
            'Connect to the broker with the client id, credentials and last '
            'will from the tabs below. Pressing Enter in the URL field does '
            'the same.',
        stopLabel: 'Disconnect',
        stopHelp: 'Send a clean disconnect to the broker.',
        onConnect: _connect,
        onStop: () => _conn.disconnect(),
      ),
      tabs: [
        ProtocolTabSpec(
          label: 'Connection',
          title: 'Connection',
          help:
              'Client id, credentials, keep-alive and session options sent '
              'to the broker when connecting.',
          example: 'client id: sensor-7',
          child: _ConnectionTab(settings: _s, onChanged: _save),
        ),
        ProtocolTabSpec(
          label: subs == 0 ? 'Subscribe' : 'Subscribe ($subs)',
          title: 'Subscriptions',
          help:
              'Topic filters to receive messages from. Switch one on or off '
              'at any time, also while connected.',
          example: 'sensors/+/temperature',
          child: _SubscribeTab(
            session: _session,
            settings: _s,
            onChanged: _save,
            onApply: _applySubscription,
            onQosChanged: _resubscribe,
          ),
        ),
        ProtocolTabSpec(
          label: 'Publish',
          title: 'Publish',
          help: 'Send a message to a topic, with a QoS level and retain flag.',
          example: 'home/light, on',
          child: _PublishTab(
            session: _session,
            settings: _s,
            onChanged: _save,
            onPublish: _publish,
          ),
        ),
        ProtocolTabSpec(
          label: _s.willEnabled ? 'Last will •' : 'Last will',
          title: 'Last will',
          help:
              'A message the broker publishes for you if this client '
              'disappears without disconnecting properly.',
          example: 'status/me → offline',
          child: _WillTab(settings: _s, onChanged: _save),
        ),
        ProtocolTabSpec(
          label: headers.isEmpty ? 'Headers' : 'Headers (${headers.length})',
          title: 'WebSocket headers',
          help:
              'HTTP headers for the upgrade request. Only used for ws:// and '
              'wss:// brokers; plain and TLS TCP connections have no '
              'headers.',
          example: 'Authorization: Bearer eyJhbGci…',
          child: KVEditor(
            rows: req.headers,
            onChanged: _touch,
            keyHint: 'Header',
            addLabel: 'Add header',
            keyHelp: 'The header name (WebSocket brokers only).',
            keyExample: 'Authorization',
            valueHelp:
                'The header value. {{variables}} are filled in when you '
                'connect.',
            valueExample: 'Bearer {{token}}',
          ),
        ),
      ],
    );
  }
}

class _ConnectionTab extends StatefulWidget {
  const _ConnectionTab({required this.settings, required this.onChanged});

  final MqttSettings settings;
  final VoidCallback onChanged;

  @override
  State<_ConnectionTab> createState() => _ConnectionTabState();
}

class _ConnectionTabState extends State<_ConnectionTab> {
  MqttSettings get s => widget.settings;

  void _change(VoidCallback fn) {
    setState(fn);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: tabPadding,
    children: [
      HelpField(
        label: 'Client ID',
        hint: 'Leave empty for a new random id each time',
        help:
            'The name this client gives the broker. Two clients with the '
            'same id push each other off, so keep it unique. Empty makes up '
            'a random id for every connection.',
        example: 'apiworkbench-3fa9c1d2',
        value: s.clientId,
        mono: true,
        trailing: HelpHover(
          'Fill in a new random client id.',
          title: 'Generate client ID',
          child: IconButton(
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.autorenew),
            onPressed: () => _change(() => s.clientId = randomClientId()),
          ),
        ),
        onChanged: (v) => _change(() => s.clientId = v),
      ),
      const SizedBox(height: 14),
      HelpField(
        label: 'Username',
        help:
            'The user name the broker checks. Leave empty if the broker '
            'allows anonymous clients. {{variables}} are filled in.',
        example: '{{mqttUser}}',
        value: s.username,
        onChanged: (v) => _change(() => s.username = v),
      ),
      const SizedBox(height: 14),
      HelpField(
        label: 'Password',
        help:
            'The password for that user. It is saved with the request, so a '
            '{{variable}} is the safer choice for real secrets.',
        example: '{{mqttPassword}}',
        value: s.password,
        obscure: true,
        onChanged: (v) => _change(() => s.password = v),
      ),
      const SizedBox(height: 14),
      SizedBox(
        width: 220,
        child: HelpField(
          label: 'Keep-alive (seconds)',
          help:
              'How often the client pings an idle connection so the broker '
              'knows it is still there. The broker drops a silent client '
              'after about 1.5 times this. 0 turns it off.',
          example: '60',
          number: true,
          value: '${s.keepAlive}',
          onChanged: (v) => _change(() {
            s.keepAlive = (int.tryParse(v) ?? 0).clamp(0, 65535);
          }),
        ),
      ),
      const Divider(height: 28),
      HelpSwitch(
        title: 'Clean session',
        subtitle: 'Start fresh: the broker forgets earlier subscriptions.',
        help:
            'On, the broker discards this client\'s old subscriptions and '
            'queued messages and starts clean. Off asks it to keep them '
            'between connections (it needs a fixed client id).',
        example: 'Off + QoS 1 subscriptions keeps messages while offline',
        value: s.cleanSession,
        onChanged: (v) => _change(() => s.cleanSession = v),
      ),
      HelpSwitch(
        title: 'Reconnect automatically',
        subtitle: 'Reconnect and subscribe again when the connection drops.',
        help:
            'If the connection is lost, keep trying to reconnect and '
            'subscribe to the same topics again. Disconnect stops it.',
        value: s.autoReconnect,
        onChanged: (v) => _change(() => s.autoReconnect = v),
      ),
      const SizedBox(height: 10),
      Text(
        'Speaks MQTT 3.1.1.',
        style: TextStyle(fontSize: 12, color: Palette.textDim),
      ),
    ],
  );
}

class _SubscribeTab extends StatefulWidget {
  const _SubscribeTab({
    required this.session,
    required this.settings,
    required this.onChanged,
    required this.onApply,
    required this.onQosChanged,
  });

  final LiveSession<MqttConnection> session;
  final MqttSettings settings;
  final VoidCallback onChanged;
  final void Function(MqttSubscription) onApply;
  final void Function(MqttSubscription) onQosChanged;

  @override
  State<_SubscribeTab> createState() => _SubscribeTabState();
}

class _SubscribeTabState extends State<_SubscribeTab> {
  MqttSettings get s => widget.settings;

  void _change(VoidCallback fn) {
    setState(fn);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final conn = widget.session.connection;
      return ListView(
        padding: tabPadding,
        children: [
          Text(
            conn.isConnected
                ? 'Switches subscribe and unsubscribe right away.'
                : 'Switched-on topics are subscribed when you connect.',
            style: TextStyle(fontSize: 12.5, color: Palette.textDim),
          ),
          const SizedBox(height: 10),
          for (final sub in s.subscriptions)
            _row(sub, conn, key: ObjectKey(sub)),
          Align(
            alignment: Alignment.centerLeft,
            child: HelpHover(
              'Add a topic filter to receive messages from.',
              title: 'Add subscription',
              example: 'home/#',
              child: TextButton.icon(
                onPressed: () =>
                    _change(() => s.subscriptions.add(MqttSubscription())),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add subscription'),
              ),
            ),
          ),
        ],
      );
    },
  );

  Widget _row(MqttSubscription sub, MqttConnection conn, {Key? key}) {
    final topic = sub.topic.trim();
    final live = conn.isConnected && conn.subscribedTopics.contains(topic);
    final count = conn.counts[topic] ?? 0;
    return Container(
      key: key,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
      decoration: BoxDecoration(
        border: Border.all(color: Palette.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              HelpHover(
                sub.enabled
                    ? 'Subscribed on connect, and now. Switch off to '
                          'unsubscribe.'
                    : 'Not subscribed. Switch on to subscribe.',
                title: sub.enabled ? 'Subscribed' : 'Off',
                child: Switch(
                  value: sub.enabled,
                  onChanged: (v) {
                    _change(() => sub.enabled = v);
                    widget.onApply(sub);
                  },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: HelpField(
                  label: 'Topic filter',
                  hint: 'home/+/temperature',
                  help:
                      'The topic to receive. + stands for one level and # '
                      'for everything below. {{variables}} are filled in.',
                  example: 'sensors/+/temp  or  home/#',
                  value: sub.topic,
                  mono: true,
                  onChanged: (v) => _change(() => sub.topic = v),
                ),
              ),
              HelpHover(
                'Remove this subscription.',
                title: 'Remove subscription',
                child: IconButton(
                  icon: Icon(Icons.close, size: 18, color: Palette.textDim),
                  onPressed: () {
                    if (sub.enabled) {
                      sub.enabled = false;
                      widget.onApply(sub);
                    }
                    _change(() => s.subscriptions.remove(sub));
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 210,
                  child: HelpDropdown<int>(
                    label: 'QoS',
                    help: _qosHelp,
                    example: '1',
                    value: sub.qos,
                    items: _qosItems,
                    onChanged: (v) {
                      _change(() => sub.qos = v);
                      widget.onQosChanged(sub);
                    },
                  ),
                ),
                HelpHover(
                  live
                      ? 'Subscribed on the broker. Messages received on this '
                            'filter since connecting: $count.'
                      : 'Not subscribed on the broker right now.',
                  title: live ? 'Active' : 'Not active',
                  child: Text(
                    live ? 'active · $count received' : 'not active',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: live ? Palette.success : Palette.textDim,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PublishTab extends StatefulWidget {
  const _PublishTab({
    required this.session,
    required this.settings,
    required this.onChanged,
    required this.onPublish,
  });

  final LiveSession<MqttConnection> session;
  final MqttSettings settings;
  final VoidCallback onChanged;
  final VoidCallback onPublish;

  @override
  State<_PublishTab> createState() => _PublishTabState();
}

class _PublishTabState extends State<_PublishTab> {
  MqttSettings get s => widget.settings;

  void _change(VoidCallback fn) {
    setState(fn);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final connected = widget.session.connection.isConnected;
      return ListView(
        padding: tabPadding,
        children: [
          HelpField(
            label: 'Topic',
            hint: 'home/livingroom/light',
            help:
                'The topic to publish to. Wildcards (+ and #) are not '
                'allowed here. {{variables}} are filled in.',
            example: 'home/livingroom/light',
            value: s.pubTopic,
            mono: true,
            onChanged: (v) => _change(() => s.pubTopic = v),
          ),
          const SizedBox(height: 12),
          PayloadKindPicker(
            value: s.pubKind,
            onChanged: (k) => _change(() => s.pubKind = k),
          ),
          const SizedBox(height: 12),
          HelpField(
            label: 'Payload',
            hint: s.pubKind == PayloadKind.binary
                ? 'Base64 bytes, for example SGVsbG8='
                : '{"state": "on"}',
            help:
                'The message body. {{variables}} are filled in. Binary '
                'payloads are written in base64.',
            example: s.pubKind == PayloadKind.binary
                ? 'SGVsbG8='
                : '{"state": "on"}',
            value: s.pubPayload,
            minLines: 3,
            maxLines: 10,
            mono: true,
            onChanged: (v) => _change(() => s.pubPayload = v),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 210,
                child: HelpDropdown<int>(
                  label: 'QoS',
                  help: _qosHelp,
                  example: '1',
                  value: s.pubQos,
                  items: _qosItems,
                  onChanged: (v) => _change(() => s.pubQos = v),
                ),
              ),
              SizedBox(
                width: 210,
                child: HelpSwitch(
                  title: 'Retain',
                  subtitle: 'Broker keeps it for new subscribers.',
                  help:
                      'The broker stores this message and hands it to every '
                      'client that subscribes later, until it is replaced. '
                      'Publish an empty payload with Retain to clear it.',
                  example: 'A device\'s last known state',
                  value: s.pubRetain,
                  onChanged: (v) => _change(() => s.pubRetain = v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: HelpHover(
              connected
                  ? 'Publish the payload to the topic now.'
                  : 'Connect first; messages can only be published while '
                        'connected.',
              title: 'Publish',
              child: FilledButton.icon(
                onPressed: connected ? widget.onPublish : null,
                icon: const Icon(Icons.send, size: 16),
                label: const Text('Publish'),
              ),
            ),
          ),
        ],
      );
    },
  );
}

class _WillTab extends StatefulWidget {
  const _WillTab({required this.settings, required this.onChanged});

  final MqttSettings settings;
  final VoidCallback onChanged;

  @override
  State<_WillTab> createState() => _WillTabState();
}

class _WillTabState extends State<_WillTab> {
  MqttSettings get s => widget.settings;

  void _change(VoidCallback fn) {
    setState(fn);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: tabPadding,
    children: [
      HelpSwitch(
        title: 'Send a last will',
        subtitle: 'The broker publishes it if this client vanishes.',
        help:
            'Register a message with the broker when connecting. If the '
            'connection dies without a clean disconnect, the broker '
            'publishes it for you, so others can see you went offline.',
        example: 'status/me → offline',
        value: s.willEnabled,
        onChanged: (v) => _change(() => s.willEnabled = v),
      ),
      if (s.willEnabled) ...[
        const SizedBox(height: 12),
        HelpField(
          label: 'Will topic',
          hint: 'status/me',
          help: 'The topic the will message is published to.',
          example: 'status/sensor-7',
          value: s.willTopic,
          mono: true,
          onChanged: (v) => _change(() => s.willTopic = v),
        ),
        const SizedBox(height: 14),
        HelpField(
          label: 'Will payload',
          hint: 'offline',
          help: 'The text of the will message.',
          example: 'offline',
          value: s.willPayload,
          minLines: 2,
          maxLines: 6,
          mono: true,
          onChanged: (v) => _change(() => s.willPayload = v),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 14,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 210,
              child: HelpDropdown<int>(
                label: 'Will QoS',
                help: _qosHelp,
                example: '1',
                value: s.willQos,
                items: _qosItems,
                onChanged: (v) => _change(() => s.willQos = v),
              ),
            ),
            SizedBox(
              width: 210,
              child: HelpSwitch(
                title: 'Retain will',
                subtitle: 'Keep it for new subscribers.',
                help:
                    'Publish the will as a retained message, so clients that '
                    'subscribe later still see it.',
                value: s.willRetain,
                onChanged: (v) => _change(() => s.willRetain = v),
              ),
            ),
          ],
        ),
      ],
    ],
  );
}

/// Live message log of a Mqtt tab.
class MqttMessages extends StatefulWidget {
  const MqttMessages({super.key, required this.tab});

  final RequestTab tab;

  @override
  State<MqttMessages> createState() => _MqttMessagesState();
}

class _MqttMessagesState extends State<MqttMessages> {
  late final LiveSession<MqttConnection> _session = sessionOf(
    widget.tab,
    MqttConnection.new,
  );

  @override
  Widget build(BuildContext context) => ProtocolLogPane(
    session: _session,
    emptyHint:
        'Connect, subscribe to a topic and publish. Each message is listed '
        'with its topic, QoS and retain flag.',
    extraStatus: ListenableBuilder(
      listenable: _session,
      builder: (context, _) {
        final conn = _session.connection;
        final id = conn.clientId;
        if (id == null || !conn.isActive) return const SizedBox.shrink();
        return HelpHover(
          'The client id this connection uses.',
          title: 'Client ID',
          example: 'apiworkbench-3fa9c1d2',
          child: Text(
            id,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              color: Palette.textDim,
            ),
          ),
        );
      },
    ),
  );
}
