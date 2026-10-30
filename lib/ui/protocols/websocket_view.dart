import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../services/protocols/live_connection.dart';
import '../../services/protocols/websocket_connection.dart';
import '../../services/request_builder.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../help_tip.dart';
import '../kv_editor.dart';
import '../request/params_tab.dart';
import 'protocol_widgets.dart';

final _tabMemory = Expando<int>('websocket tab');

/// Connection settings and composer of a WebSocket tab (issue #23).
class WebSocketEditor extends StatefulWidget {
  const WebSocketEditor({super.key, required this.tab});

  final RequestTab tab;

  @override
  State<WebSocketEditor> createState() => _WebSocketEditorState();
}

class _WebSocketEditorState extends State<WebSocketEditor> {
  late final LiveSession<WebSocketConnection> _session;
  late final WebSocketSettings _s;

  RequestModel get req => widget.tab.request;
  WebSocketConnection get _conn => _session.connection;

  @override
  void initState() {
    super.initState();
    _session = sessionOf(widget.tab, WebSocketConnection.new);
    _s = WebSocketSettings.fromJson(req.protocolConfig);
  }

  /// Saves the settings into the request and marks the tab as edited.
  void _save() {
    req.protocolConfig.addAll(_s.toJson());
    context.read<AppState>().touchActive();
  }

  void _touch() => context.read<AppState>().touchActive();

  Future<void> _connect() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final state = context.read<AppState>();
    final WebSocketConfig config;
    try {
      config = WebSocketConfig.fromRequest(
        req,
        state.varsFor(widget.tab.sourceCollectionId),
        clientFactory: clientFactoryFor(state, widget.tab),
      );
    } on RequestBuildException catch (e) {
      reportProblem(context, _conn, e.message);
      return;
    }
    await _conn.connect(config);
  }

  void _send(PayloadKind kind, String body) {
    final vars = context.read<AppState>().varsFor(
      widget.tab.sourceCollectionId,
    );
    try {
      _conn.send(buildPayload(kind, substituteVars(body, vars)));
    } on FormatException catch (e) {
      reportProblem(context, _conn, e.message);
    } on StateError {
      reportProblem(context, _conn, 'Connect first, then send a message.');
    }
  }

  String _counted(String label, List<KV> rows) {
    final n = rows.where((r) => r.enabled && r.key.isNotEmpty).length;
    return n == 0 ? label : '$label ($n)';
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppState>();
    return ProtocolEditorFrame(
      tab: widget.tab,
      memory: _tabMemory,
      urlBar: ProtocolUrlBar(
        tab: widget.tab,
        session: _session,
        hint: 'wss://echo.example.com/socket  —  {{vars}} allowed',
        urlTitle: 'WebSocket URL',
        urlHelp:
            'The address to connect to, starting with ws:// or wss:// '
            '(wss is encrypted). {{name}} inserts a variable.',
        urlExample: 'wss://api.example.com/stream',
        connectLabel: 'Connect',
        connectHelp:
            'Open the WebSocket connection. Params and headers are sent with '
            'the upgrade request. Pressing Enter in the URL field does the '
            'same.',
        stopLabel: 'Disconnect',
        stopHelp:
            'Close the connection politely and stop any automatic '
            'reconnecting.',
        onConnect: _connect,
        onStop: () => _conn.disconnect(),
      ),
      tabs: [
        ProtocolTabSpec(
          label: 'Message',
          title: 'Message',
          help:
              'Write a message and send it, or keep it under a name to send '
              'again with one click.',
          example: '{"type": "subscribe"}',
          child: _MessageTab(
            session: _session,
            settings: _s,
            onChanged: _save,
            onSend: _send,
          ),
        ),
        ProtocolTabSpec(
          label: _counted('Params', req.params),
          title: 'Query parameters',
          help:
              'Name and value pairs added to the end of the URL when you '
              'connect. Unticked rows are kept but not sent.',
          example: '?token=abc',
          child: ParamsTab(request: req, onChanged: _touch),
        ),
        ProtocolTabSpec(
          label: _counted('Headers', req.headers),
          title: 'Headers',
          help:
              'Extra HTTP headers sent with the upgrade request that opens '
              'the connection, such as a token. Unticked rows are kept but '
              'not sent.',
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
        ProtocolTabSpec(
          label: 'Settings',
          title: 'Connection settings',
          help: 'Subprotocols, keep-alive pings and automatic reconnecting.',
          child: _SettingsTab(settings: _s, onChanged: _save),
        ),
      ],
    );
  }
}

class _MessageTab extends StatefulWidget {
  const _MessageTab({
    required this.session,
    required this.settings,
    required this.onChanged,
    required this.onSend,
  });

