import 'dart:convert';

import '../models/models.dart';

/// Serialized workspace shared between machines / teammates.
///
/// Version 1 files written before globals existed have no `globals` key and
/// still read; newer files stay readable by older apps, which ignore the key.
const workspaceFormatVersion = 1;

/// The whole workspace as JSON text.
///
/// Variables carry their local current value only when [includeCurrentValues]
/// is set: a workspace is usually shared, and current values are where
/// session tokens end up.
String buildWorkspaceJson(
  List<CollectionModel> collections,
  List<EnvironmentModel> environments, {
  List<KV> globals = const [],
  bool includeCurrentValues = false,
}) {
  Map<String, dynamic> variable(KV v) {
    final j = v.toJson();
    if (!includeCurrentValues) j.remove('c');
    return j;
  }

  Map<String, dynamic> collection(CollectionModel c) {
    final j = c.toJson();
    if (c.variables.isNotEmpty) {
      j['variables'] = c.variables.map(variable).toList();
    }
    return j;
  }

  return const JsonEncoder.withIndent('  ').convert({
    'app': 'apiworkbench',
    'format': workspaceFormatVersion,
    'exportedAt': DateTime.now().toIso8601String(),
    'collections': collections.map(collection).toList(),
    'environments': [
      for (final e in environments)
        {...e.toJson(), 'variables': e.variables.map(variable).toList()},
    ],
    if (globals.isNotEmpty) 'globals': globals.map(variable).toList(),
  });
}

class WorkspaceImport {
  WorkspaceImport(
    this.collections,
    this.environments, {
    this.globals = const [],
  });

  final List<CollectionModel> collections;
  final List<EnvironmentModel> environments;

  /// Empty for files written before globals were part of the format.
  final List<KV> globals;
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
      'The file is not an ApiWorkbench workspace export.',
    );
  }
  final format = decoded['format'] as int? ?? 0;
  if (format > workspaceFormatVersion) {
    throw FormatException(
      'This export uses format v$format; this app understands up to '
      'v$workspaceFormatVersion. Update ApiWorkbench.',
    );
  }
  return WorkspaceImport(
    (decoded['collections'] as List<dynamic>? ?? [])
        .map((e) => CollectionModel.fromJson(e as Map<String, dynamic>))
        .toList(),
    (decoded['environments'] as List<dynamic>? ?? [])
        .map((e) => EnvironmentModel.fromJson(e as Map<String, dynamic>))
        .toList(),
    globals: (decoded['globals'] as List<dynamic>? ?? [])
        .map((e) => KV.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}
