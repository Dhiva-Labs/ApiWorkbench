/// Loads a server's schema with gRPC server reflection
/// (`grpc.reflection.v1`, falling back to `v1alpha`).
library;

import 'dart:async';
import 'dart:convert';

import 'package:grpc/grpc.dart';

import 'descriptor_proto.dart';
import 'descriptors.dart';
import 'grpc_transport.dart';
import 'proto_json.dart';
import 'well_known.dart';

/// The server answered a reflection request with an error.
class ReflectionException implements Exception {
  ReflectionException(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() => message;
}

final Map<String, DescriptorPool> _schemas = {};

/// The reflection service and `descriptor.proto`, parsed with our own
/// parser.
DescriptorPool _schema(String version) => _schemas.putIfAbsent(
  version,
  () => DescriptorPool.build([
    builtInProto('grpc/reflection/$version/reflection.proto')!,
    builtInProto('google/protobuf/descriptor.proto')!,
  ]),
);

class ReflectionClient {
  ReflectionClient(
    this.connection, {
    this.metadata = const {},
    this.timeout = const Duration(seconds: 30),
  });

  final GrpcConnection connection;

  /// Sent with the reflection call (servers may require auth for it).
  final Map<String, String> metadata;
  final Duration timeout;

  /// The protocol version that answered the last [load].
  String? version;

  /// Every service the server lists (except reflection itself), with the
  /// files that define them and their imports.
  ///
  /// Throws [GrpcError] when the server cannot be reached or has no
  /// reflection, [ReflectionException] when it refuses a request, and
  /// [ProtoSchemaException] when the descriptors do not link.
  Future<DescriptorPool> load() async {
    try {
      return await _load('v1');
    } on GrpcError catch (e) {
      if (e.code != StatusCode.unimplemented) rethrow;
    }
    try {
      return await _load('v1alpha');
    } on GrpcError catch (e) {
      if (e.code != StatusCode.unimplemented) rethrow;
      throw GrpcError.unimplemented(
        'The server does not support reflection (neither '
        'grpc.reflection.v1 nor v1alpha). Import its .proto files instead.',
      );
    }
  }

  Future<DescriptorPool> _load(String v) async {
    final schema = _schema(v);
    final codec = ProtoJsonCodec(schema);
    final requestType = schema.findMessage(
      'grpc.reflection.$v.ServerReflectionRequest',
    )!;
    final responseType = schema.findMessage(
      'grpc.reflection.$v.ServerReflectionResponse',
    )!;
    final fileType = schema.findMessage('google.protobuf.FileDescriptorProto')!;
    final call = connection.call(
      '/grpc.reflection.$v.ServerReflection/ServerReflectionInfo',
      metadata: metadata,
      timeout: timeout,
    );
    final responses = StreamIterator(call.responses);

    Future<Map<String, Object?>> ask(Map<String, Object?> request) async {
      call.send(codec.encode(requestType, request));
      if (!await responses.moveNext()) {
        throw ReflectionException(
          'The server closed the reflection stream without answering.',
        );
      }
      final res =
          codec.decode(responseType, responses.current, protoNames: true)
              as Map<String, Object?>;
      final error = res['error_response'] as Map?;
      if (error != null) {
        throw ReflectionException(
          '${error['error_message'] ?? 'Reflection request failed'}',
          code: error['error_code'] as int?,
        );
      }
      return res;
    }

    final files = <String, ProtoFile>{};
    void addFiles(Map<String, Object?> res) {
      final fd = res['file_descriptor_response'] as Map?;
      for (final b64 in fd?['file_descriptor_proto'] as List? ?? const []) {
        final json =
            codec.decode(fileType, base64Decode('$b64'), protoNames: true)
                as Map<String, Object?>;
        final file = protoFileFromDescriptor(json);
        files.putIfAbsent(file.name, () => file);
      }
    }

    try {
      final list = await ask({'list_services': ''});
      final services = [
        for (final s
            in ((list['list_services_response'] as Map?)?['service']
                    as List?) ??
                const [])
          '${(s as Map)['name']}',
      ].where((s) => !s.startsWith('grpc.reflection.')).toList();
      final failures = <String>[];
      for (final s in services) {
        try {
          addFiles(await ask({'file_containing_symbol': s}));
        } on ReflectionException catch (e) {
          failures.add('$s: ${e.message}');
        }
      }
      if (files.isEmpty && failures.isNotEmpty) {
        throw ReflectionException(
          'The server listed services but sent no descriptors for them: '
          '${failures.join('; ')}',
        );
      }
      // Fetch imports the server did not send along.
      final pending = [for (final f in files.values) ...f.dependencies];
      while (pending.isNotEmpty) {
        final dep = pending.removeLast();
        if (files.containsKey(dep)) continue;
        try {
          final before = files.keys.toSet();
          addFiles(await ask({'file_by_filename': dep}));
          for (final name in files.keys.toSet().difference(before)) {
            pending.addAll(files[name]!.dependencies);
          }
        } on ReflectionException {
          if (builtInProtos.containsKey(dep)) continue;
          rethrow;
        }
      }
      version = v;
      return DescriptorPool.build(files.values, fallback: builtInProto);
    } finally {
      call.closeSend();
      unawaited(responses.cancel());
    }
  }
}
