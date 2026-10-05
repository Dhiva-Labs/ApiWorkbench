import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/theme.dart';
import 'package:api_workbench/ui/load_test_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('load test screen runs a collection and shows stats', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late HttpServer server;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('aw_load_');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) {
        r.response
          ..headers.contentType = ContentType.json
          ..write('{"ok":true}')
          ..close();
      });
    });
    final url = 'http://127.0.0.1:${server.port}/ping';

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(storage: Storage(overrideDir: dir)),
        child: MaterialApp(
          theme: buildTheme(),
          home: LoadTestScreen(
            title: 'Demo',
            requests: [RequestModel(name: 'Ping', url: url)],
          ),
        ),
      ),
    );
    expect(find.text('Load test • Demo'), findsOneWidget);

    await tester.tap(find.text('Run'));
    // Let real file and network I/O happen until the run renders as done.
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      if (find.textContaining('Finished in').evaluate().isNotEmpty) break;
    }

    expect(find.textContaining('Finished in'), findsOneWidget);
    expect(find.text('50'), findsWidgets); // 5 users x 10 iterations
    expect(find.text('Throughput (requests / second)'), findsOneWidget);
    expect(find.text('Request log'), findsOneWidget);
    expect(find.text('50 calls logged'), findsOneWidget);
    expect(find.text('Save report'), findsOneWidget);
    await tester.tap(find.text('Save report'));
    await tester.pumpAndSettle();
    expect(find.text('HTML report (summary + log)'), findsOneWidget);
    expect(find.text('CSV log (every call)'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5)); // close the menu
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.runAsync(() async {
      await server.close(force: true);
      await dir.delete(recursive: true);
    });
  });
}
