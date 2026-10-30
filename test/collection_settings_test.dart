import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/theme.dart';
import 'package:api_workbench/ui/collection_settings_dialog.dart';
import 'package:api_workbench/ui/request/auth_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/state_harness.dart';
import 'support/test_fonts.dart';

void main() {
  setUpAll(loadRoboto);

  final h = StateHarness();
  late AppState state;
  late CollectionModel col;

  Future<void> setUpState(WidgetTester tester) async {
    await h.setUp(tester);
    state = h.state;
    col = state.addCollection('Shop');
    col.requests.add(RequestModel(name: 'A', folder: 'Orders/Refunds'));
  }

  Future<void> tearDownState(WidgetTester tester) => h.tearDown(tester);

  Future<List<CollectionModel>> savedCollections(WidgetTester tester) =>
      h.saved(tester);

  Future<void> open(
    WidgetTester tester,
    Future<void> Function(BuildContext) show,
  ) async {
    await tester.pumpWidget(opener(buildTheme(), show));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder tab(String label) => find.widgetWithText(Tab, label);

  testWidgets('collection dialog has Auth, Scripts, Docs and Variables', (
    tester,
  ) async {
    await setUpState(tester);
    await open(tester, (ctx) => showCollectionSettings(ctx, state, col));

    expect(find.text('Shop settings'), findsOneWidget);
    for (final t in ['Auth', 'Scripts', 'Docs', 'Variables']) {
      expect(tab(t), findsOneWidget, reason: t);
    }
    // A collection cannot inherit.
    final editor = tester.widget<AuthEditor>(find.byType(AuthEditor));
    expect(editor.allowInherit, isFalse);
    expect(identical(editor.auth, col.auth), isTrue);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tearDownState(tester);
  });

  testWidgets('auth edits go straight to the collection', (tester) async {
    await setUpState(tester);
    await open(tester, (ctx) => showCollectionSettings(ctx, state, col));

    await tester.tap(find.byType(DropdownButtonFormField<AuthType>));
    await tester.pumpAndSettle();
    expect(find.text('Inherit from parent'), findsNothing);
    await tester.tap(find.text('Bearer Token').last);
    await tester.pumpAndSettle();
    expect(col.auth.type, AuthType.bearer);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    // Closing saves, even inside the typing pause.
    final saved = await savedCollections(tester);
    expect(saved.single.auth.type, AuthType.bearer);
    await tearDownState(tester);
  });

  testWidgets('scripts, docs and variables are edited in place', (
    tester,
  ) async {
    await setUpState(tester);
    await open(tester, (ctx) => showCollectionSettings(ctx, state, col));

    await tester.tap(tab('Scripts'));
    await tester.pumpAndSettle();
    final scripts = find.byType(TextField);
    expect(scripts, findsNWidgets(2));
    await tester.enterText(scripts.first, 'pm.environment.set("a", 1);');
    await tester.enterText(scripts.last, 'pm.test("ok", () => {});');
    expect(col.preRequestScript, 'pm.environment.set("a", 1);');
    expect(col.testScript, 'pm.test("ok", () => {});');
    final style = tester.widget<TextField>(scripts.first).style!;
    expect(style.fontFamily, 'monospace');

    await tester.tap(tab('Docs'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Orders and refunds.');
    expect(col.description, 'Orders and refunds.');

    await tester.tap(tab('Variables'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add variable'));
    await tester.pumpAndSettle();
    expect(col.variables, hasLength(1));
    // Columns: name, initial value, current value.
    await tester.enterText(find.byType(TextField).at(0), 'baseUrl');
    await tester.enterText(find.byType(TextField).at(1), 'https://x.dev');
    expect(col.variables.single.key, 'baseUrl');
    expect(col.variables.single.value, 'https://x.dev');

    // Scripts come back as typed when the tab is revisited.
    await tester.tap(tab('Scripts'));
    await tester.pumpAndSettle();
    expect(find.text('pm.test("ok", () => {});'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    final saved = (await savedCollections(tester)).single;
    expect(saved.preRequestScript, contains('pm.environment.set'));
    expect(saved.testScript, contains('pm.test'));
    expect(saved.description, 'Orders and refunds.');
    expect(saved.variables.single.key, 'baseUrl');
    await tearDownState(tester);
  });

  testWidgets('saving waits for a pause in typing and happens once', (
    tester,
  ) async {
    await setUpState(tester);
    var saves = 0;
    state.addListener(() => saves++);
    await open(tester, (ctx) => showCollectionSettings(ctx, state, col));

    await tester.tap(tab('Docs'));
    await tester.pumpAndSettle();
    saves = 0;
    for (final text in ['a', 'ab', 'abc']) {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(saves, 0);
    await tester.pump(const Duration(milliseconds: 500));
    expect(saves, 1);

    // An edit followed by closing is saved on close.
    await tester.enterText(find.byType(TextField), 'abcd');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(saves, 2);
    expect(col.description, 'abcd');
    await tearDownState(tester);
  });

  testWidgets('folder dialog inherits by default and has no variables', (
    tester,
  ) async {
    await setUpState(tester);
    col.auth = AuthConfig(type: AuthType.bearer, bearerToken: 'tok');
    await open(
      tester,
      (ctx) => showFolderSettings(ctx, state, col, 'Orders/Refunds'),
    );

    expect(find.text('Refunds settings'), findsOneWidget);
    expect(tab('Variables'), findsNothing);
    for (final t in ['Auth', 'Scripts', 'Docs']) {
      expect(tab(t), findsOneWidget, reason: t);
    }
    final editor = tester.widget<AuthEditor>(find.byType(AuthEditor));
    expect(editor.allowInherit, isTrue);
    expect(editor.auth.type, AuthType.inherit);
    expect(editor.inheritedFrom, 'Bearer Token from the collection Shop');
    expect(identical(editor.auth, col.folders['Orders/Refunds']!.auth), isTrue);

    await tester.tap(tab('Scripts'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'console.log(1)');
    await tester.tap(tab('Docs'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Refund flows.');

    final meta = col.folders['Orders/Refunds']!;
    expect(meta.preRequestScript, 'console.log(1)');
    expect(meta.description, 'Refund flows.');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tearDownState(tester);
  });

  testWidgets('a folder names the nearest parent that sets auth', (
    tester,
  ) async {
    await setUpState(tester);
    col.folders['Orders'] = FolderMeta(
      auth: AuthConfig(type: AuthType.basic, basicUser: 'ada'),
    );
    await open(
      tester,
      (ctx) => showFolderSettings(ctx, state, col, 'Orders/Refunds'),
    );
    final editor = tester.widget<AuthEditor>(find.byType(AuthEditor));
    expect(editor.inheritedFrom, 'Basic Auth from the folder Orders');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tearDownState(tester);
  });

  testWidgets('works on a 320 px phone without overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await setUpState(tester);
    await open(tester, (ctx) => showCollectionSettings(ctx, state, col));

    expect(find.byType(Dialog), findsOneWidget);
    expect(
      tester.widget<Dialog>(find.byType(Dialog)).insetPadding,
      EdgeInsets.zero,
    );
    for (final t in ['Scripts', 'Docs', 'Variables', 'Auth']) {
      await tester.tap(tab(t));
      await tester.pumpAndSettle();
    }
    await tester.tap(tab('Variables'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add variable'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    await tearDownState(tester);
  });
}
