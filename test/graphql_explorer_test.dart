import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/graphql_schema.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/theme.dart';
import 'package:api_workbench/ui/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'graphql_schema_test.dart' show introspectionFixture;

/// Widget tests answer every HttpClient request with a 400 unless the
/// override is lifted; these tests talk to a real local server.
void _realHttp() {
  final saved = HttpOverrides.current;
  HttpOverrides.global = null;
  addTearDown(() => HttpOverrides.global = saved);
}

/// Lets real network and file I/O run until [done] holds.
Future<void> _settle(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 50 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

void main() {
  for (final width in [320.0, 1100.0]) {
    testWidgets('GraphQL schema tools at $width px', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      _realHttp();
      graphqlSchemaCache.clear();

      late HttpServer server;
      late Directory dir;
      late AppState state;
      final seen = <Map<String, String?>>[];
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('aw_graphql_');
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((r) async {
          final body = jsonDecode(await utf8.decodeStream(r)) as Map;
          seen.add({
            'method': r.method,
            'auth': r.headers.value('authorization'),
            'key': r.headers.value('x-api'),
            'query': '${body['query']}'.contains('__schema') ? 'intro' : '',
          });
          r.response
            ..headers.contentType = ContentType.json
            ..write(introspectionFixture)
            ..close();
        });
        state = AppState(storage: Storage(overrideDir: dir));
        while (!state.loaded) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      state.globals.add(KV(key: 'apiKey', value: 'k1'));
      final request = RequestModel(
        name: 'Blog',
        method: 'GET', // introspection is always POSTed
        url: 'http://127.0.0.1:${server.port}/graphql',
        bodyType: BodyType.graphql,
        headers: [KV(key: 'X-Api', value: '{{apiKey}}')],
        authType: AuthType.bearer,
        bearerToken: 'tok',
      );
      state.newTab(request);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(theme: buildTheme(), home: const HomeScreen()),
        ),
      );
      await tester.pumpAndSettle();
      final bodyTab = find.descendant(
        of: find.byType(TabBar),
        matching: find.text('Body • GraphQL'),
      );
      await tester.ensureVisible(bodyTab);
      await tester.pumpAndSettle();
      await tester.tap(bodyTab);
      await tester.pumpAndSettle();
      expect(find.text('No schema'), findsOneWidget);

      await tester.tap(find.text('Fetch schema'));
      await _settle(tester, () => find.text('14 types').evaluate().isNotEmpty);
      expect(find.text('14 types'), findsOneWidget);
      expect(seen.single, {
        'method': 'POST',
        'auth': 'Bearer tok',
        'key': 'k1',
        'query': 'intro',
      });
      expect(tester.takeException(), isNull);

      // Explorer: open Query, insert user (its id becomes a variable).
      await tester.tap(find.text('Explorer'));
      await tester.pumpAndSettle();
      expect(find.text('Schema explorer'), findsOneWidget);
      await tester.tap(find.text('Query  ·  Query'));
      await tester.pumpAndSettle();
      final userRow = find.ancestor(
        of: find.textContaining('user(id: ID!)', findRichText: true),
        matching: find.byType(ListTile),
      );
      await tester.tap(
        find.descendant(
          of: userRow,
          matching: find.byIcon(Icons.add_circle_outline),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Added user with variables \$id.'), findsOneWidget);
      expect(request.body, contains('user(id: \$id) {'));
      expect(jsonDecode(request.graphqlVariables), {'id': ''});

      // Browse into User and insert a nested field.
      await tester.tap(
        find.textContaining('user(id: ID!)', findRichText: true),
      );
      await tester.pumpAndSettle();
      expect(find.text('Query › user'), findsOneWidget);
      final friendsRow = find.ancestor(
        of: find.textContaining('friends', findRichText: true),
        matching: find.byType(ListTile),
      );
      await tester.tap(
        find.descendant(
          of: friendsRow,
          matching: find.byIcon(Icons.add_circle_outline),
        ),
      );
      await tester.pumpAndSettle();
      expect(request.body, contains('    friends {\n      id\n'));
      expect(tester.takeException(), isNull);
      await tester.tap(
        width < 600 ? find.byType(CloseButton) : find.text('Close'),
      );
      await tester.pumpAndSettle();

      // Suggestions follow the cursor; tapping one inserts it.
      final query = find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            (w.decoration?.hintText?.startsWith('query Users') ?? false),
      );
      await tester.enterText(query, '{ user(id: 1) { po');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ActionChip, 'posts'), findsOneWidget);
      await tester.tap(find.widgetWithText(ActionChip, 'posts'));
      await tester.pumpAndSettle();
      expect(request.body, '{ user(id: 1) { posts {  }');

      await tester.enterText(query, '{user{id name}}');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prettify'));
      await tester.pumpAndSettle();
      expect(request.body, '{\n  user {\n    id\n    name\n  }\n}');
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      state.dispose();
      await tester.runAsync(() async {
        await server.close(force: true);
        await dir.delete(recursive: true);
      });
    });
  }

  testWidgets('a failed fetch shows the error in the status chip', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    _realHttp();
    graphqlSchemaCache.clear();
    late HttpServer server;
    late Directory dir;
    late AppState state;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('aw_graphql_err_');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) async {
        await r.drain<void>();
        r.response
          ..statusCode = 400
          ..headers.contentType = ContentType.json
          ..write('{"errors": [{"message": "introspection disabled"}]}')
          ..close();
      });
      state = AppState(storage: Storage(overrideDir: dir));
      while (!state.loaded) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    state.newTab(
      RequestModel(
        method: 'POST',
        url: 'http://127.0.0.1:${server.port}/graphql',
        bodyType: BodyType.graphql,
      ),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(theme: buildTheme(), home: const HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final bodyTab = find.descendant(
      of: find.byType(TabBar),
      matching: find.text('Body • GraphQL'),
    );
    await tester.ensureVisible(bodyTab);
    await tester.pumpAndSettle();
    await tester.tap(bodyTab);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fetch schema'));
    const message =
        'HTTP 400: The server answered with errors: introspection disabled';
    await _settle(tester, () => find.text(message).evaluate().isNotEmpty);
    expect(find.text(message), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    state.dispose();
    await tester.runAsync(() async {
      await server.close(force: true);
      await dir.delete(recursive: true);
    });
  });
}
