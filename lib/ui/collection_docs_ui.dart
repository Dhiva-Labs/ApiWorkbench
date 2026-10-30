import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/collection_docs.dart';
import '../state/app_state.dart';
import 'app_menu.dart' show savePickedFile;
import 'help_tip.dart';

enum _DocFormat { html, markdown }

/// Asks for a format, then saves the collection's documentation (issue #34)
/// as a single HTML page or a Markdown file. Secrets are masked.
Future<void> exportCollectionDocs(
  BuildContext context,
  AppState state,
  CollectionModel c,
) async {
  final format = await showDialog<_DocFormat>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Export collection docs'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Every folder and request with its parameters, headers, body, '
            'auth type, scripts and saved examples. Tokens, passwords and '
            'secret variables are masked.',
            style: Theme.of(ctx).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          HelpHover(
            'One file with its styles built in, light and dark colours and a '
            'table of contents. Open it in any browser or attach it to an '
            'email.',
            title: 'HTML page',
            example: 'shop-api-docs.html',
            child: ListTile(
              leading: const Icon(Icons.language),
              title: const Text('HTML page'),
              subtitle: const Text('Self-contained, opens in a browser'),
              onTap: () => Navigator.pop(ctx, _DocFormat.html),
            ),
          ),
          HelpHover(
            'The same content as plain Markdown, for a README or a wiki.',
            title: 'Markdown',
            example: 'shop-api-docs.md',
            child: ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Markdown'),
              subtitle: const Text('For READMEs and wikis'),
              onTap: () => Navigator.pop(ctx, _DocFormat.markdown),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
  if (format == null || !context.mounted) return;

  final html = format == _DocFormat.html;
  final secrets = state.secretValues;
  final text = html
      ? buildCollectionHtml(c, secrets: secrets)
      : buildCollectionMarkdown(c, secrets: secrets);
  final messenger = ScaffoldMessenger.of(context);
  try {
    final path = await savePickedFile(
      dialogTitle: 'Save collection docs',
      fileName: '${docFileStem(c.name)}-docs.${html ? 'html' : 'md'}',
      extensions: [html ? 'html' : 'md'],
      bytes: utf8.encode(text),
    );
    if (path == null) return;
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Docs saved (tokens and secret variables are masked).'),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not save docs: $e')));
  }
}

/// A file name stem from a collection name: letters, digits, dashes.
String docFileStem(String name) {
  final stem = name
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return stem.isEmpty ? 'collection' : stem;
}
