import 'dart:io';
import 'dart:typed_data';

import 'package:api_workbench/services/grpc/grpc.dart';
import 'package:flutter_test/flutter_test.dart';

const _scalarsProto = '''
syntax = "proto3";
package t;

enum E { ZERO = 0; ONE = 1; NEG = -1; }

message Test1 { int32 a = 1; }
message Test2 { string b = 2; }
message Test3 { Test1 c = 3; }
message Test4 { repeated int32 d = 4; }

message Scalars {
  int32 i32 = 1;
  int64 i64 = 2;
  uint32 u32 = 3;
  uint64 u64 = 4;
  sint32 s32 = 5;
  sint64 s64 = 6;
  fixed32 f32 = 7;
  fixed64 f64 = 8;
  sfixed32 sf32 = 9;
  sfixed64 sf64 = 10;
  float fl = 11;
  double db = 12;
  bool flag = 13;
  string str = 14;
  bytes raw = 15;
  E e = 16;
  optional int32 opt = 17;
  map<string, int32> counts = 18;
  map<bool, string> flags = 19;
  oneof choice {
    string name = 20;
    int32 number = 21;
  }
  repeated string names = 22;
  repeated sint32 zig = 23;
  repeated fixed32 fixeds = 24;
}
''';

const _wktProto = '''
syntax = "proto3";
package w;

import "google/protobuf/any.proto";
import "google/protobuf/duration.proto";
import "google/protobuf/empty.proto";
import "google/protobuf/field_mask.proto";
import "google/protobuf/struct.proto";
import "google/protobuf/timestamp.proto";
import "google/protobuf/wrappers.proto";

message W {
  google.protobuf.Timestamp ts = 1;
  google.protobuf.Duration dur = 2;
  google.protobuf.Struct st = 3;
  google.protobuf.Value val = 4;
  google.protobuf.ListValue list = 5;
  google.protobuf.Int32Value i32 = 6;
  google.protobuf.Int64Value i64 = 7;
  google.protobuf.BytesValue bin = 8;
  google.protobuf.FieldMask mask = 9;
  google.protobuf.Any any = 10;
  google.protobuf.Empty empty = 11;
  google.protobuf.StringValue name = 12;
}
''';

/// Bytes from space-separated hex: `08 96 01`.
Uint8List _hex(String s) => Uint8List.fromList([
  for (final b in s.split(' ').where((b) => b.isNotEmpty))
    int.parse(b, radix: 16),
]);

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

/// [text] as a UTF-8 hex string, for readable expectations.
String _ascii(String text) => _toHex(text.codeUnits);

