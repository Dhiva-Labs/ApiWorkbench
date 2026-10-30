/// Converts between JSON and protobuf wire bytes for any message in a
/// [DescriptorPool], following the proto3 JSON mapping: 64-bit integers as
/// strings, bytes as base64, enums by name, and the special forms of the
/// well-known types (Timestamp, Duration, wrappers, Struct, Value,
/// ListValue, FieldMask, Empty and Any).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'descriptors.dart';
import 'wire.dart';

/// A JSON value that does not fit the message schema. [path] points at it,
/// such as `user.tags[2]`.
class ProtoJsonException implements Exception {
  ProtoJsonException(this.path, this.message);

  final String path;
  final String message;

  @override
  String toString() => path.isEmpty ? message : '$path: $message';
}

const _any = 'google.protobuf.Any';
const _timestamp = 'google.protobuf.Timestamp';
const _duration = 'google.protobuf.Duration';
const _fieldMask = 'google.protobuf.FieldMask';
const _struct = 'google.protobuf.Struct';
const _value = 'google.protobuf.Value';
const _listValue = 'google.protobuf.ListValue';
const _nullValue = 'google.protobuf.NullValue';
const _wrappers = {
  'google.protobuf.DoubleValue',
  'google.protobuf.FloatValue',
  'google.protobuf.Int64Value',
  'google.protobuf.UInt64Value',
  'google.protobuf.Int32Value',
  'google.protobuf.UInt32Value',
  'google.protobuf.BoolValue',
  'google.protobuf.StringValue',
  'google.protobuf.BytesValue',
};

/// Well-known types whose JSON is not a plain object of their fields.
bool hasSpecialJson(String fullName) =>
    fullName == _any ||
    fullName == _timestamp ||
    fullName == _duration ||
    fullName == _fieldMask ||
    fullName == _struct ||
    fullName == _value ||
    fullName == _listValue ||
    _wrappers.contains(fullName);

class ProtoJsonCodec {
  /// [pool] resolves the `@type` of `google.protobuf.Any` values.
  ProtoJsonCodec([this.pool]);

  final DescriptorPool? pool;

  /// Encodes [json] (a value from `jsonDecode`) as a [type] message.
  ///
  /// Fields are written in field-number order; proto3 fields without
  /// presence are left out when they hold their default, as protoc's
  /// serializers do. Throws [ProtoJsonException].
  Uint8List encode(MessageDescriptor type, Object? json) {
    final w = ProtoWriter();
    _writeMessage(w, type, json, '');
    return w.takeBytes();
  }

  /// Parses [text] as JSON and encodes it; blank text is an empty message.
  Uint8List encodeText(MessageDescriptor type, String text) {
    if (text.trim().isEmpty) return encode(type, const <String, Object?>{});
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException catch (e) {
      throw ProtoJsonException(
        '',
        'The message is not valid JSON: ${_where(e, text)}',
      );
    }
    return encode(type, json);
  }

  /// Decodes [bytes] as a [type] message into JSON values.
  ///
  /// With [emitDefaults], proto3 fields that hold their default (and empty
  /// lists and maps) are included. With [protoNames], keys are the .proto
  /// field names instead of their lowerCamelCase JSON names. Throws
  /// [ProtoDecodeException] for malformed bytes.
  Object? decode(
    MessageDescriptor type,
    List<int> bytes, {
    bool emitDefaults = false,
    bool protoNames = false,
  }) => _Decoder(
    this,
    emitDefaults,
    protoNames,
  ).message(type, bytes is Uint8List ? bytes : Uint8List.fromList(bytes));

  // ---------------- Encoding ----------------