  final LiveSession<WebSocketConnection> session;
  final WebSocketSettings settings;
  final VoidCallback onChanged;
  final void Function(PayloadKind kind, String body) onSend;

  @override
  State<_MessageTab> createState() => _MessageTabState();
}

class _MessageTabState extends State<_MessageTab> {
  WebSocketSettings get s => widget.settings;

  void _change(VoidCallback fn) {
    setState(fn);
    widget.onChanged();
  }

  String get _hint => switch (s.compose) {
    PayloadKind.text => 'Type a message. {{variables}} are filled in on send.',
    PayloadKind.json => '{"type": "subscribe", "channel": "prices"}',
    PayloadKind.binary => 'Base64 bytes, for example SGVsbG8=',
  };

  void _format() {
    try {
      final pretty = const JsonEncoder.withIndent(
        '  ',
      ).convert(jsonDecode(s.draft));
      _change(() => s.draft = pretty);
    } on FormatException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('The message is not valid JSON: ${e.message}')),
      );
    }
  }

  Future<void> _saveDraft() async {
    final name = await promptText(
      context,
      title: 'Save message',
      label: 'Name',
      initial: 'Message ${s.messages.length + 1}',
      help:
          'A short name to find this message by. It is kept with the request.',
    );
    if (name == null || name.isEmpty) return;
    _change(
      () => s.messages.add(
        SavedMessage(name: name, kind: s.compose, body: s.draft),
      ),
    );
  }

  Future<void> _rename(SavedMessage m) async {
    final name = await promptText(
      context,
      title: 'Rename message',
      label: 'Name',
      initial: m.name,
    );
    if (name == null || name.isEmpty) return;
    _change(() => m.name = name);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final connected = widget.session.connection.isConnected;
      return ListView(
        padding: tabPadding,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              PayloadKindPicker(
                value: s.compose,
                onChanged: (k) => _change(() => s.compose = k),
              ),
              if (s.compose == PayloadKind.json)
                HelpHover(
                  'Re-indent the JSON in the box so it is easy to read. '
                  'What you send is exactly what is in the box.',
                  title: 'Format JSON',
                  child: OutlinedButton.icon(
                    onPressed: _format,
                    icon: const Icon(Icons.format_align_left, size: 16),
                    label: const Text('Format'),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          HelpField(
            label: 'Message',
            hint: _hint,
            help:
                'What to send. {{variables}} are filled in when you send. '
                'Binary messages are written in base64.',
            example: s.compose == PayloadKind.json
                ? '{"op": "ping"}'
                : s.compose == PayloadKind.binary
                ? 'SGVsbG8='
                : 'hello',
            value: s.draft,
            minLines: 4,
            maxLines: 10,
            mono: true,
            onChanged: (v) {
              s.draft = v;
              widget.onChanged();
            },
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              HelpHover(
                connected
                    ? 'Send the message in the box now.'
                    : 'Connect first; messages can only be sent while the '
                          'connection is open.',
                title: 'Send',
                child: FilledButton.icon(
                  onPressed: connected
                      ? () => widget.onSend(s.compose, s.draft)
                      : null,
                  icon: const Icon(Icons.send, size: 16),
                  label: const Text('Send'),
                ),
              ),
              HelpHover(
                'Keep the message in the box under a name, to send again with '
                'one click from the list below.',
                title: 'Save message',
                child: OutlinedButton.icon(
                  onPressed: s.draft.trim().isEmpty ? null : _saveDraft,
                  icon: const Icon(Icons.bookmark_add_outlined, size: 16),
                  label: const Text('Save message'),
                ),
              ),
            ],
          ),
          const Divider(height: 28),
          const SectionTitle(
            'Saved messages',
            help:
                'Messages you keep with this request. Send sends one now; '
                'Edit puts it back in the box; click a name to rename it.',
            example: 'Subscribe to prices',
          ),
          if (s.messages.isEmpty)
            Text(
              'No saved messages yet. Write one above and choose Save message.',
              style: TextStyle(fontSize: 12.5, color: Palette.textDim),
            ),
          for (final m in s.messages)
            _savedTile(m, connected, key: ObjectKey(m)),
        ],
      );
    },
  );

  Widget _savedTile(SavedMessage m, bool connected, {Key? key}) => Container(
    key: key,
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.fromLTRB(12, 6, 4, 8),
    decoration: BoxDecoration(
      border: Border.all(color: Palette.border),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: HelpHover(
                'Click to rename this saved message.',
                title: 'Name',
                child: InkWell(
                  onTap: () => _rename(m),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      m.name.isEmpty ? '(unnamed)' : m.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            HelpHover(
              connected
                  ? 'Send this saved message now.'
                  : 'Connect first to send this message.',
              title: 'Send',
              child: IconButton(
                icon: Icon(
                  Icons.send,
                  size: 18,
                  color: connected ? Palette.accent : null,
                ),
                onPressed: connected
                    ? () => widget.onSend(m.kind, m.body)
                    : null,
              ),
            ),
            HelpHover(
              'Put this message in the box above to change it or send it.',
              title: 'Edit',
              child: IconButton(
                icon: const Icon(Icons.edit_outlined, size: 18),
                onPressed: () => _change(() {
                  s.compose = m.kind;
                  s.draft = m.body;
                }),
              ),
            ),
            HelpHover(
              'Remove this saved message from the request.',
              title: 'Delete',
              child: IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => _change(() => s.messages.remove(m)),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Text(
            '${m.kind.label} · ${m.body.replaceAll(RegExp(r'\s+'), ' ').trim()}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: Palette.textDim,
            ),
          ),
        ),
      ],
    ),
  );
}

