import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/collection_docs.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/theme.dart';
import 'package:api_workbench/ui/collection_docs_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/state_harness.dart';

CollectionModel sample() => CollectionModel(
  id: 'c1',
  name: 'Shop API',
  description: 'Orders and payments.\nSecond line.',
  auth: AuthConfig(type: AuthType.bearer, bearerToken: 'collection-token-123'),
  preRequestScript: 'pm.environment.set("t", 1);',
  variables: [
    KV(key: 'baseUrl', value: 'https://shop.example.com'),
    KV(key: 'apiKey', value: 'sk_live_supersecret', secret: true),
    KV(key: 'off', value: 'x', enabled: false),
  ],
  folders: {
    'Orders': FolderMeta(
      description: 'Everything about **orders**.',
      auth: AuthConfig(
        type: AuthType.basic,
        basicUser: 'ada',
        basicPassword: 'hunter2hunter2',
      ),
      testScript: 'pm.test("ok", () => {});',
    ),
  },
  requests: [
    RequestModel(
      id: 'r0',
      name: 'Health',
      method: 'GET',
      url: '{{baseUrl}}/health',
      auth: AuthConfig(type: AuthType.none),
    ),
    RequestModel(
      id: 'r1',
      name: 'Create <b>order</b>',
      method: 'POST',
      url: '{{baseUrl}}/orders/:orderId?x=1&y=2',
      folder: 'Orders',
      description: 'Creates an order.\n<script>alert(1)</script>',
      auth: AuthConfig(type: AuthType.inherit),
      pathVariables: [KV(key: 'orderId', value: '42', description: 'The id')],
      params: [
        KV(key: 'dryRun', value: 'true', description: 'No side effects'),
        KV(key: 'old', value: '1', enabled: false),
      ],
      headers: [
        KV(key: 'Content-Type', value: 'application/json'),
        KV(key: 'Authorization', value: 'Bearer literal-secret-token'),
        KV(key: 'X-Trace', value: 'a|b'),
        KV(key: 'X-Api-Key', value: '{{apiKey}}'),
      ],
      bodyType: BodyType.json,
      body: '{"item":"sk_live_supersecret","qty":2}',
      preRequestScript: 'console.log("hi")',
      examples: [
        ResponseExample(
          name: 'Created',
          statusCode: 201,
          statusText: 'Created',
          headers: [
            KV(key: 'Content-Type', value: 'application/json'),
            KV(key: 'Set-Cookie', value: 'sid=abcdef123456'),
          ],
          body: '{"id":7,"note":"<img src=x onerror=alert(1)>"}',
          originalRequest: RequestModel(
            method: 'POST',
            url: '{{baseUrl}}/orders',
          ),
        ),
      ],
    ),
    RequestModel(
      id: 'r2',
      name: 'Pay',
      method: 'PUT',
      url: '{{baseUrl}}/orders/1/pay',
      folder: 'Orders/Payments',
      auth: AuthConfig(
        type: AuthType.apiKey,
        apiKeyName: 'X-Key',
        apiKeyValue: 'real-key-value',
        apiKeyInHeader: false,
      ),
      bodyType: BodyType.formUrlEncoded,
      formFields: [
        KV(key: 'card', value: '4111'),
        KV(key: 'cvc', value: '1', enabled: false),
      ],
    ),
  ],
);

final at = DateTime(2026, 10, 31, 12, 0);

