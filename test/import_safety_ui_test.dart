import 'dart:convert';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/theme.dart';
import 'package:api_workbench/ui/import_dialog.dart';
import 'package:api_workbench/ui/script_consent_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/state_harness.dart';

/// A Postman data export: one collection with a script and a file upload,
/// plus globals.
String dump() => jsonEncode({
  'version': 1,
  'collections': [
    {
      'info': {'name': 'Shared', 'schema': 'collection/v2.1.0'},
      'event': [
        {
          'listen': 'prerequest',
          'script': {'exec': 'console.log("hi")'},
        },
      ],
      'item': [
        {
          'name': 'Upload',
          'request': {
            'method': 'POST',
            'url': 'https://x.test/upload',
            'body': {
              'mode': 'formdata',
              'formdata': [
                {'key': 'doc', 'type': 'file', 'src': '/home/me/report.pdf'},
              ],
            },
          },
        },
      ],
    },
  ],
  'globals': [
    {
      'values': [
        {'key': 'host', 'value': 'theirs.test'},
        {'key': 'fresh', 'value': 'new'},
      ],
    },
  ],
});

void main() {
  final h = StateHarness();

  Future<void> open(
    WidgetTester tester,
    AppState state,
    Future<void> Function(BuildContext) show,
  ) async {
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: opener(buildTheme(), show),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('the script question returns what the user picks', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await h.setUp(tester);
    const c = ScriptConsentQuestion(name: 'Shop API', scripts: 4);
    final answers = <ScriptConsent>[];
    for (final button in [
      'Allow scripts',
      'Run without scripts',
      'Cancel',
      null, // tapping outside
    ]) {
      await open(tester, h.state, (ctx) async {
        answers.add(await showScriptConsentDialog(ctx, c));
      });
      expect(find.text('Run scripts from "Shop API"?'), findsOneWidget);
      expect(find.textContaining('has 4 scripts'), findsOneWidget);
      if (button == null) {
        await tester.tapAt(const Offset(5, 5));
      } else {
        await tester.tap(find.text(button));
      }
      await tester.pumpAndSettle();
    }
    expect(answers, [
      ScriptConsent.allow,
      ScriptConsent.skipScripts,
      ScriptConsent.cancel,
      ScriptConsent.cancel,
    ]);
    expect(tester.takeException(), isNull);
    await h.tearDown(tester);
  });

  testWidgets('a request reopened from History is asked about as such', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await h.setUp(tester);
    ScriptConsent? answer;
    await open(tester, h.state, (ctx) async {
      answer = await showScriptConsentDialog(
        ctx,
        const ScriptConsentQuestion(
          name: 'Get user',
          scripts: 1,
          request: true,
        ),
      );
    });
    expect(find.text('Run scripts from "Get user"?'), findsOneWidget);
    expect(
      find.textContaining('This request came from an imported collection'),
      findsOneWidget,
    );
    expect(find.textContaining('has 1 script ('), findsOneWidget);
    expect(find.textContaining('remembered for this request'), findsOneWidget);
    await tester.tap(find.text('Run without scripts'));
    await tester.pumpAndSettle();
    expect(answer, ScriptConsent.skipScripts);
    await h.tearDown(tester);
  });

  testWidgets('the import summary counts scripts and cleared files, and '
      'existing globals are kept unless replaced', (tester) async {
    tester.view.physicalSize = const Size(1100, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await h.setUp(tester);
    final state = h.state;
    state.globals.add(KV(key: 'host', value: 'mine.test'));

    await open(tester, state, (ctx) => showImportDialog(ctx));
    await tester.enterText(find.byType(TextField), dump());
    tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Add'))
        .onPressed!();
    await tester.pumpAndSettle();

    expect(find.textContaining('1 script imported.'), findsOneWidget);
    expect(find.textContaining('asks before running them'), findsOneWidget);
    expect(
      find.textContaining('1 file path(s) were not imported'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Import').last);
    await tester.pumpAndSettle();
    expect(find.text('Replace the global "host"?'), findsOneWidget);
    await tester.tap(find.text('Keep mine'));
    await tester.pumpAndSettle();

    expect(kvMap(state.globals), {'host': 'mine.test', 'fresh': 'new'});
    final c = state.collections.single;
    expect(c.name, 'Shared');
    expect(c.untrusted, isTrue);
    final doc = c.requests.single.formFields.single;
    expect(doc.isFile, isTrue);
    expect(doc.value, isEmpty);
    expect(tester.takeException(), isNull);
    await h.tearDown(tester);
  });

  testWidgets('replacing globals, or cancelling the import', (tester) async {
    tester.view.physicalSize = const Size(1100, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await h.setUp(tester);
    final state = h.state;
    state.globals.add(KV(key: 'host', value: 'mine.test'));

    Future<void> importDump() async {
      await open(tester, state, (ctx) => showImportDialog(ctx));
      await tester.enterText(find.byType(TextField), dump());
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Add'))
          .onPressed!();
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Import').last);
      await tester.pumpAndSettle();
    }

    await importDump();
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(state.collections, isEmpty, reason: 'nothing was imported');
    expect(kvMap(state.globals), {'host': 'mine.test'});
    // The import dialog is still open.
    await tester.tap(find.widgetWithText(FilledButton, 'Import').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();
    expect(kvMap(state.globals), {'host': 'theirs.test', 'fresh': 'new'});
    expect(state.collections.single.untrusted, isTrue);
    expect(tester.takeException(), isNull);
    await h.tearDown(tester);
  });
}
