import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/postman_export.dart';
import 'package:api_workbench/services/postman_import.dart';
import 'package:api_workbench/services/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

String fixture(String name) =>
    File('test/fixtures/postman/$name').readAsStringSync();

CollectionModel importRich() =>
    importApiFile(fixture('rich.postman_collection.json')).collections.single;

Map<String, dynamic> decode(PostmanExport e) =>
    jsonDecode(e.json) as Map<String, dynamic>;

/// The first item named [name] among [items].
Map<String, dynamic> named(Object? items, String name) => (items as List)
    .cast<Map<String, dynamic>>()
    .firstWhere((i) => i['name'] == name);

/// The variable with [key] among [vars].
Map<String, dynamic> keyed(Object? vars, String key) => (vars as List)
    .cast<Map<String, dynamic>>()
    .firstWhere((v) => v['key'] == key);

/// Models as JSON without their random ids, for deep comparison.
Object? bare(Object? j) => switch (j) {
  Map() => {
    for (final e in j.entries)
      if (e.key != 'id') e.key: bare(e.value),
  },
  List() => [for (final x in j) bare(x)],
  _ => j,
};

Map<String, dynamic> attrMap(Map<String, dynamic> auth) => {
  for (final a in (auth[auth['type']] as List).cast<Map<String, dynamic>>())
    a['key'] as String: a['value'],
};

