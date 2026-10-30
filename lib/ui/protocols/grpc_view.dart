import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:grpc/grpc.dart' show GrpcError;
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../services/grpc/grpc.dart';
import '../../services/http_service.dart' show substituteVars;
import '../../state/app_state.dart';
import '../../theme.dart';
import '../help_tip.dart';
import '../kv_editor.dart';
import '../tab_memory.dart';
import '../adaptive.dart';

/// Which editor tab (Message, Metadata, ...) each gRPC tab shows.
final _selectedTab = Expando<int>('grpc editor tab');

/// The live side of a gRPC tab: its loaded schema, the channel, the call in
/// flight and the timeline. Kept in [RequestTab.session], so the editor and
/// the message log share it and it closes with the tab.
class GrpcTabSession extends ChangeNotifier implements TabSession {
  /// The session of [tab], created on first use.
  static GrpcTabSession of(RequestTab tab) {
    final s = tab.session;
    if (s is GrpcTabSession) return s;
    final created = GrpcTabSession();
    tab.session = created;
    return created;
  }

  DescriptorPool? pool;
  String? schemaError;
  bool loadingSchema = false;
  String? _schemaKey;
  GrpcConnection? _connection;

  /// The current (or last) call.
  GrpcInvocation? call;
  GrpcStatus? status;
  final List<GrpcEvent> events = [];
  final Stopwatch _sinceInvoke = Stopwatch();
  bool _closed = false;

  /// Timelines of long streams are capped so memory stays bounded.
  static const maxEvents = 500;

  bool get active => call != null && !call!.finished;
  bool get canSend => call?.canSend ?? false;

  void _notify() {
    if (!_closed) notifyListeners();
  }

  void _add(GrpcEvent e) {
    if (_closed) return;
    events.add(e);
    if (events.length > maxEvents) {
      events.removeRange(0, events.length - maxEvents);
    }
    _notify();
  }

  void _note(GrpcEventKind kind, String title, [String? body]) =>
      _add(GrpcEvent(kind, title, body: body, elapsed: _sinceInvoke.elapsed));

  /// Identifies where a schema comes from, to know when to reload it.
  static String schemaKey(GrpcConfig cfg, String address) =>
      cfg.source == GrpcSchemaSource.reflection
      ? 'r|$address|${cfg.tls}|${cfg.verify}'
      : 'p|${cfg.protoPaths.join(';')}|${cfg.importPaths.join(';')}|'
            '${cfg.protoText.hashCode}';

  bool isStale(GrpcConfig cfg, String address) =>
      pool == null || _schemaKey != schemaKey(cfg, address);

  GrpcConnection _connectionFor(String address, GrpcConfig cfg) {
    final target = GrpcTarget.parse(address, tlsDefault: cfg.tls);
    final tls = target.tls ?? cfg.tls;
    final existing = _connection;
    if (existing != null &&
        existing.matches(target, tls: tls, verify: cfg.verify)) {
      return existing;
    }
    unawaited(existing?.close());
    return _connection = GrpcConnection(target, tls: tls, verify: cfg.verify);
  }

  static Map<String, String> metadataOf(
    GrpcConfig cfg,
    Map<String, String> vars,
  ) => {
    for (final m in cfg.metadata)
      if (m.enabled && m.key.trim().isNotEmpty)
        substituteVars(m.key.trim(), vars).toLowerCase(): substituteVars(
          m.effective,
          vars,
        ),
  };

  /// Loads services by reflection or from the .proto files of [cfg].
  Future<void> loadSchema(
    GrpcConfig cfg,
    String address,
    Map<String, String> vars,
  ) async {
    if (loadingSchema || _closed) return;
    loadingSchema = true;
    schemaError = null;
    _notify();
    final resolved = substituteVars(address, vars);
    try {
      if (cfg.source == GrpcSchemaSource.reflection) {
        final conn = _connectionFor(resolved, cfg);
        pool = await ReflectionClient(
          conn,
          metadata: metadataOf(cfg, vars),
        ).load();
      } else {
        if (cfg.protoPaths.isEmpty && cfg.protoText.trim().isEmpty) {
          throw const FormatException(
            'Add .proto files or paste a .proto definition in the Proto '
            'tab first.',
          );
        }
        pool = await loadProtoFiles(
          [for (final p in cfg.protoPaths) substituteVars(p, vars)],
          importPaths: [
            for (final p in cfg.importPaths) substituteVars(p, vars),
          ],
          text: cfg.protoText,
        );
      }
      _schemaKey = schemaKey(cfg, resolved);
    } catch (e) {
      schemaError = describeError(e);
    } finally {
      loadingSchema = false;
      _notify();
    }
  }

  /// Readable text for the errors schema loading and calls can raise.
  static String describeError(Object e) => switch (e) {
    GrpcError g => '${GrpcStatus(g.code).name}: ${g.message ?? 'no details'}',
    FileSystemException f =>
      'Could not read ${f.path ?? 'a file'}: '
          '${f.osError?.message ?? f.message}',
    FormatException f => f.message,
    _ => '$e',
  };

