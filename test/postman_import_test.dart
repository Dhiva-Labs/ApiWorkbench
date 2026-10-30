import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/http_service.dart';
import 'package:api_workbench/services/postman_import.dart';
import 'package:api_workbench/services/runner.dart';
import 'package:api_workbench/services/workspace.dart';
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
      'description': 'Signing in',
      'auth': {'type': 'noauth'},
      'event': [
        {
          'listen': 'prerequest',
          'script': {
            'exec': ['console.log("folder");'],
          },
        },
      ],
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
      // `:name` stays in the URL; the values are path variables.
      expect(g.url, '{{baseUrl}}/orders/:orderId/items/:itemId#top');
      expect(g.pathVariables.map((p) => '${p.key}=${p.value}'), [
        'orderId=42',
        'itemId=',
      ]);
      expect(g.params.map((p) => '${p.key}=${p.value}:${p.enabled}'), [
        'expand=true:true',
        'debug=1:false',
      ]);
      expect(g.description, 'Fetch one order');
      expect(req('Health').url, '{{baseUrl}}/health');
      expect(req('Health').method, 'GET');
    });

    test('auth: no auth key inherits; types keep their own fields', () {
      // The parent's auth is no longer copied into the request.
      expect(req('Get order').authType, AuthType.inherit);
      expect(req('Login').authType, AuthType.inherit);
      expect(req('Health').authType, AuthType.inherit);
      expect(c.auth.type, AuthType.bearer);
      expect(c.auth.bearerToken, '{{token}}');
      expect(c.folders['Auth']!.auth.type, AuthType.none);
      final up = req('Upload invoice');
      expect(up.authType, AuthType.apiKey);
      expect(up.apiKeyName, 'api_key');
      expect(up.apiKeyInHeader, isFalse);
      final digest = req('Search (form)');
      expect(digest.authType, AuthType.digest);
      expect(digest.auth.params, {'username': 'u'});
      expect(r.unsupportedAuth, isEmpty);
    });

    test('folder description and settings', () {
      final meta = c.folders['Auth']!;
      expect(meta.description, 'Signing in');
      expect(meta.preRequestScript, 'console.log("folder");');
      expect(c.folders.containsKey('Orders'), isFalse, reason: 'no settings');
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

    test('scripts are kept at every level and not converted', () {
      final login = req('Login');
      // Converting them as well would run every check twice.
      expect(login.assertions, isEmpty);
      expect(login.captures, isEmpty);
      expect(login.testScript, contains('pm.environment.set("token"'));
      expect(login.testScript, contains('console.log'));
      expect(login.preRequestScript, isEmpty);
      expect(c.testScript, contains('responseTime'));
      expect(c.preRequestScript, isEmpty);
      expect(c.folders['Auth']!.preRequestScript, contains('folder'));
      expect(r.scriptsKept, 3);
      expect(r.assertionsFromScripts + r.capturesFromScripts, 0);
    });

    test('saved responses become examples', () {
      final ex = req('Login').examples.single;
      expect(ex.name, 'Success example');
      expect(ex.statusCode, 200);
      expect(r.examples, 1);
      expect(r.warnings.join('\n'), isNot(contains('example')));
    });

    test('round-trips through the workspace format', () {
      final copy = CollectionModel.fromJson(
        jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>,
      );
      expect(jsonEncode(copy.toJson()), jsonEncode(c.toJson()));
    });
  });

  group('rich fixture', () {
    late ImportReport r;
    late CollectionModel c;
    RequestModel req(String name) =>
        c.requests.firstWhere((x) => x.name == name);

    setUp(() {
      r = importApiFile(
        File(
          'test/fixtures/postman/rich.postman_collection.json',
        ).readAsStringSync(),
      );
      c = r.collections.single;
    });

    test('collection level: description, auth, scripts and variables', () {
      expect(c.name, 'Rich Shop');
      expect(c.description, startsWith('Everything the shop API does.'));
      expect(c.auth.type, AuthType.bearer);
      expect(c.auth.bearerToken, '{{token}}');
      expect(c.preRequestScript, contains('collectionVariables.set'));
      expect(c.testScript, contains('fast enough'));
      expect(
        c.variables.map(
          (v) =>
              '${v.key}=${v.value}:${v.enabled}:${v.secret}:${v.description}',
        ),
        [
          'baseUrl=https://api.shop.test:true:false:Root of the API',
          'pageSize=20:true:false:',
          'apiSecret=s3cr3t:true:true:',
          'legacy=old:false:false:',
        ],
      );
      expect(r.unsupportedAuth, isEmpty);
      expect(r.warnings, isEmpty);
    });

    test('folders keep description, auth and scripts', () {
      expect(c.folders.keys, ['Auth', 'Auth/Tokens', 'Orders', 'Orders/Admin']);
      final auth = c.folders['Auth']!;
      expect(auth.description, 'Everything to do with signing in.');
      expect(auth.auth.type, AuthType.oauth2);
      expect(auth.preRequestScript, 'console.log("entering Auth");');
      expect(auth.testScript, contains('not a server error'));
      final tokens = c.folders['Auth/Tokens']!;
      expect(tokens.description, 'Short-lived tokens.');
      expect(tokens.auth.type, AuthType.none);
      expect(c.folders['Orders']!.auth.type, AuthType.apiKey);
      expect(c.folders['Orders']!.auth.apiKeyInHeader, isFalse);
      expect(c.folders['Orders/Admin']!.auth.type, AuthType.awsV4);
      expect(c.folders['Orders/Admin']!.description, isEmpty);
    });

    test('oauth2 on a folder: every attribute verbatim', () {
      final p = c.folders['Auth']!.auth.params;
      expect(p['grant_type'], 'authorization_code_with_pkce');
      expect(p['authUrl'], '{{baseUrl}}/oauth/authorize');
      expect(p['clientSecret'], '{{clientSecret}}');
      expect(p['useBrowser'], 'true', reason: 'booleans become JSON text');
      expect(p['challengeAlgorithm'], 'S256');
      expect(p['client_authentication'], 'header');
      expect(jsonDecode(p['tokenRequestParams']!), [
        {
          'key': 'audience',
          'value': 'shop',
          'enabled': true,
          'send_as': 'request_body',
        },
      ]);
      expect(p.length, 14);
    });

    test('every other auth type keeps its attributes', () {
      expect(req('Refresh').authType, AuthType.digest);
      expect(req('Refresh').auth.params, {
        'username': 'u',
        'password': 'p',
        'realm': 'shop',
        'nonce': 'n1',
        'algorithm': 'MD5',
        'qop': 'auth',
        'nonceCount': '00000001',
        'clientNonce': 'c1',
        'opaque': 'o1',
        'disableRetryRequest': 'false',
      });
      final hawk = req('Upload invoice').auth;
      expect(hawk.type, AuthType.hawk);
      expect(hawk.params['authId'], 'id');
      expect(hawk.params['includePayloadHash'], 'true');
      final ntlm = req('Search').auth;
      expect(ntlm.type, AuthType.ntlm);
      expect(ntlm.params['domain'], 'DOM');
      expect(ntlm.params['username'], r'dom\u');
      expect(req('Blob').auth.type, AuthType.edgegrid);
      expect(req('Blob').auth.params['baseURL'], 'https://x.akamai.test');
      final o1 = req('Signed').auth;
      expect(o1.type, AuthType.oauth1);
      expect(o1.params['signatureMethod'], 'HMAC-SHA1');
      expect(o1.params['addEmptyParamsToSign'], 'false');
      final jwt = req('Token check').auth;
      expect(jwt.type, AuthType.jwt);
      expect(jwt.params['payload'], '{"sub":"1"}');
      expect(jwt.params['isSecretBase64Encoded'], 'false');
    });

    test('basic keeps its fields; extra attributes ride in params', () {
      final basic = req('Plain text').auth;
      expect(basic.type, AuthType.basic);
      expect(basic.basicUser, 'ada');
      expect(basic.basicPassword, 'lovelace');
      expect(basic.params, {'showPassword': 'false'});
    });

    test('inheritance: no auth key and an explicit inherit both inherit', () {
      for (final name in ['Login', 'Get order', 'Explicit inherit', 'Health']) {
        expect(req(name).authType, AuthType.inherit, reason: name);
      }
    });

    test('scripts on a request', () {
      final login = req('Login');
      expect(login.preRequestScript, contains('nonce'));
      expect(login.testScript, contains('pm.response.to.have.status(200)'));
      expect(login.testScript, contains('\n'), reason: 'exec lines joined');
      expect(login.assertions, isEmpty);
      expect(login.captures, isEmpty);
      expect(r.scriptsKept, 6, reason: '2 collection + 2 folder + 2 request');
    });

    test('request settings from protocolProfileBehavior', () {
      final s = req('Login').settings;
      expect(s.followRedirects, isFalse);
      expect(s.maxRedirects, 3);
      expect(s.verifySsl, isFalse);
      expect(s.encodeUrl, isFalse);
      expect(s.useCookies, isFalse);
      expect(s.followOriginalMethod, isTrue);
      expect(s.followAuthorizationHeader, isTrue);
      expect(s.removeRefererOnRedirect, isTrue);
      expect(req('Health').settings.isDefault, isTrue);
    });

    test('examples with their original requests', () {
      final ex = req('Login').examples;
      expect(ex.map((e) => '${e.name}|${e.statusCode}|${e.statusText}'), [
        'Success|200|OK',
        'Bad password|401|Unauthorized',
      ]);
      expect(ex[0].headers.map((h) => h.key), ['Content-Type', 'X-Request-Id']);
      expect(ex[0].contentType, 'application/json');
      expect(ex[0].body, contains('tok-123'));
      final orig = ex[0].originalRequest!;
      expect(orig.method, 'POST');
      expect(orig.url, '{{baseUrl}}/auth/login');
      expect(orig.bodyType, BodyType.json);
      expect(orig.body, contains('ada'));
      expect(orig.examples, isEmpty, reason: 'no examples inside examples');
      expect(ex[1].originalRequest, isNull);
      expect(r.examples, 2);
    });

    test('rows keep their descriptions', () {
      final login = req('Login');
      expect(login.headers.first.description, 'We send JSON');
      final get = req('Get order');
      expect(get.params.first.description, 'Include line items');
      expect(get.pathVariables.first.description, 'The order number');
      expect(req('Refresh').formFields.first.description, 'The long-lived one');
      expect(req('Upload invoice').formFields.first.description, 'Which order');
      expect(get.description, 'Fetch one order');
    });

    test('bodies of every mode', () {
      expect(req('Login').bodyType, BodyType.json);
      expect(req('Refresh').bodyType, BodyType.formUrlEncoded);
      expect(req('Refresh').formFields.map((f) => f.enabled), [true, false]);
      expect(req('Upload invoice').bodyType, BodyType.formData);
      expect(req('Upload invoice').formFields.where((f) => f.isFile).length, 3);
      expect(req('Search').bodyType, BodyType.graphql);
      expect(req('Blob').bodyType, BodyType.binary);
      expect(req('Blob').body, '/tmp/blob.bin');
      expect(req('Signed').bodyType, BodyType.xml);
      expect(req('Plain text').bodyType, BodyType.text);
    });
  });

  group('variables files', () {
    test(
      'environment: secrets, disabled rows, descriptions, current values',
      () {
        final r = importApiFile(
          File(
            'test/fixtures/postman/staging.postman_environment.json',
          ).readAsStringSync(),
        );
        expect(r.formats, {'Postman environment'});
        final vars = r.environments.single.variables;
        expect(vars.map((v) => v.key), ['baseUrl', 'token', 'unused']);
        expect(vars[0].secret, isFalse);
        expect(vars[1].secret, isTrue);
        expect(vars[1].value, 'initial-token');
        expect(vars[1].current, 'live-token');
        expect(vars[1].effective, 'live-token');
        expect(vars[2].enabled, isFalse);
        expect(vars[2].description, 'Kept for later');
        expect(vars[0].current, isNull);
      },
    );

    test('globals go to the Globals scope, not to an environment', () {
      final r = importApiFile(
        File(
          'test/fixtures/postman/workspace.postman_globals.json',
        ).readAsStringSync(),
      );
      expect(r.formats, {'Postman globals'});
      expect(r.environments, isEmpty);
      expect(r.globals.map((v) => '${v.key}:${v.secret}:${v.enabled}'), [
        'tenant:false:true',
        'apiToken:true:true',
        'off:false:false',
      ]);
    });

    test('a data dump carries globals as a list of scopes too', () {
      final r = importApiFile(
        jsonEncode({
          'version': 1,
          'globals': [
            {
              'values': [
                {'key': 'a', 'value': '1'},
              ],
            },
            {'key': 'b', 'value': '2', 'type': 'secret'},
          ],
        }),
      );
      expect(r.globals.map((v) => '${v.key}=${v.value}:${v.secret}'), [
        'a=1:false',
        'b=2:true',
      ]);
    });

    test('a workspace file brings its globals along', () {
      final json = buildWorkspaceJson(
        [CollectionModel(name: 'C')],
        [],
        globals: [KV(key: 'g', value: '1', secret: true)],
      );
      final r = importApiFile(json);
      expect(r.globals.single.key, 'g');
      expect(r.globals.single.secret, isTrue);
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

  test('oauth2 keeps its attributes verbatim, with or without a token', () {
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
                {'key': 'addTokenTo', 'value': 'queryParams'},
                {'key': 'useBrowser', 'value': true, 'type': 'boolean'},
                {
                  'key': 'tokenRequestParams',
                  'value': [
                    {'key': 'audience', 'value': 'shop'},
                  ],
                  'type': 'any',
                },
              ],
            },
          },
        },
      ],
    };
    for (final token in ['abc', '']) {
      final r = importApiFile(jsonEncode(col(token)));
      final a = r.collections.single.requests.single.auth;
      expect(a.type, AuthType.oauth2);
      expect(a.params['accessToken'], token);
      expect(a.params['addTokenTo'], 'queryParams');
      expect(a.params['useBrowser'], 'true');
      expect(jsonDecode(a.params['tokenRequestParams']!), [
        {'key': 'audience', 'value': 'shop'},
      ]);
      expect(r.unsupportedAuth, isEmpty);
      expect(r.warnings, isEmpty);
    }
  });

  test('an auth type with no equivalent here is reported', () {
    final r = importApiFile(
      jsonEncode({
        'info': {'name': 'A', 'schema': 'collection/v2.1.0'},
        'item': [
          {
            'name': 'R',
            'request': {
              'url': 'https://x.test',
              'auth': {
                'type': 'asap',
                'asap': [
                  {'key': 'iss', 'value': 'me'},
                ],
              },
            },
          },
        ],
      }),
    );
    expect(r.collections.single.requests.single.authType, AuthType.none);
    expect(r.unsupportedAuth, {'asap': 1});
    expect(r.warnings.join('\n'), contains('ASAP'));
  });

  test(
    'collection v1 with folders, form params, legacy tests and responses',
    () {
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
              'responses': [
                {
                  'name': 'Two users',
                  'responseCode': {'code': 200, 'name': 'OK'},
                  'headers': [
                    {'key': 'Content-Type', 'value': 'application/json'},
                  ],
                  'text': '[{"id":1},{"id":2}]',
                },
              ],
            },
            {
              'id': 'r2',
              'name': 'Create',
              'url': 'https://x.test/users',
              'method': 'POST',
              'dataMode': 'params',
              'data': [
                {
                  'key': 'name',
                  'value': 'Ada',
                  'type': 'text',
                  'enabled': true,
                },
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
      expect(list.assertions, isEmpty);
      expect(list.testScript, contains('tests["ok"] = responseCode.code'));
      expect(list.examples.single.name, 'Two users');
      expect(list.examples.single.statusCode, 200);
      expect(list.examples.single.statusText, 'OK');
      expect(list.examples.single.contentType, 'application/json');
      expect(list.examples.single.body, '[{"id":1},{"id":2}]');
      final create = c.requests[1];
      expect(create.bodyType, BodyType.formData);
      expect(create.formFields[1].isFile, isTrue);
      expect(create.authType, AuthType.basic);
    },
  );

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
        (v) => '${v.key}=${v.value}:${v.enabled}:${v.secret}',
      ),
      ['baseUrl=https://staging.test:true:false', 'secret=s3:false:true'],
    );

    final globals = importApiFile(
      jsonEncode({
        '_postman_variable_scope': 'globals',
        'values': [
          {'key': 'g', 'value': '1'},
          {'key': 'k', 'value': 'v', 'type': 'secret'},
        ],
      }),
    );
    expect(globals.environments, isEmpty, reason: 'globals are not an env');
    expect(globals.globals.map((v) => '${v.key}=${v.value}:${v.secret}'), [
      'g=1:false',
      'k=v:true',
    ]);
    expect(globals.isEmpty, isFalse);

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
    expect(dump.environments.map((e) => e.name), ['Prod']);
    expect(dump.globals.single.key, 'g');
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
