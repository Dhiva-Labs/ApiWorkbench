// Regression tests for flicker and jank: stale colours after a theme switch,
// effects replaying on tab switches, the outgoing response view changing
// mid-fade, drags rebuilding the panels, and editor tabs resetting.
import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/main.dart';
import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/sound_service.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/theme.dart';
import 'package:api_workbench/ui/request_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<(AppState, Storage, Directory)> _start(
  WidgetTester tester,
  Size size,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late Directory dir;
  late Storage storage;
  late AppState state;
  await tester.runAsync(() async {
    dir = await Directory.systemTemp.createTemp('aw_flicker_');
    storage = Storage(overrideDir: dir);
    state = AppState(
      storage: storage,
      sounds: SoundService(overrideDir: dir),
    );
    while (!state.loaded) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  });
  state.updateSettings(
    state.settings
      ..theme = AppThemeId.teal
      ..themeMode = ThemeModePref.light,
  );
  await tester.pumpWidget(ApiWorkbenchApp(state: state));
  await tester.pumpAndSettle();
  return (state, storage, dir);
}

Future<void> _finish(
  WidgetTester tester,
  AppState state,
  Storage _,
  Directory dir,
) async {
  await tester.pumpWidget(const SizedBox());
  state.dispose();
  Palette.use(PaletteData.tealLight);
  // Writes started inside the fake-async test zone never complete there,
  // so there is nothing to flush; just remove the directory.
  await tester.runAsync(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });
}

ResponseData _json(int status) => ResponseData(
  statusCode: status,
  statusMessage: status == 200 ? 'OK' : 'Error',
  headers: {
    'content-type': ['application/json'],
  },
  bodyBytes: utf8.encode('{"id": 42, "name": "Ada"}'),
);

final _confetti = find.byWidgetPredicate(
  (w) =>
      w is CustomPaint &&
      w.painter.runtimeType.toString() == '_ConfettiPainter',
);

void main() {
  testWidgets('a theme switch recolours everything in the same frame', (
    tester,
  ) async {
    final (state, storage, dir) = await _start(tester, const Size(1280, 800));
    state.updateSettings(state.settings..themeMode = ThemeModePref.dark);
    await tester.pump(); // exactly one frame

    // No cross-fade of the inherited theme...
    final ctx = tester.element(find.byType(RequestEditor));
    expect(Theme.of(ctx).colorScheme.surface, PaletteData.tealDark.surface);
    // ...and const widgets that read Palette (help icons) are rebuilt in
    // that same frame rather than one frame later.
    final icons = tester.widgetList<Icon>(find.byIcon(Icons.help_outline));
    expect(icons, isNotEmpty);
    for (final icon in icons) {
      expect(icon.color, PaletteData.tealDark.textDim.withValues(alpha: 0.85));
    }
    await _finish(tester, state, storage, dir);
  });

  testWidgets('switching tabs does not replay Chaos Mode effects', (
    tester,
  ) async {
    final (state, storage, dir) = await _start(tester, const Size(1280, 800));
    state.settings.chaosMode = true;
    state.activeTab!.response = _json(200);
    state.newTab();
    state.activeTab!.response = _json(500);
    state.notifyRefresh();
    await tester.pumpAndSettle();

    state.selectTab(0); // a different tab's response, not a new one
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(_confetti, findsNothing);
    await tester.pumpAndSettle();

    state.activeTab!.response = _json(200); // a new response on this tab
    state.notifyRefresh();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(_confetti, findsOneWidget);
    await tester.pumpAndSettle();
    await _finish(tester, state, storage, dir);
  });

  testWidgets('the outgoing response keeps its content while fading out', (
    tester,
  ) async {
    final (state, storage, dir) = await _start(tester, const Size(1280, 800));
    final tab = state.activeTab!..response = _json(200);
    state.notifyRefresh();
    await tester.pumpAndSettle();
    expect(find.text('200 OK'), findsOneWidget);

    // A new send starts: the view fades to the spinner.
    tab
      ..loading = true
      ..response = null;
    state.notifyRefresh();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60)); // mid cross-fade
    expect(find.text('200 OK'), findsOneWidget);
    expect(find.text('Sending request…'), findsOneWidget);

    tab.loading = false;
    state.notifyRefresh();
    await tester.pumpAndSettle();
    await _finish(tester, state, storage, dir);
  });

  testWidgets('dragging the splitter or panel edge rebuilds no content', (
    tester,
  ) async {
    final (state, storage, dir) = await _start(tester, const Size(1280, 800));
    state.activeTab!.response = _json(200);
    state.notifyRefresh();
    await tester.pumpAndSettle();

    final rebuilt = <String>[];
    const watched = {'RequestEditor', 'ResponseView', 'Sidebar', 'JsonView'};
    debugOnRebuildDirtyWidget = (e, _) {
      final type = e.widget.runtimeType.toString();
      if (watched.contains(type)) rebuilt.add(type);
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    final splitter = find.byWidgetPredicate(
      (w) => w is MouseRegion && w.cursor == SystemMouseCursors.resizeRow,
    );
    final editorBefore = tester.getSize(find.byType(RequestEditor)).height;
    await tester.drag(splitter, const Offset(0, 60));
    await tester.pump();
    expect(
      tester.getSize(find.byType(RequestEditor)).height,
      greaterThan(editorBefore),
    );

    final edge = find.byWidgetPredicate(
      (w) => w is MouseRegion && w.cursor == SystemMouseCursors.resizeColumn,
    );
    await tester.drag(edge, const Offset(40, 0));
    await tester.pump();
    debugOnRebuildDirtyWidget = null;
    expect(rebuilt, isEmpty);
    await _finish(tester, state, storage, dir);
  });

  testWidgets('phones keep the editor tab across Request and Response', (
    tester,
  ) async {
    final (state, storage, dir) = await _start(tester, const Size(390, 844));
    final bar = find.descendant(
      of: find.byType(RequestEditor),
      matching: find.byType(TabBar),
    );
    DefaultTabController.of(tester.element(bar)).index = 2; // Body
    await tester.pumpAndSettle();

    await tester.tap(find.text('Response'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Request'));
    await tester.pumpAndSettle();
    expect(DefaultTabController.of(tester.element(bar)).index, 2);
    await _finish(tester, state, storage, dir);
  });
}
