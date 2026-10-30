import 'dart:io';

import '../models/models.dart';
import '../services/data_files.dart';
import '../services/postman_import.dart';
import 'errors.dart';
import 'options.dart' show RunOptions;

/// Everything a run needs, read from the files the command line names.
class LoadedRun {
  LoadedRun({
    required this.collection,
    required this.requests,
    required this.globals,
    required this.environment,
    required this.environmentName,
    required this.data,
    this.notRun = 0,
  });

  final CollectionModel collection;

  /// The requests to send, in order: HTTP requests of the chosen folders.
  final List<RequestModel> requests;
  final List<KV> globals;

  /// Null when no environment was asked for (captures then go to the
  /// collection's variables, as in the app).
  final List<KV>? environment;
  final String? environmentName;
  final List<Map<String, String>> data;

  /// Requests left out because they are not HTTP (WebSocket, gRPC, ...).
  final int notRun;
}

/// Reads [o]'s files. Throws [InputError] with a readable message for a
/// file that is missing or of the wrong kind.
LoadedRun loadRun(RunOptions o) {
  final main = _import(o.file);
  final collection = _pickCollection(main, o.collection, o.file);

  List<KV>? environment;
  String? environmentName;
  final envRef = o.environment;
  if (envRef != null) {
    final env = _environment(envRef, main);
    environment = [for (final v in env.variables) v.clone()];
    environmentName = env.name;
  }
  if (o.envVars.isNotEmpty) {
    environment ??= [];
    environmentName ??= 'Command line';
    _setAll(environment, o.envVars);
  }

  final globals = [for (final v in _globals(o.globals, main)) v.clone()];
  _setAll(globals, o.globalVars);

  final dataPath = o.iterationData;
  var data = const <Map<String, String>>[];
  if (dataPath != null) {
    try {
      data = readDataFile(
        decodeDataBytes(_readBytes(dataPath)),
        fileName: dataPath,
      ).rows;
    } on FormatException catch (e) {
      throw InputError('$dataPath: ${e.message}');
    }
  }

  final http = [
    for (final r in collection.requests)
      if (r.kind == RequestKind.http) r,
  ];
  final selected = _selectFolders(collection, http, o.folders);
  if (selected.isEmpty) {
    throw InputError(
      'Nothing to run: "${collection.name}" has no HTTP requests'
      '${o.folders.isEmpty ? '' : ' in ${o.folders.join(', ')}'}.',
    );
  }
  return LoadedRun(
    collection: collection,
    requests: selected,
    globals: globals,
    environment: environment,
    environmentName: environmentName,
    data: data,
    notRun: collection.requests.length - http.length,
  );
}

List<int> _readBytes(String path) {
  try {
    return File(path).readAsBytesSync();
  } on FileSystemException catch (e) {
    throw InputError('Cannot read $path: ${e.osError?.message ?? e.message}.');
  }
}

ImportReport _import(String path) {
  try {
    return importApiFile(decodeDataBytes(_readBytes(path)));
  } on FormatException catch (e) {
    throw InputError('$path: ${e.message}');
  }
}

CollectionModel _pickCollection(
  ImportReport report,
  String? want,
  String file,
) {
  final all = report.collections;
  if (all.isEmpty) {
    throw InputError(
      '$file has no collection to run (it holds '
      '${report.environments.isEmpty ? 'nothing runnable' : 'only environments'}).',
    );
  }
  if (want == null) {
    if (all.length == 1) return all.single;
    throw InputError(
      '$file has ${all.length} collections: '
      '${all.map((c) => '"${c.name}"').join(', ')}. '
      'Pick one with --collection <name>.',
    );
  }
  final lower = want.toLowerCase();
  final match =
      all.where((c) => c.id == want).firstOrNull ??
      all.where((c) => c.name == want).firstOrNull ??
      all.where((c) => c.name.toLowerCase() == lower).firstOrNull;
  if (match == null) {
    throw InputError(
      'No collection named "$want" in $file. It has: '
      '${all.map((c) => '"${c.name}"').join(', ')}.',
    );
  }
  return match;
}

EnvironmentModel _environment(String ref, ImportReport main) {
  if (File(ref).existsSync()) {
    final envs = _import(ref).environments;
    if (envs.isEmpty) throw InputError('$ref has no environment.');
    if (envs.length > 1) {
      throw InputError(
        '$ref has ${envs.length} environments '
        '(${envs.map((e) => '"${e.name}"').join(', ')}); '
        'use a file with one.',
      );
    }
    return envs.single;
  }
  final byName = main.environments.where((e) => e.name == ref).firstOrNull;
  if (byName != null) return byName;
  throw InputError(
    'Cannot find the environment "$ref": there is no such file'
    '${main.environments.isEmpty ? '' : ', and the run file has only '
              '${main.environments.map((e) => '"${e.name}"').join(', ')}'}.',
  );
}

List<KV> _globals(String? path, ImportReport main) {
  if (path == null) return const [];
  final report = _import(path);
  if (report.globals.isNotEmpty) return report.globals;
  final envs = report.environments;
  final named = envs.where((e) => e.name == 'Postman globals');
  if (named.length == 1) return named.single.variables;
  if (envs.length == 1) return envs.single.variables;
  throw InputError(
    envs.isEmpty
        ? '$path has no globals.'
        : '$path has ${envs.length} environments; use a Postman globals file.',
  );
}

/// Sets [values] as the variables' current values, adding missing ones.
void _setAll(List<KV> list, Map<String, String> values) {
  values.forEach((k, v) {
    final row = list.where((x) => x.key == k).firstOrNull;
    if (row != null) {
      row
        ..value = v
        ..current = null
        ..enabled = true;
    } else {
      list.add(KV(key: k, value: v));
    }
  });
}

List<RequestModel> _selectFolders(
  CollectionModel c,
  List<RequestModel> http,
  List<String> folders,
) {
  if (folders.isEmpty) return http;
  String clean(String f) => f.trim().replaceAll(RegExp(r'^/+|/+$'), '');
  final known = <String>{
    ...c.folders.keys,
    for (final r in c.requests) ...CollectionModel.folderChain(r.folder),
  };
  final wanted = [for (final f in folders) clean(f)];
  for (final f in wanted) {
    if (!known.contains(f)) {
      final list = known.toList()..sort();
      throw InputError(
        'No folder "$f" in "${c.name}". '
        '${list.isEmpty ? 'The collection has no folders.' : 'Folders: ${list.join(', ')}.'}',
      );
    }
  }
  return [
    for (final r in http)
      if (wanted.any((f) => r.folder == f || r.folder.startsWith('$f/'))) r,
  ];
}
