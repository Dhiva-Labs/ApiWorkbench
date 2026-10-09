import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/http_service.dart';
import 'package:api_workbench/services/postman_import.dart';
import 'package:api_workbench/services/runner.dart';
import 'package:flutter_test/flutter_test.dart';

/// A v2.1 collection exercising most of what Postman can export.
Map<String, dynamic> v21() => {
  'info': {
    'name': 'Shop API',
    'description': 'All shop endpoints',
    'schema':
        'https://schema.getpostman.com/json/collection/v2.1.0/collection.json',
  },
  'auth': {
    'type': 'bearer',
    'bearer': [
      {'key': 'token', 'value': '{{token}}', 'type': 'string'},
    ],
  },
  'variable': [
    {'key': 'baseUrl', 'value': 'https://api.shop.test'},
    {'key': 'pageSize', 'value': 20, 'type': 'number'},
  ],
  'event': [
    {
      'listen': 'test',
      'script': {
        'exec': ['pm.expect(pm.response.responseTime).to.be.below(2000);'],
      },
    },
  ],
  'item': [
    {
      'name': 'Auth',
      'auth': {'type': 'noauth'},
      'item': [
        {
          'name': 'Login',
          'event': [
            {
              'listen': 'test',
              'script': {
                'exec': [
                  'pm.test("ok", function () {',
                  '  pm.response.to.have.status(200);',
                  '});',
                  'var jsonData = pm.response.json();',
                  'pm.environment.set("token", jsonData.data.token);',
                  "pm.collectionVariables.set('etag', pm.response.headers.get('ETag'));",
                  'pm.expect(jsonData.data.user.role).to.eql("admin");',
                  'pm.expect(pm.response.text()).to.include("token");',
                  'console.log(new Date());',
                ],
              },
            },
          ],
          'request': {
            'method': 'POST',
            'header': [
              {'key': 'Content-Type', 'value': 'application/json'},
              {'key': 'X-Debug', 'value': '1', 'disabled': true},
            ],
            'body': {
              'mode': 'raw',
              'raw': '{"user":"{{user}}","pass":"{{pass}}"}',
              'options': {
                'raw': {'language': 'json'},
              },
            },
            'url': {
              'raw': '{{baseUrl}}/auth/login',
              'host': ['{{baseUrl}}'],
              'path': ['auth', 'login'],
            },
          },
          'response': [
            {'name': 'Success example'},
          ],
        },
      ],
    },
    {
      'name': 'Orders',
      'item': [
        {
          'name': 'Admin',
          'item': [
            {
              'name': 'Get order',
              'request': {
                'method': 'GET',
                'url': {
                  'raw':
                      '{{baseUrl}}/orders/:orderId/items/:itemId?expand=true&debug=1#top',
                  'host': ['{{baseUrl}}'],
                  'path': ['orders', ':orderId', 'items', ':itemId'],
                  'query': [
                    {'key': 'expand', 'value': 'true'},
                    {'key': 'debug', 'value': '1', 'disabled': true},
                  ],
                  'variable': [
                    {'key': 'orderId', 'value': '42'},
                    {'key': 'itemId', 'value': ''},
                  ],
                },
                'description': {
                  'content': 'Fetch one order',
                  'type': 'text/markdown',
                },
              },
            },
          ],
        },
        {
          'name': 'Upload invoice',
          'request': {
            'method': 'POST',
            'auth': {
              'type': 'apikey',
              'apikey': [
                {'key': 'key', 'value': 'api_key'},
                {'key': 'value', 'value': '{{apiKey}}'},
                {'key': 'in', 'value': 'query'},
              ],
            },
            'header': [
              {'key': 'Content-Type', 'value': 'multipart/form-data'},
            ],
            'body': {
              'mode': 'formdata',
              'formdata': [
                {'key': 'orderId', 'value': '42', 'type': 'text'},
                {'key': 'file', 'type': 'file', 'src': '/tmp/invoice.pdf'},
                {
                  'key': 'extra',
                  'type': 'file',
                  'src': ['/tmp/a.png', '/tmp/b.png'],
                },
                {'key': 'note', 'value': 'x', 'type': 'text', 'disabled': true},
              ],
            },
            'url': '{{baseUrl}}/orders/upload',
          },
        },
        {
          'name': 'Search (form)',
          'request': {
            'method': 'POST',
            'auth': {
              'type': 'digest',
              'digest': [
                {'key': 'username', 'value': 'u'},
              ],
            },
            'body': {
              'mode': 'urlencoded',
              'urlencoded': [
                {'key': 'q', 'value': 'shoes'},
                {'key': 'page', 'value': '{{pageSize}}'},
              ],
            },
            'url': '{{baseUrl}}/search',
          },
        },
        {
          'name': 'GraphQL',
          'request': {
            'method': 'POST',
            'body': {
              'mode': 'graphql',
              'graphql': {
                'query': '{ orders { id } }',
                'variables': '{"first": 10}',
              },
            },
            'url': '{{baseUrl}}/graphql',
          },
        },
        {
          'name': 'Upload raw',
          'request': {
            'method': 'PUT',
            'body': {
              'mode': 'file',
              'file': {'src': '/tmp/blob.bin'},
            },
            'url': '{{baseUrl}}/blob',
          },
        },
        {
          'name': 'Plain raw',
          'request': {
            'method': 'POST',
            'body': {'mode': 'raw', 'raw': '<a>1</a>'},
            'url': '{{baseUrl}}/xml',
          },
        },
      ],
    },
    {'name': 'Health', 'request': '{{baseUrl}}/health'},
  ],
};

