import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/captures.dart';
import '../services/curl.dart' as curl;
import '../state/app_state.dart';
import '../theme.dart';
import 'kv_editor.dart';
import 'load_test_screen.dart';
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
  late final TextEditingController _capturesCtrl;
  late final TextEditingController _descCtrl;

  RequestModel get req => widget.tab.request;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(text: req.url);
    _bodyCtrl = TextEditingController(text: req.body);
    _gqlVarsCtrl = TextEditingController(text: req.graphqlVariables);
    _capturesCtrl = TextEditingController(text: captureText(req.captures));
    _descCtrl = TextEditingController(text: req.description);
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _bodyCtrl.dispose();
    _gqlVarsCtrl.dispose();
    _capturesCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  void _touch() => context.read<AppState>().touchActive();

  void _send(AppState state) {
    FocusManager.instance.primaryFocus?.unfocus();
    state.sendActive();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final editor = Column(
      children: [
        _breadcrumb(state),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: _urlBar(state),
        ),
        Expanded(
          child: DefaultTabController(
            length: 7,
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
                    Tab(text: _counted('Params', req.params)),
                    Tab(text: _counted('Headers', req.headers)),
                    Tab(
                      text: req.bodyType == BodyType.none
                          ? 'Body'
                          : 'Body • ${req.bodyType.label}',
                    ),
                    Tab(
                      text: req.authType == AuthType.none
                          ? 'Auth'
                          : 'Auth • ${req.authType.label}',
                    ),
                    Tab(
                      text: req.assertions.where((a) => a.enabled).isEmpty
                          ? 'Tests'
                          : 'Tests (${req.assertions.where((a) => a.enabled).length})',
                    ),
                    Tab(
                      text: req.captures.isEmpty
                          ? 'Captures'
                          : 'Captures (${req.captures.length})',
                    ),
                    Tab(
                      text:
                          req.preRequestScript.isNotEmpty ||
                              req.testScript.isNotEmpty
                          ? 'Docs •'
                          : 'Docs',
                    ),
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
                      _capturesTab(),
                      _docsTab(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxHeight >= 280) return editor;
        return SingleChildScrollView(
          child: SizedBox(height: 360, child: editor),
        );
      },
    );
  }

  String _counted(String label, List<KV> rows) {
    final n = rows.where((r) => r.enabled && r.key.isNotEmpty).length;
    return n == 0 ? label : '$label ($n)';
  }

  // ---------------- URL bar ----------------

  Widget _urlBar(AppState state) {
    final loading = widget.tab.loading;
    final methodPicker = Container(
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
            if (m != null) {
              req.method = m;
              _touch();
            }
          },
        ),
      ),
    );
    final urlField = TextField(
      controller: _urlCtrl,
      keyboardType: TextInputType.url,
      autocorrect: false,
      enableSuggestions: false,
      textInputAction: TextInputAction.go,
      style: const TextStyle(fontSize: 13.5, fontFamily: 'monospace'),
      decoration: const InputDecoration(
        hintText: 'https://api.example.com/v1/users  —  {{vars}} allowed',
      ),
      onChanged: (v) {
        req.url = v;
        _touch();
      },
      onSubmitted: (_) => _send(state),
    );
    final sendButton = FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: loading ? Palette.delete : Palette.accent,
        foregroundColor: loading ? Colors.white : Palette.onAccent,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
      onPressed: loading ? state.cancelActive : () => _send(state),
      icon: Icon(loading ? Icons.stop : Icons.send, size: 16),
      label: Text(loading ? 'Cancel' : 'Send'),
    );
    final moreButton = PopupMenuButton<String>(
      tooltip: 'More',
      icon: Icon(Icons.more_vert, color: Palette.textDim),
      onSelected: (v) => switch (v) {
        'save' => _saveDialog(state),
        'run' => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => RunnerScreen(
              title: req.name == 'Untitled request' && req.url.isNotEmpty
                  ? req.url
                  : req.name,
              requests: [req.clone()],
              collectionId: widget.tab.sourceCollectionId,
            ),
          ),
        ),
        'load' => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => LoadTestScreen(
              title: req.name == 'Untitled request' && req.url.isNotEmpty
                  ? req.url
                  : req.name,
              requests: [req.clone()],
              collectionId: widget.tab.sourceCollectionId,
            ),
          ),
        ),
        'copy_curl' => _copyCurl(),
        'import_curl' => _importCurl(state),
        _ => null,
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'save', child: Text('Save to collection…')),
        PopupMenuItem(
          value: 'run',
          child: Text('Run repeatedly / on interval…'),
        ),
        PopupMenuItem(
          value: 'load',
          child: Text('Load test (parallel calls)…'),
        ),
        PopupMenuItem(value: 'copy_curl', child: Text('Copy as cURL')),
        PopupMenuItem(value: 'import_curl', child: Text('Import cURL…')),
      ],
    );
    // Measure the editor, not the window: a side panel can make the editor
    // narrow even when the window is wide.
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth >= 560) {
          return Row(
            children: [
              methodPicker,
              const SizedBox(width: 8),
              Expanded(child: urlField),
              const SizedBox(width: 8),
              sendButton,
              const SizedBox(width: 4),
              moreButton,
            ],
          );
        }
        return Column(
          children: [
            SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                runSpacing: 8,
                children: [
                  methodPicker,
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [sendButton, moreButton],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(width: double.infinity, child: urlField),
          ],
        );
      },
    );
  }

  void _copyCurl() {
    Clipboard.setData(ClipboardData(text: curl.toCurl(req)));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('cURL command copied to clipboard')),
    );
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
            decoration: const InputDecoration(
              hintText: "curl -X POST 'https://…'",
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    final input = ctrl.text;
    ctrl.dispose();
    if (ok != true || !mounted) return;
    final parsed = curl.fromCurl(input);
    if (parsed == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not parse that cURL command.')),
      );
      return;
    }
    state.newTab(parsed);
  }

  Future<void> _saveDialog(AppState state) async {
    final nameCtrl = TextEditingController(text: req.name);
    final newColCtrl = TextEditingController();
    String? selectedId =
        widget.tab.sourceCollectionId ??
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
                  decoration: const InputDecoration(labelText: 'Request name'),
                ),
                const SizedBox(height: 16),
                if (state.collections.isNotEmpty) ...[
                  DropdownButtonFormField<String>(
                    initialValue: selectedId,
                    decoration: const InputDecoration(labelText: 'Collection'),
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
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    final collectionName = newColCtrl.text.trim();
    final requestName = nameCtrl.text.trim();
    nameCtrl.dispose();
    newColCtrl.dispose();
    if (ok != true || !mounted) return;

    CollectionModel? target;
    if (collectionName.isNotEmpty) {
      target = state.addCollection(collectionName);
    } else {
      for (final c in state.collections) {
        if (c.id == selectedId) target = c;
      }
    }
    if (target == null) return;
    state.saveActiveTo(target, name: requestName);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved to "${target.name}"')));
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
                        label: Text(
                          t.label,
                          style: const TextStyle(fontSize: 12),
                        ),
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
            BodyType.none => Center(
              child: Text(
                'This request has no body',
                style: TextStyle(color: Palette.textDim),
              ),
            ),
            BodyType.formUrlEncoded => KVEditor(
              rows: req.formFields,
              onChanged: _touch,
              keyHint: 'Field',
              addLabel: 'Add field',
            ),
            BodyType.formData => KVEditor(
              key: const ValueKey('form-data'),
              rows: req.formFields,
              onChanged: _touch,
              keyHint: 'Field',
              addLabel: 'Add field',
              allowFiles: true,
            ),
            BodyType.binary => _binaryBody(),
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
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                      decoration: const InputDecoration(
                        hintText:
                            'query Users(\$limit: Int) {\n  users(limit: \$limit) { id name }\n}',
                      ),
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
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                      decoration: const InputDecoration(
                        hintText: 'Variables (JSON): {"limit": 10}',
                      ),
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
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Body is not valid JSON')));
      return;
    }
    setState(() {
      req.body = pretty;
      _bodyCtrl.text = pretty;
    });
    _touch();
  }

  Widget _binaryBody() => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _bodyCtrl,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Path of the file to send as the body',
                  prefixIcon: Icon(
                    Icons.insert_drive_file_outlined,
                    size: 17,
                    color: Palette.textDim,
                  ),
                ),
                onChanged: (v) {
                  req.body = v;
                  _touch();
                },
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () async {
                final picked = await FilePicker.platform.pickFiles(
                  dialogTitle: 'Choose the body file',
                );
                final path = picked?.files.singleOrNull?.path;
                if (path == null || !mounted) return;
                setState(() {
                  req.body = path;
                  _bodyCtrl.text = path;
                });
                _touch();
              },
              icon: const Icon(Icons.folder_open_outlined, size: 17),
              label: const Text('Choose file'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'The file is sent as-is with Content-Type application/octet-stream '
          'unless you set one in Headers.',
          style: TextStyle(fontSize: 12, color: Palette.textDim),
        ),
      ],
    ),
  );

  // ---------------- Breadcrumb ----------------

  Widget _breadcrumb(AppState state) {
    final col = state.collectionById(widget.tab.sourceCollectionId);
    final segs = [
      if (col != null) col.name,
      if (col != null && req.folder.isNotEmpty) ...req.folder.split('/'),
    ];
    final dim = TextStyle(fontSize: 12.5, color: Palette.textDim);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 2),
      child: Row(
        children: [
          Icon(
            col == null ? Icons.edit_note : Icons.folder_outlined,
            size: 16,
            color: Palette.textDim,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Row(
              children: [
                for (final s in segs) ...[
                  Flexible(
                    child: Text(s, overflow: TextOverflow.ellipsis, style: dim),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(
                      Icons.chevron_right,
                      size: 15,
                      color: Palette.textDim,
                    ),
                  ),
                ],
                Flexible(
                  flex: 2,
                  child: Tooltip(
                    message: 'Rename',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () => _rename(state),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 2,
                          vertical: 2,
                        ),
                        child: Text(
                          req.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: Palette.text,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (widget.tab.dirty)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Tooltip(
                      message: 'Unsaved changes',
                      child: Icon(
                        Icons.circle,
                        size: 7,
                        color: Palette.warning,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: () => saveOrAsk(state),
            icon: const Icon(Icons.save_outlined, size: 16),
            label: Text(col == null ? 'Save…' : 'Save'),
          ),
        ],
      ),
    );
  }

  /// Saves into the request's collection, or asks where when it has none.
  void saveOrAsk(AppState state) {
    final col = state.collectionById(widget.tab.sourceCollectionId);
    if (col == null) {
      _saveDialog(state);
      return;
    }
    state.saveActiveTo(col);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Saved to "${col.name}"')));
  }

  Future<void> _rename(AppState state) async {
    final ctrl = TextEditingController(text: req.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename request'),
        content: SizedBox(
          width: 380,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    setState(() => req.name = name);
    _touch();
  }

  // ---------------- Captures tab ----------------

  Widget _capturesTab() => ListView(
    padding: const EdgeInsets.all(14),
    children: [
      Text(
        'Save values from each successful response into variables that '
        'later requests can use as {{name}}. One per line:',
        style: TextStyle(fontSize: 12.5, color: Palette.textDim, height: 1.45),
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _capturesCtrl,
        minLines: 4,
        maxLines: 12,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        decoration: const InputDecoration(
          hintText:
              'token = body.data.token\nuserId = data.user.id\n'
              'etag = header.ETag\ncode = status',
        ),
        onChanged: (v) {
          req.captures = parseCaptureText(v);
          _touch();
        },
      ),
      const SizedBox(height: 10),
      Text(
        'Values go to the active environment, or to the collection\'s '
        'variables when no environment is selected. The runner and load '
        'tester pass them between requests of the same run.',
        style: TextStyle(fontSize: 12, color: Palette.textDim, height: 1.45),
      ),
    ],
  );

  // ---------------- Docs tab ----------------

  Widget _docsTab() => ListView(
    padding: const EdgeInsets.all(14),
    children: [
      TextField(
        controller: _descCtrl,
        minLines: 4,
        maxLines: 14,
        style: const TextStyle(fontSize: 13.5, height: 1.45),
        decoration: const InputDecoration(
          labelText: 'Description',
          alignLabelWithHint: true,
          hintText: 'What this request does, parameters, examples…',
        ),
        onChanged: (v) {
          req.description = v;
          _touch();
        },
      ),
      if (req.preRequestScript.isNotEmpty)
        _scriptBlock('Pre-request script', req.preRequestScript),
      if (req.testScript.isNotEmpty)
        _scriptBlock('Test script', req.testScript),
    ],
  );

  Widget _scriptBlock(String title, String code) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: Container(
      decoration: BoxDecoration(
        border: Border.all(color: Palette.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ExpansionTile(
        shape: const Border(),
        dense: true,
        leading: Icon(Icons.code, size: 18, color: Palette.textDim),
        title: Text(title, style: const TextStyle(fontSize: 13)),
        subtitle: Text(
          'Imported from Postman, kept for reference. ApiWorkbench does not '
          'run JavaScript; recognised checks were added to Tests and Captures.',
          style: TextStyle(fontSize: 11.5, color: Palette.textDim),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Palette.surfaceAlt,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(
              code,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ],
      ),
    ),
  );

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
            Text(
              'No authentication will be applied.',
              style: TextStyle(color: Palette.textDim),
            ),
          ],
          AuthType.bearer => [
            _authField(
              'Token',
              req.bearerToken,
              (v) => req.bearerToken = v,
              obscure: true,
            ),
          ],
          AuthType.basic => [
            _authField('Username', req.basicUser, (v) => req.basicUser = v),
            const SizedBox(height: 12),
            _authField(
              'Password',
              req.basicPassword,
              (v) => req.basicPassword = v,
              obscure: true,
            ),
          ],
          AuthType.apiKey => [
            _authField('Key name', req.apiKeyName, (v) => req.apiKeyName = v),
            const SizedBox(height: 12),
            _authField(
              'Value',
              req.apiKeyValue,
              (v) => req.apiKeyValue = v,
              obscure: true,
            ),
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
          Padding(
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
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: (MediaQuery.sizeOf(context).width - 48).clamp(600.0, 1000.0),
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
                  style: TextStyle(fontSize: 12.5, color: Palette.text),
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
                    style: const TextStyle(
                      fontSize: 13,
                      fontFamily: 'monospace',
                    ),
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
                      AssertKind.headerContains =>
                        'value (empty = just exists)',
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
                icon: Icon(Icons.close, size: 16, color: Palette.textDim),
                onPressed: () {
                  setState(() => req.assertions.remove(a));
                  _touch();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _authField(
    String label,
    String value,
    ValueChanged<String> onChanged, {
    bool obscure = false,
  }) {
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
