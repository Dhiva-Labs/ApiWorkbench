/// Example JSON for a message type, used by "Generate example message".
library;

import 'dart:convert';

import 'descriptors.dart';
import 'proto_json.dart' show formatTimestamp;

/// An example of [type] as JSON: every field with a placeholder value
/// (strings hold their field name, numbers are zero, enums their first
/// value), lists and maps with one item, and only the first field of each
/// oneof. A message that contains itself is cut off where it recurs.
Object? exampleJson(MessageDescriptor type, {DateTime? now}) =>
    _Example(now ?? DateTime.now()).message(type, {});

/// [exampleJson] as indented JSON text.
String exampleJsonText(MessageDescriptor type, {DateTime? now}) =>
    const JsonEncoder.withIndent('  ').convert(exampleJson(type, now: now));

class _Example {
  _Example(this.now);

  final DateTime now;

  Object? message(MessageDescriptor md, Set<String> stack) {
    switch (md.fullName) {
      case 'google.protobuf.Timestamp':
        final s = now.toUtc().millisecondsSinceEpoch ~/ 1000;
        return formatTimestamp(s, 0);
      case 'google.protobuf.Duration':
        return '1.5s';
      case 'google.protobuf.FieldMask':
        return 'name';
      case 'google.protobuf.Struct':
        return {'key': 'value'};
      case 'google.protobuf.Value':
        return 'value';
      case 'google.protobuf.ListValue':
        return ['value'];
      case 'google.protobuf.Any':
        return {'@type': 'type.googleapis.com/google.protobuf.Empty'};
    }
    if (md.fullName.startsWith('google.protobuf.') &&
        md.fullName.endsWith('Value') &&
        md.fields.length == 1) {
      return single(md.fields.single, stack); // wrappers
    }
    final next = {...stack, md.fullName};
    final out = <String, Object?>{};
    final usedOneofs = <OneofDescriptor>{};
    for (final f in md.fields) {
      final oneof = f.realOneof;
      if (oneof != null && !usedOneofs.add(oneof)) continue;
      if (f.isMap) {
        final entry = f.messageType!;
        final value = single(entry.mapValue, next);
        out[f.jsonName] = {_mapKey(entry.mapKey): value};
        continue;
      }
      final recursive = f.isMessage && next.contains(f.messageType!.fullName);
      if (recursive) {
        if (f.isRepeated) out[f.jsonName] = <Object?>[];
        continue;
      }
      final value = single(f, next);
      out[f.jsonName] = f.isRepeated ? [value] : value;
    }
    return out;
  }

  Object? single(FieldDescriptor f, Set<String> stack) {
    if (f.isMessage) {
      final md = f.messageType!;
      if (stack.contains(md.fullName)) return <String, Object?>{};
      return message(md, stack);
    }
    return switch (f.type) {
      FieldType.enumeration =>
        f.enumType!.fullName == 'google.protobuf.NullValue'
            ? null
            : f.enumType!.values.first.name,
      FieldType.string => f.name,
      FieldType.bytes => '',
      FieldType.boolean => false,
      FieldType.float32 || FieldType.float64 => 0.0,
      final t => t.is64Bit ? '0' : 0,
    };
  }

  static String _mapKey(FieldDescriptor key) => switch (key.type) {
    FieldType.string => 'key',
    FieldType.boolean => 'true',
    _ => '0',
  };
}