  void _writeMessage(
    ProtoWriter w,
    MessageDescriptor md,
    Object? json,
    String path,
  ) {
    final obj = _fromSpecialJson(md, json, path);
    if (obj == null) return;
    if (obj is! Map) {
      throw ProtoJsonException(
        path,
        'Expected an object for ${md.fullName}, got ${_show(obj)}.',
      );
    }
    final set = <FieldDescriptor, Object?>{};
    for (final e in obj.entries) {
      final key = '${e.key}';
      final f = md.fieldByName(key);
      if (f == null) {
        throw ProtoJsonException(
          _join(path, key),
          'Unknown field "$key" in ${md.fullName}.${_known(md)}',
        );
      }
      if (set.containsKey(f)) {
        throw ProtoJsonException(
          _join(path, key),
          'Field "${f.name}" is set twice (as "${f.name}" and '
          '"${f.jsonName}").',
        );
      }
      set[f] = e.value;
    }
    final oneofs = <OneofDescriptor, FieldDescriptor>{};
    for (final f in set.keys) {
      final o = f.realOneof;
      if (o == null || (set[f] == null && !_nullIsValue(f))) continue;
      final other = oneofs[o];
      if (other != null) {
        throw ProtoJsonException(
          path,
          'Only one field of oneof "${o.name}" can be set, but both '
          '"${other.jsonName}" and "${f.jsonName}" are.',
        );
      }
      oneofs[o] = f;
    }
    final ordered = set.keys.toList()
      ..sort((a, b) => a.number.compareTo(b.number));
    for (final f in ordered) {
      _writeField(w, f, set[f], _join(path, f.jsonName));
    }
  }

  /// `null` means "not set", except for `google.protobuf.Value` (and
  /// `NullValue`), where it is the JSON null.
  bool _nullIsValue(FieldDescriptor f) =>
      !f.isRepeated &&
      (f.messageType?.fullName == _value || f.enumType?.fullName == _nullValue);

  void _writeField(ProtoWriter w, FieldDescriptor f, Object? v, String path) {
    if (v == null) {
      if (_nullIsValue(f)) _writeSingle(w, f, null, path, force: true);
      return;
    }
    if (f.isMap) {
      if (v is! Map) {
        throw ProtoJsonException(
          path,
          'Expected an object (${f.typeLabel}), got ${_show(v)}.',
        );
      }
      final entry = f.messageType!;
      for (final e in v.entries) {
        final p = '$path["${e.key}"]';
        final ew = ProtoWriter();
        _writeSingle(ew, entry.mapKey, '${e.key}', p, force: true);
        _writeSingle(ew, entry.mapValue, e.value, p, force: true);
        w
          ..tag(f.number, WireType.lengthDelimited)
          ..bytes(ew.takeBytes());
      }
      return;
    }
    if (f.isRepeated) {
      if (v is! List) {
        throw ProtoJsonException(
          path,
          'Expected a list (${f.typeLabel}), got ${_show(v)}.',
        );
      }
      if (f.isPacked) {
        if (v.isEmpty) return;
        final pw = ProtoWriter();
        for (var i = 0; i < v.length; i++) {
          _writeValue(pw, f.type, _scalar(f, v[i], '$path[$i]'));
        }
        w
          ..tag(f.number, WireType.lengthDelimited)
          ..bytes(pw.takeBytes());
        return;
      }
      for (var i = 0; i < v.length; i++) {
        final item = v[i];
        if (item == null && f.messageType?.fullName != _value) {
          throw ProtoJsonException('$path[$i]', 'Lists cannot contain null.');
        }
        _writeSingle(w, f, item, '$path[$i]', force: true);
      }
      return;
    }
    _writeSingle(w, f, v, path, force: f.hasPresence);
  }

  /// Writes the tag and one value. Without [force], a default scalar is
  /// left out (proto3 fields without presence).
  void _writeSingle(
    ProtoWriter w,
    FieldDescriptor f,
    Object? v,
    String path, {
    required bool force,
  }) {
    switch (f.type) {
      case FieldType.message:
        final nested = ProtoWriter();
        _writeMessage(nested, f.messageType!, v, path);
        w
          ..tag(f.number, WireType.lengthDelimited)
          ..bytes(nested.takeBytes());
      case FieldType.group:
        w.tag(f.number, WireType.startGroup);
        _writeMessage(w, f.messageType!, v, path);
        w.tag(f.number, WireType.endGroup);
      default:
        final value = _scalar(f, v, path);
        if (!force && _isDefault(value)) return;
        w.tag(f.number, f.type.wireType);
        _writeValue(w, f.type, value);
    }
  }

