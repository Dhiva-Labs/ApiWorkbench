import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/captures.dart';
import '../services/curl.dart' as curl;
import '../state/app_state.dart';
import '../theme.dart';
import 'adaptive.dart';
import 'help_tip.dart';
import 'kv_editor.dart';
import 'load_test_screen.dart';
import 'runner_screen.dart';
import 'tab_memory.dart';

/// Which editor tab (Params, Headers, Body…) each request tab shows, kept
/// when the editor is rebuilt: switching request tabs, or Request and
/// Response on phones.
final _selectedTab = Expando<int>('editor tab');

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
    _chipScroll.dispose();
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
            initialIndex: TabMemory.initialIndex(_selectedTab, widget.tab, 7),
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
                      HelpHover(
                        'Name and value pairs added to the end of the URL. '
                        'Unticked rows are kept but not sent.',
                        title: 'Query parameters',
                        example: '?page=2&limit=20',
                        child: Tab(text: _counted('Params', req.params)),
                      ),
                      HelpHover(
                        'Extra HTTP headers sent with the request, such as the '
                        'format you accept. Unticked rows are kept but not sent.',
                        title: 'Request headers',
                        example: 'Accept: application/json',
                        child: Tab(text: _counted('Headers', req.headers)),
                      ),
                      HelpHover(
                        'Data sent with the request, such as JSON or a form. '
                        'GET and HEAD requests never send a body.',
                        title: 'Request body',
                        example: '{"name": "Ada"}',
                        child: Tab(
                          text: req.bodyType == BodyType.none
                              ? 'Body'
                              : 'Body • ${req.bodyType.label}',
                        ),
                      ),
                      HelpHover(
                        'Proves who you are. Pick a scheme and the right header '
                        'or query parameter is added for you.',
                        title: 'Authentication',
                        example: 'Authorization: Bearer eyJhbGci…',
                        child: Tab(
                          text: req.authType == AuthType.none
                              ? 'Auth'
                              : 'Auth • ${req.authType.label}',
                        ),
                      ),
                      HelpHover(
                        'Checks run on every response. Results show in the '
                        'response\'s Tests tab and decide pass or fail in the '
                        'runner.',
                        title: 'Tests',
                        example: 'Status equals 2xx',
                        child: Tab(
                          text: req.assertions.where((a) => a.enabled).isEmpty
                              ? 'Tests'
                              : 'Tests (${req.assertions.where((a) => a.enabled).length})',
                        ),
                      ),
                      HelpHover(
                        'Save values from the response, like a login token, '
                        'into variables that later requests use as {{name}}.',
                        title: 'Captures',
                        example: 'token = body.data.token',
                        child: Tab(
                          text: req.captures.isEmpty
                              ? 'Captures'
                              : 'Captures (${req.captures.length})',
                        ),
                      ),
                      HelpHover(
                        'Notes about this request. A dot means it has scripts '
                        'imported from Postman, shown for reference but never '
                        'run.',
                        title: 'Docs',
                        child: Tab(
                          text:
                              req.preRequestScript.isNotEmpty ||
                                  req.testScript.isNotEmpty
                              ? 'Docs •'
                              : 'Docs',
                        ),
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
                          keyHelp:
                              'The name part of a query parameter. Rows are '
                              'added to the URL when you send.',
                          keyExample: 'page',
                          valueHelp:
                              'The value for that name. {{variables}} are '
                              'filled in when you send.',
                          valueExample: '2  or  {{pageSize}}',
                        ),
                        KVEditor(
                          rows: req.headers,
                          onChanged: _touch,
                          keyHint: 'Header',
                          addLabel: 'Add header',
                          keyHelp:
                              'The header name. Auth adds its own '
                              'Authorization header, and the body type sets '
                              'Content-Type unless you add one here.',
                          keyExample: 'X-Request-Id',
                          valueHelp:
                              'The header value. {{variables}} are filled in '
                              'when you send.',
                          valueExample: '{{\$guid}}',
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
    final methodPicker = _methodBox();
    final urlField = TextField(
      controller: _urlCtrl,
      keyboardType: TextInputType.url,
      autocorrect: false,
      enableSuggestions: false,
      textInputAction: TextInputAction.go,
      style: const TextStyle(fontSize: 13.5, fontFamily: 'monospace'),
      decoration: const InputDecoration(
        hintText: 'https://api.example.com/v1/users  —  {{vars}} allowed',
        suffixIcon: HelpTip(
          'The address to call. {{name}} inserts a variable, and built-ins '
          'like {{\$guid}}, {{\$timestamp}} or {{\$randomEmail}} make a fresh '
          'value on every send.',
          title: 'Request URL',
          example: '{{baseUrl}}/users?id={{\$guid}}',
        ),
        suffixIconConstraints: BoxConstraints(minWidth: 32, minHeight: 32),
      ),
      onChanged: (v) {
        req.url = v;
        _touch();
      },
      onSubmitted: (_) => _send(state),
    );
    final sendButton = HelpHover(
      loading
          ? 'Stop waiting for this response and cancel the request.'
          : 'Send the request now and show the response below. Pressing Enter '
                'in the URL field does the same.',
      title: loading ? 'Cancel' : 'Send',
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: loading ? Palette.delete : Palette.accent,
          foregroundColor: loading ? Colors.white : Palette.onAccent,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        ),
        onPressed: loading ? state.cancelActive : () => _send(state),
        icon: Icon(loading ? Icons.stop : Icons.send, size: 16),
        label: Text(loading ? 'Cancel' : 'Send'),
      ),
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
        PopupMenuItem(
          value: 'save',
          child: HelpHover(
            'Store this request in a collection so you can reopen, run and '
            'export it later.',
            title: 'Save to collection',
            child: Text('Save to collection…'),
          ),
        ),
        PopupMenuItem(
          value: 'run',
          child: HelpHover(
            'Send this request several times in a row, or every few seconds, '
            'and check its tests each time.',
            title: 'Runner',
            example: '10 iterations, 500 ms apart',
            child: Text('Run repeatedly / on interval…'),
          ),
        ),
        PopupMenuItem(
          value: 'load',
          child: HelpHover(
            'Send this request from many simulated users at once to see how '
            'fast the server stays under load.',
            title: 'Load test',
            example: '50 users × 20 iterations',
            child: Text('Load test (parallel calls)…'),
          ),
        ),
        PopupMenuItem(
          value: 'copy_curl',
          child: HelpHover(
            'Copy this request as a curl command for a terminal. {{variables}} '
            'are kept as written, so fill them in before running it.',
            title: 'Copy as cURL',
            example: "curl -X POST 'https://…' -H 'Accept: …'",
            child: Text('Copy as cURL'),
          ),
        ),
        PopupMenuItem(
          value: 'import_curl',
          child: HelpHover(
            'Paste a curl command, for example from browser developer tools, '
            'to open it as a new request tab.',
            title: 'Import cURL',
            example: "curl 'https://api.example.com/users'",
            child: Text('Import cURL…'),
          ),
        ),
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

  Widget _methodBox() => Container(
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
              child: HelpHover(
                httpMethodHelp(m).message,
                title: httpMethodHelp(m).title,
                child: Text(
                  m,
                  style: TextStyle(
                    color: methodColor(m),
                    fontWeight: FontWeight.w700,
                  ),
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
      builder: (ctx) => ControllerScope(
        controllers: [ctrl],
        child: AdaptiveDialog(
          title: const Text('Import cURL'),
          width: 520,
          content: SingleChildScrollView(
            child: TextField(
              controller: ctrl,
              minLines: 4,
              maxLines: 8,
              autofocus: true,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
              decoration: const InputDecoration(
                hintText: "curl -X POST 'https://…'",
              ),
            ),
          ),
          primary: FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Import'),
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
      ),
    );
    final input = ctrl.text;
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
      builder: (ctx) => ControllerScope(
        controllers: [nameCtrl, newColCtrl],
        child: StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            scrollable: true,
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
                    decoration: const InputDecoration(
                      labelText: 'Request name',
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (state.collections.isNotEmpty) ...[
                    DropdownButtonFormField<String>(
                      initialValue: selectedId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Collection',
                      ),
                      items: [
                        for (final c in state.collections)
                          DropdownMenuItem(
                            value: c.id,
                            child: Text(
                              c.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
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
                      suffixIcon: HelpTip(
                        state.collections.isEmpty
                            ? 'Collections group saved requests, for example '
                                  'one per API or project.'
                            : 'Type a name here to save into a new collection '
                                  'instead of the one picked above.',
                        title: 'New collection',
                        example: 'Shop API',
                      ),
                      suffixIconConstraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
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
      ),
    );
    final collectionName = newColCtrl.text.trim();
    final requestName = nameCtrl.text.trim();
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

  /// The selected body type chip, scrolled into view on narrow screens.
  final _selectedChip = GlobalKey();
  final _chipScroll = ScrollController();

  /// Centres the selected chip in the swipeable chip row. Only that row
  /// scrolls (Scrollable.ensureVisible would also move the tab pages).
  void _revealSelectedChip({bool animate = true}) {
    final ro = _selectedChip.currentContext?.findRenderObject();
    if (ro == null || !ro.attached || !_chipScroll.hasClients) return;
    final viewport = RenderAbstractViewport.maybeOf(ro);
    if (viewport == null) return;
    final target = viewport
        .getOffsetToReveal(ro, 0.5)
        .offset
        .clamp(0.0, _chipScroll.position.maxScrollExtent);
    if (animate) {
      _chipScroll.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    } else {
      _chipScroll.jumpTo(target);
    }
  }

  Widget _bodyTypeChip(BodyType t) => HelpHover(
    _bodyTypeHelp(t).message,
    title: _bodyTypeHelp(t).title,
    example: _bodyTypeHelp(t).example,
    child: ChoiceChip(
      key: req.bodyType == t ? _selectedChip : null,
      label: Text(t.label, style: const TextStyle(fontSize: 12)),
      selected: req.bodyType == t,
      onSelected: (_) {
        setState(() => req.bodyType = t);
        _touch();
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _revealSelectedChip(),
        );
      },
    ),
  );

  /// Body type chips: wrapped on wide editors; one swipeable row on narrow
  /// ones, so the editor below keeps its height on phones.
  Widget _bodyTypes() {
    final help = HelpTip(
      _bodyEditorHelp(req.bodyType).message,
      title: _bodyEditorHelp(req.bodyType).title,
      example: _bodyEditorHelp(req.bodyType).example,
    );
    const beautifyHelp =
        'Re-indent the JSON body with line breaks and spacing. Shows a '
        'message instead if the JSON is not valid.';
    return LayoutBuilder(
      builder: (context, box) {
        final json = req.bodyType == BodyType.json;
        if (box.maxWidth >= 560) {
          return Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final t in BodyType.values) _bodyTypeChip(t),
                    help,
                  ],
                ),
              ),
              if (json)
                HelpHover(
                  beautifyHelp,
                  title: 'Beautify JSON',
                  child: TextButton(
                    onPressed: _beautifyJson,
                    child: const Text('Beautify'),
                  ),
                ),
            ],
          );
        }
        return Row(
          children: [
            Expanded(
              child: _AfterFirstLayout(
                callback: () => _revealSelectedChip(animate: false),
                child: SingleChildScrollView(
                  controller: _chipScroll,
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final t in BodyType.values)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: _bodyTypeChip(t),
                        ),
                      help,
                    ],
                  ),
                ),
              ),
            ),
            if (json)
              IconButton(
                tooltip: 'Beautify JSON: $beautifyHelp',
                icon: const Icon(Icons.auto_fix_high, size: 19),
                onPressed: _beautifyJson,
              ),
          ],
        );
      },
    );
  }

  Widget _bodyTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: _bodyTypes(),
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
              keyHelp: 'The form field name the server expects.',
              keyExample: 'email',
              valueHelp:
                  'The field value. Fields are sent as name=value pairs, '
                  'like a simple web form. {{variables}} work here too.',
              valueExample: 'ada@example.com',
            ),
            BodyType.formData => KVEditor(
              key: const ValueKey('form-data'),
              rows: req.formFields,
              onChanged: _touch,
              keyHint: 'Field',
              addLabel: 'Add field',
              allowFiles: true,
              keyHelp: 'The form field name the server expects.',
              keyExample: 'avatar',
              valueHelp:
                  'Text for a Text row, or the file to upload for a File row. '
                  'Use the Text/File menu to switch.',
              valueExample: '/home/me/photo.png',
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

  static ({String title, String message, String? example}) _bodyTypeHelp(
    BodyType t,
  ) => switch (t) {
    BodyType.none => (
      title: 'No body',
      message: 'Send no data with the request. Typical for GET and DELETE.',
      example: null,
    ),
    BodyType.json => (
      title: 'JSON body',
      message:
          'Structured data, the most common body for APIs. Sent with '
          'Content-Type application/json.',
      example: '{"name": "Ada", "age": 36}',
    ),
    BodyType.text => (
      title: 'Text body',
      message: 'Plain text, sent with Content-Type text/plain.',
      example: 'Hello server',
    ),
    BodyType.xml => (
      title: 'XML body',
      message: 'An XML document, sent with Content-Type application/xml.',
      example: '<user><name>Ada</name></user>',
    ),
    BodyType.formUrlEncoded => (
      title: 'Form URL-encoded',
      message:
          'Name and value pairs, the way a simple web form sends them. Use it '
          'for classic login or search forms.',
      example: 'email=ada%40example.com&remember=true',
    ),
    BodyType.formData => (
      title: 'Form data (multipart)',
      message:
          'Text fields plus file uploads in one body, like a web upload '
          'form.',
      example: 'avatar = photo.png, name = Ada',
    ),
    BodyType.graphql => (
      title: 'GraphQL',
      message:
          'A GraphQL query with optional variables, sent together as JSON.',
      example: 'query { users { id name } }',
    ),
    BodyType.binary => (
      title: 'Binary file',
      message:
          'One file from this device sent as the whole body, such as an image '
          'or a zip.',
      example: 'photo.png',
    ),
  };

  /// Explains the editor shown below the body type chips.
  static ({String title, String message, String? example}) _bodyEditorHelp(
    BodyType t,
  ) => switch (t) {
    BodyType.none => (
      title: 'Request body',
      message:
          'Pick a body type to send data. GET and HEAD never send a body, so '
          'use POST, PUT, PATCH or QUERY.',
      example: null,
    ),
    BodyType.json || BodyType.text || BodyType.xml => (
      title: 'Body editor',
      message:
          'Type the body exactly as it should be sent; {{variables}} are '
          'filled in. Content-Type is added unless you set one in Headers.',
      example: '{"id": "{{userId}}", "ref": "{{\$guid}}"}',
    ),
    BodyType.formUrlEncoded => (
      title: 'Form fields',
      message: 'One row per form field. Unticked rows are kept but not sent.',
      example: 'email = ada@example.com',
    ),
    BodyType.formData => (
      title: 'Multipart fields',
      message:
          'One row per field. Set a row to File to upload a file; the '
          'multipart Content-Type is added for you.',
      example: 'avatar (File) = /home/me/photo.png',
    ),
    BodyType.graphql => (
      title: 'Query and variables',
      message:
          'Write the query in the top box and its variables as JSON in the '
          'bottom box. Both are sent together as JSON.',
      example: '{"limit": 10}',
    ),
    BodyType.binary => (
      title: 'File body',
      message:
          'The chosen file is sent byte for byte, with Content-Type '
          'application/octet-stream unless you set one in Headers.',
      example: '/home/me/backup.zip',
    ),
  };

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

  Widget _binaryBody() => SingleChildScrollView(
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
                  suffixIcon: const HelpTip(
                    'The full path of a file on this device. Choose file '
                    'fills it in for you.',
                    title: 'File path',
                    example: '/home/me/photo.png',
                  ),
                  suffixIconConstraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
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
          HelpHover(
            col == null
                ? 'This request is not in a collection yet. Use Save to keep '
                      'it.'
                : 'Saved in ${segs.join(' › ')}: its collection, then any '
                      'folders.',
            title: col == null ? 'Draft request' : 'Location',
            example: col == null ? null : 'Shop API › Orders › Create order',
            child: Icon(
              col == null ? Icons.edit_note : Icons.folder_outlined,
              size: 16,
              color: Palette.textDim,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: LayoutBuilder(
              // Narrow editors show just the name; the folder icon's help
              // still tells where the request lives.
              builder: (context, box) => Row(
                children: [
                  if (box.maxWidth >= 360)
                    for (final s in segs) ...[
                      Flexible(
                        child: Text(
                          s,
                          overflow: TextOverflow.ellipsis,
                          style: dim,
                        ),
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
                    child: HelpHover(
                      'Click the name to rename this request. The new name is '
                      'kept when you save.',
                      title: 'Request name',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: () => _rename(state),
                        child: ConstrainedBox(
                          constraints: isTouch(context)
                              ? const BoxConstraints(
                                  minWidth: minTouchTarget,
                                  minHeight: minTouchTarget,
                                )
                              : const BoxConstraints(),
                          child: Align(
                            widthFactor: 1,
                            heightFactor: 1,
                            alignment: Alignment.centerLeft,
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
                    ),
                  ),
                  if (widget.tab.dirty)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: HelpHover(
                        'This tab has edits that are not saved to its '
                        'collection yet. Save to keep them.',
                        title: 'Unsaved changes',
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
          ),
          HelpHover(
            col == null
                ? 'Choose a collection to keep this request in, so you can '
                      'reopen and run it later.'
                : 'Save your changes to this request in "${col.name}".',
            title: col == null ? 'Save to a collection' : 'Save',
            child: TextButton.icon(
              onPressed: () => saveOrAsk(state),
              icon: const Icon(Icons.save_outlined, size: 16),
              label: Text(col == null ? 'Save…' : 'Save'),
            ),
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
      builder: (ctx) => ControllerScope(
        controllers: [ctrl],
        child: AlertDialog(
          scrollable: true,
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
      ),
    );
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
        // Grows with its lines instead of scrolling inside the page, so a
        // drag on a phone scrolls the page.
        maxLines: null,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        decoration: const InputDecoration(
          hintText:
              'token = body.data.token\nuserId = data.user.id\n'
              'etag = header.ETag\ncode = status',
          suffixIcon: HelpTip(
            'One per line as name = source. Source is body.path (body. is '
            'optional), header.Name, or status; values missing from a '
            'response are skipped.',
            title: 'Capture rules',
            example: 'token = body.data.token',
          ),
          suffixIconConstraints: BoxConstraints(minWidth: 32, minHeight: 32),
        ),
        onChanged: (v) {
          req.captures = parseCaptureText(v);
          _touch();
        },
      ),
      const SizedBox(height: 10),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              'Values go to the active environment, or to the collection\'s '
              'variables when no environment is selected. Unsaved requests '
              'with no environment keep them until you close the app. The '
              'runner and load tester pass them between requests of the same '
              'run.',
              style: TextStyle(
                fontSize: 12,
                color: Palette.textDim,
                height: 1.45,
              ),
            ),
          ),
          const HelpTip(
            'Captured values overwrite a variable of the same name, so the '
            'next request that uses {{name}} gets the new value.',
            title: 'Where captures go',
            example: 'Login captures token, then Orders sends {{token}}',
          ),
        ],
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
        // Grows with the text instead of scrolling inside the page: on a
        // phone a 14-line box filled the whole tab, so the imported scripts
        // below could not be scrolled to.
        maxLines: null,
        style: const TextStyle(fontSize: 13.5, height: 1.45),
        decoration: const InputDecoration(
          labelText: 'Description',
          alignLabelWithHint: true,
          hintText: 'What this request does, parameters, examples…',
          suffixIcon: HelpTip(
            'Notes for you and your team: what the request does and what it '
            'needs. Saved with the request and included in workspace exports.',
            title: 'Description',
            example: 'Creates an order. Needs a token from Login.',
          ),
          suffixIconConstraints: BoxConstraints(minWidth: 32, minHeight: 32),
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
        Row(
          children: [
            Flexible(
              child: SizedBox(
                width: 260,
                child: DropdownButtonFormField<AuthType>(
                  initialValue: req.authType,
                  decoration: const InputDecoration(labelText: 'Auth type'),
                  items: [
                    for (final t in AuthType.values)
                      DropdownMenuItem(
                        value: t,
                        child: HelpHover(
                          _authTypeHelp(t).message,
                          title: t.label,
                          example: _authTypeHelp(t).example,
                          child: Text(t.label),
                        ),
                      ),
                  ],
                  onChanged: (t) {
                    if (t != null) {
                      setState(() => req.authType = t);
                      _touch();
                    }
                  },
                ),
              ),
            ),
            const HelpTip(
              'How this request proves who you are. The matching header or '
              'query parameter is added for you when you send.',
              title: 'Auth type',
              example: 'Authorization: Bearer eyJhbGci…',
            ),
          ],
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
              help:
                  'The access token from your login or API dashboard. It is '
                  'sent in the Authorization header.',
              title: 'Bearer token',
              example: '{{token}}  →  Authorization: Bearer {{token}}',
            ),
          ],
          AuthType.basic => [
            _authField(
              'Username',
              req.basicUser,
              (v) => req.basicUser = v,
              help:
                  'Combined with the password into an Authorization: Basic '
                  'header.',
              title: 'Username',
              example: 'ada',
            ),
            const SizedBox(height: 12),
            _authField(
              'Password',
              req.basicPassword,
              (v) => req.basicPassword = v,
              obscure: true,
              help:
                  'Basic Auth only encodes the password, it does not encrypt '
                  'it, so use https:// addresses.',
              title: 'Password',
              example: '{{password}}',
            ),
          ],
          AuthType.apiKey => [
            _authField(
              'Key name',
              req.apiKeyName,
              (v) => req.apiKeyName = v,
              help:
                  'The header or query parameter name the API expects. Check '
                  'the API\'s docs.',
              title: 'Key name',
              example: 'X-API-Key',
            ),
            const SizedBox(height: 12),
            _authField(
              'Value',
              req.apiKeyValue,
              (v) => req.apiKeyValue = v,
              obscure: true,
              help:
                  'Your API key. A variable lets you change it in one place '
                  'for every request.',
              title: 'Key value',
              example: '{{apiKey}}',
            ),
            const SizedBox(height: 12),
            HelpHover(
              'Header sends the key as a request header. Query param adds it '
              'to the URL instead, where it may end up in server logs.',
              title: 'Where to send the key',
              example: 'X-API-Key: abc123  or  ?api_key=abc123',
              child: SegmentedButton<bool>(
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
            ),
          ],
        },
      ],
    );
  }

  static ({String message, String? example}) _authTypeHelp(AuthType t) =>
      switch (t) {
        AuthType.none => (
          message: 'Send no credentials. Use it for public endpoints.',
          example: null,
        ),
        AuthType.bearer => (
          message:
              'Sends a token in the Authorization header. Most modern APIs '
              'and OAuth logins use this.',
          example: 'Authorization: Bearer eyJhbGci…',
        ),
        AuthType.basic => (
          message:
              'Sends a username and password, base64-encoded, in the '
              'Authorization header.',
          example: 'Authorization: Basic YWRhOnNlY3JldA==',
        ),
        AuthType.apiKey => (
          message:
              'Sends a key under a name you choose, as a header or a query '
              'parameter.',
          example: 'X-API-Key: abc123',
        ),
      };

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
    final enabled = HelpHover(
      'Ticked tests run after every send. Untick to switch this one '
      'off without deleting it.',
      title: a.enabled ? 'Test on' : 'Test off',
      child: Checkbox(
        value: a.enabled,
        onChanged: (v) {
          setState(() => a.enabled = v ?? true);
          _touch();
        },
      ),
    );
    final kind = DropdownButtonFormField<AssertKind>(
      initialValue: a.kind,
      isExpanded: true,
      style: TextStyle(fontSize: 12.5, color: Palette.text),
      items: [
        for (final k in AssertKind.values)
          DropdownMenuItem(
            value: k,
            child: HelpHover(
              _kindHelp(k).message,
              title: k.label,
              example: _kindHelp(k).example,
              child: Text(k.label, overflow: TextOverflow.ellipsis),
            ),
          ),
      ],
      onChanged: (k) {
        if (k != null) {
          setState(() => a.kind = k);
          _touch();
        }
      },
    );
    final target = TextFormField(
      key: ValueKey('t-${a.hashCode}'),
      initialValue: a.target,
      style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
      decoration: InputDecoration(
        hintText: a.kind == AssertKind.jsonEquals ? 'JSON path' : 'Header name',
        suffixIcon: a.kind == AssertKind.jsonEquals
            ? const HelpTip(
                'Where to look in the JSON body: dots for fields and [n] for '
                'list items, counting from 0.',
                title: 'JSON path',
                example: 'data.items[0].id',
              )
            : const HelpTip(
                'The response header to check. Upper or lower case both '
                'work.',
                title: 'Header name',
                example: 'Content-Type',
              ),
        suffixIconConstraints: const BoxConstraints(
          minWidth: 32,
          minHeight: 32,
        ),
      ),
      onChanged: (v) {
        a.target = v;
        _touch();
      },
    );
    final expected = TextFormField(
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
        suffixIcon: HelpTip(
          _expectedHelp(a.kind).message,
          title: _expectedHelp(a.kind).title,
          example: _expectedHelp(a.kind).example,
        ),
        suffixIconConstraints: const BoxConstraints(
          minWidth: 32,
          minHeight: 32,
        ),
      ),
      onChanged: (v) {
        a.expected = v;
        _touch();
      },
    );
    final remove = IconButton(
      tooltip: 'Remove test',
      icon: Icon(Icons.close, size: 16, color: Palette.textDim),
      onPressed: () {
        setState(() => req.assertions.remove(a));
        _touch();
      },
    );
    // Keyed by the assertion so removing one row never hands its dropdown
    // state to the next.
    return LayoutBuilder(
      key: ObjectKey(a),
      builder: (context, box) {
        if (box.maxWidth >= 600) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                enabled,
                SizedBox(width: 180, child: kind),
                const SizedBox(width: 8),
                if (a.kind.hasTarget) ...[
                  Expanded(flex: 2, child: target),
                  const SizedBox(width: 8),
                ],
                Expanded(flex: 2, child: expected),
                remove,
              ],
            ),
          );
        }
        // Narrow: the kind on the first line, its fields below it.
        final indent =
            48 + Theme.of(context).visualDensity.baseSizeAdjustment.dx;
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: Palette.border)),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  enabled,
                  Expanded(child: kind),
                  remove,
                ],
              ),
              if (a.kind.hasTarget)
                Padding(
                  padding: EdgeInsets.fromLTRB(indent, 6, indent, 0),
                  child: target,
                ),
              Padding(
                padding: EdgeInsets.fromLTRB(indent, 6, indent, 0),
                child: expected,
              ),
            ],
          ),
        );
      },
    );
  }

  static ({String message, String example}) _kindHelp(AssertKind k) =>
      switch (k) {
        AssertKind.statusEquals => (
          message:
              'Passes when the status code matches. A class like 2xx accepts '
              'any code in that hundred.',
          example: '200  or  2xx',
        ),
        AssertKind.bodyContains => (
          message:
              'Passes when some text appears anywhere in the response body. '
              'Upper and lower case must match.',
          example: '"status":"active"',
        ),
        AssertKind.jsonEquals => (
          message:
              'Passes when the value at a path in the JSON body equals what '
              'you expect.',
          example: 'data.items[0].id = 42',
        ),
        AssertKind.headerContains => (
          message:
              'Passes when a response header contains some text, or only '
              'exists if you leave the value empty.',
          example: 'Content-Type contains json',
        ),
        AssertKind.timeBelow => (
          message:
              'Passes when the response arrives faster than a limit in '
              'milliseconds.',
          example: '500 ms',
        ),
      };

  static ({String title, String message, String example}) _expectedHelp(
    AssertKind k,
  ) => switch (k) {
    AssertKind.statusEquals => (
      title: 'Expected status',
      message:
          'The status code you expect. A class like 2xx matches any status '
          'from 200 to 299.',
      example: '201  or  2xx',
    ),
    AssertKind.bodyContains => (
      title: 'Text to find',
      message:
          'Passes when this text appears anywhere in the body. Upper and '
          'lower case must match.',
      example: '"ok":true',
    ),
    AssertKind.jsonEquals => (
      title: 'Expected value',
      message:
          'Compared as text with the value at the path. Write strings without '
          'quotes.',
      example: '42  or  true  or  Ada',
    ),
    AssertKind.headerContains => (
      title: 'Expected header text',
      message:
          'Text the header value must contain, ignoring case. Leave empty to '
          'only check that the header is there.',
      example: 'application/json',
    ),
    AssertKind.timeBelow => (
      title: 'Time limit (ms)',
      message:
          'The test fails when the response takes this many milliseconds or '
          'longer.',
      example: '1500  (1.5 seconds)',
    ),
  };

  Widget _authField(
    String label,
    String value,
    ValueChanged<String> onChanged, {
    bool obscure = false,
    required String help,
    required String title,
    String? example,
  }) {
    return SizedBox(
      width: 420,
      child: TextFormField(
        initialValue: value,
        obscureText: obscure,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: HelpTip(help, title: title, example: example),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 32,
            minHeight: 32,
          ),
        ),
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

/// Runs [callback] once after the first frame that lays out [child].
class _AfterFirstLayout extends StatefulWidget {
  const _AfterFirstLayout({required this.callback, required this.child});

  final VoidCallback callback;
  final Widget child;

  @override
  State<_AfterFirstLayout> createState() => _AfterFirstLayoutState();
}

class _AfterFirstLayoutState extends State<_AfterFirstLayout> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.callback();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
