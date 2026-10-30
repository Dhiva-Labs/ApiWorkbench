/// Protobuf schema model shared by the .proto parser, server reflection and
/// the dynamic JSON codec. Mirrors the parts of `descriptor.proto` a client
/// needs to build and read messages without generated code.
library;

/// A scalar or composite field type, with its `FieldDescriptorProto.Type`
/// number.
enum FieldType {
  float64('double', 1),
  float32('float', 2),
  int64('int64', 3),
  uint64('uint64', 4),
  int32('int32', 5),
  fixed64('fixed64', 6),
  fixed32('fixed32', 7),
  boolean('bool', 8),
  string('string', 9),
  group('group', 10),
  message('message', 11),
  bytes('bytes', 12),
  uint32('uint32', 13),
  enumeration('enum', 14),
  sfixed32('sfixed32', 15),
  sfixed64('sfixed64', 16),
  sint32('sint32', 17),
  sint64('sint64', 18);

  const FieldType(this.protoName, this.number);

  /// The keyword used in .proto files (`int32`, `bool`, ...).
  final String protoName;
  final int number;

  static final Map<String, FieldType> _scalars = {
    for (final t in values)
      if (t != group && t != message && t != enumeration) t.protoName: t,
  };

  /// The scalar type spelled [name] in a .proto file, or null for a
  /// message or enum name.
  static FieldType? scalar(String name) => _scalars[name];

  static FieldType? byNumber(int n) =>
      n >= 1 && n <= values.length ? values[n - 1] : null;

  /// Repeated fields of these types can use the packed encoding.
  bool get packable =>
      this != string && this != bytes && this != message && this != group;

  /// Integers that the JSON mapping writes as strings.
  bool get is64Bit =>
      this == int64 ||
      this == uint64 ||
      this == fixed64 ||
      this == sfixed64 ||
      this == sint64;

  /// Valid key types of a map field.
  bool get isMapKey =>
      this == string ||
      (packable && this != float32 && this != float64 && this != enumeration);

  /// The wire type of one value of this type (unpacked).
  int get wireType => switch (this) {
    float64 || fixed64 || sfixed64 => 1,
    float32 || fixed32 || sfixed32 => 5,
    string || bytes || message => 2,
    group => 3,
    _ => 0,
  };
}

enum FieldLabel { optional, required, repeated }

/// The four gRPC call shapes, from the method's stream flags.
enum CallKind {
  unary('Unary'),
  serverStreaming('Server streaming'),
  clientStreaming('Client streaming'),
  bidiStreaming('Bidirectional streaming');

  const CallKind(this.label);
  final String label;
}

/// A schema problem at a place in a .proto file: a syntax error, an
/// unknown type, a missing import.
class ProtoSchemaException implements Exception {
  ProtoSchemaException(this.file, this.line, this.column, this.message);

  final String file;

  /// 1-based; 0 when the place is unknown (reflection descriptors).
  final int line;
  final int column;
  final String message;

  @override
  String toString() {
    if (line <= 0) return file.isEmpty ? message : '$file: $message';
    return '$file:$line:$column: $message';
  }
}

/// One .proto file (parsed, or decoded from a `FileDescriptorProto`).
class ProtoFile {
  ProtoFile({required this.name, this.package = '', this.syntax = 'proto2'});

  /// The path it is imported by, such as `google/protobuf/empty.proto`.
  final String name;
  String package;

  /// `proto2`, `proto3` or `editions`.
  String syntax;

  /// Imported paths, as written.
  final List<String> dependencies = [];

  /// Line of each import, for error messages.
  final Map<String, int> importLines = {};
  final List<MessageDescriptor> messages = [];
  final List<EnumDescriptor> enums = [];
  final List<ServiceDescriptor> services = [];

  bool get isProto3 => syntax == 'proto3';
  bool get isProto2 => syntax == 'proto2';
}

class MessageDescriptor {
  MessageDescriptor({
    required this.name,
    required this.file,
    this.parent,
    this.line = 0,
    this.column = 0,
    String? fullName,
  }) : fullName = fullName ?? '';

  final String name;