  static bool _isDefault(Object value) => switch (value) {
    int v => v == 0,
    double v => v == 0 && !v.isNegative,
    bool v => !v,
    String v => v.isEmpty,
    Uint8List v => v.isEmpty,
    _ => false,
  };

  static void _writeValue(ProtoWriter w, FieldType t, Object v) {
    switch (t) {
      case FieldType.int32 ||
          FieldType.int64 ||
          FieldType.uint32 ||
          FieldType.uint64 ||
          FieldType.enumeration:
        w.varint(v as int);
      case FieldType.sint32 || FieldType.sint64:
        w.varint(zigzagEncode(v as int));
      case FieldType.boolean:
        w.varint((v as bool) ? 1 : 0);
      case FieldType.fixed32 || FieldType.sfixed32:
        w.fixed32(v as int);
      case FieldType.fixed64 || FieldType.sfixed64:
        w.fixed64(v as int);
      case FieldType.float32:
        w.float32(v as double);
      case FieldType.float64:
        w.float64(v as double);
      case FieldType.string:
        w.string(v as String);
      case FieldType.bytes:
        w.bytes(v as Uint8List);
      case FieldType.message || FieldType.group:
        throw StateError('not a scalar');
    }
  }

  /// [v] as the Dart value of [f]'s scalar type: int, double, bool,
  /// String or Uint8List.
  Object _scalar(FieldDescriptor f, Object? v, String path) {
    final t = f.type;
    switch (t) {
      case FieldType.enumeration:
        return _enumNumber(f.enumType!, v, path);
      case FieldType.float32 || FieldType.float64:
        return _double(t, v, path);
      case FieldType.boolean:
        if (v is bool) return v;
        if (v == 'true' || v == 'false') return v == 'true';
        throw ProtoJsonException(
          path,
          'Expected true or false, got ${_show(v)}.',
        );
      case FieldType.string:
        if (v is String) return v;
        throw ProtoJsonException(path, 'Expected a string, got ${_show(v)}.');
      case FieldType.bytes:
        if (v is String) {
          final bytes = _base64(v);
          if (bytes != null) return bytes;
        }
        throw ProtoJsonException(
          path,
          'Expected bytes as a base64 string, got ${_show(v)}.',
        );
      case FieldType.message || FieldType.group:
        throw StateError('not a scalar');
      default:
        return _int(t, v, path);
    }
  }

  static int _int(FieldType t, Object? v, String path) {
    final (signed, bits) = switch (t) {
      FieldType.int32 || FieldType.sint32 || FieldType.sfixed32 => (true, 32),
      FieldType.uint32 || FieldType.fixed32 => (false, 32),
      FieldType.uint64 || FieldType.fixed64 => (false, 64),
      _ => (true, 64),
    };
    BigInt? big;
    if (v is int) {
      big = BigInt.from(v);
    } else if (v is double) {
      if (v.isFinite && v == v.truncateToDouble()) big = BigInt.from(v);
    } else if (v is String) {
      final s = v.trim();
      big = BigInt.tryParse(s);
      if (big == null) {
        final d = double.tryParse(s);
        if (d != null && d.isFinite && d == d.truncateToDouble()) {
          big = BigInt.from(d);
        }
      }
    }
    if (big == null) {
      throw ProtoJsonException(
        path,
        'Expected ${t.protoName} (a whole number'
        '${t.is64Bit ? ', best written as a string' : ''}), got ${_show(v)}.',
      );
    }
    final min = signed ? -(BigInt.one << (bits - 1)) : BigInt.zero;
    final max = signed
        ? (BigInt.one << (bits - 1)) - BigInt.one
        : (BigInt.one << bits) - BigInt.one;
    if (big < min || big > max) {
      throw ProtoJsonException(
        path,
        '$big is out of range for ${t.protoName} ($min to $max).',
      );
    }
    return big.toSigned(64).toInt();
  }