void main() {
  group('collection structure', () {
    late Map<String, dynamic> doc;

    setUp(() => doc = decode(buildPostmanCollection(importRich())));

    test('info, schema and the item tree', () {
      expect(doc['info']['name'], 'Rich Shop');
      expect(doc['info']['schema'], postmanCollectionSchema);
      expect(doc['info']['description'], startsWith('Everything the shop'));
      expect((doc['item'] as List).map((i) => i['name']), [
        'Auth',
        'Orders',
        'Health',
      ]);
      final auth = named(doc['item'], 'Auth');
      expect((auth['item'] as List).map((i) => i['name']), ['Login', 'Tokens']);
      final admin = named(named(doc['item'], 'Orders')['item'], 'Admin');
      expect((admin['item'] as List).single['name'], 'Get order');
    });

    test('collection auth, events and variables', () {
      expect(doc['auth']['type'], 'bearer');
      expect(attrMap(doc['auth']), {'token': '{{token}}'});
      expect((doc['event'] as List).map((e) => e['listen']), [
        'prerequest',
        'test',
      ]);
      final script = doc['event'][1]['script'];
      expect(script['type'], 'text/javascript');
      expect(script['exec'], hasLength(3));
      expect((doc['variable'] as List).map((v) => v['key']), [
        'baseUrl',
        'pageSize',
        'apiSecret',
        'legacy',
      ]);
      final secret = keyed(doc['variable'], 'apiSecret');
      expect(secret['type'], 'secret');
      expect(keyed(doc['variable'], 'legacy')['disabled'], isTrue);
      expect(
        keyed(doc['variable'], 'baseUrl')['description'],
        'Root of the API',
      );
    });

    test('folders: description, auth and events', () {
      final auth = named(doc['item'], 'Auth');
      expect(auth['description'], 'Everything to do with signing in.');
      expect(auth['auth']['type'], 'oauth2');
      expect(auth['event'].map((e) => e['listen']), ['prerequest', 'test']);
      final tokens = named(auth['item'], 'Tokens');
      expect(tokens['auth'], {'type': 'noauth'});
      expect(tokens['description'], 'Short-lived tokens.');
      expect(named(doc['item'], 'Orders').containsKey('event'), isFalse);
    });

    test('oauth2 attributes: booleans and arrays are restored', () {
      final auth = named(doc['item'], 'Auth')['auth'] as Map<String, dynamic>;
      final attrs = {for (final a in (auth['oauth2'] as List)) a['key']: a};
      expect(attrs['useBrowser']['value'], true);
      expect(attrs['useBrowser']['type'], 'boolean');
      expect(attrs['tokenRequestParams']['value'], isA<List>());
      expect(attrs['tokenRequestParams']['value'][0]['key'], 'audience');
      expect(attrs['grant_type']['value'], 'authorization_code_with_pkce');
      expect(attrs['grant_type']['type'], 'string');
    });

    test('request: no auth key for inherit, events, settings, examples', () {
      final login = named(named(doc['item'], 'Auth')['item'], 'Login');
      final rq = login['request'] as Map<String, dynamic>;
      expect(rq.containsKey('auth'), isFalse, reason: 'inherit = absent');
      expect(rq['method'], 'POST');
      expect(rq['description'], 'Exchanges credentials for a token.');
      expect(rq['header'][0], {
        'key': 'Content-Type',
        'value': 'application/json',
        'description': 'We send JSON',
      });
      expect(rq['header'][1]['disabled'], isTrue);
      expect(rq['body']['mode'], 'raw');
      expect(rq['body']['options']['raw']['language'], 'json');
      expect(login['event'].map((e) => e['listen']), ['prerequest', 'test']);
      expect(login['protocolProfileBehavior'], {
        'followRedirects': false,
        'maxRedirects': 3,
        'strictSSL': false,
        'disableUrlEncoding': true,
        'disableCookies': true,
        'followOriginalHttpMethod': true,
        'followAuthorizationHeader': true,
        'removeRefererHeaderOnRedirect': true,
      });
      final ex = login['response'] as List;
      expect(ex, hasLength(2));
      expect(ex[0]['name'], 'Success');
      expect(ex[0]['code'], 200);
      expect(ex[0]['status'], 'OK');
      expect(ex[0]['_postman_previewlanguage'], 'json');
      expect(ex[0]['header'][1], {'key': 'X-Request-Id', 'value': 'abc'});
      expect(ex[0]['originalRequest']['method'], 'POST');
      expect(ex[0]['originalRequest']['body']['raw'], contains('ada'));
      expect(ex[1].containsKey('originalRequest'), isFalse);
      expect(ex[1]['code'], 401);
    });

    test('url object: raw, parts, query, path variables and hash', () {
      final get = named(
        named(named(doc['item'], 'Orders')['item'], 'Admin')['item'],
        'Get order',
      );
      final url = get['request']['url'] as Map<String, dynamic>;
      expect(
        url['raw'],
        '{{baseUrl}}/orders/:orderId/items/:itemId?expand=true#top',
        reason: 'disabled params are not in raw',
      );
      expect(url['host'], ['{{baseUrl}}']);
      expect(url['path'], ['orders', ':orderId', 'items', ':itemId']);
      expect(url['hash'], 'top');
      expect(url['query'], [
        {'key': 'expand', 'value': 'true', 'description': 'Include line items'},
        {'key': 'debug', 'value': '1', 'disabled': true},
      ]);
      expect(url['variable'], [
        {'key': 'orderId', 'value': '42', 'description': 'The order number'},
        {'key': 'itemId', 'value': ''},
      ]);
      // The folder chain's auth is not copied into the request.
      expect(get['request'].containsKey('auth'), isFalse);
    });

    test('every body mode', () {
      final orders = named(doc['item'], 'Orders')['item'];
      final form = named(orders, 'Upload invoice')['request']['body'];
      expect(form['mode'], 'formdata');
      expect(form['formdata'].map((f) => f['type']), [
        'text',
        'file',
        'file',
        'file',
        'text',
      ]);
      expect(form['formdata'][0], {
        'key': 'orderId',
        'type': 'text',
        'value': '42',
        'description': 'Which order',
      });
      expect(form['formdata'][1]['src'], '/tmp/invoice.pdf');
      expect(form['formdata'][4]['disabled'], isTrue);

      final gql = named(orders, 'Search')['request']['body'];
      expect(gql['mode'], 'graphql');
      expect(gql['graphql'], {
        'query': '{ orders { id } }',
        'variables': '{"first": 10}',
      });

      final bin = named(orders, 'Blob')['request']['body'];
      expect(bin, {
        'mode': 'file',
        'file': {'src': '/tmp/blob.bin'},
      });

      final xml = named(orders, 'Signed')['request']['body'];
      expect(xml['options']['raw']['language'], 'xml');
      final text = named(orders, 'Plain text')['request']['body'];
      expect(text['options']['raw']['language'], 'text');

      final auth = named(named(doc['item'], 'Auth')['item'], 'Tokens');
      final url = named(auth['item'], 'Refresh')['request']['body'];
      expect(url['mode'], 'urlencoded');
      expect(url['urlencoded'][1]['disabled'], isTrue);
      expect(url['urlencoded'][0]['description'], 'The long-lived one');
    });

    test('auth of every type: attribute arrays under the type name', () {
      final orders = named(doc['item'], 'Orders')['item'];
      Map<String, dynamic> authOf(String name) =>
          named(orders, name)['request']['auth'] as Map<String, dynamic>;
      expect(authOf('Upload invoice')['type'], 'hawk');
      expect(attrMap(authOf('Upload invoice'))['includePayloadHash'], true);
      expect(authOf('Search')['type'], 'ntlm');
      expect(attrMap(authOf('Search'))['disableRetryRequest'], true);
      expect(authOf('Blob')['type'], 'edgegrid');
      expect(authOf('Signed')['type'], 'oauth1');
      expect(attrMap(authOf('Signed'))['addParamsToHeader'], true);
      expect(attrMap(authOf('Signed'))['addEmptyParamsToSign'], false);
      expect(authOf('Token check')['type'], 'jwt');
      expect(
        attrMap(authOf('Token check'))['payload'],
        '{"sub":"1"}',
        reason: 'a JSON text payload stays a string',
      );
      final basic = authOf('Plain text');
      expect(basic['type'], 'basic');
      expect(attrMap(basic), {
        'username': 'ada',
        'password': 'lovelace',
        'showPassword': false,
      });
      expect(
        named(orders, 'Explicit inherit')['request'].containsKey('auth'),
        isFalse,
      );
      final admin = named(orders, 'Admin');
      expect(admin['auth']['type'], 'awsv4');
      expect(attrMap(admin['auth'])['addAuthDataToQuery'], false);
      final key = named(doc['item'], 'Orders')['auth'];
      expect(attrMap(key), {
        'key': 'api_key',
        'value': '{{apiKey}}',
        'in': 'query',
      });
    });

    test('counts', () {
      final e = buildPostmanCollection(importRich());
      expect(e.requests, 11);
      expect(e.folders, 4);
      expect(e.skipped, isEmpty);
      expect(e.notes, isEmpty);
    });
  });

  group('url parts', () {
    Map<String, dynamic> urlOf(String url, {List<KV>? params}) => decode(
      buildPostmanCollection(
        CollectionModel(
          name: 'C',
          requests: [RequestModel(url: url, params: params)],
        ),
      ),
    )['item'][0]['request']['url'];

    test('protocol, host, port and a trailing slash', () {
      final u = urlOf('https://api.example.com:8443/v1/users/');
      expect(u['raw'], 'https://api.example.com:8443/v1/users/');
      expect(u['protocol'], 'https');
      expect(u['host'], ['api', 'example', 'com']);
      expect(u['port'], '8443');
      expect(u['path'], ['v1', 'users', '']);
      expect(u.containsKey('query'), isFalse);
      expect(u.containsKey('variable'), isFalse);
    });

    test('a variable host with dots inside the braces stays whole', () {
      final u = urlOf('{{host.name}}.example.com/a');
      expect(u['host'], ['{{host.name}}', 'example', 'com']);
      expect(u['path'], ['a']);
    });

    test('a query typed into the URL joins the params', () {
      final u = urlOf(
        'http://x.test/a?b=1',
        params: [KV(key: 'c', value: '2')],
      );
      expect(u['raw'], 'http://x.test/a?b=1&c=2');
      expect((u['query'] as List).map((q) => q['key']), ['b', 'c']);
    });

    test('an empty URL still exports', () {
      expect(urlOf('')['raw'], '');
    });
  });

  group('what cannot be exported', () {
    test('non-HTTP requests are skipped and reported', () {
      final c = CollectionModel(
        name: 'Mixed',
        requests: [
          RequestModel(name: 'Plain', url: 'https://x.test'),
          RequestModel(
            name: 'Socket',
            kind: RequestKind.websocket,
            url: 'wss://x.test',
          ),
          RequestModel(
            name: 'Rpc',
            kind: RequestKind.grpc,
            url: 'x.test:50051',
          ),
        ],
      );
      final e = buildPostmanCollection(c);
      expect(e.requests, 1);
      expect(e.skipped, hasLength(2));
      expect(e.skipped[0], contains('WebSocket'));
      expect(e.skipped[0], contains('Socket'));
      expect(e.skipped[1], contains('gRPC'));
      expect(decode(e)['item'], hasLength(1));
    });

    test('declarative tests and captures become test script code', () {
      final r = RequestModel(
        name: 'Checked',
        url: 'https://x.test',
        testScript: 'console.log("mine");',
        assertions: [
          AssertionModel(kind: AssertKind.statusEquals, expected: '200'),
          AssertionModel(kind: AssertKind.statusEquals, expected: '2xx'),
          AssertionModel(kind: AssertKind.bodyContains, expected: 'ok'),
          AssertionModel(
            kind: AssertKind.jsonEquals,
            target: 'data.items[0].id',
            expected: '7',
          ),
          AssertionModel(
            kind: AssertKind.headerContains,
            target: 'Content-Type',
            expected: 'json',
          ),
          AssertionModel(kind: AssertKind.timeBelow, expected: '500'),
          AssertionModel(
            kind: AssertKind.statusEquals,
            expected: '404',
            enabled: false,
          ),
        ],
        captures: {
          'token': 'body.data.token',
          'etag': 'header.ETag',
          'code': 'status',
        },
      );
      final e = buildPostmanCollection(
        CollectionModel(name: 'C', requests: [r]),
      );
      final script =
          (decode(e)['item'][0]['event'] as List).single['script']['exec'].join(
                '\n',
              )
              as String;
      expect(script, startsWith('console.log("mine");'));
      expect(script, contains('pm.response.to.have.status(200)'));
      expect(script, contains('Math.floor(pm.response.code / 100)).to.eql(2)'));
      expect(script, contains('pm.response.text()).to.include("ok")'));
      expect(
        script,
        contains('String(pm.response.json().data.items[0].id)).to.eql("7")'),
      );
      expect(script, contains('pm.response.headers.get("Content-Type")'));
      expect(script, contains('pm.response.responseTime).to.be.below(500)'));
      expect(script, isNot(contains('404')), reason: 'disabled test');
      expect(script, contains('pm.environment.set("token"'));
      expect(script, contains('pm.response.json().data.token'));
      expect(script, contains('pm.response.headers.get("ETag")'));
      expect(script, contains('pm.environment.set("code"'));
      expect(e.notes.single, contains('6 test(s) and 3 captured value(s)'));
    });

    test('a request with nothing special has no events or settings', () {
      final e = buildPostmanCollection(
        CollectionModel(
          name: 'C',
          requests: [RequestModel(name: 'Bare', url: 'https://x.test')],
        ),
      );
      final item = decode(e)['item'][0] as Map<String, dynamic>;
      expect(item.containsKey('event'), isFalse);
      expect(item.containsKey('protocolProfileBehavior'), isFalse);
      expect(item['response'], isEmpty);
      expect(item['request']['auth'], {'type': 'noauth'});
      expect(item['request'].containsKey('body'), isFalse);
    });

    test('empty folders that only hold settings are kept', () {
      final e = buildPostmanCollection(
        CollectionModel(
          name: 'C',
          folders: {'Docs': FolderMeta(description: 'Nothing here yet')},
        ),
      );
      final folder = decode(e)['item'][0];
      expect(folder['name'], 'Docs');
      expect(folder['description'], 'Nothing here yet');
      expect(folder['item'], isEmpty);
    });
  });

  group('round trip: import -> export -> import loses nothing', () {
    void expectSame(CollectionModel again, CollectionModel original) {
      expect(bare(again.toJson()), bare(original.toJson()));
    }

    CollectionModel again(CollectionModel c, {bool current = false}) =>
        importApiFile(
          buildPostmanCollection(c, includeCurrentValues: current).json,
        ).collections.single;

    test('the rich fixture comes back identical', () {
      final original = importRich();
      expectSame(again(original), original);
      // The comparison sees deep differences.
      final changed = again(original);
      changed.folders['Auth']!.auth.params['useBrowser'] = 'false';
      expect(
        bare(changed.toJson()),
        isNot(bare(original.toJson())),
        reason: 'control',
      );
      expect(jsonEncode(original.toJson()), contains('tokenRequestParams'));
    });

    test('and a second time over', () {
      final original = importRich();
      expectSame(again(again(original)), original);
    });

    test('the exported file keeps the same names and counts', () {
      final original = importRich();
      final r = importApiFile(buildPostmanCollection(original).json);
      expect(r.requests, 11);
      expect(r.folders, 4);
      expect(r.scriptsKept, 6);
      expect(r.examples, 2);
      expect(r.unsupportedAuth, isEmpty);
      expect(r.warnings, isEmpty);
    });

    test('folder names with a slash survive', () {
      final original = importApiFile(
        jsonEncode({
          'info': {'name': 'S', 'schema': 'collection/v2.1.0'},
          'item': [
            {
              'name': 'v1/v2',
              'description': 'Both versions',
              'item': [
                {
                  'name': 'Ping',
                  'request': {'url': 'https://x.test/ping'},
                },
              ],
            },
          ],
        }),
      ).collections.single;
      expect(original.requests.single.folder, 'v1∕v2');
      final doc = decode(buildPostmanCollection(original));
      expect(doc['item'][0]['name'], 'v1/v2');
      expectSame(again(original), original);
    });

    test('a timeout survives in protocolProfileBehavior', () {
      final original = importApiFile(
        jsonEncode({
          'info': {'name': 'S', 'schema': 'collection/v2.1.0'},
          'item': [
            {
              'name': 'Slow',
              'protocolProfileBehavior': {
                'timeout': 5000,
                'disableBodyPruning': true,
              },
              'request': {'url': 'https://x.test'},
            },
          ],
        }),
      ).collections.single;
      expect(original.requests.single.settings.timeoutMs, 5000);
      expectSame(again(original), original);
    });

    test('a collection made in the app survives too', () {
      final original = CollectionModel(
        name: 'Native',
        description: 'Made here',
        auth: AuthConfig(
          type: AuthType.basic,
          basicUser: 'u',
          basicPassword: 'p',
        ),
        preRequestScript: 'a();',
        testScript: 'b();',
        variables: [
          KV(key: 'k', value: 'v', secret: true, description: 'note'),
          KV(key: 'off', value: 'x', enabled: false),
        ],
        folders: {
          'A': FolderMeta(
            description: 'Folder A',
            auth: AuthConfig(type: AuthType.bearer, bearerToken: 't'),
            preRequestScript: 'c();',
          ),
          'A/B': FolderMeta(testScript: 'd();'),
        },
        requests: [
          RequestModel(
            name: 'One',
            folder: 'A/B',
            method: 'PUT',
            url: 'https://x.test/a/:id',
            params: [
              KV(key: 'x', value: '1'),
              KV(key: 'y', enabled: false),
            ],
            pathVariables: [KV(key: 'id', value: '9', description: 'which')],
            headers: [KV(key: 'X-A', value: 'b')],
            bodyType: BodyType.json,
            body: '{"a":1}',
            auth: AuthConfig(
              type: AuthType.oauth2,
              params: {'accessToken': 'tok', 'useBrowser': 'false'},
            ),
            preRequestScript: 'e();',
            testScript: 'f();',
            description: 'Does a thing',
            settings: RequestSettings(
              followRedirects: false,
              maxRedirects: 2,
              verifySsl: true,
              encodeUrl: false,
              useCookies: false,
              timeoutMs: 1500,
              followOriginalMethod: true,
              followAuthorizationHeader: true,
              removeRefererOnRedirect: true,
            ),
            examples: [
              ResponseExample(
                name: 'Fine',
                statusCode: 201,
                statusText: 'Created',
                headers: [KV(key: 'Content-Type', value: 'text/plain')],
                body: 'made',
              ),
            ],
          ),
          RequestModel(name: 'Two', method: 'GET', url: 'https://x.test'),
        ],
      );
      expectSame(again(original), original);
    });
  });

  group('current values', () {
    test('collection variables export the initial value by default', () {
      final c = CollectionModel(
        name: 'C',
        variables: [KV(key: 'token', value: 'init', current: 'live')],
      );
      final doc = decode(buildPostmanCollection(c));
      expect(doc['variable'][0]['value'], 'init');
      final withCurrent = decode(
        buildPostmanCollection(c, includeCurrentValues: true),
      );
      expect(withCurrent['variable'][0]['value'], 'live');
    });

    test('a variable with no current value exports its initial one', () {
      final e = EnvironmentModel(
        name: 'E',
        variables: [KV(key: 'a', value: '1')],
      );
      expect(
        decode(
          buildPostmanEnvironment(e, includeCurrentValues: true),
        )['values'][0]['value'],
        '1',
      );
    });
  });

  group('environments and globals', () {
    final env = EnvironmentModel(
      name: 'Staging',
      variables: [
        KV(key: 'baseUrl', value: 'https://staging.test'),
        KV(key: 'token', value: 'init', current: 'live', secret: true),
        KV(key: 'off', value: 'x', enabled: false, description: 'later'),
      ],
    );

    test('Postman environment format', () {
      final doc = decode(buildPostmanEnvironment(env));
      expect(doc['name'], 'Staging');
      expect(doc['_postman_variable_scope'], 'environment');
      expect(doc['_postman_exported_using'], 'ApiWorkbench');
      expect(doc['id'], env.id);
      expect(doc['values'], [
        {
          'key': 'baseUrl',
          'value': 'https://staging.test',
          'type': 'default',
          'enabled': true,
        },
        {'key': 'token', 'value': 'init', 'type': 'secret', 'enabled': true},
        {
          'key': 'off',
          'value': 'x',
          'type': 'default',
          'enabled': false,
          'description': 'later',
        },
      ]);
    });

    test('current values replace initial ones when asked', () {
      final doc = decode(
        buildPostmanEnvironment(env, includeCurrentValues: true),
      );
      expect(doc['values'][1]['value'], 'live');
      expect(doc['values'][0]['value'], 'https://staging.test');
    });

    test('Postman globals format', () {
      final doc = decode(
        buildPostmanGlobals([
          KV(key: 'tenant', value: 'acme'),
          KV(key: 'apiToken', value: 's', secret: true),
        ]),
      );
      expect(doc['_postman_variable_scope'], 'globals');
      expect(doc['name'], 'Globals');
      expect(doc['values'][1]['type'], 'secret');
    });

    test('environment round trip', () {
      final r = importApiFile(buildPostmanEnvironment(env).json);
      final back = r.environments.single;
      expect(back.name, 'Staging');
      final expected = [
        for (final v in env.variables) v.clone()..current = null,
      ];
      expect(
        bare(back.variables.map((v) => v.toJson()).toList()),
        bare(expected.map((v) => v.toJson()).toList()),
      );
    });

    test('with current values the effective values round trip', () {
      final r = importApiFile(
        buildPostmanEnvironment(env, includeCurrentValues: true).json,
      );
      expect(r.environments.single.variables.map((v) => v.effective), [
        'https://staging.test',
        'live',
        'x',
      ]);
    });

    test('globals round trip to the Globals scope', () {
      final globals = [
        KV(key: 'tenant', value: 'acme'),
        KV(key: 'apiToken', value: 's', secret: true),
        KV(key: 'off', value: '0', enabled: false),
      ];
      final r = importApiFile(buildPostmanGlobals(globals).json);
      expect(r.environments, isEmpty);
      expect(
        r.globals.map((v) => v.toJson()).toList(),
        globals.map((v) => v.toJson()).toList(),
      );
    });

    test('the fixture environment and globals survive an export', () {
      final r = importApiFile(fixture('staging.postman_environment.json'));
      final out = importApiFile(
        buildPostmanEnvironment(
          r.environments.single,
          includeCurrentValues: true,
        ).json,
      );
      expect(out.environments.single.variables[1].effective, 'live-token');
      expect(out.environments.single.variables[1].secret, isTrue);

      final g = importApiFile(fixture('workspace.postman_globals.json'));
      final back = importApiFile(buildPostmanGlobals(g.globals).json);
      expect(back.globals.map((v) => v.key), ['tenant', 'apiToken', 'off']);
      expect(back.globals[2].enabled, isFalse);
    });
  });

  group('ApiWorkbench workspace file', () {
    final col = CollectionModel(
      name: 'C',
      variables: [KV(key: 'a', value: '1', current: 'cur')],
    );
    final env = EnvironmentModel(
      name: 'E',
      variables: [KV(key: 'b', value: '2', current: 'cur2', secret: true)],
    );
    final globals = [KV(key: 'g', value: '3', current: 'cur3')];

    test('carries globals', () {
      final ws = parseWorkspaceJson(
        buildWorkspaceJson([col], [env], globals: globals),
      );
      expect(ws.globals.single.key, 'g');
      expect(ws.globals.single.value, '3');
    });

    test('drops current values unless asked to keep them', () {
      final plain = parseWorkspaceJson(
        buildWorkspaceJson([col], [env], globals: globals),
      );
      expect(plain.collections.single.variables.single.current, isNull);
      expect(plain.environments.single.variables.single.current, isNull);
      expect(plain.globals.single.current, isNull);
      expect(plain.environments.single.variables.single.secret, isTrue);
      expect(plain.collections.single.variables.single.value, '1');

      final full = parseWorkspaceJson(
        buildWorkspaceJson(
          [col],
          [env],
          globals: globals,
          includeCurrentValues: true,
        ),
      );
      expect(full.collections.single.variables.single.current, 'cur');
      expect(full.environments.single.variables.single.current, 'cur2');
      expect(full.globals.single.current, 'cur3');
    });

    test('the export itself is not changed by dropping current values', () {
      buildWorkspaceJson([col], [env], globals: globals);
      expect(col.variables.single.current, 'cur');
      expect(globals.single.current, 'cur3');
    });

    test('files from before globals existed still read', () {
      final old = jsonEncode({
        'app': 'apiworkbench',
        'format': 1,
        'collections': [
          {'id': 'c1', 'name': 'Old', 'requests': []},
        ],
        'environments': [
          {
            'id': 'e1',
            'name': 'Dev',
            'variables': [
              {'k': 'x', 'v': '1', 'e': true},
            ],
          },
        ],
      });
      final ws = parseWorkspaceJson(old);
      expect(ws.collections.single.name, 'Old');
      expect(ws.environments.single.variables.single.key, 'x');
      expect(ws.globals, isEmpty);
    });

    test('no globals key is written when there are none', () {
      final json = jsonDecode(buildWorkspaceJson([col], [env]));
      expect((json as Map).containsKey('globals'), isFalse);
    });

    test('the rich fixture survives the workspace format', () {
      final original = importRich();
      final ws = parseWorkspaceJson(buildWorkspaceJson([original], []));
      expect(bare(ws.collections.single.toJson()), bare(original.toJson()));
    });
  });
}
