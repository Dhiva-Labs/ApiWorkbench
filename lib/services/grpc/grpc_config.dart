/// The saved settings of a gRPC request, kept in
/// `RequestModel.protocolConfig`, and loading its schema from .proto files.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../models/models.dart';
import 'descriptors.dart';
import 'proto_parser.dart';
import 'well_known.dart';

/// Where a gRPC tab gets its services from.
enum GrpcSchemaSource { reflection, protoFiles }

/// Settings of a gRPC tab. Everything round-trips through JSON, so it can
/// live in `RequestModel.protocolConfig`.
class GrpcConfig {
  GrpcConfig({
    this.service = '',
    this.method = '',
    this.source = GrpcSchemaSource.reflection,
    List<String>? protoPaths,
    List<String>? importPaths,
    this.protoText = '',
    List<KV>? metadata,
    this.message = '{}',
    this.tls = false,
    this.verify = true,
    this.deadlineMs = 0,
    this.emitDefaults = true,
  }) : protoPaths = protoPaths ?? [],
       importPaths = importPaths ?? [],
       metadata = metadata ?? [];

  /// Full service name, such as `helloworld.Greeter`.
  String service;
  String method;
  GrpcSchemaSource source;

  /// Imported .proto files on this device.
  List<String> protoPaths;

  /// Extra folders searched for the files those import.
  List<String> importPaths;

  /// Pasted .proto source, used with (or instead of) [protoPaths].
  String protoText;
  List<KV> metadata;

  /// The request message as JSON text ({{variables}} allowed).
  String message;
  bool tls;

  /// Check the server's TLS certificate.
  bool verify;

  /// Call deadline in milliseconds; 0 waits forever.
  int deadlineMs;

  /// Show fields that hold their default value in responses.
  bool emitDefaults;

  factory GrpcConfig.fromJson(Map<String, dynamic> j) => GrpcConfig(
    service: j['service'] as String? ?? '',
    method: j['method'] as String? ?? '',
    source: j['source'] == 'proto'
        ? GrpcSchemaSource.protoFiles
        : GrpcSchemaSource.reflection,
    protoPaths: [for (final x in j['protoPaths'] as List? ?? const []) '$x'],
    importPaths: [for (final x in j['importPaths'] as List? ?? const []) '$x'],
    protoText: j['protoText'] as String? ?? '',
    metadata: [
      for (final x in j['metadata'] as List? ?? const [])
        KV.fromJson((x as Map).cast<String, dynamic>()),
    ],
    message: j['message'] as String? ?? '{}',
    tls: j['tls'] as bool? ?? false,
    verify: j['verify'] as bool? ?? true,
    deadlineMs: (j['deadlineMs'] as num?)?.toInt() ?? 0,
    emitDefaults: j['emitDefaults'] as bool? ?? true,
  );

  Map<String, dynamic> toJson() => {
    if (service.isNotEmpty) 'service': service,
    if (method.isNotEmpty) 'method': method,
    'source': source == GrpcSchemaSource.protoFiles ? 'proto' : 'reflection',
    if (protoPaths.isNotEmpty) 'protoPaths': protoPaths,
    if (importPaths.isNotEmpty) 'importPaths': importPaths,
    if (protoText.isNotEmpty) 'protoText': protoText,
    if (metadata.isNotEmpty) 'metadata': [for (final m in metadata) m.toJson()],
    'message': message,
    'tls': tls,
    'verify': verify,
    if (deadlineMs > 0) 'deadlineMs': deadlineMs,
    if (!emitDefaults) 'emitDefaults': false,
  };

  /// Reads [request]'s settings (defaults when it has none).
  static GrpcConfig of(RequestModel request) =>
      GrpcConfig.fromJson(request.protocolConfig);

  /// Writes these settings into [request].
  void saveTo(RequestModel request) => request.protocolConfig = toJson();
}

/// Name given to pasted .proto text.
const pastedProtoName = 'pasted.proto';

/// Reads [paths] (and [text], when not blank) and every file they import,
/// then links them. Imports are looked up next to the importing file and
/// in its parent folders, then in [importPaths]; the well-known types are
/// built in.
///
/// Throws [ProtoSchemaException] for syntax and schema errors, and
/// [FileSystemException] for unreadable files.
Future<DescriptorPool> loadProtoFiles(
  List<String> paths, {
  List<String> importPaths = const [],
  String text = '',
}) async {
  final parsed = <String, ProtoFile>{};
  final dirs = <String, String>{}; // file name → its folder on disk
  final queue = <ProtoFile>[];

  Future<void> add(String name, String path) async {
    final source = await File(path).readAsString();
    final file = parseProto(source, name: name);
    parsed[name] = file;
    dirs[name] = p.dirname(path);
    queue.add(file);
  }

  for (final path in paths) {
    if (parsed.containsKey(path)) continue;
    await add(path, path);
  }
  if (text.trim().isNotEmpty) {
    final file = parseProto(text, name: pastedProtoName);
    parsed[pastedProtoName] = file;
    queue.add(file);
  }

  bool known(String import) {
    if (parsed.containsKey(import)) return true;
    final wanted = import.replaceAll('\\', '/');
    return parsed.keys.any((k) => k.replaceAll('\\', '/').endsWith('/$wanted'));
  }

  while (queue.isNotEmpty) {
    final file = queue.removeAt(0);
    for (final import in file.dependencies) {
      if (known(import) || builtInProtos.containsKey(import)) continue;
      final candidates = <String>[];
      final dir = dirs[file.name];
      if (dir != null) {
        // The file's own folder and its parents: protos usually import
        // relative to a root a few levels up.
        var d = dir;
        while (true) {
          candidates.add(d);
          final parent = p.dirname(d);
          if (parent == d) break;
          d = parent;
        }
      }
      candidates.addAll(importPaths);
      for (final c in candidates) {
        final path = p.join(c, import);
        if (await File(path).exists()) {
          await add(import, path);
          break;
        }
      }
      // Still missing: DescriptorPool.build reports it with its line.
    }
  }
  return DescriptorPool.build(parsed.values, fallback: builtInProto);
}