  /// Package-qualified name without a leading dot (`pkg.Outer.Inner`).
  String fullName;
  final ProtoFile file;
  final MessageDescriptor? parent;
  final int line;
  final int column;
  final List<FieldDescriptor> fields = [];
  final List<OneofDescriptor> oneofs = [];
  final List<MessageDescriptor> messages = [];
  final List<EnumDescriptor> enums = [];

  /// The synthesized `XxxEntry` message of a map field.
  bool mapEntry = false;

  Map<int, FieldDescriptor>? _byNumber;
  Map<String, FieldDescriptor>? _byName;

  FieldDescriptor? fieldByNumber(int number) =>
      (_byNumber ??= {for (final f in fields) f.number: f})[number];

  /// Looks a field up by its .proto name or its JSON name.
  FieldDescriptor? fieldByName(String name) => (_byName ??= {
    for (final f in fields) f.jsonName: f,
    for (final f in fields) f.name: f,
  })[name];

  /// Key and value fields of a map entry.
  FieldDescriptor get mapKey => fieldByNumber(1)!;
  FieldDescriptor get mapValue => fieldByNumber(2)!;

  @override
  String toString() => fullName;
}

class FieldDescriptor {
  FieldDescriptor({
    required this.name,
    required this.number,
    required this.type,
    this.label = FieldLabel.optional,
    this.typeName,
    String? jsonName,
    this.line = 0,
    this.column = 0,
  }) : jsonName = jsonName ?? protoJsonName(name);

  final String name;
  final int number;
  FieldLabel label;

  /// For message and enum fields, set when the pool links [typeName].
  FieldType type;

  /// The message, enum or group type as written; `.pkg.Msg` when fully
  /// qualified. Null for scalars.
  String? typeName;
  MessageDescriptor? messageType;
  EnumDescriptor? enumType;
  late MessageDescriptor containingType;
  OneofDescriptor? oneof;

  /// A proto3 `optional` field (it has presence, through a synthetic oneof).
  bool proto3Optional = false;

  /// The `[packed = ...]` option, when given.
  bool? packedOption;

  /// The proto2 `[default = ...]` value as written.
  String? defaultValue;
  String jsonName;
  final int line;
  final int column;

  bool get isRepeated => label == FieldLabel.repeated;
  bool get isMap => isRepeated && (messageType?.mapEntry ?? false);
  bool get isMessage => type == FieldType.message || type == FieldType.group;

  /// Repeated scalars are packed by default except in proto2.
  bool get isPacked =>
      isRepeated &&
      type.packable &&
      (packedOption ?? !containingType.file.isProto2);

  /// Whether "not set" differs from the default value. Fields without it
  /// (proto3 scalars) are not written when they hold the default.
  bool get hasPresence =>
      !isRepeated &&
      (isMessage || oneof != null || !containingType.file.isProto3);

  /// The real (non-synthetic) oneof this field belongs to.
  OneofDescriptor? get realOneof =>
      oneof == null || oneof!.synthetic ? null : oneof;

  /// The type as a .proto file spells it, such as `map<string, int32>`.
  String get typeLabel {
    if (isMap) {
      return 'map<${messageType!.mapKey.typeLabel}, '
          '${messageType!.mapValue.typeLabel}>';
    }
    final base = switch (type) {
      FieldType.message || FieldType.group => messageType?.fullName ?? '',
      FieldType.enumeration => enumType?.fullName ?? '',
      _ => type.protoName,
    };
    return isRepeated ? 'repeated $base' : base;
  }

  @override
  String toString() => '${containingType.fullName}.$name';
}

class OneofDescriptor {
  OneofDescriptor(this.name, {this.synthetic = false});

  final String name;

  /// The hidden oneof of a proto3 `optional` field.
  final bool synthetic;
  final List<FieldDescriptor> fields = [];
}

class EnumValueDescriptor {
  const EnumValueDescriptor(this.name, this.number);

  final String name;
  final int number;
}

class EnumDescriptor {
  EnumDescriptor({
    required this.name,
    required this.file,
    this.line = 0,
    this.column = 0,
    String? fullName,
  }) : fullName = fullName ?? '';

  final String name;
  String fullName;
  final ProtoFile file;
  final int line;
  final int column;
  final List<EnumValueDescriptor> values = [];