  static double _double(FieldType t, Object? v, String path) {
    double? d;
    if (v is num) {
      d = v.toDouble();
    } else if (v is String) {
      d = switch (v.trim()) {
        'NaN' => double.nan,
        'Infinity' => double.infinity,
        '-Infinity' => double.negativeInfinity,
        final s => double.tryParse(s),
      };
    }
    if (d == null) {
      throw ProtoJsonException(
        path,
        'Expected a number (or "NaN", "Infinity", "-Infinity"), got '
        '${_show(v)}.',
      );
    }
    if (t == FieldType.float32 &&
        d.isFinite &&
        d.abs() > 3.4028234663852886e38) {
      throw ProtoJsonException(path, '$d is out of range for float.');
    }
    return d;
  }

  static int _enumNumber(EnumDescriptor e, Object? v, String path) {
    if (v == null && e.fullName == _nullValue) return 0;
    if (v is String) {
      final hit = e.valueByName(v);
      if (hit != null) return hit.number;
      final n = int.tryParse(v);
      if (n != null) return n;
      final names = e.values.map((x) => x.name).take(12).join(', ');
      throw ProtoJsonException(
        path,
        'Unknown value "$v" for enum ${e.fullName}. Use one of: $names'
        '${e.values.length > 12 ? ', ...' : ''}.',
      );
    }
    if (v is num && v == v.truncate()) {
      final n = v.toInt();
      if (n < -2147483648 || n > 2147483647) {
        throw ProtoJsonException(path, '$n is out of the enum range (int32).');
      }
      if (e.file.isProto2 && e.valueByNumber(n) == null) {
        throw ProtoJsonException(path, '$n is not a value of ${e.fullName}.');
      }
      return n;
    }
    throw ProtoJsonException(
      path,
      'Expected an enum value name of ${e.fullName}, got ${_show(v)}.',
    );
  }

  /// Rewrites the special JSON of a well-known type as the plain object of
  /// its fields. Other messages are returned unchanged.
  Object? _fromSpecialJson(MessageDescriptor md, Object? json, String path) {
    final name = md.fullName;
    if (!hasSpecialJson(name)) return json;
    if (name == _value) {
      return switch (json) {
        null => {'nullValue': 'NULL_VALUE'},
        num v => {'numberValue': v},
        String v => {'stringValue': v},
        bool v => {'boolValue': v},
        Map v => {'structValue': v},
        List v => {'listValue': v},
        _ => throw ProtoJsonException(
          path,
          'Unsupported value ${_show(json)}.',
        ),
      };
    }
    if (json == null) return null;
    if (_wrappers.contains(name)) return {'value': json};
    switch (name) {
      case _timestamp:
        if (json is Map) return json;
        if (json is! String) {
          throw ProtoJsonException(
            path,
            'Expected a timestamp string such as "2024-05-01T12:30:00Z", got '
            '${_show(json)}.',
          );
        }
        final (s, n) = parseTimestamp(json, path);
        return {'seconds': '$s', 'nanos': n};
      case _duration:
        if (json is Map) return json;
        if (json is! String) {
          throw ProtoJsonException(
            path,
            'Expected a duration string such as "1.5s", got ${_show(json)}.',
          );
        }
        final (s, n) = parseDuration(json, path);
        return {'seconds': '$s', 'nanos': n};
      case _fieldMask:
        if (json is Map) return json;
        if (json is! String) {
          throw ProtoJsonException(
            path,
            'Expected field paths joined by commas, such as "name,address.city", '
            'got ${_show(json)}.',
          );
        }
        return {
          'paths': [
            for (final p in json.split(','))
              if (p.trim().isNotEmpty) _camelToSnake(p.trim()),
          ],
        };
      case _struct:
        if (json is! Map) {
          throw ProtoJsonException(
            path,
            'Expected an object, got ${_show(json)}.',
          );
        }
        return {'fields': json};
      case _listValue:
        if (json is! List) {
          throw ProtoJsonException(
            path,
            'Expected a list, got ${_show(json)}.',
          );
        }
        return {'values': json};
      case _any:
        return _anyFromJson(json, path);
    }
    return json;
  }

