import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../services/protocols/socketio_connection.dart';
import '../../services/request_builder.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../help_tip.dart';
import '../kv_editor.dart';
import '../request/params_tab.dart';
import 'protocol_widgets.dart';

final _tabMemory = Expando<int>('socket.io tab');

/// Connection settings and composer of a SocketIo tab (issue #24).
class SocketIoEditor extends StatefulWidget {
  const SocketIoEditor({super.key, required this.tab});

  final RequestTab tab;

  @override
  State<SocketIoEditor> createState() => _SocketIoEditorState();
}

class _SocketIoEditorState extends State<SocketIoEditor> {
  late final LiveSession<SocketIoConnection> _session;
  late final SocketIoSettings _s;

  RequestModel get req => widget.tab.request;
  SocketIoConnection get _conn => _session.connection;

  @override
  void initState() {
    super.initState();
    _session = sessionOf(widget.tab, SocketIoConnection.new);
    _s = SocketIoSettings.fromJson(req.protocolConfig);
  }

  void _save() {
    req.protocolConfig.addAll(_s.toJson());
    context.read<AppState>().touchActive();
  }

  void _touch() => context.read<AppState>().touchActive();

  /// Applies the listener list to the open connection.
  void _applyListening() => _conn.setListening(
    catchAll: _s.catchAll,
    events: {
      for (final l in _s.listeners)
        if (l.enabled && l.event.trim().isNotEmpty) l.event.trim(),
    },
  );

