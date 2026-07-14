import 'dart:convert';

import '../models/models.dart';

/// Serialized workspace shared between machines / teammates.
const workspaceFormatVersion = 1;

String buildWorkspaceJson(
    List<CollectionModel> collections, List<EnvironmentModel> environments) {
  return const JsonEncoder.withIndent('  ').convert({
    'app': 'apiworkbench',
    'format': workspaceFormatVersion,
    'exportedAt': DateTime.now().toIso8601String(),
    'collections': collections.map((c) => c.toJson()).toList(),
    'environments': environments.map((e) => e.toJson()).toList(),
  });
}

class WorkspaceImport {
  WorkspaceImport(this.collections, this.environments);

  final List<CollectionModel> collections;
  final List<EnvironmentModel> environments;
}

/// Parses an exported workspace. Throws [FormatException] with a readable
/// message when the file is not an ApiWorkbench export.
WorkspaceImport parseWorkspaceJson(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    throw const FormatException('The file is not valid JSON.');
  }
  if (decoded is! Map<String, dynamic> || decoded['app'] != 'apiworkbench') {
    throw const FormatException(
        'The file is not an ApiWorkbench workspace export.');
  }
  final format = decoded['format'] as int? ?? 0;
  if (format > workspaceFormatVersion) {
    throw FormatException(
        'This export uses format v$format; this app understands up to '
        'v$workspaceFormatVersion. Update ApiWorkbench.');
  }
  return WorkspaceImport(
    (decoded['collections'] as List<dynamic>? ?? [])
        .map((e) => CollectionModel.fromJson(e as Map<String, dynamic>))
        .toList(),
    (decoded['environments'] as List<dynamic>? ?? [])
        .map((e) => EnvironmentModel.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}
