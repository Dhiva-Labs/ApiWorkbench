import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'adaptive.dart';
import 'kv_editor.dart';

/// Edits environment, collection or global variables (issue #22 adds
/// initial/current values and secrets).
class VariablesEditor extends StatelessWidget {
  const VariablesEditor({
    super.key,
    required this.rows,
    required this.onChanged,
    this.valueHelp,
    this.valueExample,
  });

  final List<KV> rows;
  final VoidCallback onChanged;
  final String? valueHelp;
  final String? valueExample;

  @override
  Widget build(BuildContext context) => KVEditor(
    rows: rows,
    onChanged: onChanged,
    keyHint: 'Variable',
    addLabel: 'Add variable',
    keyHelp: 'The variable name. Use it anywhere in a request as {{name}}.',
    keyExample: 'baseUrl',
    valueHelp: valueHelp ?? 'The value that replaces {{name}} when you send.',
    valueExample: valueExample ?? 'https://api.example.com',
  );
}

/// Opens the Globals scope for editing.
Future<void> editGlobals(BuildContext context, AppState state) =>
    showDialog<void>(
      context: context,
      builder: (ctx) => AdaptiveDialog(
        title: const Text('Globals'),
        height: 380,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Available to every request, in every collection. Collection '
              'and environment variables win on a name clash.',
              style: TextStyle(fontSize: 12.5, color: Palette.textDim),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: VariablesEditor(
                rows: state.globals,
                onChanged: state.updateGlobals,
              ),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Done'),
          ),
        ],
      ),
    );
