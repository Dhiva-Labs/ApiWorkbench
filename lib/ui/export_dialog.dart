import 'package:flutter/material.dart';

import '../models/models.dart';
import 'app_menu.dart' show exportWorkspace;

/// Export choices: ApiWorkbench workspace, Postman collection or
/// environment, OpenAPI (issue #29). [collection] preselects one.
Future<void> showExportDialog(
  BuildContext context, {
  CollectionModel? collection,
}) => exportWorkspace(context);
