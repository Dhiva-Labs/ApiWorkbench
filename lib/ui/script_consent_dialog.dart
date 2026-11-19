import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/scripting/script_trust.dart';
import '../theme.dart';

export '../services/scripting/script_trust.dart' show ScriptConsent;

/// Asks whether the [scripts] scripts of the imported collection [c] may
/// run. Shown once, before the first send that would run them; dismissing
/// it cancels the send.
Future<ScriptConsent> showScriptConsentDialog(
  BuildContext context,
  CollectionModel c,
  int scripts,
) async {
  final answer = await showDialog<ScriptConsent>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: Row(
        children: [
          Icon(Icons.code, color: Palette.warning),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              'Run scripts from "${c.name}"?',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This collection was imported and has $scripts '
              '${scripts == 1 ? 'script' : 'scripts'} (pre-request and '
              'test). Scripts can read and change your variables, including '
              'the active environment and globals, and send requests of '
              'their own.',
              style: const TextStyle(height: 1.45),
            ),
            const SizedBox(height: 10),
            Text(
              'Allow them only if you trust where the collection came from. '
              'Allowing is remembered for this collection.',
              style: TextStyle(fontSize: 12.5, color: Palette.textDim),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, ScriptConsent.cancel),
          child: const Text('Cancel'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.pop(ctx, ScriptConsent.skipScripts),
          child: const Text('Run without scripts'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, ScriptConsent.allow),
          child: const Text('Allow scripts'),
        ),
      ],
    ),
  );
  return answer ?? ScriptConsent.cancel;
}
