import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/theme.dart';
import 'package:api_workbench/ui/export_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Future<AppState> _state(WidgetTester tester, {bool withData = true}) async {
  late AppState state;
  late Directory dir;
  await tester.runAsync(() async {
    dir = await Directory.systemTemp.createTemp('aw_export_');
    state = AppState(storage: Storage(overrideDir: dir));
    while (!state.loaded) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  });
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    state.dispose();
    await tester.runAsync(() => dir.delete(recursive: true));
  });
  if (withData) {
    state.collections
      ..clear()
      ..add(CollectionModel(name: 'Shop API'))
      ..add(CollectionModel(name: 'Admin API'));
    state.environments
      ..clear()
      ..add(EnvironmentModel(name: 'Staging'));
    state.globals
      ..clear()
      ..add(KV(key: 'tenant', value: 'acme'));
  }
  return state;
}

Future<void> _open(
  WidgetTester tester,
  AppState state, {
  CollectionModel? collection,
}) async {
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        theme: buildTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  showExportDialog(context, collection: collection),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  for (final size in const [Size(1100, 900), Size(320, 640)]) {
    testWidgets(
      'export dialog offers every format at ${size.width.toInt()} px',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final state = await _state(tester);
        await _open(tester, state);

        for (final label in [
          'ApiWorkbench workspace',
          'Postman collection',
          'Postman environment',
          'Postman globals',
          'OpenAPI 3.0',
        ]) {
          expect(find.text(label), findsOneWidget, reason: label);
        }
        expect(find.text('Include current values'), findsOneWidget);
        expect(find.text('Export'), findsWidgets);

        await tester.tap(find.text('Postman collection'));
        await tester.pumpAndSettle();
        expect(find.text('Collection'), findsOneWidget);
        expect(find.text('Shop API'), findsOneWidget);
        expect(find.text('Include current values'), findsOneWidget);

        await tester.tap(find.text('Postman environment'));
        await tester.pumpAndSettle();
        expect(find.text('Environment'), findsOneWidget);
        expect(find.text('Staging'), findsOneWidget);

        await tester.tap(find.text('OpenAPI 3.0'));
        await tester.pumpAndSettle();
        expect(find.text('Collection'), findsOneWidget);
        expect(find.text('File type'), findsOneWidget);
        expect(find.text('JSON'), findsOneWidget);
        expect(find.text('YAML'), findsOneWidget);
        expect(
          find.text('Include current values'),
          findsNothing,
          reason: 'an OpenAPI document holds no variable values',
        );
        await tester.ensureVisible(find.text('YAML'));
        await tester.tap(find.text('YAML'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('a collection from the sidebar preselects the Postman export', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = await _state(tester);
    await _open(tester, state, collection: state.collections[1]);
    expect(find.text('Collection'), findsOneWidget);
    expect(find.text('Admin API'), findsOneWidget);
    expect(find.text('Environment'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('formats with nothing to export are disabled', (tester) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = await _state(tester, withData: false);
    await _open(tester, state);
    expect(find.textContaining('Nothing to export yet'), findsOneWidget);
    final export = find.widgetWithText(FilledButton, 'Export');
    expect(tester.widget<FilledButton>(export).onPressed, isNull);
    await tester.tap(find.text('OpenAPI 3.0'));
    await tester.pumpAndSettle();
    expect(find.text('File type'), findsNothing, reason: 'tile is disabled');
    expect(tester.takeException(), isNull);
  });
}