  /// Starts the method selected in [cfg]. Unary and server-streaming
  /// calls send the message right away; streaming requests wait for
  /// [send].
  Future<void> invoke(
    RequestModel request,
    GrpcConfig cfg,
    Map<String, String> vars,
  ) async {
    if (active || _closed) return;
    events.clear();
    status = null;
    call = null;
    _sinceInvoke
      ..reset()
      ..start();
    final address = substituteVars(request.url, vars);
    try {
      GrpcTarget.parse(address, tlsDefault: cfg.tls);
    } on FormatException catch (e) {
      _note(GrpcEventKind.error, 'Invalid server address', e.message);
      return;
    }
    if (isStale(cfg, address)) {
      _note(GrpcEventKind.info, 'Loading services');
      await loadSchema(cfg, request.url, vars);
      if (pool == null || schemaError != null) {
        _note(
          GrpcEventKind.error,
          'Could not load services',
          schemaError ?? 'Unknown error',
        );
        return;
      }
    }
    final method = pool!.findMethod(cfg.service, cfg.method);
    if (method == null) {
      _note(
        GrpcEventKind.error,
        'Pick a method',
        cfg.method.isEmpty
            ? 'Choose a service and a method above, then Invoke.'
            : '${cfg.service}/${cfg.method} is not among the loaded '
                  'services. Reload them, or pick another method.',
      );
      return;
    }
    Object? first;
    if (!method.clientStreaming) {
      try {
        first = _parse(method, cfg.message, vars);
      } on ProtoJsonException catch (e) {
        _note(
          GrpcEventKind.error,
          'The message does not fit ${method.input.name}',
          '$e',
        );
        return;
      }
    }
    final GrpcConnection conn;
    try {
      conn = _connectionFor(address, cfg);
    } on FormatException catch (e) {
      _note(GrpcEventKind.error, 'Invalid server address', e.message);
      return;
    }
    _note(
      GrpcEventKind.info,
      '${method.kind.label} call',
      '${method.path} on ${conn.target} (${conn.tls ? 'TLS' : 'plaintext'}'
          '${cfg.deadlineMs > 0 ? ', deadline ${cfg.deadlineMs} ms' : ''})',
    );
    final metadata = metadataOf(cfg, vars);
    if (metadata.isNotEmpty) {
      _note(
        GrpcEventKind.headers,
        'Request metadata',
        metadata.entries.map((e) => '${e.key}: ${e.value}').join('\n'),
      );
    }
    final invocation = GrpcInvocation.start(
      connection: conn,
      method: method,
      codec: ProtoJsonCodec(pool),
      onEvent: _add,
      metadata: metadata,
      deadline: cfg.deadlineMs > 0
          ? Duration(milliseconds: cfg.deadlineMs)
          : null,
      emitDefaults: cfg.emitDefaults,
      clock: _sinceInvoke,
    );
    call = invocation;
    unawaited(
      invocation.done.then((s) {
        status = s;
        _notify();
      }),
    );
    if (!method.clientStreaming) {
      invocation
        ..send(first)
        ..end();
    }
    _notify();
  }

  /// [text] with variables filled in, parsed and checked against the
  /// request type.
  Object? _parse(
    MethodDescriptor method,
    String text,
    Map<String, String> vars,
  ) {
    final resolved = substituteVars(text, vars);
    ProtoJsonCodec(pool).encodeText(method.input, resolved); // validates
    return resolved.trim().isEmpty ? <String, Object?>{} : jsonDecode(resolved);
  }

  /// Sends one more message on a client or bidirectional stream.
  void send(String text, Map<String, String> vars) {
    final c = call;
    if (c == null || !c.canSend) return;
    try {
      c.send(_parse(c.method, text, vars));
    } on ProtoJsonException catch (e) {
      _note(
        GrpcEventKind.error,
        'Not sent: the message does not fit ${c.method.input.name}',
        '$e',
      );
    }
  }

  void endStream() {
    call?.end();
    _notify();
  }

  Future<void> cancel() async => call?.cancel();

  void clear() {
    events.clear();
    if (!active) status = null;
    _notify();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    unawaited(call?.cancel());
    unawaited(_connection?.close());
    _connection = null;
  }
}

/// Connection settings and composer of a gRPC tab (issue #27).
class GrpcEditor extends StatefulWidget {
  const GrpcEditor({super.key, required this.tab});

  final RequestTab tab;

  @override
  State<GrpcEditor> createState() => _GrpcEditorState();
}

class _GrpcEditorState extends State<GrpcEditor> {
  late GrpcConfig _cfg;
  late final TextEditingController _address;
  late final TextEditingController _message;
  late final TextEditingController _deadline;
  late final TextEditingController _protoText;
  late final GrpcTabSession _session;

  RequestModel get _req => widget.tab.request;