  EnumValueDescriptor? valueByName(String name) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    return null;
  }

  /// The first value with [number] (aliases share numbers).
  EnumValueDescriptor? valueByNumber(int number) {
    for (final v in values) {
      if (v.number == number) return v;
    }
    return null;
  }

  @override
  String toString() => fullName;
}

class ServiceDescriptor {
  ServiceDescriptor({
    required this.name,
    required this.file,
    this.line = 0,
    String? fullName,
  }) : fullName = fullName ?? '';

  final String name;
  String fullName;
  final ProtoFile file;
  final int line;
  final List<MethodDescriptor> methods = [];

  MethodDescriptor? method(String name) {
    for (final m in methods) {
      if (m.name == name) return m;
    }
    return null;
  }

  @override
  String toString() => fullName;
}

class MethodDescriptor {
  MethodDescriptor({
    required this.name,
    required this.inputTypeName,
    required this.outputTypeName,
    this.clientStreaming = false,
    this.serverStreaming = false,
    this.line = 0,
    this.column = 0,
  });

  final String name;
  final String inputTypeName;
  final String outputTypeName;
  final bool clientStreaming;
  final bool serverStreaming;
  final int line;
  final int column;
  late ServiceDescriptor service;
  late MessageDescriptor input;
  late MessageDescriptor output;

  /// The HTTP/2 path of the call: `/pkg.Service/Method`.
  String get path => '/${service.fullName}/$name';

  CallKind get kind => switch ((clientStreaming, serverStreaming)) {
    (false, false) => CallKind.unary,
    (false, true) => CallKind.serverStreaming,
    (true, false) => CallKind.clientStreaming,
    (true, true) => CallKind.bidiStreaming,
  };

  @override
  String toString() => '${service.fullName}.$name';
}

/// The JSON name protoc derives from a field name: underscores dropped and
/// the letter after each one upper-cased (`user_id` → `userId`).
String protoJsonName(String name) {
  final out = StringBuffer();
  var upper = false;
  for (final c in name.split('')) {
    if (c == '_') {
      upper = true;
    } else if (upper) {
      out.write(c.toUpperCase());
      upper = false;
    } else {
      out.write(c);
    }
  }
  return out.toString();
}

/// Every message, enum and service of a set of linked files, by full name.
class DescriptorPool {
  DescriptorPool._();

  /// Files by name, imports included.
  final Map<String, ProtoFile> files = {};
  final Map<String, MessageDescriptor> _messages = {};
  final Map<String, EnumDescriptor> _enums = {};
  final Map<String, ServiceDescriptor> _services = {};

  /// Links [files] and their imports. An import is matched to a file of
  /// the same name, then to one whose path ends with it (a file picked
  /// from disk as `/home/me/protos/foo/bar.proto` satisfies
  /// `import "foo/bar.proto"`), then to [fallback] (the built-in
  /// well-known types).
  ///
  /// Throws [ProtoSchemaException] for a missing import, a duplicate
  /// symbol or an unknown type.
  factory DescriptorPool.build(
    Iterable<ProtoFile> files, {
    ProtoFile? Function(String path)? fallback,
  }) {
    final pool = DescriptorPool._();
    final queue = <ProtoFile>[];
    for (final f in files) {
      if (pool.files.containsKey(f.name)) continue;
      pool.files[f.name] = f;
      queue.add(f);
    }
    while (queue.isNotEmpty) {
      final f = queue.removeAt(0);
      for (final dep in f.dependencies) {
        final hit = pool._findImport(dep) ?? fallback?.call(dep);
        if (hit == null) {
          throw ProtoSchemaException(
            f.name,
            f.importLines[dep] ?? 0,
            1,
            'Import "$dep" was not found. Load that file too, or add the '
            'folder that contains it as an import path.',
          );
        }
        if (!pool.files.containsKey(hit.name)) {
          pool.files[hit.name] = hit;
          queue.add(hit);
        }
      }
    }
    for (final f in pool.files.values) {
      pool._register(f);
    }
    for (final f in pool.files.values) {
      pool._link(f);
    }
    return pool;
  }

  ProtoFile? _findImport(String path) {
    final exact = files[path];
    if (exact != null) return exact;
    final wanted = path.replaceAll('\\', '/');
    for (final f in files.values) {
      final name = f.name.replaceAll('\\', '/');
      if (name == wanted || name.endsWith('/$wanted')) return f;
    }
    return null;
  }