  Map<String, Object?> _anyFromJson(Object json, String path) {
    if (json is! Map) {
      throw ProtoJsonException(
        path,
        'Expected an object with "@type", got ${_show(json)}.',
      );
    }
    final url = json['@type'];
    if (url is! String || url.isEmpty) {
      throw ProtoJsonException(
        path,
        'An Any needs "@type", such as '
        '"type.googleapis.com/google.protobuf.Duration".',
      );
    }
    final typeName = url.substring(url.lastIndexOf('/') + 1);
    final inner = pool?.findMessage(typeName);
    if (inner == null) {
      // Keep unknown payloads that were decoded as raw base64.
      final raw = json['value'];
      if (raw is String && json.length == 2) {
        return {'typeUrl': url, 'value': raw};
      }
      throw ProtoJsonException(
        _join(path, '@type'),
        'Unknown type "$typeName". Load the .proto file that defines it.',
      );
    }
    final Object? body;
    if (hasSpecialJson(inner.fullName)) {
      body = json['value'];
    } else {
      body = Map<String, Object?>.of(json.cast<String, Object?>())
        ..remove('@type');
    }
    return {'typeUrl': url, 'value': base64Encode(encode(inner, body))};
  }

  // ---------------- Helpers ----------------

  static String _join(String path, String key) =>
      path.isEmpty ? key : '$path.$key';

  static String _show(Object? v) {
    final s = v is String ? '"$v"' : jsonEncode(v);
    return s.length > 60 ? '${s.substring(0, 57)}...' : s;
  }

  static String _known(MessageDescriptor md) {
    if (md.fields.isEmpty) return ' It has no fields.';
    final names = md.fields.map((f) => f.jsonName).take(15).join(', ');
    return ' Known fields: $names${md.fields.length > 15 ? ', ...' : ''}.';
  }

  static String _where(FormatException e, String text) {
    final offset = e.offset;
    if (offset == null || offset > text.length) return e.message;
    final before = text.substring(0, offset);
    final line = '\n'.allMatches(before).length + 1;
    final col = offset - (before.lastIndexOf('\n') + 1) + 1;
    return '${e.message} (line $line, column $col)';
  }
}

/// Decodes standard or URL-safe base64, with or without padding.
Uint8List? _base64(String s) {
  var t = s.trim().replaceAll(RegExp(r'\s'), '');
  t = t.replaceAll('-', '+').replaceAll('_', '/');
  while (t.length % 4 != 0) {
    t += '=';
  }
  try {
    return base64Decode(t);
  } on FormatException {
    return null;
  }
}

String _camelToSnake(String s) =>
    s.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m.group(0)!.toLowerCase()}');

String _snakeToCamel(String s) =>
    s.replaceAllMapped(RegExp('_([a-z0-9])'), (m) => m.group(1)!.toUpperCase());

final _timestampRe = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})[Tt ](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?'
  r'([Zz]|[+-]\d{2}:\d{2})$',
);

/// Seconds and nanos since the Unix epoch of an RFC 3339 timestamp.
(int, int) parseTimestamp(String s, [String path = '']) {
  final m = _timestampRe.firstMatch(s.trim());
  Never bad() => throw ProtoJsonException(
    path,
    'Expected an RFC 3339 timestamp such as "2024-05-01T12:30:00Z" or '
    '"2024-05-01T12:30:00.5+05:30", got "$s".',
  );
  if (m == null) bad();
  final parts = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
  final dt = DateTime.utc(
    parts[0],
    parts[1],
    parts[2],
    parts[3],
    parts[4],
    parts[5],
  );
  if (parts[0] < 1 ||
      dt.year != parts[0] ||
      dt.month != parts[1] ||
      dt.day != parts[2] ||
      parts[3] > 23 ||
      parts[4] > 59 ||
      parts[5] > 59) {
    bad();
  }
  var seconds = dt.millisecondsSinceEpoch ~/ 1000;
  final zone = m.group(8)!;
  if (zone != 'Z' && zone != 'z') {
    final sign = zone[0] == '-' ? -1 : 1;
    final h = int.parse(zone.substring(1, 3));
    final mi = int.parse(zone.substring(4, 6));
    seconds -= sign * (h * 3600 + mi * 60);
  }
  final frac = m.group(7);
  final nanos = frac == null ? 0 : int.parse(frac.padRight(9, '0'));
  return (seconds, nanos);
}

