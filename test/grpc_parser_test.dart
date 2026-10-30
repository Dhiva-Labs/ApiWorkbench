import 'dart:io';

import 'package:api_workbench/services/grpc/grpc.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixtures = 'test/fixtures/proto';

String _read(String path) => File('$_fixtures/$path').readAsStringSync();

DescriptorPool _shop() => buildPool({
  'shop/v1/shop.proto': _read('shop/v1/shop.proto'),
  'shop/v1/common.proto': _read('shop/v1/common.proto'),
});

/// The error message of parsing (and linking) [text].
String _error(String text, {Map<String, String> more = const {}}) {
  try {
    buildPool({'bad.proto': text, ...more});
  } on ProtoSchemaException catch (e) {
    return e.toString();
  }
  fail('expected a schema error');
}

void main() {
  group('proto3 fixture', () {
    test('packages, imports, nested messages and enums', () {
      final pool = _shop();
      final product = pool.findMessage('shop.v1.Product')!;
      expect(product.file.syntax, 'proto3');
      expect(product.file.package, 'shop.v1');
      expect(pool.files.keys, contains('google/protobuf/timestamp.proto'));
      expect(pool.findMessage('shop.v1.Product.Variant'), isNotNull);
      final status = pool.findEnum('shop.v1.Product.Status')!;
      expect(status.values.map((v) => v.name), [
        'STATUS_UNSPECIFIED',
        'ACTIVE',
        'LIVE',
        'RETIRED',
      ]);
      expect(status.valueByNumber(1)!.name, 'ACTIVE');

      final price = product.fieldByName('price')!;
      expect(price.type, FieldType.message);
      expect(price.messageType!.fullName, 'shop.common.Money');
      expect(product.fieldByName('status')!.enumType, same(status));
      expect(
        product.fieldByName('variants')!.messageType!.fullName,
        'shop.v1.Product.Variant',
      );
      expect(product.fieldByName('variants')!.isRepeated, isTrue);
    });

    test('json names, maps, oneofs and proto3 optional', () {
      final product = _shop().findMessage('shop.v1.Product')!;
      expect(
        product.fieldByName('title'),
        same(product.fieldByName('display_name')),
      );
      expect(product.fieldByName('createdAt')!.name, 'created_at');

      final stock = product.fieldByName('stock_by_store')!;
      expect(stock.isMap, isTrue);
      expect(stock.messageType!.name, 'StockByStoreEntry');
      expect(stock.messageType!.mapKey.type, FieldType.string);
      expect(stock.messageType!.mapValue.type, FieldType.int32);
      expect(stock.typeLabel, 'map<string, int32>');
      final byId = product.fieldByName('variant_by_id')!;
      expect(byId.messageType!.mapValue.messageType!.name, 'Variant');

      final discount = product.oneofs.firstWhere((o) => o.name == 'discount');
      expect(discount.synthetic, isFalse);
      expect(discount.fields.map((f) => f.name), ['percent_off', 'amount_off']);
      expect(
        product.fieldByName('amount_off')!.messageType!.fullName,
        'shop.common.Money',
      );

      final note = product.fieldByName('note')!;
      expect(note.proto3Optional, isTrue);
      expect(note.oneof!.synthetic, isTrue);
      expect(note.hasPresence, isTrue);
      expect(product.fieldByName('id')!.hasPresence, isFalse);
      // Synthetic oneofs come after the real ones, as protoc orders them.
      expect(product.oneofs.map((o) => o.name), ['discount', '_note']);
    });

    test('packed defaults and the packed option', () {
      final product = _shop().findMessage('shop.v1.Product')!;
      final variant = product.messages.firstWhere((m) => m.name == 'Variant');
      expect(variant.fieldByName('sizes')!.isPacked, isTrue);
      expect(variant.fieldByName('tags')!.isPacked, isFalse);
      expect(product.fieldByName('weights')!.isPacked, isFalse);
    });

    test('services and stream flags', () {
      final pool = _shop();
      final service = pool.findService('shop.v1.ProductService')!;
      expect(service.methods.map((m) => m.name), [
        'GetProduct',
        'ListProducts',
        'UploadProducts',
        'Chat',
        'Ping',
      ]);
      expect(service.method('GetProduct')!.kind, CallKind.unary);
      expect(service.method('ListProducts')!.kind, CallKind.serverStreaming);
      expect(service.method('UploadProducts')!.kind, CallKind.clientStreaming);
      expect(service.method('Chat')!.kind, CallKind.bidiStreaming);
      expect(service.method('Chat')!.path, '/shop.v1.ProductService/Chat');
      expect(service.method('Ping')!.input.fullName, 'google.protobuf.Empty');
      expect(pool.services.map((s) => s.fullName), ['shop.v1.ProductService']);
    });
  });

  group('proto2 fixture', () {
    test('labels, defaults, groups and packed', () {
      final pool = buildPool({'legacy.proto': _read('legacy.proto')});
      final inv = pool.findMessage('legacy.Inventory')!;
      expect(inv.file.syntax, 'proto2');
      expect(inv.fieldByName('name')!.label, FieldLabel.required);
      expect(inv.fieldByName('count')!.defaultValue, '10');
      expect(inv.fieldByName('label')!.defaultValue, 'none');
      expect(inv.fieldByName('kind')!.defaultValue, 'BIG');
      expect(inv.fieldByName('count')!.hasPresence, isTrue);
      // proto2 repeated scalars are unpacked unless asked.
      expect(inv.fieldByName('codes')!.isPacked, isFalse);
      expect(inv.fieldByName('deltas')!.isPacked, isTrue);
      final result = inv.fieldByName('result')!;
      expect(result.type, FieldType.group);
      expect(result.messageType!.fullName, 'legacy.Inventory.Result');
      expect(result.messageType!.fieldByName('url')!.number, 7);
      // The extension is skipped, not added as a field.
      expect(inv.fieldByName('extra'), isNull);
    });
  });

  group('syntax details', () {
    test('comments, string escapes and concatenation', () {
      final pool = buildPool({
        'a.proto': '''
syntax = 'proto3'; // single quotes work too
package a;
/* block
   comment */
message M {
  string s = 1 [json_name = "a\\x62" "c\\n"];
  int32 hex = 0x2;
  int32 oct = 07;
}
''',
      });
      final m = pool.findMessage('a.M')!;
      expect(m.fieldByName('s')!.jsonName, 'abc\n');
      expect(m.fieldByName('hex')!.number, 2);
      expect(m.fieldByName('oct')!.number, 7);
    });

    test('relative names resolve from the innermost scope out', () {
      final pool = buildPool({
        'a.proto': '''
syntax = "proto3";
package outer.inner;
message Thing { int32 x = 1; }
message Box {
  message Thing { string y = 1; }
  Thing near = 1;
  inner.Thing far = 2;
  .outer.inner.Thing absolute = 3;
}
''',
      });
      final box = pool.findMessage('outer.inner.Box')!;
      expect(
        box.fieldByName('near')!.messageType!.fullName,
        'outer.inner.Box.Thing',
      );
      expect(
        box.fieldByName('far')!.messageType!.fullName,
        'outer.inner.Thing',
      );
      expect(
        box.fieldByName('absolute')!.messageType!.fullName,
        'outer.inner.Thing',
      );
    });

    test('imports match by path suffix', () {
      final pool = buildPool({
        '/home/me/protos/dep/types.proto':
            'syntax = "proto3"; package dep; message T {}',
        'main.proto':
            'syntax = "proto3"; import "dep/types.proto"; '
            'message M { dep.T t = 1; }',
      });
      expect(
        pool.findMessage('M')!.fieldByName('t')!.messageType!.fullName,
        'dep.T',
      );
    });
  });

  group('errors carry file, line and column', () {
    test('missing semicolon', () {
      expect(
        _error('syntax = "proto3";\nmessage M {\n  int32 a = 1\n}\n'),
        'bad.proto:4:1: Expected ";" after field "a", found "}".',
      );
    });

    test('unknown type', () {
      expect(
        _error('syntax = "proto3";\nmessage M {\n  Missing m = 1;\n}\n'),
        startsWith('bad.proto:3:3: Unknown type "Missing" for field "m" in M.'),
      );
    });

    test('missing import', () {
      expect(
        _error('syntax = "proto3";\nimport "nope/other.proto";\n'),
        startsWith('bad.proto:2:1: Import "nope/other.proto" was not found.'),
      );
    });

    test('duplicate field number and name', () {
      expect(
        _error(
          'syntax = "proto3";\nmessage M {\n  int32 a = 1;\n  int32 b = 1;\n}',
        ),
        'bad.proto:4:3: Field number 1 is already used by "a" in message "M".',
      );
      expect(
        _error(
          'syntax = "proto3";\nmessage M {\n  int32 a = 1;\n  string a = 2;\n}',
        ),
        'bad.proto:4:3: Message "M" already has a field named "a".',
      );
    });

    test('proto3 rules', () {
      expect(
        _error('syntax = "proto3";\nmessage M { required int32 a = 1; }'),
        'bad.proto:2:13: Required fields are not allowed in proto3.',
      );
      expect(
        _error('syntax = "proto3";\nenum E { A = 1; }'),
        contains('The first value of enum "E" must be zero in proto3'),
      );
      expect(
        _error('syntax = "proto3";\nmessage M { int32 a = 1 [default = 3]; }'),
        contains('Default values are not allowed in proto3'),
      );
    });

    test('bad map key, field number and unclosed blocks', () {
      expect(
        _error('syntax = "proto3";\nmessage M { map<float, int32> m = 1; }'),
        'bad.proto:2:17: Invalid map key type "float". Keys must be an '
        'integer type, bool or string.',
      );
      expect(
        _error('syntax = "proto3";\nmessage M { int32 a = 19500; }'),
        contains('Field numbers 19000 to 19999 are reserved'),
      );
      expect(
        _error('syntax = "proto3";\nmessage M {\n  int32 a = 1;\n'),
        'bad.proto:4:1: Message "M" (line 2) is never closed with "}".',
      );
      expect(
        _error('syntax = "proto3";\n/* open'),
        'bad.proto:2:1: This /* comment is never closed with */.',
      );
      expect(
        _error('syntax = "proto4";'),
        'bad.proto:1:10: Unknown syntax "proto4". Use "proto2" or "proto3".',
      );
    });

    test('rpc types must be messages', () {
      expect(
        _error(
          'syntax = "proto3";\nenum E { A = 0; }\nmessage M {}\n'
          'service S {\n  rpc Do(E) returns (M);\n}',
        ),
        'bad.proto:5:3: "E" is an enum; rpc Do needs a message as its '
        'request type.',
      );
    });

    test('duplicate symbols across files', () {
      expect(
        _error(
          'syntax = "proto3"; package p; message M {}',
          more: {'other.proto': 'syntax = "proto3"; package p; message M {}'},
        ),
        anyOf(
          'bad.proto:1:31: "p.M" is already defined in other.proto.',
          'other.proto:1:31: "p.M" is already defined in bad.proto.',
        ),
      );
    });
  });

  test('loadProtoFiles follows imports on disk', () async {
    final pool = await loadProtoFiles(['$_fixtures/shop/v1/shop.proto']);
    expect(pool.findMessage('shop.common.Money'), isNotNull);
    expect(pool.findService('shop.v1.ProductService'), isNotNull);
  });
}