  Future<void> _connect() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final state = context.read<AppState>();
    final SocketIoConfig config;
    try {
      config = SocketIoConfig.fromRequest(
        req,
        state.varsFor(widget.tab.sourceCollectionId),
        clientFactory: clientFactoryFor(state, widget.tab),
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

  void _emit() {
    final vars = context.read<AppState>().varsFor(
      widget.tab.sourceCollectionId,
    );
    try {
      _conn.emit(
        substituteVars(_s.emitEvent, vars),
        parseEmitArgs(_s.args, vars),
        ack: _s.wantAck,
      );
    } on FormatException catch (e) {
      reportProblem(context, _conn, e.message);
    } on StateError {
      reportProblem(context, _conn, 'Connect first, then emit an event.');
    }
  }

  String _counted(String label, List<KV> rows) {
    final n = rows.where((r) => r.enabled && r.key.isNotEmpty).length;
    return n == 0 ? label : '$label ($n)';
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppState>();
    final listening = _s.listeners.where((l) => l.enabled).length;
    return ProtocolEditorFrame(
      tab: widget.tab,
      memory: _tabMemory,
      urlBar: ProtocolUrlBar(
        tab: widget.tab,
        session: _session,
        hint: 'http://localhost:3000  —  add /namespace for a namespace',
        urlTitle: 'Socket.IO server',
        urlHelp:
            'The server address, with http(s):// or ws(s)://. A path after '
            'the host is the namespace, not the handshake path (that is in '
            'Handshake). {{name}} inserts a variable.',
        urlExample: 'https://chat.example.com/admin',
        connectLabel: 'Connect',
        connectHelp:
            'Open the Socket.IO connection. Auth, params and headers are '
            'sent with the handshake. Pressing Enter in the URL field does '
            'the same.',
        stopLabel: 'Disconnect',
        stopHelp: 'Close the Socket.IO connection and stop reconnecting.',
        onConnect: _connect,
        onStop: () => _conn.disconnect(),
      ),
      tabs: [
        ProtocolTabSpec(
          label: 'Emit',
          title: 'Emit an event',
          help:
              'Send a named event with one or more arguments, and optionally '
              'ask the server to acknowledge it.',
          example: 'chat message, {"text": "hi"}',
          child: _EmitTab(
            session: _session,
            settings: _s,
            onChanged: _save,
            onEmit: _emit,
          ),
        ),
        ProtocolTabSpec(
          label: listening == 0 && !_s.catchAll
              ? 'Listen'
              : _s.catchAll
              ? 'Listen • all'
              : 'Listen ($listening)',
          title: 'Event listeners',
          help:
              'Choose which incoming events are shown in the log. Switch '
              'them on or off at any time, also while connected.',
          example: 'news, chat message',
          child: _ListenTab(
            settings: _s,
            onChanged: () {
              _save();
              _applyListening();
            },
          ),
        ),
        ProtocolTabSpec(
          label: 'Handshake',
          title: 'Handshake',
          help:
              'The handshake path, the transports to use, the auth payload '
              'the server checks, and reconnecting.',
          example: '/socket.io',
          child: _HandshakeTab(settings: _s, onChanged: _save),
        ),
        ProtocolTabSpec(
          label: _counted('Params', req.params),
          title: 'Query parameters',
          help:
              'Name and value pairs added to the handshake URL as its query '
              'string. Unticked rows are kept but not sent.',
          example: '?room=blue',
          child: ParamsTab(request: req, onChanged: _touch),
        ),
        ProtocolTabSpec(
          label: _counted('Headers', req.headers),
          title: 'Headers',
          help:
              'Extra HTTP headers sent with the handshake, such as a token '
              'or cookie. Unticked rows are kept but not sent.',
          example: 'Authorization: Bearer eyJhbGci…',
          child: KVEditor(
            rows: req.headers,
            onChanged: _touch,
            keyHint: 'Header',
            addLabel: 'Add header',
            keyHelp: 'The header name.',
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

class _EmitTab extends StatefulWidget {
  const _EmitTab({
    required this.session,
    required this.settings,
    required this.onChanged,
    required this.onEmit,
  });

  final LiveSession<SocketIoConnection> session;
  final SocketIoSettings settings;
  final VoidCallback onChanged;
  final VoidCallback onEmit;

  @override
  State<_EmitTab> createState() => _EmitTabState();
}

class _EmitTabState extends State<_EmitTab> {
  SocketIoSettings get s => widget.settings;

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
            label: 'Event name',
            hint: 'chat message',
            help:
                'The name of the event to emit. The server has a handler for '
                'this name. Names such as connect and disconnect are reserved.',
            example: 'chat message',
            value: s.emitEvent,
            onChanged: (v) => _change(() => s.emitEvent = v),
          ),
          const SizedBox(height: 14),
          const SectionTitle(
            'Arguments',
            help:
                'The values sent with the event, in order. JSON arguments '
                'are parsed (text needs double quotes); Text arguments are '
                'sent as plain strings. Empty JSON rows send nothing.',
            example: '{"room": "a"}',
          ),
          for (var i = 0; i < s.args.length; i++)
            _argRow(s.args[i], i, key: ObjectKey(s.args[i])),
          Align(
            alignment: Alignment.centerLeft,
            child: HelpHover(
              'Add another argument. Events can carry several values, which '
              'the server receives as separate parameters.',
              title: 'Add argument',
              child: TextButton.icon(
                onPressed: () => _change(() => s.args.add(SocketArg())),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add argument'),
              ),
            ),
          ),
          const SizedBox(height: 4),
          HelpSwitch(
            title: 'Ask for an acknowledgement',
            subtitle:
                'The server answers with a callback; its reply is shown in '
                'the log.',
            help:
                'Emit with an acknowledgement callback. When the server '
                'handler calls it, the reply appears in the log next to this '
                'event, with the time it took. A note is added if nothing '
                'arrives in time.',
            example: 'socket.emit("save", data, (reply) => …)',
            value: s.wantAck,
            onChanged: (v) => _change(() => s.wantAck = v),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: HelpHover(
              connected
                  ? 'Emit the event with the arguments above now.'
                  : 'Connect first; events can only be emitted while the '
                        'connection is open.',
              title: 'Emit',
              child: FilledButton.icon(
                onPressed: connected ? widget.onEmit : null,
                icon: const Icon(Icons.send, size: 16),
                label: const Text('Emit'),
              ),
            ),
          ),
        ],
      );
    },
  );

  Widget _argRow(SocketArg a, int index, {Key? key}) {
    final kindButton = HelpHover(
      a.kind == SocketArgKind.json
          ? 'This argument is parsed as JSON. Click to send it as plain '
                'text instead.'
          : 'This argument is sent as a plain string. Click to read it as '
                'JSON instead.',
      title: a.kind == SocketArgKind.json ? 'JSON argument' : 'Text argument',
      child: TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(44, 30),
          padding: const EdgeInsets.symmetric(horizontal: 6),
        ),
        onPressed: () => _change(
          () => a.kind = a.kind == SocketArgKind.json
              ? SocketArgKind.text
              : SocketArgKind.json,
        ),
        child: Text(
          a.kind == SocketArgKind.json ? 'JSON' : 'Text',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
      ),
    );
    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: HelpField(
              label: 'Argument ${index + 1}',
              hint: a.kind == SocketArgKind.json
                  ? '{"text": "hello"}'
                  : 'plain text',
              help:
                  'One value sent with the event. {{variables}} are filled '
                  'in when you emit.',
              example: a.kind == SocketArgKind.json ? '{"id": 5}' : 'hello',
              value: a.body,
              minLines: 1,
              maxLines: 6,
              mono: true,
              trailing: kindButton,
              onChanged: (v) {
                a.body = v;
                widget.onChanged();
              },
            ),
          ),
          HelpHover(
            'Remove this argument.',
            title: 'Remove argument',
            child: IconButton(
              icon: Icon(Icons.close, size: 18, color: Palette.textDim),
              onPressed: s.args.length <= 1
                  ? null
                  : () => _change(() => s.args.remove(a)),
            ),
          ),
        ],
      ),
    );
  }
}