  @override
  void initState() {
    super.initState();
    _cfg = GrpcConfig.of(_req);
    _address = TextEditingController(text: _req.url);
    _message = TextEditingController(text: _cfg.message);
    _deadline = TextEditingController(
      text: _cfg.deadlineMs > 0 ? '${_cfg.deadlineMs}' : '',
    );
    _protoText = TextEditingController(text: _cfg.protoText);
    _session = GrpcTabSession.of(widget.tab)..addListener(_changed);
    // Local .proto files load without asking; reflection waits for the
    // user, as it connects to the server.
    if (_cfg.source == GrpcSchemaSource.protoFiles &&
        _hasProtos &&
        _session.pool == null &&
        !_session.loadingSchema) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadSchema();
      });
    }
  }

  @override
  void dispose() {
    _session.removeListener(_changed);
    _address.dispose();
    _message.dispose();
    _deadline.dispose();
    _protoText.dispose();
    super.dispose();
  }

  bool get _hasProtos =>
      _cfg.protoPaths.isNotEmpty || _cfg.protoText.trim().isNotEmpty;

  void _changed() {
    if (mounted) setState(() {});
  }

  void _save() {
    _cfg.saveTo(_req);
    context.read<AppState>().touchActive();
  }

  void _set(VoidCallback change) {
    setState(change);
    _save();
  }

  Map<String, String> _vars() =>
      context.read<AppState>().varsFor(widget.tab.sourceCollectionId);

  Future<void> _loadSchema() async {
    await _session.loadSchema(_cfg, _req.url, _vars());
    if (mounted) _pickDefaults();
  }

  /// After a schema loads, keep the saved method when it still exists,
  /// otherwise select the first one.
  void _pickDefaults() {
    final pool = _session.pool;
    if (pool == null || pool.services.isEmpty) return;
    final service = pool.findService(_cfg.service);
    if (service == null) {
      _selectService(pool.services.first.fullName);
    } else if (service.method(_cfg.method) == null &&
        service.methods.isNotEmpty) {
      _selectMethod(service.methods.first.name);
    }
  }

  MethodDescriptor? get _method =>
      _session.pool?.findMethod(_cfg.service, _cfg.method);

  void _selectService(String name) {
    final service = _session.pool?.findService(name);
    if (service == null) return;
    _cfg.service = name;
    if (service.method(_cfg.method) == null) {
      _selectMethod(service.methods.isEmpty ? '' : service.methods.first.name);
    } else {
      _set(() {});
    }
  }

  /// Selecting a method fills an empty editor with an example message.
  void _selectMethod(String name) {
    _cfg.method = name;
    final text = _message.text.trim();
    final m = _method;
    if ((text.isEmpty || text == '{}') && m != null) {
      _setMessage(exampleJsonText(m.input));
    }
    _set(() {});
  }

  void _setMessage(String text) {
    _message.text = text;
    _cfg.message = text;
  }

  void _invoke() {
    FocusManager.instance.primaryFocus?.unfocus();
    if (_session.active) {
      _session.cancel();
      return;
    }
    _session.invoke(_req, _cfg, _vars()).then((_) {
      if (mounted) _pickDefaults();
    });
  }

  @override
  Widget build(BuildContext context) {
    final enabledMetadata = _cfg.metadata
        .where((m) => m.enabled && m.key.isNotEmpty)
        .length;
    // Short panes (phones, the keyboard up) scroll the whole editor at a
    // usable height instead of squeezing its tabs.
    return LayoutBuilder(
      builder: (context, box) => box.maxHeight >= 520
          ? _editor(enabledMetadata)
          : SingleChildScrollView(
              child: SizedBox(height: 520, child: _editor(enabledMetadata)),
            ),
    );
  }

  Widget _editor(int enabledMetadata) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          child: _addressBar(),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: _methodRow(),
        ),
        if (_session.schemaError != null) _schemaErrorBanner(),
        Expanded(
          child: DefaultTabController(
            length: 4,
            initialIndex: TabMemory.initialIndex(_selectedTab, widget.tab, 4),
            child: TabMemory(
              owner: widget.tab,
              memory: _selectedTab,
              child: Column(
                children: [
                  TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    labelStyle: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    tabs: [
                      const HelpHover(
                        'The request message as JSON, in the proto3 JSON '
                        'format: 64-bit numbers as strings, bytes as base64, '
                        'enums by name.',
                        title: 'Message',
                        example: '{"name": "Ada", "id": "42"}',
                        child: Tab(text: 'Message'),
                      ),
                      HelpHover(
                        'Key and value pairs sent as gRPC metadata (HTTP/2 '
                        'headers), such as auth tokens. Unticked rows are '
                        'kept but not sent.',
                        title: 'Metadata',
                        example: 'authorization: Bearer eyJhbGci…',
                        child: Tab(
                          text: enabledMetadata == 0
                              ? 'Metadata'
                              : 'Metadata ($enabledMetadata)',
                        ),
                      ),
                      const HelpHover(
                        'Where the services come from: the server\'s '
                        'reflection, or .proto files you import or paste.',
                        title: 'Proto definitions',
                        example: 'protos/greeter.proto',
                        child: Tab(text: 'Proto'),
                      ),
                      const HelpHover(
                        'TLS, certificate checks, the deadline and how '
                        'responses are shown.',
                        title: 'Settings',
                        example: 'Deadline 5000 ms',
                        child: Tab(text: 'Settings'),
                      ),
                    ],
                  ),
                  Divider(height: 1, color: Palette.border),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _messageTab(),
                        _metadataTab(),
                        _protoTab(),
                        _settingsTab(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------- Address and method ----------------

  Widget _addressBar() {
    final active = _session.active;
    final field = TextField(
      controller: _address,
      keyboardType: TextInputType.url,
      autocorrect: false,
      enableSuggestions: false,
      textInputAction: TextInputAction.go,
      style: const TextStyle(fontSize: 13.5, fontFamily: 'monospace'),
      decoration: const InputDecoration(
        hintText: 'localhost:50051  —  {{vars}} allowed',
        suffixIcon: HelpTip(
          'The server as host:port. grpcs:// turns TLS on; a bare host:port '
          'or grpc:// follows the TLS switch in Settings.',
          title: 'Server address',
          example: 'grpcs://api.example.com:443',
        ),
        suffixIconConstraints: BoxConstraints(minWidth: 32, minHeight: 32),
      ),
      onChanged: (v) {
        _req.url = v;
        _save();
      },
      onSubmitted: (_) => _invoke(),
    );
    final invoke = HelpHover(
      active
          ? 'Stop the call now. The server sees it as cancelled.'
          : 'Call the selected method. Unary and server-streaming calls send '
                'the message at once; streaming requests open the stream so '
                'you can Send messages.',
      title: active ? 'Cancel' : 'Invoke',
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: active ? Palette.danger : Palette.accent,
          foregroundColor: active ? Colors.white : Palette.onAccent,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        ),
        onPressed: _session.loadingSchema && !active ? null : _invoke,
        icon: Icon(active ? Icons.stop : Icons.play_arrow, size: 18),
        label: Text(active ? 'Cancel' : 'Invoke'),
      ),
    );
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth >= 520) {
          return Row(
            children: [
              Expanded(child: field),
              const SizedBox(width: 8),
              invoke,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            field,
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerRight, child: invoke),
          ],
        );
      },
    );
  }

  Widget _methodRow() {
    final pool = _session.pool;
    final services = pool?.services ?? const <ServiceDescriptor>[];
    final service = pool?.findService(_cfg.service);
    final method = _method;
    final stale =
        pool != null &&
        _session.isStale(_cfg, substituteVars(_req.url, _vars()));
    return LayoutBuilder(
      builder: (context, box) {
        final pickerWidth = box.maxWidth < 420 ? box.maxWidth : 300.0;
        return Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: box.maxWidth),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: _sourcePicker(),
              ),
            ),
            _Picker(
              maxWidth: pickerWidth,
              label: service?.fullName ?? _orHint(_cfg.service, 'service'),
              enabled: services.isNotEmpty,
              help: 'The service to call, from the loaded definitions.',
              helpTitle: 'Service',
              example: 'helloworld.Greeter',
              items: [
                for (final s in services)
                  PopupMenuItem(
                    value: s.fullName,
                    child: Text(s.fullName, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onSelected: _selectService,
            ),
            _Picker(
              maxWidth: pickerWidth,
              label: method == null
                  ? _orHint(_cfg.method, 'method')
                  : '${method.name}  ·  ${_kindShort(method.kind)}',
              enabled: service != null && service.methods.isNotEmpty,
              help:
                  'The rpc to call. Its tag shows whether the request, the '
                  'response or both are streams.',
              helpTitle: 'Method',
              example: 'SayHello  ·  unary',
              items: [
                for (final m in service?.methods ?? const <MethodDescriptor>[])
                  PopupMenuItem(
                    value: m.name,
                    child: _MethodItem(method: m),
                  ),
              ],
              onSelected: _selectMethod,
            ),
            HelpHover(
              _cfg.source == GrpcSchemaSource.reflection
                  ? 'Ask the server for its services again (server '
                        'reflection).'
                  : 'Read the .proto files again, for example after editing '
                        'them.',
              title: 'Load services',
              child: IconButton(
                onPressed: _session.loadingSchema ? null : _loadSchema,
                icon: _session.loadingSchema
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 20),
              ),
            ),
            if (pool != null)
              HelpHover(
                'The services found, and the files they come from. After '
                'changing the address or the files, reload to update them.',
                title: 'Loaded schema',
                example: pool.files.keys.take(2).join(', '),
                child: Text(
                  '${services.length} '
                  'service${services.length == 1 ? '' : 's'}'
                  '${stale ? ' · reload to update' : ''}',
                  style: TextStyle(fontSize: 12, color: Palette.textDim),
                ),
              ),
          ],
        );
      },
    );
  }

  static String _orHint(String saved, String what) =>
      saved.isEmpty ? 'Select a $what' : saved;

  static String _kindShort(CallKind k) => switch (k) {
    CallKind.unary => 'unary',
    CallKind.serverStreaming => 'server stream',
    CallKind.clientStreaming => 'client stream',
    CallKind.bidiStreaming => 'bidi stream',
  };

  Widget _sourcePicker() => SegmentedButton<GrpcSchemaSource>(
    showSelectedIcon: false,
    style: isTouch(context)
        ? const ButtonStyle(
            minimumSize: WidgetStatePropertyAll(Size(0, minTouchTarget)),
          )
        : const ButtonStyle(visualDensity: VisualDensity.compact),
    segments: const [
      ButtonSegment(
        value: GrpcSchemaSource.reflection,
        label: HelpHover(
          'Ask the server which services it has (gRPC server reflection). '
          'Nothing to import, but the server must enable reflection.',
          title: 'Use reflection',
          example: 'grpc.reflection.v1',
          child: Text('Use reflection'),
        ),
      ),
      ButtonSegment(
        value: GrpcSchemaSource.protoFiles,
        label: HelpHover(
          'Describe the services with .proto files from this device, or '
          'paste a definition. Works when reflection is off.',
          title: 'Import .proto files',
          example: 'greeter.proto',
          child: Text('Import .proto files'),
        ),
      ),
    ],
    selected: {_cfg.source},
    onSelectionChanged: (s) {
      _set(() => _cfg.source = s.first);
      if (_cfg.source == GrpcSchemaSource.protoFiles && _hasProtos) {
        _loadSchema();
      }
    },
  );

  Widget _schemaErrorBanner() => Container(
    width: double.infinity,
    margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: Palette.danger.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: Palette.danger.withValues(alpha: 0.4)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline, size: 16, color: Palette.danger),
        const SizedBox(width: 6),
        Expanded(
          child: SelectableText(
            _session.schemaError!,
            maxLines: 4,
            style: TextStyle(fontSize: 12, color: Palette.text),
          ),
        ),
      ],
    ),
  );

  // ---------------- Tabs ----------------

  Widget _messageTab() {
    final method = _method;
    final streaming = method?.clientStreaming ?? false;
    final canSend = _session.canSend && _session.call!.method.clientStreaming;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              HelpHover(
                'Fill the editor with every field of the request type: '
                'strings hold their field name, numbers are zero, and lists '
                'have one item.',
                title: 'Generate example message',
                example: '{"name": "name", "count": 0}',
                child: OutlinedButton.icon(
                  onPressed: method == null
                      ? null
                      : () => _set(
                          () => _setMessage(exampleJsonText(method.input)),
                        ),
                  icon: const Icon(Icons.auto_awesome, size: 16),
                  label: const Text('Generate example message'),
                ),
              ),
              HelpHover(
                'Re-indent the JSON message.',
                title: 'Format JSON',
                child: TextButton.icon(
                  onPressed: _formatMessage,
                  icon: const Icon(Icons.auto_fix_high, size: 16),
                  label: const Text('Format'),
                ),
              ),
              if (canSend) ...[
                HelpHover(
                  'Send the message in the editor on the open stream. Edit '
                  'it and send again as often as you like.',
                  title: 'Send',
                  child: FilledButton.tonalIcon(
                    onPressed: () => _session.send(_message.text, _vars()),
                    icon: const Icon(Icons.send, size: 16),
                    label: const Text('Send'),
                  ),
                ),
                HelpHover(
                  'Close the request stream. The server then knows no more '
                  'messages are coming and finishes its reply.',
                  title: 'End stream',
                  child: OutlinedButton.icon(
                    onPressed: _session.endStream,
                    icon: const Icon(Icons.stop_circle_outlined, size: 16),
                    label: const Text('End stream'),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          if (method != null)
            Text(
              streaming && !_session.active
                  ? '${method.input.fullName} · Invoke opens the stream, then '
                        'Send each message and End stream.'
                  : method.input.fullName,
              style: TextStyle(fontSize: 11.5, color: Palette.textDim),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          const SizedBox(height: 6),
          Expanded(
            child: TextField(
              controller: _message,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: const InputDecoration(
                hintText: '{\n  "name": "Ada"\n}',
                suffixIcon: Align(
                  alignment: Alignment.topRight,
                  widthFactor: 1,
                  heightFactor: 1,
                  child: HelpTip(
                    'The request as JSON. {{variables}} are filled in before '
                    'sending; leave it empty or {} to send an empty message.',
                    title: 'Request message',
                    example: '{"id": "{{userId}}", "tags": ["a"]}',
                  ),
                ),
              ),
              onChanged: (v) {
                _cfg.message = v;
                _save();
              },
            ),
          ),
        ],
      ),
    );
  }

  void _formatMessage() {
    final text = _message.text.trim();
    if (text.isEmpty) return;
    try {
      final pretty = const JsonEncoder.withIndent(
        '  ',
      ).convert(jsonDecode(text));
      _set(() => _setMessage(pretty));
    } on FormatException catch (e) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('Not valid JSON: ${e.message}')));
    }
  }

  Widget _metadataTab() => KVEditor(
    rows: _cfg.metadata,
    onChanged: _save,
    keyHint: 'Key',
    valueHint: 'Value',
    addLabel: 'Add metadata',
    keyHelp:
        'The metadata key, in lower case. Keys ending in -bin carry base64 '
        'binary values.',
    keyExample: 'authorization',
    valueHelp: 'The value sent with the call. {{variables}} work here too.',
    valueExample: 'Bearer {{token}}',
  );

  Widget _protoTab() {
    final reflection = _cfg.source == GrpcSchemaSource.reflection;
    final pool = _session.pool;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
      children: [
        if (reflection) ...[
          Text(
            'Services come from the server through gRPC server reflection '
            '(grpc.reflection.v1, or v1alpha on older servers). Choose '
            '"Import .proto files" above when the server has reflection off.',
            style: TextStyle(fontSize: 12.5, color: Palette.textDim),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: HelpHover(
              'Connect to the server and ask it for its services now.',
              title: 'Load services now',
              child: FilledButton.tonalIcon(
                onPressed: _session.loadingSchema ? null : _loadSchema,
                icon: const Icon(Icons.travel_explore, size: 16),
                label: const Text('Load services now'),
              ),
            ),
          ),
        ] else ...[
          _sectionTitle(
            '.proto files',
            'Files on this device that define the services. Their imports '
                'are found next to them, in parent folders, or in the import '
                'folders below.',
            '/home/me/protos/greeter.proto',
          ),
          for (final path in _cfg.protoPaths)
            _pathRow(path, () => _set(() => _cfg.protoPaths.remove(path))),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              HelpHover(
                'Choose one or more .proto files from this device.',
                title: 'Add .proto files',
                example: 'greeter.proto',
                child: OutlinedButton.icon(
                  onPressed: _addProtoFiles,
                  icon: const Icon(Icons.note_add_outlined, size: 16),
                  label: const Text('Add .proto files'),
                ),
              ),
              HelpHover(
                'Read the files again and list their services.',
                title: 'Load services',
                child: FilledButton.tonalIcon(
                  onPressed: _session.loadingSchema ? null : _loadSchema,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Load services'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _sectionTitle(
            'Import folders',
            'Extra folders searched for imported files, like protoc\'s -I.',
            '/home/me/third_party/googleapis',
          ),
          for (final path in _cfg.importPaths)
            _pathRow(path, () => _set(() => _cfg.importPaths.remove(path))),
          Align(
            alignment: Alignment.centerLeft,
            child: HelpHover(
              'Choose a folder that imports are relative to.',
              title: 'Add import folder',
              example: 'third_party/googleapis',
              child: OutlinedButton.icon(
                onPressed: _addImportFolder,
                icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                label: const Text('Add import folder'),
              ),
            ),
          ),
          const SizedBox(height: 16),
          _sectionTitle(
            'Paste a definition',
            'A .proto source typed or pasted here, used with the files '
                'above. Handy on phones.',
            'syntax = "proto3"; service Greeter { … }',
          ),
          SizedBox(
            height: 180,
            child: TextField(
              controller: _protoText,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
              decoration: const InputDecoration(
                hintText:
                    'syntax = "proto3";\nservice Greeter {\n  rpc SayHello '
                    '(HelloRequest) returns (HelloReply);\n}',
              ),
              onChanged: (v) {
                _cfg.protoText = v;
                _save();
              },
            ),
          ),
        ],
        if (pool != null) ...[
          const SizedBox(height: 16),
          _sectionTitle(
            'Loaded files',
            'Every file of the current schema, imports included.',
            'google/protobuf/timestamp.proto',
          ),
          for (final f in pool.files.keys)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                f,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: Palette.textDim,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ],
    );
  }

  Widget _sectionTitle(String title, String help, String example) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Align(
      alignment: Alignment.centerLeft,
      child: LabelWithHelp(
        title,
        help,
        example: example,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    ),
  );

  Widget _pathRow(String path, VoidCallback onRemove) => Row(
    children: [
      Icon(Icons.description_outlined, size: 16, color: Palette.textDim),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          path,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
          overflow: TextOverflow.ellipsis,
        ),
      ),
      IconButton(
        tooltip: 'Remove',
        icon: const Icon(Icons.close, size: 16),
        onPressed: onRemove,
      ),
    ],
  );

  Future<void> _addProtoFiles() async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Choose .proto files',
      allowMultiple: true,
    );
    if (picked == null || !mounted) return;
    final paths = [
      for (final f in picked.files)
        if (f.path != null && !_cfg.protoPaths.contains(f.path)) f.path!,
    ];
    if (paths.isEmpty) return;
    _set(() => _cfg.protoPaths.addAll(paths));
    await _loadSchema();
  }

  Future<void> _addImportFolder() async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose an import folder',
    );
    if (dir == null || !mounted || _cfg.importPaths.contains(dir)) return;
    _set(() => _cfg.importPaths.add(dir));
  }

  Widget _settingsTab() => ListView(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
    children: [
      _toggle(
        'Use TLS',
        'Encrypt the connection. Off sends plaintext HTTP/2, as most local '
            'dev servers expect. A grpcs:// or http:// address overrides it.',
        'api.example.com:443 with TLS on',
        _cfg.tls,
        (v) => _set(() => _cfg.tls = v),
      ),
      _toggle(
        'Verify the certificate',
        'Check that the server\'s TLS certificate is valid and trusted. '
            'Turn off for self-signed certificates in development.',
        'Off for a self-signed localhost certificate',
        _cfg.verify,
        _cfg.tls ? (v) => _set(() => _cfg.verify = v) : null,
      ),
      _toggle(
        'Show default values',
        'List response fields that hold their default (0, "", false, empty '
            'lists), which protobuf does not send.',
        '"count": 0',
        _cfg.emitDefaults,
        (v) => _set(() => _cfg.emitDefaults = v),
      ),
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 6,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: _label(
                'Deadline (ms)',
                'Give up with DEADLINE_EXCEEDED if the call takes longer. '
                    'Empty waits as long as the server takes.',
              ),
            ),
            SizedBox(
              width: 140,
              child: TextField(
                controller: _deadline,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  hintText: 'None',
                  isDense: true,
                  suffixIcon: HelpTip(
                    'Milliseconds the whole call may take, streams included.',
                    title: 'Deadline',
                    example: '5000',
                  ),
                  suffixIconConstraints: BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                ),
                onChanged: (v) {
                  _cfg.deadlineMs = int.tryParse(v) ?? 0;
                  _save();
                },
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _label(String title, String subtitle) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: const TextStyle(fontSize: 13.5)),
      const SizedBox(height: 2),
      Text(
        subtitle,
        style: TextStyle(fontSize: 11.5, height: 1.3, color: Palette.textDim),
      ),
    ],
  );

  Widget _toggle(
    String title,
    String subtitle,
    String example,
    bool value,
    ValueChanged<bool>? onChanged,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(child: _label(title, subtitle)),
        HelpHover(
          subtitle,
          title: title,
          example: example,
          child: Switch(value: value, onChanged: onChanged),
        ),
      ],
    ),
  );
}

