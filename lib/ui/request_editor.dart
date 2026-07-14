import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/curl.dart' as curl;
import '../state/app_state.dart';
import '../theme.dart';
import 'kv_editor.dart';
import 'runner_screen.dart';

/// The main editor for one request tab. Give it `key: ValueKey(tab.id)` so
/// text controllers reset when the active tab changes.
class RequestEditor extends StatefulWidget {
  const RequestEditor({super.key, required this.tab});

  final RequestTab tab;

  @override
  State<RequestEditor> createState() => _RequestEditorState();
}

class _RequestEditorState extends State<RequestEditor> {
  late final TextEditingController _urlCtrl;
  late final TextEditingController _bodyCtrl;
  late final TextEditingController _gqlVarsCtrl;

  RequestModel get req => widget.tab.request;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(text: req.url);
    _bodyCtrl = TextEditingController(text: req.body);
    _gqlVarsCtrl = TextEditingController(text: req.graphqlVariables);
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _bodyCtrl.dispose();
    _gqlVarsCtrl.dispose();
    super.dispose();
  }

  void _touch() => context.read<AppState>().touchActive();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: _urlBar(state),
        ),
        Expanded(
          child: DefaultTabController(
            length: 5,
            child: Column(
              children: [
                TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  labelStyle: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                  tabs: [
                    Tab(text: _counted('Params', req.params)),
                    Tab(text: _counted('Headers', req.headers)),
                    Tab(
                        text: req.bodyType == BodyType.none
                            ? 'Body'
                            : 'Body • ${req.bodyType.label}'),
                    Tab(
                        text: req.authType == AuthType.none
                            ? 'Auth'
                            : 'Auth • ${req.authType.label}'),
                    Tab(
                        text: req.assertions.where((a) => a.enabled).isEmpty
                            ? 'Tests'
                            : 'Tests (${req.assertions.where((a) => a.enabled).length})'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      KVEditor(
                        rows: req.params,
                        onChanged: _touch,
                        keyHint: 'Parameter',
                        addLabel: 'Add parameter',
                      ),
                      KVEditor(
                        rows: req.headers,
                        onChanged: _touch,
                        keyHint: 'Header',
                        addLabel: 'Add header',
                      ),
                      _bodyTab(),
                      _authTab(),
                      _testsTab(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _counted(String label, List<KV> rows) {
    final n = rows.where((r) => r.enabled && r.key.isNotEmpty).length;
    return n == 0 ? label : '$label ($n)';
  }

  // ---------------- URL bar ----------------

  Widget _urlBar(AppState state) {
    final loading = widget.tab.loading;
    return Row(
      children: [
        Container(
          decoration: BoxDecoration(
            color: Palette.surfaceAlt,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Palette.border),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: req.method,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              borderRadius: BorderRadius.circular(8),
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: methodColor(req.method),
              ),
              items: [
                for (final m in httpMethods)
                  DropdownMenuItem(
                    value: m,
                    child: Text(m,
                        style: TextStyle(
                            color: methodColor(m),
                            fontWeight: FontWeight.w700)),
                  ),
              ],
              onChanged: (m) {
                if (m != null) {
                  req.method = m;
                  _touch();
                }
              },
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _urlCtrl,
            style: const TextStyle(fontSize: 13.5, fontFamily: 'monospace'),
            decoration: const InputDecoration(
                hintText: 'https://api.example.com/v1/users  —  {{vars}} allowed'),
            onChanged: (v) {
              req.url = v;
              _touch();
            },
            onSubmitted: (_) => state.sendActive(),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: loading ? Palette.delete : Palette.accent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          ),
          onPressed: loading ? state.cancelActive : state.sendActive,
          icon: Icon(loading ? Icons.stop : Icons.send, size: 16),
          label: Text(loading ? 'Cancel' : 'Send'),
        ),
        const SizedBox(width: 4),
        PopupMenuButton<String>(
          tooltip: 'More',
          icon: const Icon(Icons.more_vert, color: Palette.textDim),
          onSelected: (v) => switch (v) {
            'save' => _saveDialog(state),
            'run' => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => RunnerScreen(
                      title: req.name == 'Untitled request' && req.url.isNotEmpty
                          ? req.url
                          : req.name,
                      requests: [req.clone()]),
                )),
            'copy_curl' => _copyCurl(),
            'import_curl' => _importCurl(state),
            _ => null,
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'save', child: Text('Save to collection…')),
            PopupMenuItem(
                value: 'run', child: Text('Run repeatedly / on interval…')),
            PopupMenuItem(value: 'copy_curl', child: Text('Copy as cURL')),
            PopupMenuItem(value: 'import_curl', child: Text('Import cURL…')),
          ],
        ),
      ],
    );
  }

  void _copyCurl() {
    Clipboard.setData(ClipboardData(text: curl.toCurl(req)));
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('cURL command copied to clipboard')));
  }

  Future<void> _importCurl(AppState state) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import cURL'),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: ctrl,
            maxLines: 8,
            autofocus: true,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
            decoration:
                const InputDecoration(hintText: "curl -X POST 'https://…'"),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Import')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final parsed = curl.fromCurl(ctrl.text);
    if (parsed == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not parse that cURL command.')));
      return;
    }
    state.newTab(parsed);
  }

  Future<void> _saveDialog(AppState state) async {
    final nameCtrl = TextEditingController(text: req.name);
    final newColCtrl = TextEditingController();
    String? selectedId = widget.tab.sourceCollectionId ??
        (state.collections.isNotEmpty ? state.collections.first.id : null);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Save request'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  decoration:
                      const InputDecoration(labelText: 'Request name'),
                ),
                const SizedBox(height: 16),
                if (state.collections.isNotEmpty) ...[
                  DropdownButtonFormField<String>(
                    initialValue: selectedId,
                    decoration:
                        const InputDecoration(labelText: 'Collection'),
                    items: [
                      for (final c in state.collections)
                        DropdownMenuItem(value: c.id, child: Text(c.name)),
                    ],
                    onChanged: (v) => setLocal(() => selectedId = v),
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: newColCtrl,
                  decoration: InputDecoration(
                    labelText: state.collections.isEmpty
                        ? 'New collection name'
                        : 'Or create a new collection',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;

    CollectionModel? target;
    if (newColCtrl.text.trim().isNotEmpty) {
      target = state.addCollection(newColCtrl.text.trim());
    } else {
      for (final c in state.collections) {
        if (c.id == selectedId) target = c;
      }
    }
    if (target == null) return;
    state.saveActiveTo(target, name: nameCtrl.text.trim());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved to "${target.name}"')));
    }
  }

  // ---------------- Body tab ----------------

  Widget _bodyTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final t in BodyType.values)
                      ChoiceChip(
                        label: Text(t.label,
                            style: const TextStyle(fontSize: 12)),
                        selected: req.bodyType == t,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) {
                          setState(() => req.bodyType = t);
                          _touch();
                        },
                      ),
                  ],
                ),
              ),
              if (req.bodyType == BodyType.json)
                TextButton(
                  onPressed: _beautifyJson,
                  child: const Text('Beautify'),
                ),
            ],
          ),
        ),
        Expanded(
          child: switch (req.bodyType) {
            BodyType.none => const Center(
                child: Text('This request has no body',
                    style: TextStyle(color: Palette.textDim))),
            BodyType.formUrlEncoded => KVEditor(
                rows: req.formFields,
                onChanged: _touch,
                keyHint: 'Field',
                addLabel: 'Add field',
              ),
            BodyType.graphql => Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _bodyCtrl,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 13),
                        decoration: const InputDecoration(
                            hintText:
                                'query Users(\$limit: Int) {\n  users(limit: \$limit) { id name }\n}'),
                        onChanged: (v) {
                          req.body = v;
                          _touch();
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _gqlVarsCtrl,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 13),
                        decoration: const InputDecoration(
                            hintText: 'Variables (JSON): {"limit": 10}'),
                        onChanged: (v) {
                          req.graphqlVariables = v;
                          _touch();
                        },
                      ),
                    ),
                  ],
                ),
              ),
            _ => Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  controller: _bodyCtrl,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  decoration: InputDecoration(
                    hintText: req.bodyType == BodyType.json
                        ? '{\n  "key": "value"\n}'
                        : 'Raw request body',
                  ),
                  onChanged: (v) {
                    req.body = v;
                    _touch();
                  },
                ),
              ),
          },
        ),
      ],
    );
  }

  void _beautifyJson() {
    final pretty = _tryFormat(req.body);
    if (pretty == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Body is not valid JSON')));
      return;
    }
    setState(() {
      req.body = pretty;
      _bodyCtrl.text = pretty;
    });
    _touch();
  }

  // ---------------- Auth tab ----------------

  Widget _authTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SizedBox(
          width: 260,
          child: DropdownButtonFormField<AuthType>(
            initialValue: req.authType,
            decoration: const InputDecoration(labelText: 'Auth type'),
            items: [
              for (final t in AuthType.values)
                DropdownMenuItem(value: t, child: Text(t.label)),
            ],
            onChanged: (t) {
              if (t != null) {
                setState(() => req.authType = t);
                _touch();
              }
            },
          ),
        ),
        const SizedBox(height: 16),
        ...switch (req.authType) {
          AuthType.none => [
              const Text('No authentication will be applied.',
                  style: TextStyle(color: Palette.textDim)),
            ],
          AuthType.bearer => [
              _authField('Token', req.bearerToken, (v) => req.bearerToken = v,
                  obscure: true),
            ],
          AuthType.basic => [
              _authField('Username', req.basicUser, (v) => req.basicUser = v),
              const SizedBox(height: 12),
              _authField(
                  'Password', req.basicPassword, (v) => req.basicPassword = v,
                  obscure: true),
            ],
          AuthType.apiKey => [
              _authField(
                  'Key name', req.apiKeyName, (v) => req.apiKeyName = v),
              const SizedBox(height: 12),
              _authField('Value', req.apiKeyValue, (v) => req.apiKeyValue = v,
                  obscure: true),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Header')),
                  ButtonSegment(value: false, label: Text('Query param')),
                ],
                selected: {req.apiKeyInHeader},
                onSelectionChanged: (s) {
                  setState(() => req.apiKeyInHeader = s.first);
                  _touch();
                },
              ),
            ],
        },
      ],
    );
  }

  // ---------------- Tests tab ----------------

  Widget _testsTab() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (req.assertions.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 10, left: 4),
            child: Text(
              'Tests run automatically after every send — and in the collection '
              'runner. Example JSON path: data.items[0].id',
              style: TextStyle(color: Palette.textDim, fontSize: 12.5),
            ),
          ),
        for (final a in req.assertions) _assertionRow(a),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () {
              setState(() => req.assertions.add(AssertionModel()));
              _touch();
            },
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add test'),
          ),
        ),
      ],
    );
  }

  Widget _assertionRow(AssertionModel a) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Checkbox(
            value: a.enabled,
            visualDensity: VisualDensity.compact,
            onChanged: (v) {
              setState(() => a.enabled = v ?? true);
              _touch();
            },
          ),
          SizedBox(
            width: 180,
            child: DropdownButtonFormField<AssertKind>(
              initialValue: a.kind,
              style: const TextStyle(fontSize: 12.5, color: Palette.text),
              items: [
                for (final k in AssertKind.values)
                  DropdownMenuItem(value: k, child: Text(k.label)),
              ],
              onChanged: (k) {
                if (k != null) {
                  setState(() => a.kind = k);
                  _touch();
                }
              },
            ),
          ),
          const SizedBox(width: 8),
          if (a.kind.hasTarget) ...[
            Expanded(
              flex: 2,
              child: TextFormField(
                key: ValueKey('t-${a.hashCode}'),
                initialValue: a.target,
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                decoration: InputDecoration(
                  hintText: a.kind == AssertKind.jsonEquals
                      ? 'JSON path'
                      : 'Header name',
                ),
                onChanged: (v) {
                  a.target = v;
                  _touch();
                },
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            flex: 2,
            child: TextFormField(
              key: ValueKey('x-${a.hashCode}'),
              initialValue: a.expected,
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
              decoration: InputDecoration(
                hintText: switch (a.kind) {
                  AssertKind.statusEquals => '200',
                  AssertKind.timeBelow => '1500',
                  AssertKind.headerContains => 'value (empty = just exists)',
                  _ => 'Expected value',
                },
              ),
              onChanged: (v) {
                a.expected = v;
                _touch();
              },
            ),
          ),
          IconButton(
            tooltip: 'Remove test',
            icon: const Icon(Icons.close, size: 16, color: Palette.textDim),
            onPressed: () {
              setState(() => req.assertions.remove(a));
              _touch();
            },
          ),
        ],
      ),
    );
  }

  Widget _authField(String label, String value, ValueChanged<String> onChanged,
      {bool obscure = false}) {
    return SizedBox(
      width: 420,
      child: TextFormField(
        initialValue: value,
        obscureText: obscure,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(labelText: label),
        onChanged: (v) {
          onChanged(v);
          _touch();
        },
      ),
    );
  }
}

String? _tryFormat(String raw) {
  try {
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
  } catch (_) {
    return null;
  }
}
