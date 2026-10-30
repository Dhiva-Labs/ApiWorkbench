import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/theme.dart';
import 'package:api_workbench/ui/protocols/protocol_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// Opens [request] in a tab of a fresh [AppState] and shows its editor and
/// message log side by side at [size], like the desktop layout.
Future<(AppState, RequestTab)> pump(
  WidgetTester tester,
  RequestModel request,
  Size size, {
  bool logOnly = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late Directory dir;
  await tester.runAsync(() async {
    dir = await Directory.systemTemp.createTemp('aw_proto_');
  });
  final state = AppState(storage: Storage(overrideDir: dir));
  state.newTab(request);
  final tab = state.activeTab!;
  addTearDown(() async {
    (tab.session as TabSession?)?.close();
    await tester.runAsync(() => dir.delete(recursive: true));
  });
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: logOnly
              ? ProtocolMessages(key: ValueKey('${tab.id}-log'), tab: tab)
              : ProtocolEditor(key: ValueKey(tab.id), tab: tab),
        ),
      ),
    ),
  );
  await tester.pump();
  return (state, tab);
}

void main() {
  final kinds = {
    RequestKind.websocket: ['Message', 'Params', 'Headers', 'Settings'],
    RequestKind.socketio: ['Emit', 'Listen', 'Handshake', 'Params', 'Headers'],
    RequestKind.mqtt: [
      'Connection',
      'Subscribe',
      'Publish',
      'Last will',
      'Headers',
    ],
    RequestKind.sse: ['Params', 'Headers', 'Body', 'Settings'],
  };
  final sizes = {
    '320x568': const Size(320, 568),
    '360x640': const Size(360, 640),
    '1280x800': const Size(1280, 800),
  };

  for (final kind in kinds.keys) {
    for (final entry in sizes.entries) {
      testWidgets('${kind.label} editor fits at ${entry.key}', (tester) async {
        await pump(tester, newRequestOfKind(kind), entry.value);
        for (final label in kinds[kind]!) {
          final tabFinder = find.descendant(
            of: find.byType(TabBar),
            matching: find.textContaining(label),
          );
          expect(tabFinder, findsWidgets, reason: 'tab $label');
          await tester.ensureVisible(tabFinder.first);
          await tester.pumpAndSettle();
          await tester.tap(tabFinder.first);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'tab $label');
        }
      });

      testWidgets('${kind.label} log fits at ${entry.key}', (tester) async {
        final (_, tab) = await pump(
          tester,
          newRequestOfKind(kind),
          entry.value,
          logOnly: true,
        );
        expect(tab.session, isNotNull);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