/// A compact dropdown that works at phone widths: the label shrinks with
/// an ellipsis instead of overflowing.
class _Picker extends StatelessWidget {
  const _Picker({
    required this.label,
    required this.items,
    required this.onSelected,
    required this.enabled,
    required this.maxWidth,
    required this.help,
    required this.helpTitle,
    required this.example,
  });

  final String label;
  final List<PopupMenuEntry<String>> items;
  final ValueChanged<String> onSelected;
  final bool enabled;
  final double maxWidth;
  final String help;
  final String helpTitle;
  final String example;

  @override
  Widget build(BuildContext context) => HelpHover(
    enabled ? help : '$help Load the services first (the reload button).',
    title: helpTitle,
    example: example,
    child: PopupMenuButton<String>(
      enabled: enabled,
      tooltip: '',
      onSelected: onSelected,
      itemBuilder: (_) => items,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          minHeight: isTouch(context) ? minTouchTarget : 36,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Palette.surfaceAlt,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Palette.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: enabled ? Palette.text : Palette.textDim,
                ),
              ),
            ),
            Icon(
              Icons.arrow_drop_down,
              size: 20,
              color: enabled ? Palette.text : Palette.textDim,
            ),
          ],
        ),
      ),
    ),
  );
}

class _MethodItem extends StatelessWidget {
  const _MethodItem({required this.method});

