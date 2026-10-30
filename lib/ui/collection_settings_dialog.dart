import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import 'adaptive.dart';
import 'request/auth_editor.dart';

/// A collection's auth, scripts and description (issue #9 adds scripts and
/// docs).
Future<void> showCollectionSettings(
  BuildContext context,
  AppState state,
  CollectionModel c,
) => _authDialog(
  context,
  '${c.name} settings',
  c.auth,
  state.updateCollections,
  allowInherit: false,
);

/// Settings shared by a folder's requests.
Future<void> showFolderSettings(
  BuildContext context,
  AppState state,
  CollectionModel c,
  String folderPath,
) => _authDialog(
  context,
  '${folderPath.split('/').last} settings',
  c.folders.putIfAbsent(folderPath, FolderMeta.new).auth,
  state.updateCollections,
);

Future<void> _authDialog(
  BuildContext context,
  String title,
  AuthConfig auth,
  VoidCallback onChanged, {
  bool allowInherit = true,
}) => showDialog<void>(
  context: context,
  builder: (ctx) => AdaptiveDialog(
    title: Text(title, overflow: TextOverflow.ellipsis),
    height: 420,
    content: AuthEditor(
      auth: auth,
      onChanged: onChanged,
      allowInherit: allowInherit,
    ),
    actions: [
      FilledButton(
        onPressed: () => Navigator.pop(ctx),
        child: const Text('Done'),
      ),
    ],
  ),
);