void main() {
  group('HTML', () {
    final secrets = {'sk_live_supersecret'};
    late String html;
    setUp(
      () => html = buildCollectionHtml(
        sample(),
        secrets: secrets,
        generatedAt: at,
      ),
    );

    test('is one self-contained page with light and dark colours', () {
      expect(html, startsWith('<!doctype html>'));
      expect(html, contains('<style>'));
      expect(html, contains('prefers-color-scheme:dark'));
      expect(html, isNot(contains('<link')));
      expect(html, isNot(contains('<script')));
      expect(html, isNot(contains(' src="')));
      expect(html, isNot(contains('href="http')));
      expect(html, contains('<title>Shop API'));
      expect(html, contains('2026-10-31 12:00'));
    });

    test('escapes every piece of HTML from the collection', () {
      expect(html, contains('Create &lt;b&gt;order&lt;/b&gt;'));
      expect(html, isNot(contains('<b>order')));
      expect(html, contains('&lt;script&gt;alert(1)&lt;/script&gt;'));
      // Example bodies are escaped too.
      expect(html, contains('&lt;img src=x onerror=alert(1)&gt;'));
      expect(html, isNot(contains('<img')));
    });

    test('masks secrets in text, auth and credential headers', () {
      expect(html, isNot(contains('sk_live_supersecret')));
      expect(html, isNot(contains('literal-secret-token')));
      expect(html, isNot(contains('collection-token-123')));
      expect(html, isNot(contains('hunter2hunter2')));
      expect(html, isNot(contains('real-key-value')));
      expect(html, isNot(contains('abcdef123456')));
      expect(html, contains('Bearer $docMask'));
      // A variable reference documents where the value comes from.
      expect(html, contains('{{apiKey}}'));
      // Non-secret values stay.
      expect(html, contains('https://shop.example.com'));
      expect(html, contains('ada'));
    });

    test('has a table of contents linking every folder and request', () {
      expect(html, contains('<nav class="toc">'));
      final nav = html.substring(html.indexOf('<nav'), html.indexOf('</nav>'));
      for (final name in ['Health', 'Orders', 'Payments', 'Pay']) {
        expect(nav, contains('$name</a>'), reason: name);
      }
      expect(nav, contains('Create &lt;b&gt;order&lt;/b&gt;'));
      // Every link has a target.
      for (final m in RegExp('href="#([^"]+)"').allMatches(nav)) {
        expect(html, contains('id="${m[1]}"'));
      }
      expect(nav, contains('badge m-post'));
      expect(nav, contains('badge m-put'));
    });

    test('documents each request part', () {
      expect(html, contains('class="badge m-post">POST</span>'));
      expect(html, contains('{{baseUrl}}/orders/:orderId?x=1&amp;y=2'));
      expect(html, contains('Path variables'));
      expect(html, contains('The id'));
      expect(html, contains('Query parameters'));
      expect(html, contains('No side effects'));
      expect(html, contains('<tr class="off">')); // disabled param
      expect(html, contains('Headers'));
      expect(html, contains('Body (JSON)'));
      expect(html, contains('Body (Form URL-encoded)'));
      expect(
        html,
        contains('Everything about **orders**.'),
      ); // folder description
      expect(html, contains('Orders and payments.'));
      // Inherited auth names its source.
      expect(html, contains('Basic Auth (from the folder Orders)'));
      expect(html, contains('API Key'));
      expect(html, contains('query string'));
    });

    test('collapses scripts and lists variables with secrets masked', () {
      expect(
        html,
        contains('<details class="script"><summary>Pre-request script'),
      );
      expect(html, contains('<summary>Test script'));
      final vars = html.substring(html.indexOf('>Variables<'));
      expect(vars, contains('baseUrl'));
      expect(vars, contains('apiKey'));
      expect(vars, contains(docMask));
      // Disabled variables are left out.
      expect(
        vars.substring(0, vars.indexOf('</table>')),
        isNot(contains('>off<')),
      );
    });

    test('shows examples with status, headers and pretty body', () {
      expect(html, contains('Example: <strong>Created</strong>'));
      expect(html, contains('status s-ok">201</span>'));
      expect(html, contains('Set-Cookie'));
      expect(html, contains('POST {{baseUrl}}/orders'));
      expect(html, contains('class="language-json"'));
      expect(html, contains('&quot;id&quot;: 7')); // pretty-printed
    });
  });

  group('Markdown', () {
    final secrets = {'sk_live_supersecret'};
    late String md;
    setUp(
      () => md = buildCollectionMarkdown(
        sample(),
        secrets: secrets,
        generatedAt: at,
      ),
    );

    test('has the same content as the HTML page', () {
      expect(md, startsWith('# Shop API\n'));
      expect(md, contains('Orders and payments.'));
      expect(md, contains('## Contents'));
      expect(md, contains('[Health](#sec-'));
      expect(md, contains('| Name | Value |'));
      expect(md, contains('**Variables**'));
      expect(md, contains('**Query parameters**'));
      expect(md, contains('dryRun'));
      expect(md, contains('_(disabled)_'));
      expect(md, contains('**Body (JSON)**'));
      expect(md, contains('```json'));
      expect(md, contains('**Example: Created** `201`'));
      expect(md, contains('Basic Auth (from the folder Orders)'));
      expect(md, contains('<details><summary>Pre-request script</summary>'));
      expect(md, contains('`POST` ')); // method badge
    });

    test('masks secrets and neutralises HTML', () {
      for (final s in [
        'sk_live_supersecret',
        'literal-secret-token',
        'collection-token-123',
        'hunter2hunter2',
        'real-key-value',
        'abcdef123456',
      ]) {
        expect(md, isNot(contains(s)), reason: s);
      }
      expect(md, contains(docMask));
      expect(md, isNot(contains(RegExp(r'(?<!\\)<script>'))));
      expect(md, isNot(contains('<b>order')));
      expect(md, contains(r'\<b\>order'));
      // A pipe in a cell cannot break the table.
      expect(md, contains(r'a\|b'));
    });

    test('fences are longer than any backticks inside', () {
      final c = CollectionModel(
        name: 'T',
        requests: [
          RequestModel(name: 'x', bodyType: BodyType.text, body: 'a ``` b'),
        ],
      );
      final out = buildCollectionMarkdown(c, generatedAt: at);
      expect(out, contains('````\na ``` b\n````'));
    });
  });

  test('an empty collection still produces valid documents', () {
    final c = CollectionModel(name: 'Empty');
    final html = buildCollectionHtml(c, generatedAt: at);
    expect(html, contains('<h1 id="top">Empty</h1>'));
    expect(html, contains('0 requests'));
    final md = buildCollectionMarkdown(c, generatedAt: at);
    expect(md, startsWith('# Empty'));
    expect(md, isNot(contains('## Contents')));
  });

  test('root requests and nested folders get sensible heading levels', () {
    final html = buildCollectionHtml(sample(), generatedAt: at);
    expect(
      html,
      contains(
        '<h2 id="sec-1"><span class="badge m-get">GET</span> Health</h2>',
      ),
    );
    expect(html, contains('<h2 id="sec-2">Orders</h2>'));
    expect(
      html,
      contains('<h3 id="sec-3"><span class="badge m-post">POST</span>'),
    );
    expect(html, contains('<h3 id="sec-4">Payments</h3>'));
    expect(
      html,
      contains('<h4 id="sec-5"><span class="badge m-put">PUT</span> Pay</h4>'),
    );
  });

  test('maskHeaderValue keeps scheme words and variables', () {
    expect(maskHeaderValue('Bearer abc'), 'Bearer $docMask');
    expect(maskHeaderValue('Bearer {{t}}'), 'Bearer {{t}}');
    expect(maskHeaderValue('{{t}}'), '{{t}}');
    expect(maskHeaderValue('abc'), docMask);
    expect(maskHeaderValue(''), '');
    expect(isSensitiveHeader('X-Auth-Token'), isTrue);
    expect(isSensitiveHeader('Content-Type'), isFalse);
  });

  group('export dialog', () {
    test('file names come from the collection name', () {
      expect(docFileStem('Shop API'), 'shop-api');
      expect(docFileStem('  Ünï / v2!  '), 'n-v2');
      expect(docFileStem('???'), 'collection');
    });

    testWidgets('offers HTML and Markdown, and Cancel saves nothing', (
      tester,
    ) async {
      final h = StateHarness();
      await h.setUp(tester);
      final AppState state = h.state;
      await tester.pumpWidget(
        opener(
          buildTheme(),
          (ctx) => exportCollectionDocs(ctx, state, sample()),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Export collection docs'), findsOneWidget);
      expect(find.text('HTML page'), findsOneWidget);
      expect(find.text('Markdown'), findsOneWidget);
      expect(find.textContaining('masked'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Export collection docs'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      await h.tearDown(tester);
    });
  });
}
