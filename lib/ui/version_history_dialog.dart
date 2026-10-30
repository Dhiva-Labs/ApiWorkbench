import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_state.dart';

/// Snapshots of a collection with diff and restore (issue #35).
Future<void> showVersionHistory(
  BuildContext context,
  AppState state,
  CollectionModel c,
) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text('${c.name} history'),
    content: const Text('Version history is not available in this build.'),
    actions: [
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  ),
);