String _fraction(int nanos) {
  if (nanos == 0) return '';
  final s = nanos.toString().padLeft(9, '0');
  if (nanos % 1000000 == 0) return '.${s.substring(0, 3)}';
  if (nanos % 1000 == 0) return '.${s.substring(0, 6)}';
  return '.$s';
}

/// The RFC 3339 form (UTC, `Z`) of a Timestamp.
String formatTimestamp(int seconds, int nanos) {
  final dt = DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${dt.year.toString().padLeft(4, '0')}-${two(dt.month)}-'
      '${two(dt.day)}T${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}'
      '${_fraction(nanos)}Z';
}

final _durationRe = RegExp(r'^(-)?(\d+)(?:\.(\d{1,9}))?s$');

/// Seconds and nanos of a duration such as `1.5s` or `-0.25s`.
(int, int) parseDuration(String s, [String path = '']) {
  final m = _durationRe.firstMatch(s.trim());
  if (m == null) {
    throw ProtoJsonException(
      path,
      'Expected a duration in seconds ending in "s", such as "30s" or '
      '"0.25s", got "$s".',
    );
  }
  final sign = m.group(1) == null ? 1 : -1;
  final seconds = int.parse(m.group(2)!);
  final frac = m.group(3);
  final nanos = frac == null ? 0 : int.parse(frac.padRight(9, '0'));
  return (sign * seconds, sign * nanos);
}

String formatDuration(int seconds, int nanos) {
  final negative = seconds < 0 || nanos < 0;
  return '${negative ? '-' : ''}${seconds.abs()}${_fraction(nanos.abs())}s';
}

final _f32 = Float32List(1);

/// The shortest decimal that reads back as the same 32-bit float, so a
/// float field holding 0.1 prints as 0.1, not 0.10000000149011612.
double _shortestFloat(double v) {
  if (!v.isFinite || v == 0) return v;
  for (var p = 1; p <= 9; p++) {
    final d = double.parse(v.toStringAsPrecision(p));
    _f32[0] = d;
    if (_f32[0] == v) return d;
  }
  return v;
}

Object _floatJson(double d) {
  if (d.isNaN) return 'NaN';
  if (d == double.infinity) return 'Infinity';
  if (d == double.negativeInfinity) return '-Infinity';
  return d;
}

class _Decoder {
  _Decoder(this.codec, this.emitDefaults, this.protoNames);

  final ProtoJsonCodec codec;
  final bool emitDefaults;
  final bool protoNames;

  Object? message(MessageDescriptor md, Uint8List bytes) {
    final raw = _fields(md, bytes);
    if (hasSpecialJson(md.fullName)) return _special(md, raw);
    final out = <String, Object?>{};
    for (final f in md.fields) {
      final key = protoNames ? f.name : f.jsonName;
      if (raw.containsKey(f)) {
        final v = raw[f];
        if (f.isMap) {
          final entry = f.messageType!;
          out[key] = {
            for (final e in (v as Map<Object, Object?>).entries)
              _mapKey(entry.mapKey, e.key): e.value == null
                  ? _default(entry.mapValue)
                  : _json(entry.mapValue, e.value),
          };
        } else if (f.isRepeated) {
          out[key] = [for (final x in v as List<Object?>) _json(f, x)];
        } else {
          out[key] = _json(f, v);
        }
      } else if (emitDefaults) {
        if (f.isMap) {
          out[key] = <String, Object?>{};
        } else if (f.isRepeated) {
          out[key] = <Object?>[];
        } else if (!f.hasPresence) {
          out[key] = _default(f);
        }
      }
    }
    return out;
  }

