import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../services/prepared_request.dart';
import '../../services/protocols/sse_connection.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../help_tip.dart';
import '../kv_editor.dart';
import '../request/params_tab.dart';
import 'protocol_widgets.dart';

final _tabMemory = Expando<int>('sse tab');

/// Connection settings and composer of a Sse tab (issue #26).
class SseEditor extends StatefulWidget {
  const SseEditor({super.key, required this.tab});

  final RequestTab tab;

  @override
  State<SseEditor> createState() => _SseEditorState();
}

class _SseEditorState extends State<SseEditor> {
  late final LiveSession<SseConnection> _session;
  late final SseSettings _s;

  RequestModel get req => widget.tab.request;
  SseConnection get _conn => _session.connection;

  @override
  void initState() {
    super.initState();
    _session = sessionOf(widget.tab, SseConnection.new);
    _s = SseSettings.fromJson(req.protocolConfig);
    // Only GET and POST are offered.
    if (req.method.toUpperCase() != 'POST') req.method = 'GET';
  }

  void _save() {
    req.protocolConfig.addAll(_s.toJson());
    context.read<AppState>().touchActive();
  }

  void _touch() => context.read<AppState>().touchActive();

  Future<void> _start() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final state = context.read<AppState>();
    final SseConfig config;
    try {
      config = SseConfig.fromRequest(
        req,
        state.varsFor(widget.tab.sourceCollectionId),
        clientFactory: clientFactoryFor(state, widget.tab),
      );
    } on RequestBuildException catch (e) {
      reportProblem(context, _conn, e.message);
      return;
    }
    await _conn.start(config);
  }

  String _counted(String label, List<KV> rows) {
    final n = rows.where((r) => r.enabled && r.key.isNotEmpty).length;
    return n == 0 ? label : '$label ($n)';
  }

  Widget _methodPicker() {
    final post = req.method.toUpperCase() == 'POST';
    return HelpHover(
      'GET opens the stream with a plain request. POST sends a body first, '
      'which some streaming APIs (such as AI chat completions) require.',
      title: 'Method',
      example: 'POST with a JSON body',
      child: Container(
        decoration: BoxDecoration(
          color: Palette.surfaceAlt,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Palette.border),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: post ? 'POST' : 'GET',
            padding: const EdgeInsets.symmetric(horizontal: 10),
            borderRadius: BorderRadius.circular(8),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: methodColor(post ? 'POST' : 'GET'),
            ),
            items: [
              for (final m in const ['GET', 'POST'])
                DropdownMenuItem(
                  value: m,
                  child: Text(
                    m,
                    style: TextStyle(
                      color: methodColor(m),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
            onChanged: (m) {
              if (m == null) return;
              setState(() => req.method = m);
              _touch();
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppState>();
    final post = req.method.toUpperCase() == 'POST';
    return ProtocolEditorFrame(
      tab: widget.tab,
      memory: _tabMemory,
      urlBar: ProtocolUrlBar(
        tab: widget.tab,
        session: _session,
        leading: _methodPicker(),
        idleText: 'Stopped',
        hint: 'https://api.example.com/events  —  {{vars}} allowed',
        urlTitle: 'Stream URL',
        urlHelp:
            'The address that streams events (text/event-stream). {{name}} '
            'inserts a variable.',
        urlExample: 'https://api.example.com/v1/events',
        connectLabel: 'Start',
        connectHelp:
            'Open the stream and show events as they arrive. If the server '
            'drops it, it reconnects with the last event id. Pressing Enter '
            'in the URL field does the same.',
        stopLabel: 'Stop',
        stopHelp: 'Close the stream and stop reconnecting.',
        onConnect: _start,
        onStop: () => _conn.stop(),
      ),
      tabs: [
        ProtocolTabSpec(
          label: _counted('Params', req.params),
          title: 'Query parameters',
          help:
              'Name and value pairs added to the end of the URL. Unticked '
              'rows are kept but not sent.',
          example: '?channel=prices',
          child: ParamsTab(request: req, onChanged: _touch),
        ),
        ProtocolTabSpec(
          label: _counted('Headers', req.headers),
          title: 'Headers',
          help:
              'Extra HTTP headers sent with the request, such as a token. '
              'Accept: text/event-stream is added for you. Unticked rows '
              'are kept but not sent.',
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
                'start.',
            valueExample: 'Bearer {{token}}',
          ),
        ),
        ProtocolTabSpec(
          label: post && req.body.trim().isNotEmpty ? 'Body •' : 'Body',
          title: 'Request body',
          help:
              'The data sent with a POST request that opens the stream. '
              'GET requests have no body.',
          example: '{"stream": true}',
          child: _BodyTab(
            request: req,
            post: post,
            onChanged: _touch,
            onMakePost: () {
              setState(() => req.method = 'POST');
              _touch();
            },
          ),
        ),
        ProtocolTabSpec(
          label: 'Settings',
          title: 'Stream settings',
          help: 'Reconnecting, the wait between attempts and comment lines.',
          child: _SettingsTab(settings: _s, onChanged: _save),
        ),
      ],
    );
  }
}

class _BodyTab extends StatelessWidget {
  const _BodyTab({
    required this.request,
    required this.post,
    required this.onChanged,
    required this.onMakePost,
  });

  final RequestModel request;
  final bool post;
  final VoidCallback onChanged;
  final VoidCallback onMakePost;

  @override
  Widget build(BuildContext context) => ListView(
    padding: tabPadding,
    children: [
      if (!post) ...[
        Text(
          'A GET request has no body. Use POST for streaming APIs that '
          'expect one.',
          style: TextStyle(fontSize: 12.5, color: Palette.textDim, height: 1.4),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: HelpHover(
            'Change the method to POST so the body below is sent.',
            title: 'Use POST',
            child: OutlinedButton(
              onPressed: onMakePost,
              child: const Text('Use POST'),
            ),
          ),
        ),
        const SizedBox(height: 14),
      ],
      HelpField(
        label: 'Body',
        hint: '{"model": "…", "stream": true}',
        help:
            'Sent as the body of the POST request. JSON gets '
            'Content-Type: application/json unless you set a header. '
            '{{variables}} are filled in.',
        example: '{"stream": true}',
        value: request.body,
        enabled: post,
        minLines: 6,
        maxLines: 16,
        mono: true,
        onChanged: (v) {
          request.body = v;
          onChanged();
        },
      ),
    ],
  );
}

class _SettingsTab extends StatefulWidget {
  const _SettingsTab({required this.settings, required this.onChanged});

  final SseSettings settings;
  final VoidCallback onChanged;

  @override
  State<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<_SettingsTab> {
  SseSettings get s => widget.settings;

  void _change(VoidCallback fn) {
    setState(fn);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: tabPadding,
    children: [
      HelpSwitch(
        title: 'Reconnect automatically',
        subtitle: 'Open the stream again when the server ends or drops it.',
        help:
            'After the stream ends or fails, wait and connect again, sending '
            'the last event id so the server can resume. Stop cancels it. '
            'A non-200 answer is never retried.',
        example: 'Last-Event-ID: 42',
        value: s.autoReconnect,
        onChanged: (v) => _change(() => s.autoReconnect = v),
      ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 12,
        runSpacing: 14,
        children: [
          SizedBox(
            width: 220,
            child: HelpField(
              label: 'Default retry (ms)',
              help:
                  'How long to wait before reconnecting, until the server '
                  'sets its own with a retry: line.',
              example: '3000',
              number: true,
              value: '${s.defaultRetryMs}',
              onChanged: (v) => _change(
                () =>
                    s.defaultRetryMs = (int.tryParse(v) ?? 0).clamp(0, 3600000),
              ),
            ),
          ),
          SizedBox(
            width: 220,
            child: HelpField(
              label: 'Reconnects before giving up',
              help:
                  'How many reconnects in a row to try before stopping. A '
                  'successful connection resets the count. 0 keeps trying.',
              example: '10',
              number: true,
              value: '${s.maxReconnects}',
              onChanged: (v) => _change(
                () => s.maxReconnects = (int.tryParse(v) ?? 0).clamp(0, 1000),
              ),
            ),
          ),
        ],
      ),
      const Divider(height: 28),
      HelpSwitch(
        title: 'Show comment lines',
        subtitle: 'List lines starting with ":" such as keep-alives.',
        help:
            'Servers send lines starting with a colon to keep the '
            'connection open. They are normally hidden; switch on to list '
            'them in the log.',
        example: ': keep-alive',
        value: s.showComments,
        onChanged: (v) => _change(() => s.showComments = v),
      ),
    ],
  );
}

/// Live message log of a Sse tab.
class SseMessages extends StatefulWidget {
  const SseMessages({super.key, required this.tab});

  final RequestTab tab;

  @override
  State<SseMessages> createState() => _SseMessagesState();
}

class _SseMessagesState extends State<SseMessages> {
  late final LiveSession<SseConnection> _session = sessionOf(
    widget.tab,
    SseConnection.new,
  );

  @override
  Widget build(BuildContext context) => ProtocolLogPane(
    session: _session,
    idleText: 'Stopped',
    emptyHint:
        'Start the stream to see events. Each shows its name, id and data.',
    extraStatus: ListenableBuilder(
      listenable: _session,
      builder: (context, _) {
        final c = _session.connection;
        final parts = [
          if (c.statusCode != null) 'HTTP ${c.statusCode}',
          if (c.lastEventId != null) 'last id ${c.lastEventId}',
          if (c.isActive) 'retry ${c.retry.inMilliseconds} ms',
        ];
        if (parts.isEmpty) return const SizedBox.shrink();
        return HelpHover(
          'The latest response status, the id of the last event received '
          '(sent as Last-Event-ID when reconnecting) and the wait before '
          'a reconnect.',
          title: 'Stream details',
          example: 'HTTP 200 · last id 42 · retry 3000 ms',
          child: Text(
            parts.join(' · '),
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