class _ListenTab extends StatefulWidget {
  const _ListenTab({required this.settings, required this.onChanged});

  final SocketIoSettings settings;
  final VoidCallback onChanged;

  @override
  State<_ListenTab> createState() => _ListenTabState();
}

class _ListenTabState extends State<_ListenTab> {
  SocketIoSettings get s => widget.settings;

  void _change(VoidCallback fn) {
    setState(fn);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: tabPadding,
    children: [
      HelpSwitch(
        title: 'Catch-all',
        subtitle: 'Log every event the server sends, whatever its name.',
        help:
            'When on, every incoming event is logged and the list below is '
            'ignored. Turn it off to log only the events switched on below.',
        example: 'Like socket.onAny(…)',
        value: s.catchAll,
        onChanged: (v) => _change(() => s.catchAll = v),
      ),
      const Divider(height: 24),
      SectionTitle(
        'Events to log',
        help:
            'Named events to log when the catch-all is off. Each can be '
            'switched on or off, also while connected.',
        example: 'news',
      ),
      if (s.catchAll)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'The catch-all is on, so every event is logged. These switches '
            'apply once it is off.',
            style: TextStyle(fontSize: 12, color: Palette.textDim),
          ),
        ),
      for (final l in s.listeners) _row(l, key: ObjectKey(l)),
      Align(
        alignment: Alignment.centerLeft,
        child: HelpHover(
          'Add an event name to listen for.',
          title: 'Add listener',
          child: TextButton.icon(
            onPressed: () => _change(() => s.listeners.add(SocketListener())),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add listener'),
          ),
        ),
      ),
    ],
  );

  Widget _row(SocketListener l, {Key? key}) => Padding(
    key: key,
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: [
        HelpHover(
          l.enabled
              ? 'This event is logged. Switch off to stop logging it.'
              : 'This event is not logged. Switch on to log it.',
          title: l.enabled ? 'Listening' : 'Not listening',
          child: Switch(
            value: l.enabled,
            onChanged: (v) => _change(() => l.enabled = v),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: HelpField(
            label: 'Event name',
            hint: 'news',
            help:
                'The name of an event the server emits. It must match '
                'exactly, including case.',
            example: 'price update',
            value: l.event,
            onChanged: (v) => _change(() => l.event = v),
          ),
        ),
        HelpHover(
          'Remove this listener.',
          title: 'Remove listener',
          child: IconButton(
            icon: Icon(Icons.close, size: 18, color: Palette.textDim),
            onPressed: () => _change(() => s.listeners.remove(l)),
          ),
        ),
      ],
    ),
  );
}

