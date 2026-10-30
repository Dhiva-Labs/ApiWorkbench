import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../adaptive.dart';
import '../help_tip.dart';
import '../json_view.dart';
import '../kv_editor.dart';

/// Standard reason phrases, to keep the status text in step with the code.
const _reasons = {
  200: 'OK',
  201: 'Created',
  202: 'Accepted',
  204: 'No Content',
  301: 'Moved Permanently',
  302: 'Found',
  304: 'Not Modified',
  307: 'Temporary Redirect',
  308: 'Permanent Redirect',
  400: 'Bad Request',
  401: 'Unauthorized',
  403: 'Forbidden',
  404: 'Not Found',
  405: 'Method Not Allowed',
  409: 'Conflict',
  410: 'Gone',
  415: 'Unsupported Media Type',
  418: "I'm a teapot",
  422: 'Unprocessable Entity',
  429: 'Too Many Requests',
  500: 'Internal Server Error',
  501: 'Not Implemented',
  502: 'Bad Gateway',
  503: 'Service Unavailable',
  504: 'Gateway Timeout',
};

enum _BodyMode { pretty, raw }

/// Opens a saved example for viewing and editing. Changes are written into
/// [request] (the collection's own copy) when the user saves, and into any
/// open tab of the same request so a later save of that tab keeps them.
Future<void> showExampleEditor(
  BuildContext context,
  AppState state,
  CollectionModel collection,
  RequestModel request,
  ResponseExample example,
) => showDialog<void>(
  context: context,
  builder: (_) => ExampleDialog(
    state: state,
    collection: collection,
    request: request,
    example: example,
  ),
);

/// The example viewer and editor: a dialog on desktop, a full screen on
/// phones.
class ExampleDialog extends StatefulWidget {
  const ExampleDialog({
    super.key,
    required this.state,
    required this.collection,
    required this.request,
    required this.example,
  });

  final AppState state;
  final CollectionModel collection;
  final RequestModel request;
  final ResponseExample example;

  @override
  State<ExampleDialog> createState() => _ExampleDialogState();
}

class _ExampleDialogState extends State<ExampleDialog> {
  late final _name = TextEditingController(text: widget.example.name);
  late final _code = TextEditingController(
    text: widget.example.statusCode.toString(),
  );
  late final _text = TextEditingController(text: widget.example.statusText);
  late final _body = TextEditingController(text: widget.example.body);
  late final List<KV> _headers = [
    for (final h in widget.example.headers) h.clone(),
  ];
  late _BodyMode _mode =
      widget.example.body.isNotEmpty &&
          JsonView.tryPretty(widget.example.body) != null
      ? _BodyMode.pretty
      : _BodyMode.raw;
  bool _dirty = false;
  String? _codeError;