void main() {
  final pool = buildPool({'t.proto': _scalarsProto});
  final codec = ProtoJsonCodec(pool);
  MessageDescriptor type(String name) => pool.findMessage(name)!;
  String enc(String name, Object? json) =>
      _toHex(codec.encode(type(name), json));

  group('wire primitives', () {
    String varint(int v) => _toHex((ProtoWriter()..varint(v)).takeBytes());

    test('varints', () {
      expect(varint(0), '00');
      expect(varint(1), '01');
      expect(varint(127), '7f');
      expect(varint(128), '80 01');
      expect(varint(300), 'ac 02');
      expect(varint(16384), '80 80 01');
      expect(varint(-1), 'ff ff ff ff ff ff ff ff ff 01');
      for (final v in [0, 1, 300, 1 << 40, -1, -300, 1 << 63]) {
        final bytes = (ProtoWriter()..varint(v)).takeBytes();
        expect(ProtoReader(bytes).varint(), v);
      }
    });

    test('zigzag', () {
      expect(zigzagEncode(0), 0);
      expect(zigzagEncode(-1), 1);
      expect(zigzagEncode(1), 2);
      expect(zigzagEncode(-2), 3);
      expect(zigzagEncode(2147483647), 4294967294);
      expect(zigzagEncode(-2147483648), 4294967295);
      expect(zigzagEncode(-9223372036854775808), -1); // 2^64 - 1
      for (final v in [0, -1, 1, -2, 2147483647, -2147483648, 1 << 62]) {
        expect(zigzagDecode(zigzagEncode(v)), v);
      }
    });
  });

  group('encode, byte exact', () {
    test('the classic examples', () {
      expect(enc('t.Test1', {'a': 150}), '08 96 01');
      expect(enc('t.Test2', {'b': 'testing'}), '12 07 74 65 73 74 69 6e 67');
      expect(
        enc('t.Test3', {
          'c': {'a': 150},
        }),
        '1a 03 08 96 01',
      );
      expect(
        enc('t.Test4', {
          'd': [3, 270, 86942],
        }),
        '22 06 03 8e 02 9e a7 05',
      );
    });

    test('every scalar type', () {
      final cases = {
        '{"i32": -1}': '08 ff ff ff ff ff ff ff ff ff 01',
        '{"i64": "-9223372036854775808"}': '10 80 80 80 80 80 80 80 80 80 01',
        '{"i64": 5}': '10 05',
        '{"u32": 4294967295}': '18 ff ff ff ff 0f',
        '{"u64": "18446744073709551615"}': '20 ff ff ff ff ff ff ff ff ff 01',
        '{"s32": -1}': '28 01',
        '{"s32": 1}': '28 02',
        '{"s32": -2147483648}': '28 ff ff ff ff 0f',
        '{"s64": "-9223372036854775808"}': '30 ff ff ff ff ff ff ff ff ff 01',
        '{"f32": 1}': '3d 01 00 00 00',
        '{"f64": "18446744073709551615"}': '41 ff ff ff ff ff ff ff ff',
        '{"sf32": -2}': '4d fe ff ff ff',
        '{"sf64": "-2"}': '51 fe ff ff ff ff ff ff ff',
        '{"fl": 1.5}': '5d 00 00 c0 3f',
        '{"db": 1.5}': '61 00 00 00 00 00 00 f8 3f',
        '{"db": "-Infinity"}': '61 00 00 00 00 00 00 f0 ff',
        '{"flag": true}': '68 01',
        '{"str": "é"}': '72 02 c3 a9',
        '{"raw": "AQID"}': '7a 03 01 02 03',
        '{"raw": "-_8"}': '7a 02 fb ff',
        '{"e": "ONE"}': '80 01 01',
        '{"e": 1}': '80 01 01',
        '{"e": "NEG"}': '80 01 ff ff ff ff ff ff ff ff ff 01',
      };
      cases.forEach((json, hex) {
        expect(
          _toHex(codec.encodeText(type('t.Scalars'), json)),
          hex,
          reason: json,
        );
      });
    });

    test('defaults are left out unless the field has presence', () {
      expect(
        enc('t.Scalars', {
          'i32': 0,
          'str': '',
          'flag': false,
          'e': 'ZERO',
          'db': 0.0,
          'names': <String>[],
          'counts': <String, int>{},
        }),
        '',
      );
      expect(enc('t.Scalars', {'opt': 0}), '88 01 00');
      expect(enc('t.Scalars', {'number': 0}), 'a8 01 00');
      // -0.0 is not the default bit pattern.
      expect(enc('t.Scalars', {'db': -0.0}), '61 00 00 00 00 00 00 00 80');
    });

    test('fields are written in field-number order', () {
      expect(enc('t.Scalars', {'str': 'x', 'i32': 1}), '08 01 72 01 78');
    });

    test('maps, packed and unpacked repeated fields', () {
      expect(
        enc('t.Scalars', {
          'counts': {'a': 1},
        }),
        '92 01 05 0a 01 61 10 01',
      );
      expect(
        enc('t.Scalars', {
          'flags': {'true': 'y'},
        }),
        '9a 01 05 08 01 12 01 79',
      );
      expect(
        enc('t.Scalars', {
          'zig': [1, -1, 2],
        }),
        'ba 01 03 02 01 04',
      );
      expect(
        enc('t.Scalars', {
          'fixeds': [1, 2],
        }),
        'c2 01 08 01 00 00 00 02 00 00 00',
      );
      expect(
        enc('t.Scalars', {
          'names': ['a', 'b'],
        }),
        'b2 01 01 61 b2 01 01 62',
      );
    });

    test('proto2: presence, unpacked repeats and groups', () {
      final legacy = buildPool({
        'legacy.proto': File(
          'test/fixtures/proto/legacy.proto',
        ).readAsStringSync(),
      });
      final inv = legacy.findMessage('legacy.Inventory')!;
      final c = ProtoJsonCodec(legacy);
      final json = {
        'name': 'x',
        'codes': [1, 2],
        'deltas': [-1, 1],
        'result': {'url': 'u'},
      };
      final bytes = c.encode(inv, json);
      expect(_toHex(bytes), '0a 01 78 20 01 20 02 2a 02 01 02 33 3a 01 75 34');
      expect(_toHex(c.encode(inv, {'count': 0})), '10 00');
      expect(c.decode(inv, bytes), {
        'name': 'x',
        'codes': [1, 2],
        'deltas': ['-1', '1'],
        'result': {'url': 'u'},
      });
    });
  });

  group('decode', () {
    test('plain, packed or unpacked, unknown fields skipped', () {
      expect(codec.decode(type('t.Test1'), _hex('08 96 01')), {'a': 150});
      expect(codec.decode(type('t.Test4'), _hex('20 03 20 8e 02')), {
        'd': [3, 270],
      });
      expect(codec.decode(type('t.Test4'), _hex('22 06 03 8e 02 9e a7 05')), {
        'd': [3, 270, 86942],
      });
      expect(
        codec.decode(
          type('t.Test1'),
          _hex('08 01 10 05 1a 01 00 25 00 00 00 00'),
        ),
        {'a': 1},
      );
    });

    test('last value wins; repeated messages merge; oneofs keep the last', () {
      expect(codec.decode(type('t.Test1'), _hex('08 01 08 02')), {'a': 2});
      final shop = buildPool({
        'shop/v1/shop.proto': File(
          'test/fixtures/proto/shop/v1/shop.proto',
        ).readAsStringSync(),
        'shop/v1/common.proto': File(
          'test/fixtures/proto/shop/v1/common.proto',
        ).readAsStringSync(),
      });
      final product = shop.findMessage('shop.v1.Product')!;
      expect(
        ProtoJsonCodec(
          shop,
        ).decode(product, _hex('1a 05 0a 03 45 55 52 1a 02 10 05')),
        {
          'price': {'currencyCode': 'EUR', 'units': '5'},
        },
      );
      expect(codec.decode(type('t.Scalars'), _hex('a2 01 01 78 a8 01 05')), {
        'number': 5,
      });
    });

    test('JSON forms of 64-bit, float, NaN and enums', () {
      final s = type('t.Scalars');
      expect(codec.decode(s, _hex('20 ff ff ff ff ff ff ff ff ff 01')), {
        'u64': '18446744073709551615',
      });
      expect(codec.decode(s, _hex('10 80 80 80 80 80 80 80 80 80 01')), {
        'i64': '-9223372036854775808',
      });
      expect(codec.decode(s, _hex('28 ff ff ff ff 0f')), {'s32': -2147483648});
      expect(codec.decode(s, _hex('5d cd cc cc 3d')), {'fl': 0.1});
      expect(codec.decode(s, _hex('61 00 00 00 00 00 00 f8 7f')), {
        'db': 'NaN',
      });
      expect(codec.decode(s, _hex('80 01 01')), {'e': 'ONE'});
      expect(codec.decode(s, _hex('80 01 07')), {'e': 7});
      expect(codec.decode(s, _hex('7a 03 01 02 03')), {'raw': 'AQID'});
      expect(codec.decode(s, _hex('9a 01 05 08 01 12 01 79')), {
        'flags': {'true': 'y'},
      });
    });

    test('emitDefaults and protoNames', () {
      expect(codec.decode(type('t.Scalars'), [], emitDefaults: true), {
        'i32': 0,
        'i64': '0',
        'u32': 0,
        'u64': '0',
        's32': 0,
        's64': '0',
        'f32': 0,
        'f64': '0',
        'sf32': 0,
        'sf64': '0',
        'fl': 0.0,
        'db': 0.0,
        'flag': false,
        'str': '',
        'raw': '',
        'e': 'ZERO',
        'counts': <String, Object?>{},
        'flags': <String, Object?>{},
        'names': <Object?>[],
        'zig': <Object?>[],
        'fixeds': <Object?>[],
      });
      final p = buildPool({
        'p.proto': 'syntax = "proto3"; message P { string display_name = 1; }',
      });
      final bytes = ProtoJsonCodec(
        p,
      ).encode(p.findMessage('P')!, {'display_name': 'A'});
      expect(ProtoJsonCodec(p).decode(p.findMessage('P')!, bytes), {
        'displayName': 'A',
      });
      expect(
        ProtoJsonCodec(p).decode(p.findMessage('P')!, bytes, protoNames: true),
        {'display_name': 'A'},
      );
    });

    test('truncated input is an error', () {
      expect(
        () => codec.decode(type('t.Test1'), _hex('08')),
        throwsA(isA<ProtoDecodeException>()),
      );
      expect(
        () => codec.decode(type('t.Test2'), _hex('12 05 61')),
        throwsA(isA<ProtoDecodeException>()),
      );
    });
  });

  group('well-known types', () {
    final wp = buildPool({'w.proto': _wktProto});
    final wc = ProtoJsonCodec(wp);
    final w = wp.findMessage('w.W')!;
    final url = 'type.googleapis.com/google.protobuf.Duration';
    final cases = <String, (Map<String, Object?>, String)>{
      'Timestamp': (
        {'ts': '1970-01-01T00:00:01.500Z'},
        '0a 08 08 01 10 80 ca b5 ee 01',
      ),
      'Duration': ({'dur': '0.250s'}, '12 05 10 80 e5 9a 77'),
      'Struct': (
        {
          'st': {'a': 1.0},
        },
        '1a 10 0a 0e 0a 01 61 12 09 11 00 00 00 00 00 00 f0 3f',
      ),
      'Value null': ({'val': null}, '22 02 08 00'),
      'Value string': ({'val': 'x'}, '22 03 1a 01 78'),
      'ListValue': (
        {
          'list': [true, null],
        },
        '2a 08 0a 02 20 01 0a 02 08 00',
      ),
      'Int32Value zero': ({'i32': 0}, '32 00'),
      'Int32Value': ({'i32': 7}, '32 02 08 07'),
      'Int64Value': ({'i64': '5'}, '3a 02 08 05'),
      'BytesValue': ({'bin': 'AQ=='}, '42 03 0a 01 01'),
      'FieldMask': (
        {'mask': 'fooBar,baz.quxQuux'},
        '4a 17 0a 07 ${_ascii('foo_bar')} 0a 0c ${_ascii('baz.qux_quux')}',
      ),
      'Any': (
        {
          'any': {'@type': url, 'value': '1s'},
        },
        '52 32 0a 2c ${_ascii(url)} 12 02 08 01',
      ),
      'Empty': ({'empty': <String, Object?>{}}, '5a 00'),
      'StringValue empty': ({'name': ''}, '62 00'),
    };
    cases.forEach((name, c) {
      test('$name encodes byte exact and decodes back', () {
        final bytes = wc.encode(w, c.$1);
        expect(_toHex(bytes), c.$2);
        expect(wc.decode(w, bytes), c.$1);
      });
    });

    test('timestamps with offsets, and fraction digits', () {
      expect(
        _toHex(wc.encode(w, {'ts': '1970-01-01T05:30:00+05:30'})),
        '0a 00',
      );
      expect(formatTimestamp(1, 0), '1970-01-01T00:00:01Z');
      expect(formatTimestamp(1, 1000), '1970-01-01T00:00:01.000001Z');
      expect(formatTimestamp(1, 1), '1970-01-01T00:00:01.000000001Z');
      expect(formatTimestamp(-62135596800, 0), '0001-01-01T00:00:00Z');
      expect(parseTimestamp('2024-02-29T23:59:59.123Z'), (
        1709251199,
        123000000,
      ));
      expect(formatDuration(1, 500000000), '1.500s');
      expect(formatDuration(-1, -500000000), '-1.500s');
      expect(formatDuration(0, -250000000), '-0.250s');
      expect(parseDuration('-0.25s'), (0, -250000000));
    });

    test('Any of a regular message keeps its fields inline', () {
      final json = {
        'any': {'@type': 'type.googleapis.com/w.W', 'dur': '3s'},
      };
      expect(wc.decode(w, wc.encode(w, json)), json);
    });

    test('bad values name the field', () {
      expect(
        () => wc.encode(w, {'ts': 'yesterday'}),
        throwsA(
          isA<ProtoJsonException>()
              .having((e) => e.path, 'path', 'ts')
              .having((e) => e.message, 'message', contains('RFC 3339')),
        ),
      );
      expect(
        () => wc.encode(w, {
          'any': {'@type': 'type.googleapis.com/nope.Missing'},
        }),
        throwsA(
          isA<ProtoJsonException>().having(
            (e) => e.toString(),
            'text',
            'any.@type: Unknown type "nope.Missing". Load the .proto file '
                'that defines it.',
          ),
        ),
      );
    });
  });

  group('encode errors', () {
    String error(String name, Object? json) {
      try {
        codec.encode(type(name), json);
      } on ProtoJsonException catch (e) {
        return e.toString();
      }
      fail('expected an error');
    }

    test('readable messages with paths', () {
      expect(
        error('t.Test1', {'nope': 1}),
        'nope: Unknown field "nope" in t.Test1. Known fields: a.',
      );
      expect(
        error('t.Test3', {
          'c': {'a': 'x'},
        }),
        'c.a: Expected int32 (a whole number), got "x".',
      );
      expect(
        error('t.Scalars', {'u32': -1}),
        'u32: -1 is out of range for uint32 (0 to 4294967295).',
      );
      expect(
        error('t.Scalars', {'e': 'TWO'}),
        'e: Unknown value "TWO" for enum t.E. Use one of: ZERO, ONE, NEG.',
      );
      expect(
        error('t.Scalars', {'name': 'x', 'number': 1}),
        'Only one field of oneof "choice" can be set, but both "name" and '
        '"number" are.',
      );
      expect(
        error('t.Scalars', {
          'names': ['a', null],
        }),
        'names[1]: Lists cannot contain null.',
      );
      expect(
        error('t.Scalars', {
          'counts': {'a': 'x'},
        }),
        'counts["a"]: Expected int32 (a whole number), got "x".',
      );
      expect(
        error('t.Scalars', {'raw': '***'}),
        'raw: Expected bytes as a base64 string, got "***".',
      );
      expect(
        () => codec.encodeText(type('t.Test1'), '{"a": }'),
        throwsA(
          isA<ProtoJsonException>().having(
            (e) => e.message,
            'message',
            startsWith('The message is not valid JSON:'),
          ),
        ),
      );
    });
  });

  test('example messages fit their schema', () {
    final shop = buildPool({
      'shop/v1/shop.proto': File(
        'test/fixtures/proto/shop/v1/shop.proto',
      ).readAsStringSync(),
      'shop/v1/common.proto': File(
        'test/fixtures/proto/shop/v1/common.proto',
      ).readAsStringSync(),
    });
    final product = shop.findMessage('shop.v1.Product')!;
    final example =
        exampleJson(product, now: DateTime.utc(2026, 1, 2, 3, 4, 5))
            as Map<String, Object?>;
    expect(example['id'], 'id');
    expect(example['title'], 'display_name');
    expect(example['status'], 'STATUS_UNSPECIFIED');
    expect(example['stockByStore'], {'key': 0});
    expect(example['variantById'], isA<Map<String, Object?>>());
    expect(example.containsKey('percentOff'), isTrue);
    expect(example.containsKey('amountOff'), isFalse); // first of the oneof
    expect(example['createdAt'], '2026-01-02T03:04:05Z');
    expect(example['rating'], 0);
    final c = ProtoJsonCodec(shop);
    final bytes = c.encode(product, example);
    final back = c.decode(product, bytes) as Map<String, Object?>;
    expect(back['title'], 'display_name');
    expect(back['createdAt'], '2026-01-02T03:04:05Z');
  });
}