  final MethodDescriptor method;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(method.name, overflow: TextOverflow.ellipsis),
      Text(
        '${method.kind.label} · ${method.input.name} → ${method.output.name}',
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11.5, color: Palette.textDim),
      ),
    ],
  );
}

/// Live message log of a gRPC tab: a timeline of sent and received
/// messages, metadata and the final status.
class GrpcMessages extends StatefulWidget {
  const GrpcMessages({super.key, required this.tab});

  final RequestTab tab;

  @override
  State<GrpcMessages> createState() => _GrpcMessagesState();
}

class _GrpcMessagesState extends State<GrpcMessages> {
  late final GrpcTabSession _session;
  final _scroll = ScrollController();
  int _seen = 0;

  @override
  void initState() {
    super.initState();
    _session = GrpcTabSession.of(widget.tab)..addListener(_changed);
    _seen = _session.events.length;
  }

  @override
  void dispose() {
    _session.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }

  /// Follows new events while the list is scrolled to its end.
  void _changed() {
    if (!mounted) return;
    final grew = _session.events.length > _seen;
    final atEnd =
        !_scroll.hasClients ||
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 40;
    _seen = _session.events.length;
    setState(() {});
    if (grew && atEnd) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final events = _session.events;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
          child: SizedBox(width: double.infinity, child: _header()),
        ),
        Divider(height: 1, color: Palette.border),
        Expanded(
          child: events.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Invoke a method to see its messages, metadata and '
                      'status here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Palette.textDim),
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                  itemCount: events.length,
                  itemBuilder: (_, i) => _EventTile(event: events[i]),
                ),
        ),
      ],
    );
  }

  Widget _header() {
    final status = _session.status;
    final call = _session.call;
    final active = _session.active;
    String? lastReceived;
    for (final e in _session.events.reversed) {
      if (e.kind == GrpcEventKind.received) {
        lastReceived = e.body;
        break;
      }
    }
    return Wrap(
      spacing: 10,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (active)
          HelpHover(
            _session.canSend
                ? 'The call is open: send more messages, or End stream.'
                : 'Waiting for the server to finish.',
            title: 'Call in progress',
            child: Chip(
              avatar: const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              label: Text(_session.canSend ? 'Streaming' : 'Waiting'),
              visualDensity: VisualDensity.compact,
            ),
          )
        else if (status != null)
          HelpHover(
            _statusHelp(status),
            title: '${status.code} ${status.name}',
            example: status.message.isEmpty ? null : status.message,
            child: Chip(
              label: Text(
                status.name,
                style: TextStyle(
                  color: status.ok ? Palette.success : Palette.danger,
                  fontWeight: FontWeight.w700,
                ),
              ),
              visualDensity: VisualDensity.compact,
              side: BorderSide(
                color: (status.ok ? Palette.success : Palette.danger)
                    .withValues(alpha: 0.5),
              ),
            ),
          )
        else
          Text(
            'Response',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Palette.textDim,
            ),
          ),
        if (call != null)
          HelpHover(
            'Messages sent and received in this call.',
            title: 'Message count',
            example: '1 sent · 3 received',
            child: Text(
              '${call.sentCount} sent · ${call.receivedCount} received',
              style: TextStyle(fontSize: 12, color: Palette.textDim),
            ),
          ),
        if (lastReceived != null)
          HelpHover(
            'Copy the last response message as JSON.',
            title: 'Copy response',
            child: IconButton(
              icon: const Icon(Icons.copy, size: 17),
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: lastReceived!)),
            ),
          ),
        if (_session.events.isNotEmpty)
          HelpHover(
            'Empty the timeline. A call in progress keeps running.',
            title: 'Clear',
            child: TextButton.icon(
              onPressed: _session.clear,
              icon: const Icon(Icons.clear_all, size: 17),
              label: const Text('Clear'),
            ),
          ),
      ],
    );
  }

  static String _statusHelp(GrpcStatus s) => switch (s.code) {
    0 => 'The call finished successfully.',
    1 => 'The call was cancelled before it finished.',
    3 => 'The server rejected the request message as invalid.',
    4 => 'The deadline passed before the call finished.',
    5 => 'The server could not find what was asked for.',
    7 => 'The caller is not allowed to do this.',
    12 => 'The server does not implement this method.',
    13 => 'Something broke on the server.',
    14 =>
      'The server could not be reached, or dropped the connection. Check '
          'the address and the TLS setting.',
    16 => 'Missing or invalid credentials; check the metadata.',
    _ => 'The gRPC status the call ended with.',
  };
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});

  final GrpcEvent event;

  @override
  Widget build(BuildContext context) {
    final ok = event.status?.ok ?? false;
    final (icon, color, help) = switch (event.kind) {
      GrpcEventKind.sent => (
        Icons.north_east,
        Palette.accent,
        'A request message this app sent.',
      ),
      GrpcEventKind.received => (
        Icons.south_west,
        Palette.success,
        'A response message from the server.',
      ),
      GrpcEventKind.headers => (
        Icons.list_alt,
        Palette.textDim,
        'Metadata sent at the start of the call.',
      ),
      GrpcEventKind.trailers => (
        Icons.playlist_add_check,
        Palette.textDim,
        'Metadata the server sent after its last message.',
      ),
      GrpcEventKind.status => (
        ok ? Icons.check_circle : Icons.cancel,
        ok ? Palette.success : Palette.danger,
        'The status the call ended with.',
      ),
      GrpcEventKind.error => (
        Icons.error_outline,
        Palette.danger,
        'Something went wrong before or during the call.',
      ),
      GrpcEventKind.info => (
        Icons.info_outline,
        Palette.textDim,
        'What the call is doing.',
      ),
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Palette.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              HelpHover(
                help,
                title: event.title,
                child: Icon(icon, size: 16, color: color),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  event.title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
              if (event.size != null)
                Text(
                  '${event.size} B · ',
                  style: TextStyle(fontSize: 11.5, color: Palette.textDim),
                ),
              HelpHover(
                'Time since Invoke was pressed.',
                title: 'Elapsed',
                example: '+120 ms',
                child: Text(
                  '+${event.elapsed.inMilliseconds} ms',
                  style: TextStyle(fontSize: 11.5, color: Palette.textDim),
                ),
              ),
              if (event.body != null)
                IconButton(
                  tooltip: 'Copy',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy, size: 15),
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: event.body!)),
                ),
            ],
          ),
          if (event.body != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 4),
              child: SelectableText(
                event.body!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
              ),
            ),
        ],
      ),
    );
  }
}