void main() {
  group('Postman collection v2.1', () {
    late ImportReport r;
    late CollectionModel c;
    RequestModel req(String name) =>
        c.requests.firstWhere((x) => x.name == name);

    setUp(() {
      r = importApiFile(jsonEncode(v21()));
      c = r.collections.single;
    });

    test('collection metadata, variables and folder structure', () {
      expect(r.formats, {'Postman collection v2.1'});
      expect(c.name, 'Shop API');
      expect(c.description, 'All shop endpoints');
      expect(c.variableMap, {
        'baseUrl': 'https://api.shop.test',
        'pageSize': '20',
      });
      expect(r.requests, 8);
      expect(r.folders, 3);
      expect(req('Login').folder, 'Auth');
      expect(req('Get order').folder, 'Orders/Admin');
      expect(req('Health').folder, '');
      expect(c.requests.map((x) => x.name), [
        'Login', 'Get order', 'Upload invoice', 'Search (form)', 'GraphQL', //
        'Upload raw', 'Plain raw', 'Health',
      ]);
    });

    test('url, path variables, query params and description', () {
      final g = req('Get order');
      expect(g.url, '{{baseUrl}}/orders/42/items/{{itemId}}#top');
      expect(g.params.map((p) => '${p.key}=${p.value}:${p.enabled}'), [
        'expand=true:true',
        'debug=1:false',
      ]);
      expect(g.description, 'Fetch one order');
      expect(req('Health').url, '{{baseUrl}}/health');
      expect(req('Health').method, 'GET');
    });

    test('auth: inherited, overridden, noauth and unsupported', () {
      expect(req('Get order').authType, AuthType.bearer);
      expect(req('Get order').bearerToken, '{{token}}');
      expect(req('Login').authType, AuthType.none, reason: 'folder noauth');
      final up = req('Upload invoice');
      expect(up.authType, AuthType.apiKey);
      expect(up.apiKeyName, 'api_key');
      expect(up.apiKeyInHeader, isFalse);
      expect(
        req('Search (form)').authType,
        AuthType.none,
        reason: 'digest is unsupported; left empty, parent not applied',
      );
      expect(r.unsupportedAuth, {'digest': 1});
    });

    test('every body mode', () {
      final login = req('Login');
      expect(login.bodyType, BodyType.json);
      expect(login.headers.map((h) => '${h.key}:${h.enabled}'), [
        'Content-Type:true',
        'X-Debug:false',
      ]);
      final up = req('Upload invoice');
      expect(up.bodyType, BodyType.formData);
      expect(
        up.formFields.map(
          (f) => '${f.key}|${f.value}|${f.isFile}|${f.enabled}',
        ),
        [
          'orderId|42|false|true',
          'file|/tmp/invoice.pdf|true|true',
          'extra|/tmp/a.png|true|true',
          'extra|/tmp/b.png|true|true',
          'note|x|false|false',
        ],
      );
      expect(req('Search (form)').bodyType, BodyType.formUrlEncoded);
      expect(req('Search (form)').formFields.length, 2);
      final gql = req('GraphQL');
      expect(gql.bodyType, BodyType.graphql);
      expect(gql.body, '{ orders { id } }');
      expect(gql.graphqlVariables, '{"first": 10}');
      expect(req('Upload raw').bodyType, BodyType.binary);
      expect(req('Upload raw').body, '/tmp/blob.bin');
      expect(req('Plain raw').bodyType, BodyType.xml);
    });

    test('test scripts become assertions and captures', () {
      final login = req('Login');
      final a = login.assertions.map(
        (x) => '${x.kind.name}|${x.target}|${x.expected}',
      );
      expect(
        a,
        containsAll([
          'statusEquals||200',
          'jsonEquals|data.user.role|admin',
          'bodyContains||token',
          'timeBelow||2000', // inherited from the collection-level script
        ]),
      );
      expect(login.captures, {
        'token': 'body.data.token',
        'etag': 'header.ETag',
      });
      expect(login.testScript, contains('console.log'));
      expect(r.examplesSkipped, 1);
      expect(r.warnings.join('\n'), contains('Digest'));
    });

    test('round-trips through the workspace format', () {
      final copy = CollectionModel.fromJson(
        jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>,
      );
      expect(jsonEncode(copy.toJson()), jsonEncode(c.toJson()));
    });
  });

  test('v2.0 auth objects and string headers', () {
    final r = importApiFile(
      jsonEncode({
        'info': {
          'name': 'Old',
          'schema':
              'https://schema.getpostman.com/json/collection/v2.0.0/collection.json',
        },
        'item': [
          {
            'name': 'Basic',
            'request': {
              'url': 'https://x.test/a?b=1',
              'method': 'get',
              'header': 'Accept: application/json\n// X-Off: 1\n',
              'auth': {
                'type': 'basic',
                'basic': {'username': 'u', 'password': 'p'},
              },
            },
          },
        ],
      }),
    );
    final q = r.collections.single.requests.single;
    expect(r.formats, {'Postman collection v2.0'});
    expect(q.method, 'GET');
    expect(q.url, 'https://x.test/a');
    expect(q.params.single.key, 'b');
    expect(q.authType, AuthType.basic);
    expect(q.basicPassword, 'p');
    expect(q.headers.map((h) => '${h.key}:${h.enabled}'), [
      'Accept:true',
      'X-Off:false',
    ]);
  });

  test(
    'oauth2 with a saved token becomes bearer; without one it is flagged',
    () {
      Map<String, dynamic> col(String token) => {
        'info': {'name': 'O', 'schema': 'collection/v2.1.0'},
        'item': [
          {
            'name': 'R',
            'request': {
              'url': 'https://x.test',
              'auth': {
                'type': 'oauth2',
                'oauth2': [
                  {'key': 'accessToken', 'value': token},
                ],
              },
            },
          },
        ],
      };
      final ok = importApiFile(
        jsonEncode(col('abc')),
      ).collections.single.requests.single;
      expect(ok.authType, AuthType.bearer);
      expect(ok.bearerToken, 'abc');
      final r = importApiFile(jsonEncode(col('')));
      expect(r.unsupportedAuth, {'oauth2': 1});
    },
  );

  test('collection v1 with folders, form params and legacy tests', () {
    final r = importApiFile(
      jsonEncode({
        'id': 'c1',
        'name': 'Legacy',
        'order': ['r3'],
        'folders': [
          {
            'id': 'f1',
            'name': 'Users',
            'order': ['r1', 'r2'],
          },
        ],
        'requests': [
          {
            'id': 'r1',
            'name': 'List',
            'url': 'https://x.test/users?page=1',
            'method': 'GET',
            'headers': 'Accept: application/json\n',
            'tests':
                'tests["ok"] = responseCode.code === 200;\n'
                'tests["fast"] = responseTime < 300;\n'
                'tests["has"] = responseBody.has("users");',
          },
          {
            'id': 'r2',
            'name': 'Create',
            'url': 'https://x.test/users',
            'method': 'POST',
            'dataMode': 'params',
            'data': [
              {'key': 'name', 'value': 'Ada', 'type': 'text', 'enabled': true},
              {
                'key': 'avatar',
                'value': '/tmp/a.png',
                'type': 'file',
                'enabled': true,
              },
            ],
            'currentHelper': 'basicAuth',
            'helperAttributes': {'username': 'u', 'password': 'p'},
          },
          {
            'id': 'r3',
            'name': 'Root',
            'url': 'https://x.test/',
            'method': 'GET',
          },
          {
            'id': 'r4',
            'name': 'Orphan',
            'url': 'https://x.test/o',
            'method': 'GET',
          },
        ],
      }),
    );
    final c = r.collections.single;
    expect(r.formats, {'Postman collection v1'});
    expect(c.requests.map((x) => '${x.folder}/${x.name}'), [
      'Users/List',
      'Users/Create',
      '/Root',
      '/Orphan',
    ]);
    final list = c.requests.first;
    expect(list.params.single.value, '1');
    expect(list.assertions.map((a) => '${a.kind.name}|${a.expected}'), [
      'statusEquals|200',
      'timeBelow|300',
      'bodyContains|users',
    ]);
    final create = c.requests[1];
    expect(create.bodyType, BodyType.formData);
    expect(create.formFields[1].isFile, isTrue);
    expect(create.authType, AuthType.basic);
  });

  test('environment, globals and full data export', () {
    final env = importApiFile(
      jsonEncode({
        'name': 'Staging',
        '_postman_variable_scope': 'environment',
        'values': [
          {'key': 'baseUrl', 'value': 'https://staging.test', 'enabled': true},
          {'key': 'secret', 'value': 's3', 'type': 'secret', 'enabled': false},
        ],
      }),
    );
    expect(env.environments.single.name, 'Staging');
    expect(
      env.environments.single.variables.map(
        (v) => '${v.key}=${v.value}:${v.enabled}',
      ),
      ['baseUrl=https://staging.test:true', 'secret=s3:false'],
    );

    final globals = importApiFile(
      jsonEncode({
        '_postman_variable_scope': 'globals',
        'values': [
          {'key': 'g', 'value': '1'},
        ],
      }),
    );
    expect(globals.environments.single.name, 'Postman globals');

    final dump = importApiFile(
      jsonEncode({
        'version': 1,
        'collections': [v21()],
        'environments': [
          {'name': 'Prod', 'values': []},
        ],
        'globals': [
          {'key': 'g', 'value': '1'},
        ],
      }),
    );
    expect(dump.collections.single.name, 'Shop API');
    expect(dump.environments.map((e) => e.name), ['Prod', 'Postman globals']);
  });

  test('several files accumulate into one report', () {
    final r = importApiFile(jsonEncode(v21()));
    importApiFile(jsonEncode({'name': 'Dev', 'values': []}), into: r);
    expect(r.collections.length, 1);
    expect(r.environments.length, 1);
  });

  test('single requests, request lists and folders can be pasted', () {
    final one = importApiFile(
      jsonEncode({
        'name': 'Ping',
        'request': {'method': 'GET', 'url': 'https://x.test/ping'},
      }),
    );
    expect(one.formats, {'Postman requests'});
    expect(one.collections.single.requests.single.name, 'Ping');

    final list = importApiFile(
      jsonEncode([
        {
          'name': 'A',
          'request': {'url': 'https://x.test/a'},
        },
        {
          'name': 'Folder',
          'item': [
            {
              'name': 'B',
              'request': {'url': 'https://x.test/b'},
            },
          ],
        },
      ]),
    );
    expect(
      list.collections.single.requests.map((r) => '${r.folder}|${r.name}'),
      ['|A', 'Folder|B'],
    );

    final folder = importApiFile(
      jsonEncode({
        'name': 'Users',
        'item': [
          {
            'name': 'List',
            'request': {'url': 'https://x.test/users'},
          },
        ],
      }),
    );
    expect(folder.collections.single.requests.single.folder, 'Users');

    final bare = importApiFile(
      jsonEncode({
        'item': [
          {
            'name': 'C',
            'request': {'url': 'https://x.test/c'},
          },
        ],
      }),
    );
    expect(bare.collections.single.requests.single.folder, '');
  });

  test('rejects non-JSON and unrelated JSON', () {
    expect(() => importApiFile('nope'), throwsFormatException);
    expect(() => importApiFile('{"hello": 1}'), throwsFormatException);
  });

  test('script conversion handles status classes and json literals', () {
    final c = convertTestScript('''
const body = pm.response.json();
pm.response.to.be.success;
pm.expect(pm.response.code).to.equal(201);
pm.expect(body.items[0]["id"]).to.eql(7);
pm.expect(body.active).to.be.true;
pm.response.to.have.header("Content-Type", "json");
pm.variables.set("firstId", body.items[0].id);
pm.globals.set("code", pm.response.code);
''');
    expect(
      c.assertions.map((a) => '${a.kind.name}|${a.target}|${a.expected}'),
      [
        'statusEquals||2xx',
        'statusEquals||201',
        'headerContains|Content-Type|json',
        'jsonEquals|items[0].id|7',
        'jsonEquals|active|true',
      ],
    );
    expect(c.captures, {'firstId': 'body.items[0].id', 'code': 'status'});
  });

  group('sending imported features', () {
    late HttpServer server;
    late String base;
    final seen = <Map<String, Object?>>[];

    setUp(() async {
      seen.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        final bytes = await req.fold<List<int>>([], (a, b) => a..addAll(b));
        seen.add({
          'path': req.uri.path,
          'query': req.uri.query,
          'ct': req.headers.contentType?.mimeType,
          'auth': req.headers.value('authorization'),
          'body': latin1.decode(bytes),
          'len': bytes.length,
        });
        req.response.headers.contentType = ContentType.json;
        if (req.uri.path == '/login') {
          req.response.write('{"data":{"token":"tok-123"}}');
        } else {
          req.response.write('{}');
        }
        await req.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    test('multipart form-data with a file, and a binary body', () async {
      final dir = await Directory.systemTemp.createTemp('aw_pm_');
      addTearDown(() => dir.delete(recursive: true));
      final f = File('${dir.path}/invoice.txt')
        ..writeAsStringSync('INVOICE-BYTES');
      final http = HttpService();
      addTearDown(http.dispose);

      final form = RequestModel(
        method: 'POST',
        url: '$base/upload',
        bodyType: BodyType.formData,
        headers: [KV(key: 'Content-Type', value: 'multipart/form-data')],
        formFields: [
          KV(key: 'orderId', value: '{{id}}'),
          KV(key: 'file', value: f.path, isFile: true),
        ],
      );
      final res = await http.send(form, {'id': '42'}, tabId: 't1');
      expect(res.error, isNull);
      expect(seen.last['ct'], 'multipart/form-data');
      expect(seen.last['body'] as String, contains('name="orderId"'));
      expect(seen.last['body'] as String, contains('42'));
      expect(seen.last['body'] as String, contains('filename="invoice.txt"'));
      expect(seen.last['body'] as String, contains('INVOICE-BYTES'));

      final bin = RequestModel(
        method: 'PUT',
        url: '$base/blob',
        bodyType: BodyType.binary,
        body: f.path,
      );
      expect((await http.send(bin, const {}, tabId: 't2')).error, isNull);
      expect(seen.last['body'], 'INVOICE-BYTES');
      expect(seen.last['ct'], 'application/octet-stream');

      final missing = RequestModel(
        method: 'PUT',
        url: '$base/blob',
        bodyType: BodyType.binary,
        body: '${dir.path}/nope',
      );
      expect(
        (await http.send(missing, const {}, tabId: 't3')).error,
        contains('not found'),
      );
    });

    test('dynamic variables are generated per occurrence', () async {
      final http = HttpService();
      addTearDown(http.dispose);
      await http.send(
        RequestModel(
          url:
              '$base/d?a={{\$guid}}&b={{\$guid}}&t={{\$timestamp}}&x={{\$unknownThing}}',
        ),
        const {},
        tabId: 't',
      );
      final q = Uri.splitQueryString(seen.last['query'] as String);
      expect(q['a'], hasLength(36));
      expect(q['a'], isNot(q['b']));
      expect(int.parse(q['t']!), greaterThan(1700000000));
      expect(q['x'], r'{{$unknownThing}}');
    });

    test('runner chains a captured token into the next request', () async {
      final runner = RunnerService(HttpService());
      addTearDown(runner.dispose);
      await runner.start(
        requests: [
          RequestModel(
            method: 'POST',
            url: '$base/login',
            captures: {'token': 'body.data.token'},
          ),
          RequestModel(
            url: '$base/me',
            authType: AuthType.bearer,
            bearerToken: '{{token}}',
          ),
        ],
        vars: const {},
      );
      expect(seen.last['path'], '/me');
      expect(seen.last['auth'], 'Bearer tok-123');
    });
  });
}
