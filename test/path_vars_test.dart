import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/request_builder.dart';
import 'package:api_workbench/theme.dart';
import 'package:api_workbench/ui/help_tip.dart';
import 'package:api_workbench/ui/request/params_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> keys(RequestModel r) => r.pathVariables.map((v) => v.key).toList();

void main() {
  group('syncPathVariables', () {
    test('adds a row for each :name segment, in URL order', () {
      final r = RequestModel(url: 'https://x.dev/users/:id/posts/:postId');
      expect(syncPathVariables(r), isTrue);
      expect(keys(r), ['id', 'postId']);
      expect(syncPathVariables(r), isFalse); // nothing left to do
    });

    test('keeps the value, description and flags while the name stays', () {
      final r = RequestModel(
        url: 'https://x.dev/users/:id',
        pathVariables: [KV(key: 'id', value: '42', description: 'The user')],
      );
      final row = r.pathVariables.single;
      r.url = 'https://x.dev/v2/users/:id/posts';
      syncPathVariables(r);
      expect(identical(r.pathVariables.single, row), isTrue);
      expect(r.pathVariables.single.value, '42');
      expect(r.pathVariables.single.description, 'The user');
      // A new name next to it starts empty and the old one is untouched.
      r.url = 'https://x.dev/v2/users/:id/posts/:postId';
      syncPathVariables(r);
      expect(keys(r), ['id', 'postId']);
      expect(r.pathVariables.first.value, '42');
      expect(r.pathVariables.last.value, '');
    });

    test('reordering segments keeps each value with its name', () {
      final r = RequestModel(
        url: '/a/:one/:two',
        pathVariables: [
          KV(key: 'one', value: '1'),
          KV(key: 'two', value: '2'),
        ],
      );
      r.url = '/a/:two/:one';
      syncPathVariables(r);
      expect(keys(r), ['two', 'one']);
      expect(r.pathVariables.map((v) => v.value), ['2', '1']);
    });

    test('rows for names that left the URL are dropped', () {
      final r = RequestModel(
        url: 'https://x.dev/a/:one/b/:two',
        pathVariables: [
          KV(key: 'one', value: '1'),
          KV(key: 'two', value: '2'),
        ],
      );
      r.url = 'https://x.dev/a/:one/b';
      expect(syncPathVariables(r), isTrue);
      expect(keys(r), ['one']);
      r.url = 'https://x.dev/a/b';
      syncPathVariables(r);
      expect(r.pathVariables, isEmpty);
    });

    test('a name being retyped carries its value over', () {
      final r = RequestModel(
        url: 'https://x.dev/users/:id',
        pathVariables: [KV(key: 'id', value: '42', description: 'who')],
      );
      for (final url in [
        'https://x.dev/users/:i',
        'https://x.dev/users/:ide',
        'https://x.dev/users/:identifier',
      ]) {
        r.url = url;
        syncPathVariables(r);
        expect(r.pathVariables.single.value, '42', reason: url);
        expect(r.pathVariables.single.description, 'who', reason: url);
      }
      expect(keys(r), ['identifier']);
    });

    test('a rename only carries over when it is unambiguous', () {
      final r = RequestModel(
        url: '/a/:x/:y',
        pathVariables: [
          KV(key: 'x', value: '1'),
          KV(key: 'y', value: '2'),
        ],
      );
      r.url = '/a/:p/:q/:s'; // two gone, three new: no pairing
      syncPathVariables(r);
      expect(keys(r), ['p', 'q', 's']);
      expect(r.pathVariables.map((v) => v.value), ['', '', '']);
    });

    test('ports, {{variables}} and the query are not path variables', () {
      final r = RequestModel(url: 'http://localhost:8080/a/{{b}}/c?x=:y#:z');
      syncPathVariables(r);
      expect(r.pathVariables, isEmpty);
    });

    test('a repeated name is one row', () {
      final r = RequestModel(url: '/:id/x/:id');
      syncPathVariables(r);
      expect(keys(r), ['id']);
    });

    test('a request loaded with duplicate rows ends up with one', () {
      final r = RequestModel(
        url: '/:id',
        pathVariables: [
          KV(key: 'id', value: '1'),
          KV(key: 'id', value: '2'),
        ],
      );
      syncPathVariables(r);
      expect(r.pathVariables.single.value, '1');
    });
  });

  group('values reach the URL on send', () {
    test('path variable values replace the segments', () async {
      final r = RequestModel(
        url: 'https://x.dev/users/:id/posts/:postId?x=1',
        pathVariables: [
          KV(key: 'id', value: '42'),
          KV(key: 'postId', value: '{{post}}'),
        ],
      );
      final p = await buildRequest(r, {'post': 'p-7'});
      expect(p.url.toString(), 'https://x.dev/users/42/posts/p-7?x=1');
    });

    test('a value kept across a URL edit is the one that is sent', () async {
      final r = RequestModel(url: 'https://x.dev/users/:id');
      syncPathVariables(r);
      r.pathVariables.single.value = '42';
      r.url = 'https://x.dev/v2/users/:id/posts';
      syncPathVariables(r);
      expect(
        (await buildRequest(r, {})).url.toString(),
        'https://x.dev/v2/users/42/posts',
      );
    });
  });

  group('Params tab', () {
    Widget host(RequestModel r, VoidCallback onChanged) => MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: ParamsTab(request: r, onChanged: onChanged),
      ),
    );

    RequestModel sample() => RequestModel(
      url: 'https://api.example.com/users/:id/posts/:postId',
      params: [KV(key: 'page', value: '2', description: 'Which page')],
      pathVariables: [
        KV(key: 'id', value: '42', description: 'The user'),
        KV(key: 'postId', value: '{{post}}'),
      ],
    );

    Future<void> setSize(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    for (final size in [
      const Size(320, 640),
      const Size(360, 640),
      const Size(768, 900),
      const Size(1280, 800),
    ]) {
      final w = size.width.toInt();
      testWidgets('shows query params and path variables at $w px', (
        tester,
      ) async {
        await setSize(tester, size);
        final r = sample();
        await tester.pumpWidget(host(r, () {}));
        expect(tester.takeException(), isNull);

        expect(find.text('Query params'), findsOneWidget);
        expect(find.text('Path variables'), findsOneWidget);
        // The keys are read-only labels showing :name.
        await tester.ensureVisible(find.text(':postId'));
        expect(find.text(':id'), findsOneWidget);
        expect(find.text(':postId'), findsOneWidget);
        expect(find.widgetWithText(TextField, ':id'), findsNothing);
        // The values and descriptions are editable fields.
        expect(find.widgetWithText(TextFormField, '42'), findsOneWidget);
        expect(find.widgetWithText(TextFormField, '{{post}}'), findsOneWidget);
        expect(find.widgetWithText(TextFormField, 'The user'), findsOneWidget);
        expect(find.widgetWithText(TextField, 'Which page'), findsOneWidget);
        expect(find.text('Bulk edit'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('has hover help on the tables at $w px', (tester) async {
        await setSize(tester, size);
        await tester.pumpWidget(host(sample(), () {}));
        // Section titles and column headers carry the help icon.
        expect(find.byIcon(Icons.help_outline), findsAtLeastNWidgets(6));
        expect(find.byType(HelpHover), findsAtLeastNWidgets(3));
      });
    }

    testWidgets('typing a value or description edits the request', (
      tester,
    ) async {
      final r = sample();
      var changes = 0;
      await tester.pumpWidget(host(r, () => changes++));
      await tester.enterText(find.widgetWithText(TextFormField, '42'), '43');
      expect(r.pathVariables.first.value, '43');
      await tester.enterText(
        find.widgetWithText(TextFormField, 'The user'),
        'Owner',
      );
      expect(r.pathVariables.first.description, 'Owner');
      expect(changes, 2);
    });

    testWidgets('a {{variable}} can be typed into a value', (tester) async {
      final r = RequestModel(url: '/u/:id');
      await tester.pumpWidget(host(r, () {}));
      await tester.enterText(
        find.byWidgetPredicate(
          (w) =>
              w is TextFormField &&
              w.initialValue == '' &&
              (w.key as ValueKey?)?.value is KV,
        ),
        '{{userId}}',
      );
      expect(r.pathVariables.single.value, '{{userId}}');
    });

    testWidgets('rows follow the URL and keep their values when it changes', (
      tester,
    ) async {
      final r = sample();
      await tester.pumpWidget(host(r, () {}));
      await tester.enterText(find.widgetWithText(TextFormField, '42'), '43');

      // What the request editor does on every URL keystroke.
      r.url = 'https://api.example.com/v2/users/:id';
      syncPathVariables(r);
      await tester.pumpWidget(host(r, () {}));
      expect(find.text(':id'), findsOneWidget);
      expect(find.text(':postId'), findsNothing);
      expect(find.widgetWithText(TextFormField, '43'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'The user'), findsOneWidget);

      r.url = 'https://api.example.com/v2/users';
      syncPathVariables(r);
      await tester.pumpWidget(host(r, () {}));
      expect(find.textContaining('No path variables'), findsOneWidget);
    });

    testWidgets('a request opened without rows still gets them', (
      tester,
    ) async {
      final r = RequestModel(url: 'https://x.dev/orders/:orderId');
      expect(r.pathVariables, isEmpty);
      await tester.pumpWidget(host(r, () {}));
      expect(keys(r), ['orderId']);
      expect(find.text(':orderId'), findsOneWidget);
    });

    testWidgets('says how to add one when the URL has none', (tester) async {
      await tester.pumpWidget(host(RequestModel(url: 'https://x.dev'), () {}));
      expect(find.textContaining('No path variables'), findsOneWidget);
    });

    testWidgets('bulk edit works on the query params', (tester) async {
      final r = sample();
      await tester.pumpWidget(host(r, () {}));
      await tester.tap(find.text('Bulk edit'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('kv-bulk-text')),
        'page: 3\n// sort: asc',
      );
      await tester.pump();
      expect(r.params.map((p) => p.key), ['page', 'sort']);
      expect(r.params.first.value, '3');
      expect(r.params.first.description, 'Which page');
      expect(r.params.last.enabled, isFalse);
      // The path variables are still below, untouched.
      expect(find.text('Path variables'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('long values do not overflow on a phone', (tester) async {
      await setSize(tester, const Size(360, 640));
      final r = RequestModel(
        url: 'https://x.dev/files/:a-very-long-path-variable-name-indeed',
        pathVariables: [
          KV(
            key: 'a-very-long-path-variable-name-indeed',
            value: 'https://example.com/${'long/' * 20}',
            description: 'A description that goes on and on ' * 4,
          ),
        ],
      );
      await tester.pumpWidget(host(r, () {}));
      expect(tester.takeException(), isNull);
    });
  });
}
