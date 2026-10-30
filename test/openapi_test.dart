import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/import_any.dart';
import 'package:api_workbench/services/openapi_export.dart';
import 'package:api_workbench/services/openapi_import.dart';
import 'package:api_workbench/services/schema_sample.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

CollectionModel importFixture(String name) =>
    importOpenApi(fixture(name)).collections.single;

RequestModel request(CollectionModel c, String name) =>
    c.requests.firstWhere((r) => r.name == name, orElse: () => fail(name));

Object? jsonBody(RequestModel r) => jsonDecode(r.body);

String kvs(List<KV> rows) =>
    rows.map((r) => '${r.enabled ? '' : '!'}${r.key}=${r.value}').join('&');

void main() {
  group('schema samples', () {
    Object? sample(Object? schema, {Map<String, Object?> refs = const {}}) =>
        sampleFromSchema(schema, resolve: (r) => refs[r]);

    test('scalars follow type and format', () {
      expect(sample({'type': 'string'}), 'string');
      expect(sample({'type': 'string', 'format': 'date-time'}), contains('T'));
      expect(sample({'type': 'string', 'format': 'date'}), '2024-01-15');
      expect(sample({'type': 'string', 'format': 'email'}), contains('@'));
      expect(
        sample({'type': 'string', 'format': 'uuid'}),
        matches(RegExp(r'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$')),
      );
      expect(sample({'type': 'string', 'format': 'uri'}), startsWith('https:'));
      expect(sample({'type': 'string', 'format': 'ipv4'}), '192.0.2.1');
      expect(sample({'type': 'integer'}), 0);
      expect(sample({'type': 'number'}), 0.0);
      expect(sample({'type': 'boolean'}), true);
      expect(sample({'type': 'null'}), isNull);
    });

    test('example, default and enum win over the type, in that order', () {
      expect(
        sample({
          'type': 'string',
          'example': 'ex',
          'default': 'def',
          'enum': ['a', 'b'],
        }),
        'ex',
      );
      expect(
        sample({
          'type': 'string',
          'default': 'def',
          'enum': ['a', 'b'],
        }),
        'def',
      );
      expect(
        sample({
          'type': 'string',
          'enum': ['a', 'b'],
        }),
        'a',
      );
      expect(
        sample({
          'type': 'string',
          'examples': ['first', 'second'],
        }),
        'first',
      );
      expect(sample({'const': 'fixed'}), 'fixed');
      expect(sample({'type': 'boolean', 'default': false}), false);
    });

    test('string length and numeric bounds are respected', () {
      expect(sample({'type': 'string', 'maxLength': 3}), 'str');
      expect(
        (sample({'type': 'string', 'minLength': 10}) as String).length,
        10,
      );
      expect(sample({'type': 'integer', 'minimum': 5}), 5);
      expect(sample({'type': 'integer', 'minimum': -9, 'maximum': -3}), -9);
      expect(sample({'type': 'integer', 'maximum': -2}), -2);
      expect(
        sample({'type': 'integer', 'minimum': 0, 'exclusiveMinimum': true}),
        1,
      );
      expect(sample({'type': 'number', 'exclusiveMinimum': 2}), 2.5);
      expect(sample({'type': 'integer', 'minimum': 7, 'multipleOf': 5}), 10);
    });

    test('objects, arrays and additionalProperties', () {
      expect(
        sample({
          'type': 'object',
          'properties': {
            'id': {'type': 'integer'},
            'tags': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'nested': {
              'properties': {
                'ok': {'type': 'boolean'},
              },
            },
          },
        }),
        {
          'id': 0,
          'tags': ['string'],
          'nested': {'ok': true},
        },
      );
      expect(
        sample({
          'type': 'array',
          'minItems': 2,
          'items': {'type': 'integer'},
        }),
        [0, 0],
      );
      expect(
        sample({
          'type': 'array',
          'maxItems': 0,
          'items': {'type': 'integer'},
        }),
        isEmpty,
      );
      expect(
        sample({
          'type': 'object',
          'additionalProperties': {'type': 'integer'},
        }),
        {'additionalProp1': 0},
      );
      expect(sample({'type': 'object'}), isEmpty);
    });

    test('allOf merges, oneOf and anyOf take the first alternative', () {
      expect(
        sample({
          'allOf': [
            {
              'type': 'object',
              'properties': {
                'a': {'type': 'integer'},
              },
            },
            {
              'type': 'object',
              'properties': {
                'b': {'type': 'string'},
              },
            },
          ],
        }),
        {'a': 0, 'b': 'string'},
      );
      expect(
        sample({
          'oneOf': [
            {'type': 'null'},
            {'type': 'integer', 'example': 4},
            {'type': 'string'},
          ],
        }),
        4,
      );
      expect(
        sample({
          'anyOf': [
            {'type': 'boolean'},
            {'type': 'string'},
          ],
        }),
        true,
      );
    });

    test('nullable and type lists produce a real value', () {
      expect(sample({'type': 'string', 'nullable': true}), 'string');
      expect(
        sample({
          'type': ['null', 'integer'],
        }),
        0,
      );
    });

    test('readOnly and writeOnly are filtered by direction', () {
      final schema = {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer', 'readOnly': true},
          'password': {'type': 'string', 'writeOnly': true},
          'name': {'type': 'string'},
        },
      };
      expect(sampleFromSchema(schema, forRequest: true), {
        'password': 'string',
        'name': 'string',
      });
      expect(sampleFromSchema(schema, forRequest: false), {
        'id': 0,
        'name': 'string',
      });
      expect(sampleFromSchema(schema), hasLength(3));
    });

    test('references resolve, siblings refine, circular ones stop', () {
      final refs = <String, Object?>{
        '#/pet': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string', 'example': 'Rex'},
            'friend': {r'$ref': '#/pet'},
            'friends': {
              'type': 'array',
              'items': {r'$ref': '#/pet'},
            },
          },
        },
        '#/a': {
          'properties': {
            'b': {r'$ref': '#/b'},
          },
        },
        '#/b': {
          'properties': {
            'a': {r'$ref': '#/a'},
            'x': {'type': 'integer'},
          },
        },
        '#/alias': {r'$ref': '#/pet'},
        '#/self': {r'$ref': '#/self'},
      };
      expect(sample({r'$ref': '#/pet'}, refs: refs), {
        'name': 'Rex',
        'friends': <Object?>[],
      });
      expect(sample({r'$ref': '#/a'}, refs: refs), {
        'b': {'x': 0},
      });
      // A reference to a reference, with a sibling that overrides.
      expect(
        sample({r'$ref': '#/alias', 'example': 'sibling'}, refs: refs),
        'sibling',
      );
      expect(sample({r'$ref': '#/self'}, refs: refs), isNull);
      expect(sample({r'$ref': '#/missing'}, refs: refs), isNull);
    });

    test('a wide schema shared at every level stays small and fast', () {
      // Eight properties per level, all pointing at the next level: a
      // million nodes if expanded naively.
      final refs = <String, Object?>{
        for (var i = 0; i < 12; i++)
          '#/l$i': {
            'type': 'object',
            'properties': {
              for (var k = 0; k < 8; k++) 'p$k': {r'$ref': '#/l${i + 1}'},
              'n': {'type': 'integer'},
            },
          },
        '#/l12': {'type': 'string'},
      };
      final watch = Stopwatch()..start();
      final v = sample({r'$ref': '#/l0'}, refs: refs);
      expect(watch.elapsedMilliseconds, lessThan(2000));
      expect(jsonEncode(v).length, lessThan(200000));
      expect(v, isA<Map>());
    });

    test('nesting depth is limited', () {
      Map<String, dynamic> deep(int n) => n == 0
          ? {'type': 'integer'}
          : {
              'type': 'object',
              'properties': {'next': deep(n - 1)},
            };
      var v = sampleFromSchema(deep(30), maxDepth: 4);
      var levels = 0;
      while (v is Map && v.containsKey('next')) {
        v = v['next'];
        levels++;
      }
      expect(levels, lessThanOrEqualTo(5));
      expect(levels, greaterThan(0));
    });
  });

  group('decodeJsonOrYaml', () {
    test('reads JSON and YAML into plain maps', () {
      expect(decodeJsonOrYaml('{"a": [1, 2]}'), {
        'a': [1, 2],
      });
      final y = decodeJsonOrYaml(
        'a:\n  200: ok\n  "404": gone\nlist:\n  - x\n',
      );
      expect(y, {
        'a': {'200': 'ok', '404': 'gone'},
        'list': ['x'],
      });
      expect(y, isA<Map<String, dynamic>>());
    });

    test('YAML merge keys are expanded', () {
      final y =
          decodeJsonOrYaml(
                'base: &b\n  x: 1\n  y: 2\nchild:\n  <<: *b\n  y: 3\n',
              )
              as Map;
      expect(y['child'], {'x': 1, 'y': 3});
    });

    test('rejects text that is neither', () {
      expect(
        () => decodeJsonOrYaml('a: [1, 2'),
        throwsA(isA<FormatException>()),
      );
      expect(() => decodeJsonOrYaml('{"a": '), throwsFormatException);
    });
  });

  group('OpenAPI 3.0 import (Petstore YAML)', () {
    late ImportReport report;
    late CollectionModel c;
    setUpAll(() {
      report = importOpenApi(fixture('openapi/petstore30.yaml'));
      c = report.collections.single;
    });

    test('collection, report and variables', () {
      expect(report.formats, {'OpenAPI 3.0'});
      expect(report.requests, 12);
      expect(report.folders, 3);
      expect(c.requests, hasLength(12));
      expect(c.name, 'Petstore - OpenAPI 3.0');
      expect(c.description, startsWith('A small pet store'));
      expect(c.description, contains('API key and OAuth 2.0'));
      // Server variables take their defaults.
      expect(c.variables.map((v) => '${v.key}=${v.value}'), [
        'baseUrl=https://staging.petstore.test/api/v3',
      ]);
      expect(
        report.warnings.single,
        allOf(contains('more servers'), contains('prod.petstore.test')),
      );
    });

    test('folders come from the first tag, with its description', () {
      expect(request(c, 'Find pet by ID').folder, 'pet');
      expect(request(c, 'Place an order for a pet').folder, 'store');
      expect(request(c, 'Create user').folder, 'user');
      expect(c.folders['pet']!.description, 'Everything about your Pets');
      expect(c.folders['user']!.description, 'Operations about the user');
      // No tags: the root.
      expect(request(c, 'Logs out current logged in user session').folder, '');
    });

    test('name is the summary, then operationId, then method and path', () {
      final c2 = importOpenApi('''
openapi: 3.0.1
info: {title: T, version: '1'}
paths:
  /a:
    get: {summary: Sum, operationId: opA, responses: {}}
  /b:
    get: {operationId: opB, responses: {}}
  /c/{id}:
    delete: {responses: {}}
''').collections.single;
      expect(c2.requests.map((r) => r.name), ['Sum', 'opB', 'DELETE /c/{id}']);
      expect(c2.requests.last.url, '{{baseUrl}}/c/:id');
    });

    test('URLs use {{baseUrl}} and :param, path variables carry examples', () {
      final r = request(c, 'Find pet by ID');
      expect(r.method, 'GET');
      expect(r.url, '{{baseUrl}}/pet/:petId');
      expect(r.description, 'Returns a single pet');
      expect(r.pathVariables, hasLength(1));
      expect(r.pathVariables.single.key, 'petId');
      expect(r.pathVariables.single.value, '10');
      expect(r.pathVariables.single.description, 'ID of pet');
      // The operation's own parameter replaces the path-level one.
      expect(
        request(c, 'Uploads an image').pathVariables.single.description,
        'ID of pet to update',
      );
    });

    test('optional query params are added disabled', () {
      final r = request(c, 'Finds Pets by status');
      expect(kvs(r.params), '!status=available&!limit=1');
      expect(r.params.first.description, contains('Status values'));
      expect(
        kvs(request(c, 'Logs user into the system').params),
        'username=theUser&!password=string',
      );
    });

    test('header and cookie parameters', () {
      final del = request(c, 'Deletes a pet');
      expect(kvs(del.headers), '!api_key=string');
      final logout = request(c, 'Logs out current logged in user session');
      expect(logout.headers, hasLength(1));
      expect(logout.headers.single.key, 'Cookie');
      expect(logout.headers.single.value, 'session=abc123; theme=dark');
      expect(logout.headers.single.enabled, isTrue);
    });

    test('JSON bodies come from examples, else from the schema', () {
      final add = request(c, 'Add a new pet to the store');
      expect(add.bodyType, BodyType.json);
      // The first of `examples`.
      expect(jsonBody(add), {
        'id': 1,
        'name': 'Rex',
        'photoUrls': ['https://example.com/rex.png'],
        'status': 'available',
      });
      // Generated: property examples, enum, nested $refs, format defaults.
      final put = request(c, 'Update an existing pet');
      expect(jsonBody(put), {
        'id': 10,
        'name': 'doggie',
        'category': {'id': 1, 'name': 'Dogs'},
        'photoUrls': ['string'],
        'tags': [
          {'id': 0, 'name': 'string'},
        ],
        'status': 'available',
      });
      // readOnly `id` is left out of a request body.
      final order = jsonBody(request(c, 'Place an order for a pet')) as Map;
      expect(order.containsKey('id'), isFalse);
      expect(order['shipDate'], '2024-01-15T10:30:00Z');
      expect(order['status'], 'approved');
      // JSON is preferred over the form alternative.
      expect(request(c, 'Place an order for a pet').formFields, isEmpty);
    });

    test('binary bodies', () {
      final r = request(c, 'Uploads an image');
      expect(r.bodyType, BodyType.binary);
      expect(r.method, 'POST');
    });

    test('security schemes become collection auth; requests inherit', () {
      expect(c.auth.type, AuthType.apiKey);
      expect(c.auth.apiKeyName, 'api_key');
      expect(c.auth.apiKeyInHeader, isTrue);
      expect(request(c, 'Find pet by ID').auth.type, AuthType.inherit);
      expect(
        request(c, 'Returns pet inventories by status').auth.type,
        AuthType.inherit,
      );
    });

    test('an operation with its own security overrides the collection', () {
      final a = request(c, 'Add a new pet to the store').auth;
      expect(a.type, AuthType.oauth2);
      expect(a.params, {
        'grant_type': 'authorization_code',
        'authUrl': 'https://petstore.test/oauth/authorize',
        'accessTokenUrl': 'https://petstore.test/oauth/token',
        'refreshTokenUrl': 'https://petstore.test/oauth/refresh',
        'scope': 'write:pets read:pets',
        'addTokenTo': 'header',
        'headerPrefix': 'Bearer',
      });
    });

    test('empty security means no auth', () {
      expect(request(c, 'Logs user into the system').auth.type, AuthType.none);
    });

    test('responses with examples become examples', () {
      final get = request(c, 'Find pet by ID');
      expect(get.examples.map((e) => e.statusCode), [200, 404]);
      expect(get.examples.first.name, '200 OK');
      expect(get.examples.first.statusText, 'OK');
      expect(get.examples.first.contentType, 'application/json');
      expect(jsonDecode(get.examples.first.body), {
        'id': 10,
        'name': 'doggie',
        'photoUrls': <Object?>[],
      });
      expect(jsonDecode(get.examples.last.body)['code'], 404);

      final login = request(c, 'Logs user into the system');
      expect(login.examples, hasLength(1));
      expect(login.examples.single.body, 'logged in user session:1234');
      final rate = login.examples.single.headers.firstWhere(
        (h) => h.key == 'X-Rate-Limit',
      );
      expect(rate.value, '100');

      // Responses without examples (and `default`) add nothing.
      expect(
        request(c, 'Updates a pet in the store with form data').examples,
        isEmpty,
      );
      expect(request(c, 'Create user').examples, isEmpty);
    });
  });

  group('OpenAPI 3.1 import (JSON with refs)', () {
    late ImportReport report;
    late CollectionModel c;
    setUpAll(() {
      report = importOpenApi(fixture('openapi/spec31.json'));
      c = report.collections.single;
    });

    test('version, base URL and bearer auth', () {
      expect(report.formats, {'OpenAPI 3.1'});
      expect(c.variables.first.value, 'https://api.shop.test/v1');
      expect(c.auth.type, AuthType.bearer);
      expect(c.folders['Orders']!.description, 'Place and track orders');
      expect(c.folders.containsKey('Admin'), isFalse);
      expect(report.folders, 2);
    });

    test('referenced parameters, request bodies and responses', () {
      final list = request(c, 'listOrders');
      expect(kvs(list.params), '!pageSize=20&!tag=new&!tag=vip');
      expect(list.params.first.description, 'Orders per page');
      expect(list.headers.single.key, 'X-Request-Id');
      expect(list.headers.single.enabled, isTrue);
      expect(list.examples.map((e) => e.name), [
        '200 OK - One order',
        '200 OK - empty',
        '401 Unauthorized',
      ]);
      expect(jsonDecode(list.examples.last.body), {'error': 'unauthorized'});

      final get = request(c, 'Get an order');
      expect(get.pathVariables.single.value, 'ord_42');
      expect(get.pathVariables.single.description, "The order's id");
      expect(get.examples.single.statusCode, 404);
      expect(jsonDecode(get.examples.single.body)['error'], 'not_found');
    });

    test('3.1 schema keywords: oneOf, const, type lists, allOf, siblings', () {
      final body = jsonBody(request(c, 'Place an order')) as Map;
      // minItems: 2
      expect(body['items'], hasLength(2));
      expect((body['items'] as List).first, {
        'sku': '3fa85f64-5717-4562-b3fc-2c963f66afa6',
        'qty': 1,
      });
      // oneOf: the first alternative, with its const.
      expect(body['payment'], {'kind': 'card', 'last4': 'stri'});
      // A $ref with a sibling description; minLength 8.
      expect(body['shipTo'], {
        'line1': 'stringst',
        'line2': 'string',
        'country': 'NL',
      });
      // `examples` list in a type-list schema.
      expect(body['notes'], 'Leave at the door');
      // exclusiveMinimum as a number, multipleOf.
      expect(body['total'], 1.0);
    });

    test('operation-level security and servers', () {
      expect(request(c, 'Health check').auth.type, AuthType.none);
      final admin = request(c, 'Download a report');
      expect(admin.auth.type, AuthType.basic);
      expect(admin.url, 'https://admin.shop.test/admin/reports');
      expect(admin.folder, 'Admin');
    });

    test('text examples and XML bodies', () {
      final health = request(c, 'Health check');
      expect(health.examples.single.body, 'ok');
      expect(health.examples.single.contentType, 'text/plain');
      final legacy = request(c, 'Legacy import');
      expect(legacy.bodyType, BodyType.xml);
      expect(legacy.body, startsWith('<?xml'));
      expect(legacy.body, contains('<Order>'));
      expect(legacy.body, contains('<payment>'));
    });

    test('a segment mixing text and parameters becomes variables', () {
      final file = request(c, 'Download a file');
      expect(file.url, '{{baseUrl}}/files/{{name}}.{{ext}}');
      expect(c.variables.map((v) => v.key), containsAll(['name', 'ext']));
      expect(file.pathVariables, isEmpty);
    });

    test('external references and webhooks are reported, not followed', () {
      final r = request(c, 'Uses a schema from another file');
      expect(r.bodyType, BodyType.json);
      expect(r.body, isEmpty);
      expect(
        report.warnings,
        containsAll([
          contains('other.yaml#/components/schemas/Remote'),
          contains('Webhooks'),
        ]),
      );
    });

    test('info.summary stands in for a missing description', () {
      final c2 = importOpenApi('''
{"openapi": "3.1.0", "info": {"title": "T", "summary": "Short", "version": "1"},
 "paths": {"/x": {"get": {"responses": {}}}}}
''').collections.single;
      expect(c2.description, 'Short');
    });
  });

  group('Swagger 2.0 import', () {
    late ImportReport report;
    late CollectionModel c;
    setUpAll(() {
      report = importOpenApi(fixture('openapi/swagger20.json'));
      c = report.collections.single;
    });

    test('base URL is built from schemes, host and basePath', () {
      expect(report.formats, {'Swagger 2.0'});
      expect(c.variables.single.value, 'https://inventory.test:8443/api');
      expect(
        importOpenApi(
          '{"swagger":"2.0","info":{"title":"x"},"host":"h.test",'
          '"schemes":["http"],"basePath":"/v1/",'
          '"paths":{"/a":{"get":{"responses":{}}}}}',
        ).collections.single.variables.single.value,
        'http://h.test/v1',
      );
    });

    test('referenced parameters, array query params, headers', () {
      final list = request(c, 'List items');
      expect(kvs(list.params), '!limit=25&color=red');
      expect(list.params.first.description, 'Maximum number of items');
      expect(kvs(list.headers), '!X-Trace=t-1');
      expect(list.folder, 'items');
      expect(c.folders['items']!.description, 'Stock items');
    });

    test('body parameter, consumes and path-level parameters', () {
      final post = request(c, 'Create an item');
      expect(post.bodyType, BodyType.json);
      expect(jsonBody(post), {
        'id': 0,
        'name': 'bolt',
        'price': 0.0,
        'tags': ['string'],
        'dimensions': {'w': 0, 'h': 0},
      });
      final put = request(c, 'replaceItem');
      expect(put.bodyType, BodyType.xml);
      expect(put.body, contains('<Item>'));
      expect(put.body, contains('<name>bolt</name>'));
      expect(put.pathVariables.single.key, 'id');
      expect(put.pathVariables.single.value, '77');
    });

    test('formData parameters: multipart with a file, urlencoded', () {
      final photo = request(c, 'Upload a photo');
      expect(photo.bodyType, BodyType.formData);
      expect(photo.formFields.map((f) => f.key), ['caption', 'photo']);
      expect(photo.formFields.first.value, 'front view');
      expect(photo.formFields.last.isFile, isTrue);
      final login = request(c, 'Log in with a form');
      expect(login.bodyType, BodyType.formUrlEncoded);
      expect(login.formFields.map((f) => f.key), ['user', 'pass']);
      expect(login.formFields.any((f) => f.isFile), isFalse);
    });

    test('securityDefinitions: apiKey in query, basic, oauth2', () {
      expect(c.auth.type, AuthType.apiKey);
      expect(c.auth.apiKeyName, 'api_key');
      expect(c.auth.apiKeyInHeader, isFalse);
      expect(request(c, 'Create an item').auth.type, AuthType.basic);
      final oauth = request(c, 'replaceItem').auth;
      expect(oauth.type, AuthType.oauth2);
      expect(oauth.params['grant_type'], 'authorization_code');
      expect(
        oauth.params['accessTokenUrl'],
        'https://inventory.test/oauth/token',
      );
      expect(oauth.params['scope'], 'write read');
      expect(request(c, 'Log in with a form').auth.type, AuthType.none);
    });

    test('response examples and referenced responses', () {
      final list = request(c, 'List items');
      expect(list.examples.single.statusCode, 200);
      expect(jsonDecode(list.examples.single.body), [
        {'id': 1, 'name': 'bolt', 'price': 0.25},
      ]);
      final get = request(c, 'Get an item');
      expect(get.examples.single.statusCode, 410);
      expect(jsonDecode(get.examples.single.body)['code'], 410);
    });

    test('auth that cannot be carried over is reported', () {
      expect(request(c, 'Needs a cookie key').auth.type, AuthType.none);
      expect(report.unsupportedAuth, {'API key in a cookie': 1});
      expect(
        report.warnings.single,
        allOf(contains('API key in a cookie'), contains('left empty')),
      );
    });
  });

  group('circular schemas', () {
    late CollectionModel c;
    setUpAll(() => c = importFixture('openapi/circular.yaml'));

    test('self-referencing schema terminates', () {
      expect(jsonBody(request(c, 'Create a node')), {
        'id': 0,
        'children': <Object?>[],
      });
    });

    test('mutually recursive schemas terminate', () {
      expect(jsonBody(request(c, 'Create a person')), {
        'name': 'string',
        'employer': {'title': 'string', 'staff': <Object?>[]},
      });
    });

    test('recursive allOf terminates', () {
      expect(jsonBody(request(c, 'Create a tree')), {'label': 'string'});
    });

    test('a reference that points at itself terminates with an empty body', () {
      final r = request(c, 'A ref that points at itself');
      expect(r.bodyType, BodyType.json);
      expect(r.body, isEmpty);
    });

    test('a circular chain of parameter refs does not hang', () {
      final c2 = importOpenApi('''
openapi: 3.0.0
info: {title: T, version: '1'}
paths:
  /x:
    get:
      parameters:
        - \$ref: '#/components/parameters/A'
      responses: {}
components:
  parameters:
    A: {\$ref: '#/components/parameters/B'}
    B: {\$ref: '#/components/parameters/A'}
''').collections.single;
      expect(c2.requests.single.params, isEmpty);
    });
  });

  group('import errors', () {
    test('documents that are not OpenAPI or Swagger', () {
      expect(() => importOpenApi('{"info": {}}'), throwsFormatException);
      expect(() => importOpenApi('just: some yaml'), throwsFormatException);
      expect(() => importOpenApi('plain text'), throwsFormatException);
    });

    test('unsupported versions and empty specs say why', () {
      expect(
        () => importOpenApi('{"openapi":"2.5","paths":{}}'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('not supported'),
          ),
        ),
      );
      expect(() => importOpenApi('{"swagger":"1.2"}'), throwsFormatException);
      expect(
        () => importOpenApi('{"openapi":"3.0.0","info":{"title":"x"}}'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('no operations'),
          ),
        ),
      );
    });

    test('a failed import leaves the report untouched', () {
      final report = ImportReport();
      expect(
        () => importOpenApi('{"openapi":"3.0.0"}', into: report),
        throwsFormatException,
      );
      expect(report.isEmpty, isTrue);
      expect(report.formats, isEmpty);
    });

    test('a malformed spec is reported, not crashed on', () {
      final c = importOpenApi('''
openapi: 3.0.0
info: oops
servers: nope
paths:
  /a:
    parameters: 5
    get:
      parameters: [1, {name: q}, {name: q, in: query}]
      requestBody: {content: {application/json: 7}}
      responses: {'200': 3}
    post: not-a-map
tags: [1]
''').collections.single;
      expect(c.requests.single.url, '{{baseUrl}}/a');
    });
  });

  group('OpenAPI export', () {
    CollectionModel sample() => CollectionModel(
      name: 'Shop API',
      description: 'The shop.',
      variables: [
        KV(key: 'baseUrl', value: 'https://api.shop.test/v1/'),
        KV(key: 'token', value: 'secret'),
      ],
      auth: AuthConfig(type: AuthType.bearer, bearerToken: '{{token}}'),
      folders: {'Orders': FolderMeta(description: 'Order endpoints')},
      requests: [
        RequestModel(
          name: 'List orders',
          method: 'GET',
          url: '{{baseUrl}}/orders?expand=items',
          folder: 'Orders',
          authType: AuthType.inherit,
          description: 'All orders.',
          params: [
            KV(key: 'page', value: '2', description: 'Page number'),
            KV(key: 'sort', value: 'created', enabled: false),
          ],
          headers: [
            KV(key: 'X-Trace', value: 'abc'),
            KV(key: 'Authorization', value: 'Bearer x'),
            KV(key: 'Content-Type', value: 'application/json'),
            KV(key: 'Accept', value: '*/*'),
            KV(key: 'Cookie', value: 'sid=1; theme=dark'),
          ],
          examples: [
            ResponseExample(
              name: 'ok',
              statusCode: 200,
              statusText: 'OK',
              headers: [
                KV(key: 'Content-Type', value: 'application/json'),
                KV(key: 'X-Total', value: '2'),
                KV(key: 'Content-Length', value: '9'),
              ],
              body: '[{"id":1}]',
            ),
            ResponseExample(
              name: 'bad',
              statusCode: 400,
              statusText: 'Bad Request',
              body: 'nope',
            ),
          ],
        ),
        RequestModel(
          name: 'Create order',
          method: 'POST',
          url: '{{baseUrl}}/orders/:orderId/lines/{{lineKind}}',
          folder: 'Orders',
          pathVariables: [
            KV(key: 'orderId', value: '42', description: 'Order id'),
          ],
          bodyType: BodyType.json,
          body: '{"sku": "A1", "qty": 2, "tags": ["x"], "gift": null}',
          authType: AuthType.none,
        ),
        RequestModel(
          name: 'Health',
          method: 'GET',
          url: '{{baseUrl}}/health',
          authType: AuthType.inherit,
        ),
        RequestModel(
          name: 'Upload',
          method: 'PUT',
          url: '{{baseUrl}}/upload',
          bodyType: BodyType.formData,
          formFields: [
            KV(key: 'title', value: 'Hello'),
            KV(key: 'file', isFile: true),
          ],
          auth: AuthConfig(
            type: AuthType.oauth2,
            params: {
              'grant_type': 'client_credentials',
              'accessTokenUrl': 'https://auth.test/token',
              'scope': 'upload read',
            },
          ),
        ),
        RequestModel(
          name: 'Login',
          method: 'POST',
          url: '{{baseUrl}}/login',
          bodyType: BodyType.formUrlEncoded,
          formFields: [KV(key: 'user', value: 'ada')],
          auth: AuthConfig(
            type: AuthType.apiKey,
            apiKeyName: 'X-Key',
            apiKeyInHeader: true,
          ),
        ),
        RequestModel(
          name: 'Soap',
          method: 'POST',
          url: '{{baseUrl}}/soap',
          bodyType: BodyType.xml,
          body: '<a/>',
        ),
        RequestModel(
          name: 'Note',
          method: 'POST',
          url: '{{baseUrl}}/note',
          bodyType: BodyType.text,
          body: 'hi',
        ),
        RequestModel(
          name: 'Sock',
          url: 'ws://x.test',
          kind: RequestKind.websocket,
        ),
      ],
    );

    Map<String, dynamic> doc() =>
        jsonDecode(buildOpenApiDocument(sample())) as Map<String, dynamic>;

    test('info, servers, tags and security', () {
      final d = doc();
      expect(d['openapi'], startsWith('3.0.'));
      expect(d['info'], {
        'title': 'Shop API',
        'description': 'The shop.',
        'version': '1.0.0',
      });
      expect(d['servers'], [
        {'url': 'https://api.shop.test/v1'},
      ]);
      expect(d['tags'], [
        {'name': 'Orders', 'description': 'Order endpoints'},
      ]);
      expect(d['security'], [
        {'bearerAuth': []},
      ]);
      final schemes = d['components']['securitySchemes'] as Map;
      expect(schemes['bearerAuth'], {'type': 'http', 'scheme': 'bearer'});
      expect(schemes['apiKeyAuth'], {
        'type': 'apiKey',
        'in': 'header',
        'name': 'X-Key',
      });
      expect(schemes['oauth2Auth'], {
        'type': 'oauth2',
        'flows': {
          'clientCredentials': {
            'tokenUrl': 'https://auth.test/token',
            'scopes': {'upload': '', 'read': ''},
          },
        },
      });
    });

    test('paths: baseUrl stripped, :param to {param}, variables kept', () {
      final paths = doc()['paths'] as Map;
      expect(paths.keys, [
        '/orders',
        '/orders/{orderId}/lines/{{lineKind}}',
        '/health',
        '/upload',
        '/login',
        '/soap',
        '/note',
      ]);
      // Streaming requests are skipped.
      expect(paths.keys.any((k) => (k as String).contains('x.test')), isFalse);
    });

    test('parameters: path, query, header; reserved headers are skipped', () {
      final op = doc()['paths']['/orders']['get'] as Map;
      expect(op['summary'], 'List orders');
      expect(op['description'], 'All orders.');
      expect(op['tags'], ['Orders']);
      expect(op['operationId'], 'listOrders');
      final params = (op['parameters'] as List).cast<Map>();
      Map p(String name, String where) =>
          params.firstWhere((x) => x['name'] == name && x['in'] == where);
      expect(p('page', 'query'), {
        'name': 'page',
        'in': 'query',
        'required': true,
        'description': 'Page number',
        'schema': {'type': 'integer'},
        'example': 2,
      });
      expect(p('sort', 'query')['required'], isFalse);
      // typed into the URL
      expect(p('expand', 'query')['example'], 'items');
      expect(p('X-Trace', 'header')['example'], 'abc');
      expect(params.where((x) => x['in'] == 'header').map((x) => x['name']), [
        'X-Trace',
      ]);
      expect(p('sid', 'cookie')['example'], 1);
      expect(p('theme', 'cookie')['example'], 'dark');
      // a cookie header is not left as a header parameter
      expect(params.any((x) => x['name'] == 'Cookie'), isFalse);

      final create =
          doc()['paths']['/orders/{orderId}/lines/{{lineKind}}']['post'] as Map;
      expect((create['parameters'] as List).single, {
        'name': 'orderId',
        'in': 'path',
        'required': true,
        'description': 'Order id',
        'schema': {'type': 'integer'},
        'example': 42,
      });
    });

    test('request bodies by type, with examples', () {
      final paths = doc()['paths'] as Map;
      final json =
          paths['/orders/{orderId}/lines/{{lineKind}}']['post']['requestBody']
              as Map;
      expect(json['content'].keys, ['application/json']);
      final media = json['content']['application/json'] as Map;
      expect(media['example'], {
        'sku': 'A1',
        'qty': 2,
        'tags': ['x'],
        'gift': null,
      });
      expect(media['schema']['properties']['qty'], {'type': 'integer'});
      expect(media['schema']['properties']['tags'], {
        'type': 'array',
        'items': {'type': 'string'},
      });

      final multipart =
          paths['/upload']['put']['requestBody']['content']['multipart/form-data']['schema']['properties']
              as Map;
      expect(multipart['title'], {'type': 'string', 'example': 'Hello'});
      expect(multipart['file'], {'type': 'string', 'format': 'binary'});

      final form =
          paths['/login']['post']['requestBody']['content']['application/x-www-form-urlencoded']['schema']['properties'];
      expect(form['user'], {'type': 'string', 'example': 'ada'});
      expect(
        paths['/soap']['post']['requestBody']['content']['application/xml']['example'],
        '<a/>',
      );
      expect(
        paths['/note']['post']['requestBody']['content']['text/plain']['example'],
        'hi',
      );
      // GET operations carry no body.
      expect(paths['/health']['get'].containsKey('requestBody'), isFalse);
    });

    test('responses come from examples; a bare 200 otherwise', () {
      final paths = doc()['paths'] as Map;
      final responses = paths['/orders']['get']['responses'] as Map;
      expect(responses.keys, ['200', '400']);
      expect(responses['200']['description'], 'OK');
      expect(responses['200']['content']['application/json']['example'], [
        {'id': 1},
      ]);
      expect(responses['200']['headers'], {
        'X-Total': {
          'schema': {'type': 'string'},
          'example': '2',
        },
      });
      expect(responses['400']['content']['text/plain']['example'], 'nope');
      expect(paths['/health']['get']['responses'], {
        '200': {'description': 'OK'},
      });
    });

    test('operation-level security only where it differs', () {
      final paths = doc()['paths'] as Map;
      // inherits the collection's bearer auth
      expect(paths['/orders']['get'].containsKey('security'), isFalse);
      expect(paths['/health']['get'].containsKey('security'), isFalse);
      // auth: none overrides it
      expect(
        paths['/orders/{orderId}/lines/{{lineKind}}']['post']['security'],
        isEmpty,
      );
      expect(paths['/login']['post']['security'], [
        {'apiKeyAuth': []},
      ]);
      expect(paths['/upload']['put']['security'], [
        {
          'oauth2Auth': ['upload', 'read'],
        },
      ]);
    });

    test('folder auth is inherited by its requests', () {
      final c = CollectionModel(
        name: 'F',
        auth: AuthConfig(type: AuthType.basic),
        folders: {'A': FolderMeta(auth: AuthConfig(type: AuthType.bearer))},
        requests: [
          RequestModel(
            name: 'x',
            url: 'https://h.test/x',
            folder: 'A',
            authType: AuthType.inherit,
          ),
          RequestModel(
            name: 'y',
            url: 'https://h.test/y',
            authType: AuthType.inherit,
          ),
        ],
      );
      final d = openApiDocumentMap(c);
      expect(d['security'], [
        {'basicAuth': []},
      ]);
      expect(d['paths']['/x']['get']['security'], [
        {'bearerAuth': []},
      ]);
      expect(d['paths']['/y']['get'].containsKey('security'), isFalse);
    });

    test('requests sharing a method and path merge their examples', () {
      final c = CollectionModel(
        name: 'Dup',
        requests: [
          RequestModel(
            name: 'one',
            url: 'https://h.test/a',
            examples: [ResponseExample(statusCode: 200, body: '1')],
          ),
          RequestModel(
            name: 'two',
            url: 'https://h.test/a',
            examples: [
              ResponseExample(statusCode: 200, body: '2'),
              ResponseExample(statusCode: 404, body: 'x'),
            ],
          ),
        ],
      );
      final d = openApiDocumentMap(c);
      expect((d['paths'] as Map).keys, ['/a']);
      expect(d['paths']['/a']['get']['summary'], 'one');
      final r = d['paths']['/a']['get']['responses'] as Map;
      expect(r.keys, ['200', '404']);
      expect(r['200']['content']['application/json']['examples'].length, 2);
    });

    test('servers are inferred from absolute URLs, others override', () {
      final c = CollectionModel(
        name: 'Abs',
        requests: [
          RequestModel(name: 'a', url: 'https://one.test/a'),
          RequestModel(name: 'b', url: 'https://one.test:8443/b'),
          RequestModel(name: 'c', url: 'https://one.test/c'),
          RequestModel(name: 'd', url: 'https://other.test/d?x=1#frag'),
        ],
      );
      final d = openApiDocumentMap(c);
      expect(d['servers'], [
        {'url': 'https://one.test'},
      ]);
      expect(d['paths']['/d']['get']['servers'], [
        {'url': 'https://other.test'},
      ]);
      expect(d['paths']['/d']['get']['parameters'].single['name'], 'x');
      expect(d['paths']['/a']['get'].containsKey('servers'), isFalse);
    });

    test('a baseUrl value is stripped from URLs that spell it out', () {
      final c = CollectionModel(
        name: 'Lit',
        variables: [KV(key: 'base_url', value: 'https://h.test/api')],
        requests: [RequestModel(name: 'a', url: 'https://h.test/api/a')],
      );
      final d = openApiDocumentMap(c);
      expect(d['servers'], [
        {'url': 'https://h.test/api'},
      ]);
      expect((d['paths'] as Map).keys, ['/a']);
    });

    test('QUERY requests use an extension key and come back', () {
      final c = CollectionModel(
        name: 'Q',
        requests: [
          RequestModel(
            name: 'search',
            method: 'QUERY',
            url: 'https://h.test/search',
            bodyType: BodyType.json,
            body: '{"q":"x"}',
          ),
        ],
      );
      final d = openApiDocumentMap(c);
      expect(d['paths']['/search'].keys, ['x-query']);
      final back = importOpenApi(buildOpenApiDocument(c)).collections.single;
      expect(back.requests.single.method, 'QUERY');
      expect(back.requests.single.body, contains('"q": "x"'));
    });

    test('operationIds are unique identifiers', () {
      final c = CollectionModel(
        name: 'Ids',
        requests: [
          RequestModel(name: 'Get thing!', url: 'https://h.test/a'),
          RequestModel(
            name: 'Get thing!',
            method: 'POST',
            url: 'https://h.test/b',
          ),
          RequestModel(name: '1st', method: 'PUT', url: 'https://h.test/c'),
          RequestModel(name: 'ünï', method: 'PATCH', url: 'https://h.test/d'),
        ],
      );
      final ids = [
        for (final p in (openApiDocumentMap(c)['paths'] as Map).values)
          for (final op in (p as Map).values) (op as Map)['operationId'],
      ];
      expect(ids.toSet(), hasLength(4));
      for (final id in ids) {
        expect(id, matches(RegExp(r'^[A-Za-z][A-Za-z0-9]*$')));
      }
    });

    test('JSON and YAML output describe the same document', () {
      final json = buildOpenApiDocument(sample());
      final yaml = buildOpenApiDocument(sample(), yaml: true);
      expect(json.trimLeft(), startsWith('{'));
      expect(jsonDecode(json), decodeJsonOrYaml(yaml));
      expect(yaml, startsWith('openapi: "3.0.3"\n'));
      // Every response code is a quoted key, so readers keep them strings.
      expect(yaml, contains('"200":'));
    });
  });

  group('YAML emitter', () {
    final awkward = <String>[
      '',
      ' ',
      ' leading',
      'trailing ',
      'true',
      'False',
      'yes',
      'No',
      'on',
      'OFF',
      'null',
      'Null',
      '~',
      'y',
      'N',
      '123',
      '-5',
      '+5',
      '1.5',
      '1e3',
      '0x1F',
      '0o17',
      '.inf',
      '-.inf',
      '.NaN',
      '1.0.0',
      '2024-01-15',
      '12:30:45',
      '2024-01-15T10:30:00Z',
      '-',
      '- item',
      '--- x',
      '...',
      '?',
      '? x',
      ': x',
      'key: value',
      'key:',
      'a: b: c',
      '#comment',
      'a #b',
      'a#b',
      '&anchor',
      '*alias',
      '!tag',
      '!!str',
      '|',
      '>',
      '| x',
      '> x',
      '{x}',
      '{{baseUrl}}/pets',
      '[x]',
      '[]',
      '{}',
      '@at',
      '`tick',
      '%pct',
      '"dq"',
      "'sq'",
      "it's",
      'say "hi"',
      'back\\slash',
      'a, b',
      'a: ',
      '<<',
      '=',
      '#/components/schemas/Pet',
      '/pets/{id}',
      '/pets/:id',
      'https://x.test:8080/a?b=c#d',
      'user@example.com',
      'Content-Type: x',
      'plain words here',
      'café',
      'naïve',
      '日本語',
      'emoji 😀',
      'tab\there',
      'line1\nline2',
      'line1\nline2\n',
      'a\n\nb',
      'a\n\n',
      '\nstarts',
      ' x\ny',
      'x\n y',
      'x\n\ty',
      'a\r\nb',
      'cr\rhere',
      'nul\u0000',
      'bell\u0007',
      'del\u007f',
      'nel\u0085',
      'ls\u2028ps\u2029',
      '\uFEFFbom',
      'trailing space \nnext',
      'x\n  indented',
    ];

    test('every awkward string survives as a value and as a key', () {
      final value = {
        for (var i = 0; i < awkward.length; i++) 'v$i': awkward[i],
      };
      // A plain `<<` key is YAML's merge key, which the reader expands.
      final keys = {
        for (var i = 0; i < awkward.length; i++)
          if (awkward[i] != '<<') awkward[i]: i,
      };
      for (final original in [value, keys]) {
        final text = emitYaml(original);
        expect(decodeJsonOrYaml(text), original, reason: 'emitted:\n$text');
      }
    });

    test('strings that look like other types come back as strings', () {
      final text = emitYaml({
        'a': '123',
        'b': 'true',
        'c': 'null',
        'd': '1.0.0',
        'e': '2024-01-15',
        'f': '',
      });
      final loaded = loadYaml(text) as YamlMap;
      for (final v in loaded.values) {
        expect(v, isA<String>());
      }
      expect(text, contains('a: "123"'));
      expect(text, contains('f: ""'));
    });

    test('scalars, nesting and empty collections', () {
      final original = {
        'int': 42,
        'neg': -7,
        'double': 1.5,
        'big': 1e21,
        'small': 1.5e-7,
        'whole': 3.0,
        'yes': true,
        'no': false,
        'nothing': null,
        'emptyMap': <String, dynamic>{},
        'emptyList': <Object?>[],
        'list': [
          'a',
          1,
          null,
          true,
          {
            'k': 'v',
            'n': [1, 2],
          },
          [
            'nested',
            [
              'deeper',
              {'x': 'y'},
            ],
          ],
          <String, dynamic>{},
          <Object?>[],
          'multi\nline',
        ],
        'map': {
          'inner': {
            'deep': {'deeper': 'value'},
          },
          '200': 'ok',
          'with space': 1,
          'a/b': 2,
        },
      };
      final text = emitYaml(original);
      expect(decodeJsonOrYaml(text), original, reason: text);
    });

    test('a top-level scalar or empty collection', () {
      expect(decodeJsonOrYaml(emitYaml('x: y')), 'x: y');
      expect(decodeJsonOrYaml(emitYaml(7)), 7);
      expect(decodeJsonOrYaml(emitYaml(<String, dynamic>{})), isEmpty);
      expect(decodeJsonOrYaml(emitYaml([1, 2])), [1, 2]);
    });

    test('multi-line text becomes a literal block', () {
      final text = emitYaml({'d': 'one\ntwo', 'e': 'one\ntwo\n'});
      expect(text, contains('d: |-\n  one\n  two\n'));
      expect(text, contains('e: |\n  one\n  two\n'));
    });

    test('no colons, braces or hashes leak out unquoted', () {
      final text = emitYaml({
        'k': ['a: b', '#x', '{y}', 'ok', '/p/{id}'],
      });
      expect(text, contains('- "a: b"'));
      expect(text, contains('- "#x"'));
      expect(text, contains('- "{y}"'));
      expect(text, contains('- ok'));
      expect(text, contains('- /p/{id}'));
    });
  });

  group('round trip', () {
    void sameBody(RequestModel a, RequestModel b, String where) {
      expect(b.bodyType, a.bodyType, reason: where);
      if (a.bodyType == BodyType.json && a.body.isNotEmpty) {
        expect(jsonDecode(b.body), jsonDecode(a.body), reason: where);
      } else {
        expect(b.body, a.body, reason: where);
      }
      expect(kvs(b.formFields), kvs(a.formFields), reason: where);
      expect(
        b.formFields.map((f) => f.isFile),
        a.formFields.map((f) => f.isFile),
        reason: where,
      );
    }

    void sameRequest(RequestModel a, RequestModel b) {
      final where = '${a.method} ${a.name}';
      expect(b.name, a.name, reason: where);
      expect(b.method, a.method, reason: where);
      expect(b.url, a.url, reason: where);
      expect(b.folder, a.folder, reason: where);
      expect(b.description, a.description, reason: where);
      expect(kvs(b.params), kvs(a.params), reason: where);
      expect(kvs(b.headers), kvs(a.headers), reason: where);
      expect(kvs(b.pathVariables), kvs(a.pathVariables), reason: where);
      sameBody(a, b, where);
      expect(b.auth.type, a.auth.type, reason: where);
      expect(b.auth.params, a.auth.params, reason: where);
      expect(b.auth.apiKeyName, a.auth.apiKeyName, reason: where);
      expect(b.auth.apiKeyInHeader, a.auth.apiKeyInHeader, reason: where);
      expect(
        b.examples.map((e) => '${e.statusCode} ${e.name}'),
        a.examples.map((e) => '${e.statusCode} ${e.name}'),
        reason: where,
      );
      for (var i = 0; i < a.examples.length; i++) {
        final ea = a.examples[i];
        final eb = b.examples[i];
        expect(eb.statusText, ea.statusText, reason: where);
        expect(eb.contentType, ea.contentType, reason: where);
        final json = (ea.contentType ?? '').contains('json');
        if (json && ea.body.trimLeft().startsWith(RegExp(r'[\[{]'))) {
          expect(jsonDecode(eb.body), jsonDecode(ea.body), reason: where);
        } else {
          expect(eb.body, ea.body, reason: where);
        }
      }
    }

    for (final name in [
      'openapi/petstore30.yaml',
      'openapi/spec31.json',
      'openapi/swagger20.json',
      'openapi/circular.yaml',
    ]) {
      for (final yaml in [false, true]) {
        test('$name through ${yaml ? 'YAML' : 'JSON'} export and back', () {
          final original = importFixture(name);
          final text = buildOpenApiDocument(original, yaml: yaml);
          final back = importOpenApi(text).collections.single;

          expect(back.name, original.name);
          expect(back.description, original.description);
          expect(
            back.variables.map((v) => '${v.key}=${v.value}').first,
            original.variables.map((v) => '${v.key}=${v.value}').first,
          );
          expect(back.requests.length, original.requests.length);
          for (var i = 0; i < original.requests.length; i++) {
            sameRequest(original.requests[i], back.requests[i]);
          }
          expect(back.auth.type, original.auth.type);
          expect(back.auth.apiKeyName, original.auth.apiKeyName);
          expect(back.auth.apiKeyInHeader, original.auth.apiKeyInHeader);
          expect(
            back.folders.map((k, v) => MapEntry(k, v.description)),
            original.folders.map((k, v) => MapEntry(k, v.description)),
          );
        });
      }
    }

    test('a hand-built collection comes back equivalent', () {
      final original = CollectionModel(
        name: 'Hand',
        variables: [KV(key: 'baseUrl', value: 'https://h.test')],
        auth: AuthConfig(type: AuthType.basic),
        requests: [
          RequestModel(
            name: 'Search',
            url: '{{baseUrl}}/search/:kind',
            folder: 'Find',
            pathVariables: [KV(key: 'kind', value: 'users')],
            params: [
              KV(key: 'q', value: 'ada'),
              KV(key: 'limit', value: '10', enabled: false),
              KV(key: 'tag', value: 'a'),
              KV(key: 'tag', value: 'b'),
            ],
            headers: [KV(key: 'X-Trace', value: '1')],
            examples: [
              ResponseExample(
                name: '200 OK',
                statusCode: 200,
                statusText: 'OK',
                headers: [KV(key: 'Content-Type', value: 'application/json')],
                body: '{"hits":[]}',
              ),
            ],
          ),
          RequestModel(
            name: 'Post it',
            method: 'POST',
            url: '{{baseUrl}}/post',
            bodyType: BodyType.json,
            body: '{"a":1,"b":[true,null]}',
            authType: AuthType.none,
          ),
          RequestModel(
            name: 'Form',
            method: 'POST',
            url: '{{baseUrl}}/form',
            bodyType: BodyType.formUrlEncoded,
            formFields: [
              KV(key: 'a', value: '1'),
              KV(key: 'b', value: 'two words'),
            ],
            auth: AuthConfig(type: AuthType.bearer),
          ),
        ],
        folders: {'Find': FolderMeta(description: 'Search things')},
      );
      final back = importOpenApi(
        buildOpenApiDocument(original, yaml: true),
      ).collections.single;
      expect(back.requests, hasLength(3));
      for (var i = 0; i < 3; i++) {
        sameRequest(original.requests[i], back.requests[i]);
      }
      expect(back.folders['Find']!.description, 'Search things');
      expect(back.auth.type, AuthType.basic);
    });
  });

  group('importAnyFile routing', () {
    test('OpenAPI as JSON and as YAML', () {
      final json = importAnyFile(fixture('openapi/spec31.json'));
      expect(json.formats, {'OpenAPI 3.1'});
      final yaml = importAnyFile(fixture('openapi/petstore30.yaml'));
      expect(yaml.formats, {'OpenAPI 3.0'});
      final swagger = importAnyFile(fixture('openapi/swagger20.json'));
      expect(swagger.formats, {'Swagger 2.0'});
    });

    test('HAR goes to the HAR importer', () {
      final r = importAnyFile(fixture('har/browser.har'));
      expect(r.formats.single, startsWith('HAR'));
      expect(r.collections.single.name, startsWith('HAR import '));
    });

    test('Postman and workspace JSON still reach the Postman importer', () {
      final postman = importAnyFile(
        jsonEncode({
          'info': {
            'name': 'P',
            'schema':
                'https://schema.getpostman.com/json/collection/v2.1.0/collection.json',
          },
          'item': [
            {
              'name': 'one',
              'request': {'method': 'GET', 'url': 'https://h.test/one'},
            },
          ],
        }),
      );
      expect(postman.formats.single, contains('Postman collection'));
      expect(postman.collections.single.requests.single.name, 'one');

      final ws = importAnyFile(
        jsonEncode({
          'app': 'apiworkbench',
          'version': 1,
          'collections': [
            CollectionModel(
              name: 'W',
              requests: [RequestModel(name: 'r', url: 'https://h.test')],
            ).toJson(),
          ],
          'environments': [],
        }),
      );
      expect(ws.formats.single, 'ApiWorkbench workspace');
      expect(ws.collections.single.name, 'W');

      final env = importAnyFile(
        jsonEncode({
          'name': 'Env',
          'values': [
            {'key': 'a', 'value': '1'},
          ],
        }),
      );
      expect(env.environments.single.name, 'Env');
    });

    test('files of several formats accumulate into one report', () {
      var report = importAnyFile(fixture('openapi/petstore30.yaml'));
      report = importAnyFile(fixture('har/browser.har'), into: report);
      report = importAnyFile(fixture('openapi/swagger20.json'), into: report);
      expect(report.collections, hasLength(3));
      expect(report.formats.length, 3);
      expect(report.requests, 12 + 7 + 7);
      expect(report.warnings, isNotEmpty);
    });

    test('exporting then importing an exported document works', () {
      final original = importFixture('openapi/petstore30.yaml');
      final report = importAnyFile(buildOpenApiDocument(original, yaml: true));
      expect(report.collections.single.requests, hasLength(12));
    });

    test('a byte order mark is ignored', () {
      final r = importAnyFile('\uFEFF${fixture('openapi/spec31.json')}');
      expect(r.formats, {'OpenAPI 3.1'});
      final y = importAnyFile('\uFEFF${fixture('openapi/petstore30.yaml')}');
      expect(y.formats, {'OpenAPI 3.0'});
    });

    test('text nobody can read is refused with a useful message', () {
      expect(
        () => importAnyFile('hello there'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('OpenAPI'), contains('HAR'), contains('Postman')),
          ),
        ),
      );
      expect(
        () => importAnyFile('{"broken": '),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('not valid JSON'),
          ),
        ),
      );
      expect(() => importAnyFile('- just\n- a list\n'), throwsFormatException);
      expect(() => importAnyFile('42'), throwsFormatException);
      // YAML that is not a spec.
      expect(() => importAnyFile('name: x\nvalue: y\n'), throwsFormatException);
    });

    test('a YAML mistake in a spec shows where it is', () {
      expect(
        () =>
            importAnyFile('openapi: 3.0.0\ninfo:\n  title: [oops\npaths: {}\n'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('not valid YAML'), contains('line')),
          ),
        ),
      );
    });

    test('an OpenAPI error names the problem, not the format', () {
      expect(
        () => importAnyFile('openapi: 3.0.0\ninfo: {title: x}\n'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('no operations'),
          ),
        ),
      );
    });

    test('the static-asset option reaches the HAR importer', () {
      final on = importAnyFile(fixture('har/browser.har'));
      final off = importAnyFile(
        fixture('har/browser.har'),
        skipStaticAssets: false,
      );
      expect(off.requests, greaterThan(on.requests));
    });
  });
}
