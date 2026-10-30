import 'dart:convert';

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../state/app_state.dart';

/// Keeps [res] with the tab's request as a named example (issue #11 adds
/// the example viewer and editor).
Future<void> saveResponseAsExample(
  BuildContext context,
  AppState state,
  RequestTab tab,
  ResponseData res,
) async {
  final ctrl = TextEditingController(
    text: '${res.statusCode} ${res.statusMessage}'.trim(),
  );
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Save as example'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Example name'),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, ctrl.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  ctrl.dispose();
  if (name == null || name.trim().isEmpty) return;
  tab.request.examples.add(exampleFromResponse(name.trim(), tab.request, res));
  state.touchActive();
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Example added. Save the request to keep it.'),
      ),
    );
  }
}

/// An example holding [res] and a snapshot of [request].
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
  body: utf8.decode(res.bodyBytes, allowMalformed: true),
  originalRequest: request.clone(sameId: true)..examples = [],
);

/// Opens a saved example.
Future<void> openExample(
  BuildContext context,
  AppState state,
  CollectionModel collection,
  RequestModel request,
  ResponseExample example,
) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(example.name),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: SelectableText(
          '${example.statusCode} ${example.statusText}\n\n${example.body}',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
        ),
      ),
    ),
    actions: [
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  ),
);
