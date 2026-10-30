import 'dart:io';

import 'package:api_workbench/services/storage.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/theme.dart';
import 'package:api_workbench/ui/import_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

void main() {
  late Directory dir;

  Future<void> openDialog(WidgetTester tester) async {
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('aw_import_');
    });
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(storage: Storage(overrideDir: dir)),
        child: MaterialApp(
          theme: buildTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showImportDialog(context),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  Future<void> paste(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    // Long pasted text scrolls the field's own button out of reach on a
    // phone, so press it without a pointer.
    tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Add'))
        .onPressed!();
    await tester.pumpAndSettle();
  }

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  for (final size in [const Size(1100, 1000), const Size(320, 700)]) {
    testWidgets('the import dialog reads OpenAPI, HAR and the static-asset '
        'option at ${size.width.toInt()} px', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await openDialog(tester);

      // The copy names the new formats and the option is on by default.
      expect(
        find.textContaining('OpenAPI 3.x and Swagger 2.0'),
        findsOneWidget,
      );
      expect(find.textContaining('HAR'), findsWidgets);
      final option = find.widgetWithText(
        CheckboxListTile,
        'Skip static assets (images, fonts, CSS, JS)',
      );
      expect(option, findsOneWidget);
      expect(tester.widget<CheckboxListTile>(option).value, isTrue);

      // A HAR is read with the option on...
      await paste(tester, fixture('har/browser.har'));
      expect(find.textContaining('Ready to import'), findsOneWidget);
      expect(find.textContaining('HAR 1.2'), findsWidgets);
      expect(find.textContaining('— 7 requests'), findsOneWidget);
      expect(find.textContaining('Skipped 6 static assets'), findsOneWidget);

      // ...and again, without it, when the option is turned off.
      await tester.ensureVisible(option);
      await tester.tap(option);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(option).value, isFalse);
      expect(find.textContaining('— 13 requests'), findsOneWidget);
      expect(find.textContaining('Skipped 6 static assets'), findsNothing);

      // A spec added next joins the same summary.
      await paste(tester, fixture('openapi/petstore30.yaml'));
      expect(find.textContaining('OpenAPI 3.0'), findsWidgets);
      expect(
        find.textContaining('Petstore - OpenAPI 3.0 — 12 requests'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a capture of only static assets is fixed by the option', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await openDialog(tester);

    const onlyAssets =
        '{"log":{"entries":[{"request":{"method":"GET","url":"https://c.test/a.js"},'
        '"response":{"status":200}}]}}';
    await paste(tester, onlyAssets);
    expect(find.textContaining('Skip static assets'), findsWidgets);
    expect(find.textContaining('Ready to import'), findsNothing);

    final option = find.byType(CheckboxListTile);
    await tester.tap(option);
    await tester.pumpAndSettle();
    expect(find.textContaining('Ready to import'), findsOneWidget);
    expect(find.textContaining('— 1 request'), findsOneWidget);
  });

  testWidgets('unreadable text is reported with its source', (tester) async {
    tester.view.physicalSize = const Size(1100, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await openDialog(tester);
    await paste(tester, 'this is nothing');
    expect(
      find.textContaining('Pasted text: Not a supported file'),
      findsOneWidget,
    );
  });
}
