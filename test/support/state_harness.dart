import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// An [AppState] over a temporary data folder, for widget tests.
///
/// Saving runs partly on the real event loop (file I/O) and partly in the
/// test's fake zone, so [drain] turns both until the writes are done.
class StateHarness {
  late Directory dir;
  late Storage storage;
  late AppState state;

  Future<void> setUp(WidgetTester tester) async {
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('aw_widget');
      storage = Storage(overrideDir: dir);
      state = AppState(storage: storage);
      while (!state.loaded) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
  }

  /// Waits for queued writes to reach the disk.
  Future<void> drain(WidgetTester tester) async {
    var done = false;
    storage.flush().then((_) => done = true);
    for (var i = 0; i < 200 && !done; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(done, isTrue, reason: 'writes did not finish');
  }

  Future<void> tearDown(WidgetTester tester) async {
    await drain(tester);
    await tester.runAsync(() => dir.delete(recursive: true));
  }

  /// The collections as saved on disk.
  Future<List<CollectionModel>> saved(WidgetTester tester) async {
    await drain(tester);
    return (await tester.runAsync(
      () => Storage(overrideDir: dir).loadCollections(),
    ))!;
  }
}

/// A page with one button, "open", that runs [show] with its context.
Widget opener(ThemeData theme, Future<void> Function(BuildContext) show) =>
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: Builder(
          builder: (ctx) =>
              TextButton(onPressed: () => show(ctx), child: const Text('open')),
        ),
      ),
    );