  /// Raw values by field: the last scalar, a list, a key → value map, or
  /// the concatenated bytes of a message (repeats of a message merge).
  Map<FieldDescriptor, Object?> _fields(MessageDescriptor md, Uint8List bytes) {
    final out = <FieldDescriptor, Object?>{};
    final r = ProtoReader(bytes);
    while (!r.atEnd) {
      final (n, wire) = r.tag();
      if (wire == WireType.endGroup) {
        throw ProtoDecodeException(
          'Unexpected end-group tag for field $n in ${md.fullName}.',
        );
      }
      final f = md.fieldByNumber(n);
      if (f == null) {
        r.skip(n, wire);
        continue;
      }
      if (f.isMap) {
        if (wire != WireType.lengthDelimited) {
          r.skip(n, wire);
          continue;
        }
        final entryType = f.messageType!;
        final entry = _fields(entryType, r.lengthDelimited());
        final key = entry[entryType.mapKey] ?? _zero(entryType.mapKey.type);
        final map = (out[f] ??= <Object, Object?>{}) as Map<Object, Object?>;
        map[key] = entry[entryType.mapValue];
        continue;
      }
      if (f.isRepeated) {
        final list = (out[f] ??= <Object?>[]) as List<Object?>;
        if (wire == WireType.lengthDelimited && f.type.packable) {
          final packed = ProtoReader(r.lengthDelimited());
          while (!packed.atEnd) {
            list.add(_read(packed, f.type));
          }
        } else if (wire == f.type.wireType) {
          list.add(
            f.type == FieldType.group
                ? r.group(n)
                : f.type == FieldType.message
                ? r.lengthDelimited()
                : _read(r, f.type),
          );
        } else {
          r.skip(n, wire);
        }
        continue;
      }
      if (wire != f.type.wireType) {
        r.skip(n, wire);
        continue;
      }
      final oneof = f.realOneof;
      if (oneof != null) {
        for (final other in oneof.fields) {
          if (other != f) out.remove(other);
        }
      }
      if (f.isMessage) {
        final chunk = f.type == FieldType.group
            ? r.group(n)
            : r.lengthDelimited();
        ((out[f] ??= BytesBuilder()) as BytesBuilder).add(chunk);
      } else {
        out[f] = _read(r, f.type);
      }
    }
    return out;
  }

  static Object _zero(FieldType t) => switch (t) {
    FieldType.boolean => false,
    FieldType.string => '',
    _ => 0,
  };

  static Object _read(ProtoReader r, FieldType t) => switch (t) {
    FieldType.int32 || FieldType.enumeration => r.varint().toSigned(32),
    FieldType.int64 || FieldType.uint64 => r.varint(),
    FieldType.uint32 => r.varint() & 0xffffffff,
    FieldType.sint32 => zigzagDecode(r.varint() & 0xffffffff).toSigned(32),
    FieldType.sint64 => zigzagDecode(r.varint()),
    FieldType.boolean => r.varint() != 0,
    FieldType.fixed32 => r.fixed32(),
    FieldType.sfixed32 => r.fixed32().toSigned(32),
    FieldType.fixed64 || FieldType.sfixed64 => r.fixed64(),
    FieldType.float32 => r.float32(),
    FieldType.float64 => r.float64(),
    FieldType.string => utf8.decode(r.lengthDelimited(), allowMalformed: true),
    FieldType.bytes => Uint8List.fromList(r.lengthDelimited()),
    FieldType.message || FieldType.group => r.lengthDelimited(),
  };

  static Uint8List _bytes(Object? v) => switch (v) {
    BytesBuilder b => b.toBytes(),
    Uint8List b => b,
    _ => Uint8List(0),
  };

