import 'dart:convert';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/theme.dart';
import 'package:api_workbench/ui/examples/examples_ui.dart';
import 'package:api_workbench/ui/json_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/state_harness.dart';
import 'support/test_fonts.dart';

ResponseData response({
  int status = 200,
  String message = 'OK',
  String body = '{"id":1,"name":"Ada"}',
  Map<String, List<String>>? headers,
  List<int>? bytes,
}) => ResponseData(
  statusCode: status,
  statusMessage: message,
  headers:
      headers ??
      {
        'Content-Type': ['application/json'],
      },
  bodyBytes: bytes ?? utf8.encode(body),
);

void main() {
  setUpAll(loadRoboto);

  group('exampleFromResponse', () {
    test('keeps status, every header value and the body', () {
      final req = RequestModel(
        name: 'Get user',
        method: 'GET',
        url: 'https://x/u/1',
      );
      final e = exampleFromResponse(
        '200 OK',
        req,
        response(
          headers: {
            'Content-Type': ['application/json'],
            'Set-Cookie': ['a=1', 'b=2'],
          },
        ),
      );
      expect(e.name, '200 OK');
      expect(e.statusCode, 200);
      expect(e.statusText, 'OK');
      expect(e.headers.map((h) => '${h.key}=${h.value}'), [
        'Content-Type=application/json',
        'Set-Cookie=a=1',
        'Set-Cookie=b=2',
      ]);
      expect(e.body, '{"id":1,"name":"Ada"}');
      expect(e.originalRequest!.id, req.id);
      expect(e.originalRequest!.url, 'https://x/u/1');
    });

    test('the request snapshot has no examples and no credentials', () {
      final req = RequestModel(
        url: 'https://x',
        auth: AuthConfig(
          type: AuthType.bearer,
          bearerToken: 'tok-secret',
          basicUser: 'ada',
          basicPassword: 'pw-secret',
          apiKeyName: 'X-Key',
          apiKeyValue: 'key-secret',
          params: {'accessToken': 'oauth-secret', 'clientId': 'public-id'},
        ),
        examples: [ResponseExample(name: 'old')],
      );
      final o = exampleFromResponse('x', req, response()).originalRequest!;
      expect(o.examples, isEmpty);
      expect(req.examples, hasLength(1)); // the original is untouched
      expect(req.auth.bearerToken, 'tok-secret');
      expect(o.auth.type, AuthType.bearer);
      expect(o.auth.bearerToken, isEmpty);
      expect(o.auth.basicPassword, isEmpty);
      expect(o.auth.apiKeyValue, isEmpty);
      expect(o.auth.basicUser, 'ada');
      expect(o.auth.params, {'clientId': 'public-id'});
      expect(jsonEncode(o.toJson()), isNot(contains('secret')));
    });

    test('binary bodies are not kept, text bodies are', () {
      final req = RequestModel();
      final png = exampleFromResponse(
        'img',
        req,
        response(
          headers: {
            'Content-Type': ['image/png'],
          },
          bytes: [0x89, 0x50, 0x4e, 0x47],
        ),
      );
      expect(png.body, isEmpty);
      final invalid = exampleFromResponse(
        'bin',
        req,
        response(headers: {}, bytes: [0xff, 0xfe, 0xfd]),
      );
      expect(invalid.body, isEmpty);
      final svg = exampleFromResponse(
        'svg',
        req,
        response(
          headers: {
            'Content-Type': ['image/svg+xml'],
          },
          body: '<svg/>',
        ),
      );
      expect(svg.body, '<svg/>');
      expect(
        exampleFromResponse('empty', req, response(body: '')).body,
        isEmpty,
      );
    });

    test('a very large body is cut', () {
      final big = 'a' * (maxExampleBody + 1000);
      final e = exampleFromResponse(
        'big',
        RequestModel(),
        response(
          headers: {
            'Content-Type': ['text/plain'],
          },
          body: big,
        ),
      );
      expect(e.body.length, lessThan(big.length));
      expect(e.body, startsWith('a' * 100));
      expect(e.body, contains('cut at'));
    });
  });

  group('Save as example', () {
    final h = StateHarness();
    late CollectionModel col;
    late RequestTab tab;

    Future<void> start(WidgetTester tester, {bool inCollection = true}) async {
      await h.setUp(tester);
      col = h.state.addCollection('Shop');
      final req = RequestModel(name: 'Get user', url: 'https://x/u/1');
      if (inCollection) {
        col.requests.add(req.clone(sameId: true));
        h.state.openRequest(col.requests.single, collectionId: col.id);
      } else {
        h.state.newTab(req);
      }
      // Drop the blank first tab so the new one is the only (active) tab.
      tab = h.state.activeTab!;
      await tester.pumpWidget(
        opener(
          buildTheme(),
          (ctx) => saveResponseAsExample(ctx, h.state, tab, response()),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('adds the example to the tab and offers to save it', (
      tester,
    ) async {
      await start(tester);
      expect(find.text('Save as example'), findsOneWidget);
      final name = tester.widget<TextField>(find.byType(TextField));
      expect(name.controller!.text, '200 OK');
      // The request is saved and unchanged, so "save now" starts ticked.
      final box = find.byType(CheckboxListTile);
      expect(tester.widget<CheckboxListTile>(box).value, isTrue);
      expect(
        find.textContaining('Also save the request to Shop'),
        findsOneWidget,
      );

      await tester.enterText(find.byType(TextField), 'Happy path');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(tab.request.examples.single.name, 'Happy path');
      expect(col.requests.single.examples.single.name, 'Happy path');
      expect(tab.dirty, isFalse);
      expect(find.text('Example saved to Shop.'), findsOneWidget);
      await h.tearDown(tester);
    });

    testWidgets('without "save now" the example waits for a save', (
      tester,
    ) async {
      await start(tester);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(tab.request.examples, hasLength(1));
      expect(col.requests.single.examples, isEmpty);
      expect(tab.dirty, isTrue);
      expect(
        find.text('Example added. Save the request to keep it.'),
        findsOneWidget,
      );
      await h.tearDown(tester);
    });

    testWidgets('a request outside a collection has no save-now option', (
      tester,
    ) async {
      await start(tester, inCollection: false);
      expect(find.byType(CheckboxListTile), findsNothing);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(tab.request.examples, hasLength(1));
      await h.tearDown(tester);
    });

    testWidgets('a name already used gets a number; cancel adds nothing', (
      tester,
    ) async {
      await start(tester, inCollection: false);
      tab.request.examples.add(ResponseExample(name: '200 OK'));
      // Reopen: the suggestion avoids the existing name.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(tab.request.examples, hasLength(1));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final name = tester.widget<TextField>(find.byType(TextField));
      expect(name.controller!.text, '200 OK (2)');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(tab.request.examples.map((e) => e.name), ['200 OK', '200 OK (2)']);
      await h.tearDown(tester);
    });
  });

  group('Example viewer and editor', () {
    final h = StateHarness();
    late CollectionModel col;
    late RequestModel req;
    late ResponseExample ex;
    var saves = 0;

    Future<void> start(WidgetTester tester, {ResponseExample? example}) async {
      await h.setUp(tester);
      col = h.state.addCollection('Shop');
      ex =
          example ??
          ResponseExample(
            name: 'Created',
            statusCode: 201,
            statusText: 'Created',
            headers: [KV(key: 'Content-Type', value: 'application/json')],
            body: '{"id":7,"tags":["a","b"]}',
            originalRequest: RequestModel(
              method: 'POST',
              url: 'https://shop.example.com/orders',
            ),
          );
      req = RequestModel(
        name: 'Create order',
        method: 'POST',
        url: 'https://shop.example.com/orders',
        examples: [
          ResponseExample(name: 'First'),
          ex,
          ResponseExample(name: 'Last'),
        ],
      );
      col.requests.add(req);
      saves = 0;
      h.state.addListener(() => saves++);
      await tester.pumpWidget(
        opener(buildTheme(), (ctx) => openExample(ctx, h.state, col, req, ex)),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Finder field(String label) => find.widgetWithText(TextField, label);

    testWidgets('shows name, status, request and a pretty JSON body', (
      tester,
    ) async {
      await start(tester);
      expect(find.text('Created'), findsWidgets); // title + name field
      expect(
        tester.widget<TextField>(field('Name')).controller!.text,
        'Created',
      );
      expect(tester.widget<TextField>(field('Status')).controller!.text, '201');
      expect(
        tester.widget<TextField>(field('Status text')).controller!.text,
        'Created',
      );
      expect(find.text('POST'), findsOneWidget);
      expect(find.text('https://shop.example.com/orders'), findsOneWidget);
      // JSON opens as the pretty, highlighted view.
      expect(find.byType(JsonView), findsOneWidget);
      expect(find.text('Headers (1)'), findsOneWidget);

      // Raw is the editable text.
      await tester.tap(find.text('Raw'));
      await tester.pumpAndSettle();
      expect(find.byType(JsonView), findsNothing);
      expect(
        tester
            .widget<TextField>(field('Response body').hitTestable())
            .controller!
            .text,
        '{"id":7,"tags":["a","b"]}',
      );
      await tester.tap(find.text('Format JSON'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.widgetWithText(
                TextField,
                '{\n  "id": 7,\n  "tags": [\n    "a",\n    "b"\n  ]\n}',
              ),
            )
            .controller!
            .text,
        contains('\n  "id": 7'),
      );
      await h.tearDown(tester);
    });

    testWidgets('a body that is not JSON opens as raw text', (tester) async {
      await start(
        tester,
        example: ResponseExample(name: 'Plain', body: 'hello world'),
      );
      expect(find.byType(JsonView), findsNothing);
      expect(find.text('hello world'), findsOneWidget);
      await tester.tap(find.text('Pretty'));
      await tester.pumpAndSettle();
      expect(find.byType(JsonView), findsOneWidget); // plain text fallback
      await h.tearDown(tester);
    });

    testWidgets('saving writes into the collection request', (tester) async {
      await start(tester);
      await tester.enterText(field('Name'), 'Order created');
      await tester.enterText(field('Status'), '404');
      // The standard phrase follows the code.
      expect(
        tester.widget<TextField>(field('Status text')).controller!.text,
        'Not Found',
      );
      await tester.tap(find.text('Raw'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '{"id":7,"tags":["a","b"]}'),
        '{"error":"nope"}',
      );
      await tester.tap(find.text('Headers (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add header'));
      await tester.pumpAndSettle();
      expect(
        find.text('Headers (1)'),
        findsOneWidget,
      ); // blank rows do not count
      await tester.enterText(
        find.widgetWithText(TextField, 'Header').last,
        'X-Trace',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Value').last,
        'abc',
      );
      saves = 0;

      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();

      final saved = col.requests.single.examples[1];
      expect(identical(saved, ex), isTrue);
      expect(saved.name, 'Order created');
      expect(saved.statusCode, 404);
      expect(saved.statusText, 'Not Found');
      expect(saved.body, '{"error":"nope"}');
      expect(saved.headers.map((h) => '${h.key}=${h.value}'), [
        'Content-Type=application/json',
        'X-Trace=abc',
      ]);
      expect(saves, greaterThan(0));
      expect(find.text('Example "Order created" saved.'), findsOneWidget);
      expect(find.text('Save'), findsNothing); // dialog closed
      final onDisk = (await h.saved(tester)).single.requests.single.examples[1];
      expect(onDisk.name, 'Order created');
      expect(onDisk.statusCode, 404);
      await h.tearDown(tester);
    });

    testWidgets('an invalid status code is refused', (tester) async {
      await start(tester);
      await tester.enterText(field('Status'), '42');
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();
      expect(find.text('Use a status code from 100 to 599.'), findsOneWidget);
      expect(ex.statusCode, 201);
      expect(find.text('Save'), findsWidgets); // still open
      await h.tearDown(tester);
    });

    testWidgets('unsaved changes are not applied, closing asks first', (
      tester,
    ) async {
      await start(tester);
      await tester.enterText(field('Name'), 'Renamed');
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('Close'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.text('Close'), findsNothing);
      expect(ex.name, 'Created');
      await h.tearDown(tester);
    });

    testWidgets('duplicate adds a copy right after the example', (
      tester,
    ) async {
      await start(tester);
      await tester.tap(find.text('Duplicate'));
      await tester.pumpAndSettle();
      expect(req.examples.map((e) => e.name), [
        'First',
        'Created',
        'Created (copy)',
        'Last',
      ]);
      final copy = req.examples[2];
      expect(copy.id, isNot(ex.id));
      expect(copy.body, ex.body);
      expect(copy.statusCode, 201);
      expect(saves, greaterThan(0));
      expect(find.text('Duplicated as "Created (copy)".'), findsOneWidget);
      await h.tearDown(tester);
    });

    testWidgets('delete asks, then removes the example', (tester) async {
      await start(tester);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete example?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(req.examples, hasLength(3));

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();
      expect(req.examples.map((e) => e.name), ['First', 'Last']);
      expect(find.text('Close'), findsNothing);
      await h.tearDown(tester);
    });

    testWidgets('open request opens the saved request in a tab', (
      tester,
    ) async {
      await start(tester);
      await tester.tap(find.text('Open request'));
      await tester.pumpAndSettle();
      final active = h.state.activeTab!;
      expect(active.request.id, req.id);
      expect(active.sourceCollectionId, col.id);
      expect(find.text('Close'), findsNothing);
      await h.tearDown(tester);
    });

    testWidgets('edits reach an open tab of the same request', (tester) async {
      await start(tester);
      h.state.openRequest(req, collectionId: col.id);
      final tabRequest = h.state.activeTab!.request;
      expect(identical(tabRequest, req), isFalse);
      // The tab also has an example the user has not saved yet.
      tabRequest.examples.add(ResponseExample(name: 'Unsaved'));

      await tester.enterText(field('Name'), 'Renamed');
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();
      expect(tabRequest.examples.map((e) => e.name), [
        'First',
        'Renamed',
        'Last',
        'Unsaved',
      ]);

      // Duplicate and delete follow too.
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Duplicate'));
      await tester.pumpAndSettle();
      expect(
        tabRequest.examples.map((e) => e.name),
        contains('Renamed (copy)'),
      );
      await h.tearDown(tester);
    });

    testWidgets('fits a 320 px phone and keeps its actions in a menu', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await start(tester);

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('Duplicate'), findsNothing); // inside the menu
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('Open request'), findsOneWidget);
      expect(find.text('Duplicate'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5)); // dismiss the menu
      await tester.pumpAndSettle();

      await tester.tap(find.text('Raw'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Headers'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      await h.tearDown(tester);
    });
  });
}
