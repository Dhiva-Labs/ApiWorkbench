/// Converts between the descriptor model and `FileDescriptorProto` JSON
/// (as decoded by [ProtoJsonCodec] with `protoNames: true`), the form
/// server reflection sends schemas in.
library;

import 'descriptors.dart';

String _typeName(FieldType t) => 'TYPE_${t.protoName.toUpperCase()}';

FieldType? _fieldType(Object? v) {
  if (v is int) return FieldType.byNumber(v);
  for (final t in FieldType.values) {
    if (_typeName(t) == v) return t;
  }
  return null;
}

FieldLabel _label(Object? v) => switch (v) {
  'LABEL_REPEATED' || 3 => FieldLabel.repeated,
  'LABEL_REQUIRED' || 2 => FieldLabel.required,
  _ => FieldLabel.optional,
};

List<Map<String, Object?>> _list(Object? v) => [
  for (final e in v as List<Object?>? ?? const [])
    (e as Map).cast<String, Object?>(),
];

String _join(String scope, String name) =>
    scope.isEmpty ? name : '$scope.$name';

/// Builds an unlinked [ProtoFile] from a decoded `FileDescriptorProto`.
/// Link it with [DescriptorPool.build].
ProtoFile protoFileFromDescriptor(Map<String, Object?> fd) {
  final syntax = fd['syntax'] as String? ?? '';
  final file = ProtoFile(
    name: fd['name'] as String? ?? '',
    package: fd['package'] as String? ?? '',
    syntax: syntax.isEmpty ? 'proto2' : syntax,
  );
  for (final d in fd['dependency'] as List<Object?>? ?? const []) {
    file.dependencies.add('$d');
  }
  for (final m in _list(fd['message_type'])) {
    file.messages.add(_message(m, file, null, file.package));
  }
  for (final e in _list(fd['enum_type'])) {
    file.enums.add(_enum(e, file, file.package));
  }
  for (final s in _list(fd['service'])) {
    final service = ServiceDescriptor(
      name: s['name'] as String? ?? '',
      file: file,
      fullName: _join(file.package, s['name'] as String? ?? ''),
    );
    for (final m in _list(s['method'])) {
      service.methods.add(
        MethodDescriptor(
          name: m['name'] as String? ?? '',
          inputTypeName: m['input_type'] as String? ?? '',
          outputTypeName: m['output_type'] as String? ?? '',
          clientStreaming: m['client_streaming'] == true,
          serverStreaming: m['server_streaming'] == true,
        ),
      );
    }
    file.services.add(service);
  }
  return file;
}

MessageDescriptor _message(
  Map<String, Object?> m,
  ProtoFile file,
  MessageDescriptor? parent,
  String scope,
) {
  final name = m['name'] as String? ?? '';
  final md = MessageDescriptor(
    name: name,
    file: file,
    parent: parent,
    fullName: _join(scope, name),
  );
  final options = (m['options'] as Map?)?.cast<String, Object?>();
  md.mapEntry = options?['map_entry'] == true;
  final fields = _list(m['field']);
  final synthetic = {
    for (final f in fields)
      if (f['proto3_optional'] == true && f['oneof_index'] is int)
        f['oneof_index'] as int,
  };
  final decls = _list(m['oneof_decl']);
  for (var i = 0; i < decls.length; i++) {
    md.oneofs.add(
      OneofDescriptor(
        decls[i]['name'] as String? ?? '',
        synthetic: synthetic.contains(i),
      ),
    );
  }
  for (final f in fields) {
    final typeName = f['type_name'] as String?;
    final type =
        _fieldType(f['type']) ??
        (typeName != null ? FieldType.message : FieldType.string);
    final jsonName = f['json_name'] as String?;
    final field =
        FieldDescriptor(
            name: f['name'] as String? ?? '',
            number: f['number'] as int? ?? 0,
            type: type,
            label: _label(f['label']),
            typeName: typeName,
            jsonName: jsonName == null || jsonName.isEmpty ? null : jsonName,
          )
          ..containingType = md
          ..proto3Optional = f['proto3_optional'] == true
          ..defaultValue = f['default_value'] as String?;
    final fieldOptions = (f['options'] as Map?)?.cast<String, Object?>();
    field.packedOption = fieldOptions?['packed'] as bool?;
    final index = f['oneof_index'];
    if (index is int && index >= 0 && index < md.oneofs.length) {
      field.oneof = md.oneofs[index];
      md.oneofs[index].fields.add(field);
    }
    md.fields.add(field);
  }
  for (final n in _list(m['nested_type'])) {
    md.messages.add(_message(n, file, md, md.fullName));
  }
  for (final e in _list(m['enum_type'])) {
    md.enums.add(_enum(e, file, md.fullName));
  }
  return md;
}

EnumDescriptor _enum(Map<String, Object?> e, ProtoFile file, String scope) {
  final name = e['name'] as String? ?? '';
  final ed = EnumDescriptor(
    name: name,
    file: file,
    fullName: _join(scope, name),
  );
  for (final v in _list(e['value'])) {
    ed.values.add(
      EnumValueDescriptor(v['name'] as String? ?? '', v['number'] as int? ?? 0),
    );
  }
  return ed;
}

/// The `FileDescriptorProto` JSON of a linked [file], as a reflection
/// server sends it. Type names are fully qualified.
Map<String, Object?> protoFileToDescriptor(ProtoFile file) {
  Map<String, Object?> enumJson(EnumDescriptor e) => {
    'name': e.name,
    'value': [
      for (final v in e.values) {'name': v.name, 'number': v.number},
    ],
  };

  Map<String, Object?> messageJson(MessageDescriptor m) => {
    'name': m.name,
    'field': [
      for (final f in m.fields)
        {
          'name': f.name,
          'number': f.number,
          'label': 'LABEL_${f.label.name.toUpperCase()}',
          'type': _typeName(f.type),
          if (f.messageType != null) 'type_name': '.${f.messageType!.fullName}',
          if (f.enumType != null) 'type_name': '.${f.enumType!.fullName}',
          if (f.defaultValue != null) 'default_value': f.defaultValue,
          if (f.oneof != null) 'oneof_index': m.oneofs.indexOf(f.oneof!),
          'json_name': f.jsonName,
          if (f.packedOption != null) 'options': {'packed': f.packedOption},
          if (f.proto3Optional) 'proto3_optional': true,
        },
    ],
    'nested_type': [for (final n in m.messages) messageJson(n)],
    'enum_type': [for (final e in m.enums) enumJson(e)],
    'oneof_decl': [
      for (final o in m.oneofs) {'name': o.name},
    ],
    if (m.mapEntry) 'options': {'map_entry': true},
  };

  return {
    'name': file.name,
    if (file.package.isNotEmpty) 'package': file.package,
    'dependency': file.dependencies,
    'message_type': [for (final m in file.messages) messageJson(m)],
    'enum_type': [for (final e in file.enums) enumJson(e)],
    'service': [
      for (final s in file.services)
        {
          'name': s.name,
          'method': [
            for (final m in s.methods)
              {
                'name': m.name,
                'input_type': '.${m.input.fullName}',
                'output_type': '.${m.output.fullName}',
                if (m.clientStreaming) 'client_streaming': true,
                if (m.serverStreaming) 'server_streaming': true,
              },
          ],
        },
    ],
    if (!file.isProto2) 'syntax': file.syntax,
  };
}