  AppState get state => widget.state;
  ResponseExample get example => widget.example;

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    _text.dispose();
    _body.dispose();
    super.dispose();
  }

  void _changed() => setState(() => _dirty = true);

  /// The status code typed, or null when it is not 100-599.
  int? get _parsedCode {
    final n = int.tryParse(_code.text.trim());
    return n != null && n >= 100 && n <= 599 ? n : null;
  }

  void _onCodeChanged(String v) {
    final n = _parsedCode;
    if (n != null) {
      // Keep the phrase in step when it was the standard one for the old code.
      if (_text.text.trim().isEmpty || _text.text == _reasons[_lastCode]) {
        _text.text = _reasons[n] ?? '';
      }
      _lastCode = n;
    }
    setState(() {
      _dirty = true;
      _codeError = null;
    });
  }

  late int _lastCode = widget.example.statusCode;

  /// The edited example, or null (with the error shown) when the status
  /// code is not valid.
  ResponseExample? _draft({bool strict = true}) {
    final code = _parsedCode;
    if (code == null && strict) {
      setState(() => _codeError = 'Use a status code from 100 to 599.');
      return null;
    }
    return ResponseExample(
      id: example.id,
      name: _name.text.trim().isEmpty ? example.name : _name.text.trim(),
      statusCode: code ?? example.statusCode,
      statusText: _text.text.trim(),
      headers: [
        for (final h in _headers)
          if (h.key.trim().isNotEmpty) h.clone(),
      ],
      body: _body.text,
      originalRequest: example.originalRequest,
    );
  }

  List<ResponseExample> get _list => widget.request.examples;

  /// Applies [edit] to the examples of every other open tab of this request.
  void _syncTabs(void Function(List<ResponseExample>) edit) {
    for (final t in state.tabs) {
      if (t.request.id == widget.request.id &&
          !identical(t.request, widget.request)) {
        edit(t.request.examples);
      }
    }
  }

  void _save() {
    final d = _draft();
    if (d == null) return;
    final i = _list.indexWhere((e) => e.id == example.id);
    if (i >= 0) {
      _list[i]
        ..name = d.name
        ..statusCode = d.statusCode
        ..statusText = d.statusText
        ..headers = d.headers
        ..body = d.body;
    } else {
      _list.add(d);
    }
    _syncTabs((list) {
      final j = list.indexWhere((e) => e.id == d.id);
      if (j >= 0) list[j] = d.clone();
    });
    state.updateCollections();
    _dirty = false;
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.pop(context);
    messenger?.showSnackBar(
      SnackBar(content: Text('Example "${d.name}" saved.')),
    );
  }

  void _duplicate() {
    final d = _draft(strict: false)!;
    final copy = d.clone(sameId: false)..name = '${d.name} (copy)';
    final i = _list.indexWhere((e) => e.id == example.id);
    _list.insert(i < 0 ? _list.length : i + 1, copy);
    _syncTabs((list) {
      final j = list.indexWhere((e) => e.id == example.id);
      list.insert(j < 0 ? list.length : j + 1, copy.clone());
    });
    state.updateCollections();
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text('Duplicated as "${copy.name}".')));
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete example?'),
        content: Text(
          '"${example.name}" is removed from ${widget.request.name}. This '
          'cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Palette.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _list.removeWhere((e) => e.id == example.id);
    _syncTabs((list) => list.removeWhere((e) => e.id == example.id));
    state.updateCollections();
    _dirty = false;
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.pop(context);
    messenger?.showSnackBar(
      SnackBar(content: Text('Example "${example.name}" deleted.')),
    );
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('This example has changes that are not saved.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _close() async {
    if (await _confirmDiscard() && mounted) {
      _dirty = false;
      Navigator.pop(context);
    }
  }

  Future<void> _openRequest() async {
    if (!await _confirmDiscard() || !mounted) return;
    state.openRequest(widget.request, collectionId: widget.collection.id);
    _dirty = false;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final phone = isPhoneWidth(context);
    final height = (MediaQuery.sizeOf(context).height - 200).clamp(
      260.0,
      700.0,
    );
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop && await _confirmDiscard() && mounted) {
          _dirty = false;
          if (context.mounted) Navigator.pop(context);
        }
      },
      child: AdaptiveDialog(
        title: Text(example.name, overflow: TextOverflow.ellipsis),
        width: 760,
        height: height,
        contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        primary: FilledButton(
          onPressed: _save,
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 36),
            padding: const EdgeInsets.symmetric(horizontal: 14),
          ),
          child: const Text('Save'),
        ),
        headerActions: [if (phone) _overflowMenu()],
        actions: phone
            ? const []
            : [
                HelpHover(
                  'Open the request this example belongs to in a new tab.',
                  title: 'Open request',
                  child: TextButton.icon(
                    onPressed: _openRequest,
                    icon: const Icon(Icons.open_in_new, size: 17),
                    label: const Text('Open request'),
                  ),
                ),
                HelpHover(
                  'Remove this example from the request. You are asked to '
                  'confirm.',
                  title: 'Delete',
                  child: TextButton.icon(
                    onPressed: _delete,
                    style: TextButton.styleFrom(
                      foregroundColor: Palette.danger,
                    ),
                    icon: const Icon(Icons.delete_outline, size: 17),
                    label: const Text('Delete'),
                  ),
                ),
                HelpHover(
                  'Add a copy of what you see here, including edits not yet '
                  'saved, right after this example.',
                  title: 'Duplicate',
                  child: TextButton.icon(
                    onPressed: _duplicate,
                    icon: const Icon(Icons.copy_outlined, size: 17),
                    label: const Text('Duplicate'),
                  ),
                ),
                TextButton(onPressed: _close, child: const Text('Close')),
                FilledButton(onPressed: _save, child: const Text('Save')),
              ],
        content: _content(),
      ),
    );
  }

  /// Duplicate, Delete and Open request, in one menu to leave the phone's
  /// app bar room for the title.
  Widget _overflowMenu() => PopupMenuButton<String>(
    tooltip: 'More',
    onSelected: (v) => switch (v) {
      'open' => _openRequest(),
      'dup' => _duplicate(),
      _ => _delete(),
    },
    itemBuilder: (_) => const [
      PopupMenuItem(value: 'open', child: Text('Open request')),
      PopupMenuItem(value: 'dup', child: Text('Duplicate')),
      PopupMenuItem(value: 'del', child: Text('Delete')),
    ],
  );

  Widget _content() {
    final orig = example.originalRequest ?? widget.request;
    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _name,
            style: const TextStyle(fontSize: 14),
            decoration: const InputDecoration(
              labelText: 'Name',
              isDense: true,
              suffixIcon: HelpTip(
                'How this example is listed under its request.',
                title: 'Example name',
                example: '201 Created',
              ),
              suffixIconConstraints: BoxConstraints(
                minWidth: 32,
                minHeight: 32,
              ),
            ),
            onChanged: (_) => _changed(),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.start,
            children: [
              SizedBox(
                width: 110,
                child: TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(3),
                  ],
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: statusColor(_parsedCode ?? 0),
                  ),
                  decoration: InputDecoration(
                    labelText: 'Status',
                    isDense: true,
                    errorText: _codeError,
                    errorMaxLines: 3,
                  ),
                  onChanged: _onCodeChanged,
                ),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _text,
                  style: const TextStyle(fontSize: 14),
                  decoration: const InputDecoration(
                    labelText: 'Status text',
                    isDense: true,
                    suffixIcon: HelpTip(
                      'The reason phrase that goes with the code.',
                      title: 'Status text',
                      example: 'Not Found',
                    ),
                    suffixIconConstraints: BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                  ),
                  onChanged: (_) => _changed(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _requestSummary(orig),
          const SizedBox(height: 4),
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              const Tab(text: 'Body'),
              Tab(
                text:
                    'Headers (${_headers.where((h) => h.key.isNotEmpty).length})',
              ),
            ],
          ),
          Expanded(child: TabBarView(children: [_bodyTab(), _headersTab()])),
        ],
      ),
    );
  }

  Widget _requestSummary(RequestModel r) {
    final method = r.kind == RequestKind.http ? r.method : r.kind.badge;
    return HelpHover(
      'The request this response was saved from. Open request goes to the '
      'saved request itself, which may have changed since.',
      title: 'Original request',
      example: 'GET https://api.example.com/users/1',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: methodColor(method).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              method.toUpperCase(),
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: methodColor(method),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              r.url.isEmpty ? '(no URL)' : r.url,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                color: Palette.textDim,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bodyTab() {
    final raw = _mode == _BodyMode.raw;
    final canFormat =
        _body.text.length < 128 * 1024 &&
        JsonView.tryPretty(_body.text) != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              HelpHover(
                'Pretty shows JSON indented and coloured, read-only. Raw is '
                'the text you can edit.',
                title: 'Body view',
                child: SegmentedButton<_BodyMode>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(
                      value: _BodyMode.pretty,
                      label: Text('Pretty'),
                    ),
                    ButtonSegment(value: _BodyMode.raw, label: Text('Raw')),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) => setState(() => _mode = s.first),
                ),
              ),
              if (raw)
                HelpHover(
                  'Re-indent the JSON body so it reads well.',
                  title: 'Format JSON',
                  child: TextButton.icon(
                    onPressed: canFormat
                        ? () {
                            _body.text = JsonView.tryPretty(_body.text)!;
                            _changed();
                          }
                        : null,
                    icon: const Icon(Icons.format_align_left, size: 17),
                    label: const Text('Format JSON'),
                  ),
                ),
              IconButton(
                tooltip: 'Copy body',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.copy, size: 16, color: Palette.textDim),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _body.text));
                  if (!mounted) return;
                  ScaffoldMessenger.maybeOf(
                    context,
                  )?.showSnackBar(const SnackBar(content: Text('Body copied')));
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: raw
              ? TextField(
                  controller: _body,
                  expands: true,
                  maxLines: null,
                  minLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                  decoration: const InputDecoration(
                    hintText: 'Response body',
                    alignLabelWithHint: true,
                  ),
                  onChanged: (_) => _changed(),
                )
              : DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: Palette.border),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SizedBox.expand(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(10),
                      child: _body.text.isEmpty
                          ? Text(
                              'Empty body',
                              style: TextStyle(color: Palette.textDim),
                            )
                          : JsonView(text: _body.text),
                    ),
                  ),
                ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _headersTab() => KVEditor(
    rows: _headers,
    onChanged: _changed,
    keyHint: 'Header',
    addLabel: 'Add header',
    keyHelp: 'The response header name.',
    keyExample: 'Content-Type',
    valueHelp: 'The header value as the server sent it.',
    valueExample: 'application/json',
  );
}