  /// Services sorted by full name.
  List<ServiceDescriptor> get services =>
      _services.values.toList()
        ..sort((a, b) => a.fullName.compareTo(b.fullName));

  Iterable<MessageDescriptor> get messages => _messages.values;

  MessageDescriptor? findMessage(String name) =>
      _messages[name.startsWith('.') ? name.substring(1) : name];

  EnumDescriptor? findEnum(String name) =>
      _enums[name.startsWith('.') ? name.substring(1) : name];

  ServiceDescriptor? findService(String name) =>
      _services[name.startsWith('.') ? name.substring(1) : name];

  MethodDescriptor? findMethod(String service, String method) =>
      findService(service)?.method(method);

  void _define(
    String fullName,
    Object symbol,
    ProtoFile file,
    int line, [
    int column = 1,
  ]) {
    final existing =
        _messages[fullName] ?? _enums[fullName] ?? _services[fullName];
    if (existing != null) {
      final other = switch (existing) {
        MessageDescriptor m => m.file.name,
        EnumDescriptor e => e.file.name,
        ServiceDescriptor s => s.file.name,
        _ => '',
      };
      throw ProtoSchemaException(
        file.name,
        line,
        column,
        '"$fullName" is already defined'
        '${other == file.name ? '' : ' in $other'}.',
      );
    }
    switch (symbol) {
      case MessageDescriptor m:
        _messages[fullName] = m;
      case EnumDescriptor e:
        _enums[fullName] = e;
      case ServiceDescriptor s:
        _services[fullName] = s;
    }
  }

  void _register(ProtoFile f) {
    void message(MessageDescriptor m) {
      _define(m.fullName, m, f, m.line, m.column);
      m.messages.forEach(message);
      for (final e in m.enums) {
        _define(e.fullName, e, f, e.line, e.column);
      }
    }

    f.messages.forEach(message);
    for (final e in f.enums) {
      _define(e.fullName, e, f, e.line, e.column);
    }
    for (final s in f.services) {
      _define(s.fullName, s, f, s.line);
    }
  }

  /// Protobuf scoping: a relative name is looked up in the innermost scope
  /// first, then in each enclosing scope.
  Object? _resolve(String name, String scope) {
    if (name.startsWith('.')) {
      final n = name.substring(1);
      return _messages[n] ?? _enums[n];
    }
    var s = scope;
    while (true) {
      final candidate = s.isEmpty ? name : '$s.$name';
      final hit = _messages[candidate] ?? _enums[candidate];
      if (hit != null) return hit;
      if (s.isEmpty) return null;
      final dot = s.lastIndexOf('.');
      s = dot < 0 ? '' : s.substring(0, dot);
    }
  }

  void _link(ProtoFile f) {
    void message(MessageDescriptor m) {
      for (final field in m.fields) {
        field.containingType = m;
        final name = field.typeName;
        if (name == null) continue;
        final hit = _resolve(name, m.fullName);
        switch (hit) {
          case MessageDescriptor t:
            field.messageType = t;
            if (field.type != FieldType.group) field.type = FieldType.message;
          case EnumDescriptor t:
            field.enumType = t;
            field.type = FieldType.enumeration;
          default:
            throw ProtoSchemaException(
              f.name,
              field.line,
              field.column,
              'Unknown type "$name" for field "${field.name}" in '
              '${m.fullName}. Check the spelling, the package, and that the '
              'file defining it is imported.',
            );
        }
      }
      m.messages.forEach(message);
    }

    f.messages.forEach(message);
    for (final s in f.services) {
      for (final method in s.methods) {
        method.service = s;
        MessageDescriptor type(String name, String role) {
          final hit = _resolve(name, f.package);
          if (hit is MessageDescriptor) return hit;
          throw ProtoSchemaException(
            f.name,
            method.line,
            method.column,
            hit == null
                ? 'Unknown $role type "$name" for rpc ${method.name}.'
                : '"$name" is an enum; rpc ${method.name} needs a message '
                      'as its $role type.',
          );
        }

        method.input = type(method.inputTypeName, 'request');
        method.output = type(method.outputTypeName, 'response');
      }
    }
  }
}
