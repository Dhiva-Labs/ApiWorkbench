import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/har_import.dart';
import 'package:api_workbench/services/import_any.dart';
import 'package:flutter_test/flutter_test.dart';

String fixture() => File('test/fixtures/har/browser.har').readAsStringSync();

RequestModel byName(CollectionModel c, String name) =>
    c.requests.firstWhere((r) => r.name == name, orElse: () => fail(name));

String kvs(List<KV> rows) =>
    rows.map((r) => '${r.enabled ? '' : '!'}${r.key}=${r.value}').join('&');

/// A one-entry HAR with the given request/response parts.
String har({
  String method = 'GET',
  String url = 'https://api.test/x',
  Map<String, Object?> request = const {},
  Map<String, Object?> response = const {},
  String? resourceType,
  List<Map<String, Object?>> more = const [],
}) => jsonEncode({
  'log': {
    'version': '1.2',
    'entries': [
      {
        'request': {'method': method, 'url': url, ...request},
        'response': {'status': 200, ...response},
        '_resourceType': ?resourceType,
      },
      ...more,
    ],
  },
});

void main() {
  group('HAR import', () {
    test('one collection named for the date, one request per entry', () {
      final report = importHar(fixture(), now: DateTime(2026, 3, 7));
      expect(report.formats, {'HAR 1.2'});
      final c = report.collections.single;
      expect(c.name, 'HAR import 2026-03-07');
      expect(report.requests, c.requests.length);
      expect(report.folders, 0);
      expect(c.variables, isEmpty);
    });

    test('the default name uses today', () {
      final c = importHar(fixture()).collections.single;
      expect(c.name, matches(RegExp(r'^HAR import \d{4}-\d{2}-\d{2}$')));
    });

    test(
      'static assets are skipped by resource type, MIME type and extension',
      () {
        final report = importHar(fixture());
        final c = report.collections.single;
        expect(c.requests.map((r) => r.name), [
          'GET /',
          'GET /v1/users',
          'POST /v1/login',
          'POST /v1/users',
          'POST /v1/upload',
          'GET /v1/blob',
          'GET /v1/slow',
        ]);
        // app.js, site.css, logo.png, inter.woff2, vendor.min.js (by its
        // extension, query ignored), and avatar (an image by MIME type).
        expect(
          report.warnings,
          contains(startsWith('Skipped 6 static assets')),
        );
      },
    );

    test('keeping static assets imports them too', () {
      final report = importHar(fixture(), skipStaticAssets: false);
      final c = report.collections.single;
      expect(
        c.requests.map((r) => r.name),
        containsAll([
          'GET /static/app.js',
          'GET /static/site.css',
          'GET /img/logo.png',
          'GET /fonts/inter.woff2',
          'GET /lib/vendor.min.js',
          'GET /v1/avatar',
        ]),
      );
      expect(report.requests, 13);
      expect(report.warnings.any((w) => w.contains('static asset')), isFalse);
      // Binary bodies are not kept as examples.
      expect(byName(c, 'GET /img/logo.png').examples.single.body, isEmpty);
      expect(byName(c, 'GET /v1/avatar').examples.single.body, isEmpty);
      // Text assets are.
      expect(
        byName(c, 'GET /static/app.js').examples.single.body,
        'console.log(1)',
      );
    });

    test('only GET requests are judged by their extension', () {
      final c = importHar(
        har(
          method: 'POST',
          url: 'https://api.test/upload.js',
          response: {
            'content': {'mimeType': 'application/json', 'text': '{}'},
          },
        ),
      ).collections.single;
      expect(c.requests.single.method, 'POST');
    });

    test('WebSocket and non-HTTP entries are skipped and counted', () {
      final report = importAnyFile(fixture());
      expect(report.warnings, contains(startsWith('Skipped 1 non-HTTP entry')));
      final c = report.collections.single;
      expect(c.requests.any((r) => r.url.startsWith('wss:')), isFalse);
    });

    test('method, URL and query', () {
      final users = byName(
        importHar(fixture()).collections.single,
        'GET /v1/users',
      );
      expect(users.method, 'GET');
      expect(users.url, 'https://api.example.test/v1/users');
      // Decoded by the browser already; the URL keeps only its base.
      expect(kvs(users.params), 'page=2&sort=name desc');
    });

    test('query falls back to the URL when queryString is missing', () {
      final r = importHar(
        har(url: 'https://api.test/x?a=1&b=two%20words&flag#frag'),
      ).collections.single.requests.single;
      expect(r.url, 'https://api.test/x');
      expect(kvs(r.params), 'a=1&b=two words&flag=');
    });

    test(
      'headers: pseudo and computed ones are dropped, cookies become a header',
      () {
        final users = byName(
          importHar(fixture()).collections.single,
          'GET /v1/users',
        );
        final names = users.headers.map((h) => h.key.toLowerCase()).toList();
        expect(names, ['accept', 'user-agent', 'authorization', 'cookie']);
        expect(names.any((n) => n.startsWith(':')), isFalse);
        expect(names, isNot(contains('host')));
        expect(names, isNot(contains('accept-encoding')));
        expect(
          users.headers.last.value,
          'session=abc; theme=dark',
          reason: 'built from the cookies list',
        );
      },
    );

    test('a Cookie header is kept when no cookies list came with it', () {
      final r = importHar(
        har(
          request: {
            'headers': [
              {'name': 'Cookie', 'value': 'a=1'},
              {'name': 'Content-Length', 'value': '0'},
            ],
          },
        ),
      ).collections.single.requests.single;
      expect(kvs(r.headers), 'Cookie=a=1');
    });

    test('JSON post data is kept as text', () {
      final r = byName(
        importHar(fixture()).collections.single,
        'POST /v1/users',
      );
      expect(r.bodyType, BodyType.json);
      expect(r.body, '{"name":"Grace","role":"admin"}');
      expect(
        r.headers.where((h) => h.key == 'content-type').single.value,
        'application/json',
      );
    });

    test('form post data becomes URL-encoded fields', () {
      final r = byName(
        importHar(fixture()).collections.single,
        'POST /v1/login',
      );
      expect(r.bodyType, BodyType.formUrlEncoded);
      expect(kvs(r.formFields), 'email=ada@example.test&pass=s3cret');
      expect(r.body, isEmpty);
    });

    test('form fields are parsed from the text when params are absent', () {
      final r = importHar(
        har(
          method: 'POST',
          request: {
            'postData': {
              'mimeType': 'application/x-www-form-urlencoded; charset=UTF-8',
              'text': 'a=1&b=x%20y&c=',
            },
          },
        ),
      ).collections.single.requests.single;
      expect(r.bodyType, BodyType.formUrlEncoded);
      expect(kvs(r.formFields), 'a=1&b=x y&c=');
    });

    test(
      'multipart post data: fields and files, recorded boundary dropped',
      () {
        final r = byName(
          importHar(fixture()).collections.single,
          'POST /v1/upload',
        );
        expect(r.bodyType, BodyType.formData);
        expect(r.formFields.map((f) => f.key), ['title', 'photo']);
        expect(r.formFields.first.value, 'holiday');
        expect(r.formFields.first.isFile, isFalse);
        expect(r.formFields.last.isFile, isTrue);
        expect(r.formFields.last.value, isEmpty);
        expect(r.formFields.last.description, contains('beach.jpg'));
        expect(
          r.headers.any((h) => h.key.toLowerCase() == 'content-type'),
          isFalse,
        );
      },
    );

    test('multipart params from Firefox-style captures', () {
      final r = importHar(
        har(
          method: 'POST',
          request: {
            'postData': {
              'mimeType': 'multipart/form-data; boundary=xyz',
              'params': [
                {'name': 'a', 'value': '1'},
                {
                  'name': 'f',
                  'fileName': 'doc.pdf',
                  'contentType': 'application/pdf',
                },
              ],
            },
          },
        ),
      ).collections.single.requests.single;
      expect(r.bodyType, BodyType.formData);
      expect(r.formFields.map((f) => f.isFile), [false, true]);
    });

    test('other post data types', () {
      BodyType type(String mime, String text) => importHar(
        har(
          method: 'POST',
          request: {
            'postData': {'mimeType': mime, 'text': text},
          },
        ),
      ).collections.single.requests.single.bodyType;
      expect(type('application/vnd.api+json', '{}'), BodyType.json);
      expect(type('text/xml', '<a/>'), BodyType.xml);
      expect(type('application/soap+xml', '<a/>'), BodyType.xml);
      expect(type('text/plain;charset=UTF-8', 'hi'), BodyType.text);
      expect(type('text/html', '<p>'), BodyType.text);
      expect(type('', 'raw'), BodyType.text);
    });

    test('a content type the body type would not send is kept', () {
      final r = importHar(
        har(
          method: 'POST',
          request: {
            'postData': {'mimeType': 'application/vnd.api+json', 'text': '{}'},
          },
        ),
      ).collections.single.requests.single;
      final ct = r.headers.singleWhere((h) => h.key == 'Content-Type');
      expect(ct.value, 'application/vnd.api+json');
    });

    test('responses become examples', () {
      final c = importHar(fixture()).collections.single;
      final login = byName(c, 'POST /v1/login');
      final e = login.examples.single;
      expect(e.name, '200 OK');
      expect(e.statusCode, 200);
      expect(e.statusText, 'OK');
      expect(e.body, '{"token":"t-123"}');
      expect(e.contentType, 'application/json; charset=utf-8');

      final created = byName(c, 'POST /v1/users').examples.single;
      expect(created.statusCode, 201);
      expect(created.name, '201 Created');

      // Transfer headers describe the wire, not the content.
      final users = byName(c, 'GET /v1/users').examples.first;
      expect(users.headers.map((h) => h.key), ['content-type', 'x-total']);
    });

    test('an empty statusText (HTTP/2) is filled in', () {
      final e = byName(
        importHar(fixture()).collections.single,
        'POST /v1/upload',
      ).examples.single;
      expect(e.statusCode, 204);
      expect(e.statusText, 'No Content');
      expect(e.body, isEmpty);
      // Chrome's "x-unknown" is not a content type.
      expect(e.contentType, isNull);
    });

    test('a base64 body is decoded when it is text', () {
      final e = byName(
        importHar(fixture()).collections.single,
        'GET /v1/blob',
      ).examples.single;
      expect(jsonDecode(e.body), {
        'ok': true,
        'items': [1, 2],
      });
    });

    test('a base64 body that is not text is not kept', () {
      final e = importHar(
        har(
          response: {
            'content': {
              'mimeType': 'application/x-thing',
              'encoding': 'base64',
              'text': base64.encode([0xff, 0xfe, 0x00, 0x01]),
            },
          },
        ),
      ).collections.single.requests.single.examples.single;
      expect(e.body, isEmpty);
      final bad = importHar(
        har(
          response: {
            'content': {
              'mimeType': 'text/plain',
              'encoding': 'base64',
              'text': '***',
            },
          },
        ),
      ).collections.single.requests.single.examples.single;
      expect(bad.body, isEmpty);
    });

    test('a request that got no response has no example', () {
      final slow = byName(
        importHar(fixture()).collections.single,
        'GET /v1/slow',
      );
      expect(slow.examples, isEmpty);
    });

    test('very large bodies are not kept, and the report says so', () {
      final report = importHar(
        har(
          response: {
            'content': {'mimeType': 'text/plain', 'text': 'x' * (600 * 1024)},
          },
        ),
      );
      final e = report.collections.single.requests.single.examples.single;
      expect(e.body, isEmpty);
      expect(report.warnings, contains(contains('over 512 KB')));
    });
  });

  group('deduplication', () {
    test('repeated requests merge; a different response adds an example', () {
      final report = importHar(fixture());
      final c = report.collections.single;
      expect(c.requests.where((r) => r.name == 'GET /v1/users'), hasLength(1));
      final users = byName(c, 'GET /v1/users');
      expect(users.examples, hasLength(2));
      expect(users.examples.last.body, contains('"New"'));
      expect(report.warnings, contains('Merged 1 repeated request.'));
    });

    test('identical responses are not added twice', () {
      final entry = {
        'request': {'method': 'GET', 'url': 'https://api.test/x'},
        'response': {
          'status': 200,
          'content': {'mimeType': 'text/plain', 'text': 'same'},
        },
      };
      final r = importHar(
        har(
          response: {
            'content': {'mimeType': 'text/plain', 'text': 'same'},
          },
          more: [entry, entry],
        ),
      ).collections.single.requests.single;
      expect(r.examples, hasLength(1));
    });

    test('a different body or query is a different request', () {
      Map<String, Object?> post(String body) => {
        'request': {
          'method': 'POST',
          'url': 'https://api.test/x',
          'postData': {'mimeType': 'application/json', 'text': body},
        },
        'response': {'status': 200},
      };
      final c = importHar(
        jsonEncode({
          'log': {
            'entries': [post('{"a":1}'), post('{"a":2}'), post('{"a":1}')],
          },
        }),
      ).collections.single;
      expect(c.requests.map((r) => r.body), ['{"a":1}', '{"a":2}']);
    });

    test('examples per request are capped', () {
      final entries = [
        for (var i = 0; i < 12; i++)
          {
            'request': {'method': 'GET', 'url': 'https://api.test/poll'},
            'response': {
              'status': 200,
              'content': {'mimeType': 'text/plain', 'text': 'n$i'},
            },
          },
      ];
      final c = importHar(
        jsonEncode({
          'log': {'entries': entries},
        }),
      ).collections.single;
      expect(c.requests.single.examples, hasLength(5));
    });

    test('with deduplication off every entry is a request', () {
      final report = importHar(fixture(), dedupe: false);
      final users = report.collections.single.requests.where(
        (r) => r.name == 'GET /v1/users',
      );
      expect(users, hasLength(2));
      expect(users.every((r) => r.examples.length == 1), isTrue);
      expect(report.warnings.any((w) => w.contains('Merged')), isFalse);
    });
  });

  group('HAR errors', () {
    test('not JSON, not a HAR, no entries', () {
      expect(() => importHar('not json'), throwsFormatException);
      expect(() => importHar('{"log": {}}'), throwsFormatException);
      expect(() => importHar('[]'), throwsFormatException);
      expect(
        () => importHar('{"log": {"entries": []}}'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('no entries'),
          ),
        ),
      );
    });

    test('a capture of only static assets says how to include them', () {
      final onlyAssets = har(
        url: 'https://cdn.test/app.js',
        resourceType: 'script',
      );
      expect(
        () => importHar(onlyAssets),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('static'), contains('Skip static assets')),
          ),
        ),
      );
      expect(importHar(onlyAssets, skipStaticAssets: false).requests, 1);
    });

    test('a failed import leaves the report untouched', () {
      final report = importAnyFile(fixture());
      final before = report.collections.length;
      expect(
        () => importHar('{"log": {"entries": []}}', into: report),
        throwsFormatException,
      );
      expect(report.collections, hasLength(before));
    });

    test('malformed entries are tolerated', () {
      final report = importHar(
        jsonEncode({
          'log': {
            'entries': [
              'junk',
              7,
              {'request': 'oops'},
              {
                'request': {'url': 'https://api.test/ok'},
                'response': [],
              },
              {
                'request': {
                  'method': 'GET',
                  'url': 'https://api.test/ok2',
                  'headers': 'x',
                  'queryString': 4,
                  'cookies': {},
                  'postData': [],
                },
                'response': {'status': 'nope', 'headers': 3, 'content': 9},
              },
            ],
          },
        }),
      );
      expect(report.collections.single.requests.map((r) => r.url), [
        'https://api.test/ok',
        'https://api.test/ok2',
      ]);
    });
  });
}