class _HandshakeTab extends StatefulWidget {
  const _HandshakeTab({required this.settings, required this.onChanged});

  final SocketIoSettings settings;
  final VoidCallback onChanged;

  @override
  State<_HandshakeTab> createState() => _HandshakeTabState();
}

class _HandshakeTabState extends State<_HandshakeTab> {
  SocketIoSettings get s => widget.settings;

  void _change(VoidCallback fn) {
    setState(fn);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: tabPadding,
    children: [
      HelpField(
        label: 'Handshake path',
        hint: '/socket.io',
        help:
            'Where the server listens for Socket.IO connections. Leave it '
            'as it is unless the server was set up with another path.',
        example: '/socket.io',
        value: s.path,
        mono: true,
        onChanged: (v) => _change(() => s.path = v),
      ),
      const SizedBox(height: 14),
      HelpDropdown<SocketTransports>(
        label: 'Transports',
        help:
            'How the client talks to the server. WebSocket connects '
            'directly. Long polling and Polling-then-upgrade are for '
            'servers that allow only those; the Socket.IO client used here '
            'speaks WebSocket only on desktop and mobile, so it connects '
            'over WebSocket and says so in the log.',
        example: 'WebSocket',
        value: s.transports,
        items: {for (final t in SocketTransports.values) t: t.label},
        onChanged: (v) => _change(() => s.transports = v),
      ),
      const SizedBox(height: 14),
      HelpField(
        label: 'Auth payload (JSON)',
        hint: '{"token": "{{token}}"}',
        help:
            'A JSON object sent to the server with the connection request, '
            'where socket.handshake.auth is read. Leave it empty to send '
            'none. {{variables}} are filled in on connect.',
        example: '{"token": "{{token}}"}',
        value: s.auth,
        minLines: 3,
        maxLines: 8,
        mono: true,
        onChanged: (v) => _change(() => s.auth = v),
      ),
      const Divider(height: 28),
      HelpSwitch(
        title: 'Reconnect automatically',
        subtitle: 'Try again with growing waits when the connection drops.',
        help:
            'When the connection drops or cannot be made, retry up to 10 '
            'times with waits growing from 1 s to 5 s. Disconnect stops it.',
        value: s.reconnection,
        onChanged: (v) => _change(() => s.reconnection = v),
      ),
      const SizedBox(height: 10),
      SizedBox(
        width: 220,
        child: HelpField(
          label: 'Acknowledgement timeout (s)',
          help:
              'How long to wait for a server acknowledgement before a note '
              'is added to the log.',
          example: '10',
          number: true,
          value: '${s.ackTimeoutSec}',
          onChanged: (v) => _change(() {
            final n = int.tryParse(v) ?? 10;
            s.ackTimeoutSec = n.clamp(1, 600);
          }),
        ),
      ),
      const SizedBox(height: 14),
      Text(
        'Speaks Socket.IO protocol 4, used by servers on version 3 and 4. '
        'Version 2 servers are not supported by this client.',
        style: TextStyle(fontSize: 12, color: Palette.textDim, height: 1.4),
      ),
    ],
  );
}

/// Live message log of a SocketIo tab.
class SocketIoMessages extends StatefulWidget {
  const SocketIoMessages({super.key, required this.tab});

  final RequestTab tab;

  @override
  State<SocketIoMessages> createState() => _SocketIoMessagesState();
}

class _SocketIoMessagesState extends State<SocketIoMessages> {
  late final LiveSession<SocketIoConnection> _session = sessionOf(
    widget.tab,
    SocketIoConnection.new,
  );

  @override
  Widget build(BuildContext context) => ProtocolLogPane(
    session: _session,
    emptyHint:
        'Connect, then emit an event. Events you emit and events the server '
        'sends are listed here.',
    extraStatus: ListenableBuilder(
      listenable: _session,
      builder: (context, _) {
        final id = _session.connection.socketId;
        return id == null
            ? const SizedBox.shrink()
            : HelpHover(
                'The id the server gave this connection.',
                title: 'Socket id',
                example: 'Zq3k…',
                child: Text(
                  'id $id',
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
