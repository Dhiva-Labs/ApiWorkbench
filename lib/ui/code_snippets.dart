import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/curl.dart' as curl;
import '../state/app_state.dart';

/// Shows the request as code. (Issue #17 adds the other languages.)
Future<void> showCodeSnippetDialog(
  BuildContext context,
  AppState state,
  RequestTab tab,
) {
  final code = curl.toCurl(tab.request);
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Code snippet'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: SelectableText(
            code,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: code)),
          child: const Text('Copy'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