class _SettingsTab extends StatefulWidget {
  const _SettingsTab({required this.settings, required this.onChanged});

  final WebSocketSettings settings;
  final VoidCallback onChanged;

  @override
  State<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<_SettingsTab> {
  WebSocketSettings get s => widget.settings;

  void _change(VoidCallback fn) {
    setState(fn);
    widget.onChanged();
  }

  Widget _number(
    String label,
    String help,
    int value,
    ValueChanged<int> set, {
    String? example,
    String? hint,
  }) => SizedBox(
    width: 200,
    child: HelpField(
      label: label,
      help: help,
      example: example,
      hint: hint,
      number: true,
      value: '$value',
      onChanged: (v) => _change(() => set(int.tryParse(v) ?? 0)),
    ),
  );

  @override
  Widget build(BuildContext context) => ListView(
    padding: tabPadding,
    children: [
      HelpField(
        label: 'Subprotocols',
        hint: 'chat, superchat',
        help:
            'Names the client offers in the Sec-WebSocket-Protocol header. '
            'The server picks one, or none. Separate names with commas.',
        example: 'graphql-ws',
        value: s.subprotocols,
        onChanged: (v) => _change(() => s.subprotocols = v),
      ),
      const SizedBox(height: 14),
      _number(
        'Ping interval (seconds)',
        'How often to send a WebSocket ping frame to keep the connection '
            'alive and notice a dead one. 0 sends no pings.',
        s.pingSeconds,
        (v) => s.pingSeconds = v,
        example: '30',
      ),
      const Divider(height: 28),
      HelpSwitch(
        title: 'Reconnect automatically',
        subtitle:
            'When the connection drops or cannot be made, try again with '
            'growing waits.',
        help:
            'When the connection drops or cannot be made, try again after a '
            'wait that doubles each time, up to the longest wait. '
            'Disconnect stops it.',
        example: '1 s, 2 s, 4 s, 8 s, …',
        value: s.autoReconnect,
        onChanged: (v) => _change(() => s.autoReconnect = v),
      ),
      if (s.autoReconnect) ...[
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 14,
          children: [
            _number(
              'Attempts',
              'How many reconnect attempts to make in a row before giving '
                  'up. 0 keeps trying.',
              s.maxAttempts,
              (v) => s.maxAttempts = v,
              example: '5',
            ),
            _number(
              'First wait (ms)',
              'How long to wait before the first reconnect attempt. The wait '
                  'doubles after each failure.',
              s.backoffMs,
              (v) => s.backoffMs = v < 50 ? 50 : v,
              example: '1000',
            ),
            _number(
              'Longest wait (ms)',
              'The wait never grows beyond this.',
              s.backoffMaxMs,
              (v) => s.backoffMaxMs = v < 50 ? 50 : v,
              example: '30000',
            ),
          ],
        ),
      ],
    ],
  );
}

/// Live message log of a WebSocket tab.
class WebSocketMessages extends StatefulWidget {
  const WebSocketMessages({super.key, required this.tab});

  final RequestTab tab;

  @override
  State<WebSocketMessages> createState() => _WebSocketMessagesState();
}

class _WebSocketMessagesState extends State<WebSocketMessages> {
  late final LiveSession<WebSocketConnection> _session = sessionOf(
    widget.tab,
    WebSocketConnection.new,
  );

  @override
  Widget build(BuildContext context) => ProtocolLogPane(
    session: _session,
    emptyHint:
        'Connect, then send a message. Everything sent and received is '
        'listed here with its time and size.',
  );
}
