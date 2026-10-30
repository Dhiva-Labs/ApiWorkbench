import 'dart:convert';

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/collection_diff.dart' show isSecretAuthParam;
import '../../state/app_state.dart';
import '../help_tip.dart';
import 'example_editor.dart';

/// Longest body an example keeps; a bigger one is cut so collections stay
/// small to load, save and export.
const maxExampleBody = 512 * 1024;

/// Keeps [res] with the tab's request as a named example. The example is
/// added to the tab's request; the user saves the request to keep it, or
/// ticks "also save" when the request already lives in a collection.
Future<void> saveResponseAsExample(
  BuildContext context,
  AppState state,
  RequestTab tab,
  ResponseData res,
) async {
  final collection = state.activeTab?.id == tab.id
      ? state.collectionById(tab.sourceCollectionId)
      : null;
  final choice = await showDialog<_SaveChoice>(
    context: context,
    builder: (context) => _SaveExampleDialog(
      initialName: _uniqueName(
        tab.request.examples,
        '${res.statusCode} ${res.statusMessage}'.trim(),
      ),
      collection: collection,
      saveNow: !tab.dirty,
    ),
  );
  if (choice == null) return;
  final example = exampleFromResponse(
    _uniqueName(tab.request.examples, choice.name),
    tab.request,
    res,
  );
  tab.request.examples.add(example);
  tab.dirty = true;
  var saved = false;
  if (choice.saveNow && collection != null) {
    state.saveActiveTo(collection);
    saved = true;
  } else {
    state.notifyRefresh();
  }
  if (!context.mounted) return;
  final note = res.bodyBytes.isNotEmpty && example.body.isEmpty
      ? ' The body is binary, so only the status and headers were kept.'
      : '';
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        saved
            ? 'Example saved to ${collection!.name}.$note'
            : 'Example added. Save the request to keep it.$note',
      ),
    ),
  );
}

/// [name], or [name] with a number when an example already has it.
String _uniqueName(List<ResponseExample> existing, String name) {
  final base = name.trim().isEmpty ? 'Example' : name.trim();
  final taken = {for (final e in existing) e.name};
  if (!taken.contains(base)) return base;
  for (var i = 2; ; i++) {
    if (!taken.contains('$base ($i)')) return '$base ($i)';
  }
}

class _SaveChoice {
  const _SaveChoice(this.name, this.saveNow);
  final String name;
  final bool saveNow;
}

class _SaveExampleDialog extends StatefulWidget {
  const _SaveExampleDialog({
    required this.initialName,
    required this.collection,
    required this.saveNow,
  });

  final String initialName;

  /// The collection the request lives in, when it can be saved there now.
  final CollectionModel? collection;
  final bool saveNow;

  @override
  State<_SaveExampleDialog> createState() => _SaveExampleDialogState();
}

class _SaveExampleDialogState extends State<_SaveExampleDialog> {
  late final _ctrl = TextEditingController(text: widget.initialName);
  late bool _saveNow = widget.saveNow;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (_ctrl.text.trim().isEmpty) return;
    Navigator.pop(context, _SaveChoice(_ctrl.text, _saveNow));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Save as example'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _ctrl,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Example name',
              suffixIcon: HelpTip(
                'Keeps this response with the request, so you can see what it '
                'returns without sending it. Shown in the collection tree '
                'and in the docs.',
                title: 'Example name',
                example: '404 Not Found',
              ),
              suffixIconConstraints: BoxConstraints(
                minWidth: 32,
                minHeight: 32,
              ),
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (widget.collection != null) ...[
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              value: _saveNow,
              onChanged: (v) => setState(() => _saveNow = v ?? false),
              title: Row(
                children: [
                  Flexible(
                    child: Text(
                      'Also save the request to ${widget.collection!.name} now',
                    ),
                  ),
                  const HelpTip(
                    'Saves the request as it is in the editor, including any '
                    'other changes you have not saved yet. Without this the '
                    'example waits until you save the request.',
                    title: 'Save to collection now',
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Save')),
    ],
  );
}

/// An example holding [res] and a snapshot of [request]. Binary bodies are
/// not kept, and text beyond [maxExampleBody] is cut.
ResponseExample exampleFromResponse(
  String name,
  RequestModel request,
  ResponseData res,
) => ResponseExample(
  name: name,
  statusCode: res.statusCode,
  statusText: res.statusMessage,
  headers: [
    for (final e in res.headers.entries)
      for (final v in e.value) KV(key: e.key, value: v),
  ],
  body: _bodyText(res),
  originalRequest: _snapshot(request),
);

/// The request as an example records it: no examples inside, and no
/// credentials, since examples are exported and put in the docs.
RequestModel _snapshot(RequestModel request) {
  final r = request.clone(sameId: true)..examples = [];
  r.auth
    ..bearerToken = ''
    ..basicPassword = ''
    ..apiKeyValue = ''
    ..params.removeWhere((k, _) => isSecretAuthParam(k));
  return r;
}

String _bodyText(ResponseData res) {
  if (res.bodyBytes.isEmpty || _isBinary(res)) return '';
  final text = utf8.decode(res.bodyBytes);
  return text.length <= maxExampleBody
      ? text
      : '${text.substring(0, maxExampleBody)}\n… (cut at $maxExampleBody characters)';
}

bool _isBinary(ResponseData res) {
  final type = (res.contentType ?? '').toLowerCase();
  const binaryTypes = [
    'image/',
    'audio/',
    'video/',
    'font/',
    'octet-stream',
    'pdf',
    'zip',
    'protobuf',
  ];
  if (!type.contains('svg') && binaryTypes.any(type.contains)) return true;
  try {
    utf8.decode(res.bodyBytes);
    return false;
  } on FormatException {
    return true;
  }
}

/// Opens a saved example in a viewer and editor: rename it, change its
/// status, headers and body, duplicate or delete it, or jump to its request.
Future<void> openExample(
  BuildContext context,
  AppState state,
  CollectionModel collection,
  RequestModel request,
  ResponseExample example,
) => showExampleEditor(context, state, collection, request, example);
