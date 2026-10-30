import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_state.dart';

/// Generates HTML or Markdown docs for a collection (issue #34).
Future<void> exportCollectionDocs(
  BuildContext context,
  AppState state,
  CollectionModel c,
) async {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('Collection docs are not available in this build.'),
    ),
  );
}
