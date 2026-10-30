/// Protobuf wire format: varints, zigzag, fixed-width numbers and
/// length-delimited fields. Integers are Dart's 64-bit ints; unsigned
/// 64-bit values keep their bit pattern.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Wire type numbers.
abstract final class WireType {
  static const varint = 0;
  static const fixed64 = 1;
  static const lengthDelimited = 2;
  static const startGroup = 3;
  static const endGroup = 4;
  static const fixed32 = 5;
}

/// A malformed or truncated message.
class ProtoDecodeException implements Exception {
  ProtoDecodeException(this.message);

  final String message;

  @override
  String toString() => message;
}

int zigzagEncode(int v) => (v << 1) ^ (v >> 63);

int zigzagDecode(int v) => (v >>> 1) ^ -(v & 1);

/// Builds a message's bytes.
class ProtoWriter {
  final BytesBuilder _out = BytesBuilder(copy: false);
  final ByteData _scratch = ByteData(8);

  int get length => _out.length;

  void tag(int field, int wireType) => varint((field << 3) | wireType);

  /// Writes [v] as an unsigned 64-bit varint; negative numbers take ten
  /// bytes, as int32 and enum values are sign-extended.
  void varint(int v) {
    final bytes = Uint8List(10);
    var n = 0;
    while ((v & ~0x7f) != 0) {
      bytes[n++] = (v & 0x7f) | 0x80;
      v = v >>> 7;
    }
    bytes[n++] = v;
    _out.add(Uint8List.sublistView(bytes, 0, n));
  }

  void fixed32(int v) {
    _scratch.setUint32(0, v & 0xffffffff, Endian.little);
    _out.add(Uint8List.fromList(_scratch.buffer.asUint8List(0, 4)));
  }

  void fixed64(int v) {
    _scratch.setInt64(0, v, Endian.little);
    _out.add(Uint8List.fromList(_scratch.buffer.asUint8List(0, 8)));
  }

  void float32(double v) {
    _scratch.setFloat32(0, v, Endian.little);
    _out.add(Uint8List.fromList(_scratch.buffer.asUint8List(0, 4)));
  }

  void float64(double v) {
    _scratch.setFloat64(0, v, Endian.little);
    _out.add(Uint8List.fromList(_scratch.buffer.asUint8List(0, 8)));
  }

  /// A length prefix followed by [data].
  void bytes(List<int> data) {
    varint(data.length);
    raw(data);
  }

  void string(String s) => bytes(utf8.encode(s));

  void raw(List<int> data) =>
      _out.add(data is Uint8List ? data : Uint8List.fromList(data));

  Uint8List takeBytes() => _out.takeBytes();
}

/// Reads a message's bytes field by field.
class ProtoReader {
  ProtoReader(List<int> bytes)
    : _b = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

  final Uint8List _b;
  int _pos = 0;

  bool get atEnd => _pos >= _b.length;
  int get position => _pos;

  Never _truncated() => throw ProtoDecodeException(
    'The message is truncated (it ends in the middle of a field).',
  );

  int _byte() {
    if (_pos >= _b.length) _truncated();
    return _b[_pos++];
  }

  int varint() {
    var result = 0;
    for (var shift = 0; shift < 70; shift += 7) {
      final b = _byte();
      if (shift < 64) result |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) return result;
    }
    throw ProtoDecodeException('A varint is longer than 10 bytes.');
  }

  /// The next field number and wire type.
  (int, int) tag() {
    final t = varint();
    final field = t >>> 3;
    final wire = t & 7;
    if (field == 0) throw ProtoDecodeException('Field number 0 is invalid.');
    if (wire > 5) throw ProtoDecodeException('Invalid wire type $wire.');
    return (field, wire);
  }

  ByteData _view(int n) {
    if (_pos + n > _b.length) _truncated();
    final v = ByteData.sublistView(_b, _pos, _pos + n);
    _pos += n;
    return v;
  }

  /// Unsigned 32 bits.
  int fixed32() => _view(4).getUint32(0, Endian.little);

  /// 64 bits as a signed int (the bit pattern of uint64 values).
  int fixed64() => _view(8).getInt64(0, Endian.little);

  double float32() => _view(4).getFloat32(0, Endian.little);

  double float64() => _view(8).getFloat64(0, Endian.little);

  Uint8List lengthDelimited() {
    final n = varint();
    if (n < 0 || _pos + n > _b.length) _truncated();
    final out = Uint8List.sublistView(_b, _pos, _pos + n);
    _pos += n;
    return out;
  }

  /// The contents of a group whose start tag was just read, up to (not
  /// including) its end tag.
  Uint8List group(int field) {
    final start = _pos;
    while (true) {
      final before = _pos;
      final (n, wire) = tag();
      if (wire == WireType.endGroup) {
        if (n != field) {
          throw ProtoDecodeException(
            'Group $field is closed by the end tag of group $n.',
          );
        }
        return Uint8List.sublistView(_b, start, before);
      }
      skip(n, wire);
    }
  }

  /// Skips the value of a field with [wire] type.
  void skip(int field, int wire) {
    switch (wire) {
      case WireType.varint:
        varint();
      case WireType.fixed64:
        _view(8);
      case WireType.lengthDelimited:
        lengthDelimited();
      case WireType.startGroup:
        group(field);
      case WireType.fixed32:
        _view(4);
      default:
        throw ProtoDecodeException(
          'Unexpected end-group tag for field $field.',
        );
    }
  }
}