  /// JSON of one value of [f] (an element, for repeated fields).
  Object? _json(FieldDescriptor f, Object? raw) {
    if (f.isMessage) return message(f.messageType!, _bytes(raw));
    if (f.type == FieldType.enumeration) {
      final e = f.enumType!;
      if (e.fullName == _nullValue) return null;
      return e.valueByNumber(raw as int)?.name ?? raw;
    }
    return _scalarJson(f.type, raw!);
  }

  static Object _scalarJson(FieldType t, Object v) => switch (t) {
    FieldType.int64 || FieldType.sint64 || FieldType.sfixed64 => '$v',
    FieldType.uint64 || FieldType.fixed64 => _unsigned(v as int),
    FieldType.float32 => _floatJson(_shortestFloat(v as double)),
    FieldType.float64 => _floatJson(v as double),
    FieldType.bytes => base64Encode(v as Uint8List),
    _ => v,
  };

  static String _unsigned(int v) =>
      v >= 0 ? '$v' : BigInt.from(v).toUnsigned(64).toString();

  static String _mapKey(FieldDescriptor key, Object v) => switch (key.type) {
    FieldType.uint64 || FieldType.fixed64 => _unsigned(v as int),
    _ => '$v',
  };

  Object? _default(FieldDescriptor f) {
    if (f.isMessage) return message(f.messageType!, Uint8List(0));
    return switch (f.type) {
      FieldType.enumeration =>
        f.enumType!.fullName == _nullValue
            ? null
            : (f.enumType!.valueByNumber(0)?.name ??
                  f.enumType!.values.first.name),
      FieldType.float32 || FieldType.float64 => 0.0,
      FieldType.boolean => false,
      FieldType.string || FieldType.bytes => '',
      final t => t.is64Bit ? '0' : 0,
    };
  }

  Object? _special(MessageDescriptor md, Map<FieldDescriptor, Object?> raw) {
    Object? field(int n) {
      final f = md.fieldByNumber(n);
      return f == null ? null : raw[f];
    }

    final name = md.fullName;
    if (_wrappers.contains(name)) {
      final f = md.fieldByNumber(1)!;
      return raw.containsKey(f) ? _json(f, raw[f]) : _default(f);
    }
    switch (name) {
      case _timestamp:
        return formatTimestamp(field(1) as int? ?? 0, field(2) as int? ?? 0);
      case _duration:
        return formatDuration(field(1) as int? ?? 0, field(2) as int? ?? 0);
      case _fieldMask:
        final paths = field(1) as List<Object?>? ?? const [];
        return paths.map((p) => _snakeToCamel('$p')).join(',');
      case _struct:
        final f = md.fieldByNumber(1)!;
        final values = raw[f] as Map<Object, Object?>? ?? const {};
        final valueType = f.messageType!.mapValue.messageType!;
        return {
          for (final e in values.entries)
            '${e.key}': message(valueType, _bytes(e.value)),
        };
      case _listValue:
        final f = md.fieldByNumber(1)!;
        final items = raw[f] as List<Object?>? ?? const [];
        return [for (final v in items) message(f.messageType!, _bytes(v))];
      case _value:
        for (final f in md.fields) {
          if (!raw.containsKey(f)) continue;
          return switch (f.number) {
            1 => null,
            2 => _floatJson(raw[f] as double),
            _ => _json(f, raw[f]),
          };
        }
        return null;
      case _any:
        final url = field(1) as String? ?? '';
        final bytes = field(2) as Uint8List? ?? Uint8List(0);
        final typeName = url.substring(url.lastIndexOf('/') + 1);
        final inner = codec.pool?.findMessage(typeName);
        if (inner == null) return {'@type': url, 'value': base64Encode(bytes)};
        final body = message(inner, bytes);
        if (hasSpecialJson(inner.fullName) || body is! Map) {
          return {'@type': url, 'value': body};
        }
        return {'@type': url, ...body.cast<String, Object?>()};
    }
    return null;
  }
}
