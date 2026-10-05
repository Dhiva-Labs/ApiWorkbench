import 'dart:async';
import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/http_service.dart';
import 'package:api_workbench/services/runner.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/theme.dart';
import 'package:api_workbench/ui/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class FakeHttp extends HttpService {
  int count = 0;
  Completer<ResponseData>? pending;

  @override
  Future<ResponseData> send(
    RequestModel r,
    Map<String, String> vars, {
    required String tabId,
  }) async {
    if (pending != null) return pending!.future;
    count++;
    return ResponseData(
      statusCode: 200,
      durationMs: count,
      bodyBytes: List.filled(100000, 65),
    );
  }
}

void main() {
  test(
    'large previews are bounded without truncating the original response',
    () {
      final response = ResponseData(bodyBytes: List.filled(1024 * 1024, 65));
      expect(response.previewTruncated, isTrue);
      expect(response.bodyPreview.length, ResponseData.previewByteLimit);
      expect(identical(response.bodyPreview, response.bodyPreview), isTrue);
      expect(response.bodyText.length, 1024 * 1024);
      expect(response.sizeBytes, 1024 * 1024);
    },
  );

  test(
    'runner bounds retained results without losing aggregate statistics',
    () async {
      final http = FakeHttp();
      final runner = RunnerService(http, maxResults: 3);
      await runner.start(requests: [RequestModel()], vars: {}, iterations: 10);
      expect(runner.results.length, 3);
      expect(runner.results.first.iteration, 8);
      expect(runner.results.every((r) => r.response.bodyBytes.isEmpty), isTrue);
      expect(runner.total, 10);
      expect(runner.passed, 10);
      expect(runner.failed, 0);
      expect(runner.avgMs, 5);
      expect(runner.minMs, 1);
      expect(runner.maxMs, 10);
      runner.dispose();
      http.dispose();
    },
  );

  test(
    'disposing during a send drops the response and does not notify',
    () async {
      final http = FakeHttp()..pending = Completer<ResponseData>();
      final runner = RunnerService(http);
      final done = runner.start(requests: [RequestModel()], vars: {});
      runner.dispose();
      http.pending!.complete(ResponseData(statusCode: 200));
      await done;
      expect(runner.results, isEmpty);
      http.dispose();
    },
  );

  for (final width in [320.0, 390.0, 768.0]) {
    testWidgets('request and response fit a $width pixel viewport', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory dir;
      late Storage storage;
      late AppState state;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('mobile_test');
        storage = Storage(overrideDir: dir);
        state = AppState(storage: storage);
        while (!state.loaded) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      await tester.runAsync(() async {
        state.addEnvironment(
          'A long development environment name for small phones',
        );
        await storage.flush();
      });
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(theme: buildTheme(), home: const HomeScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Send'), findsOneWidget);
      expect(state.activeTab!.response, isNull);
      state.activeTab!.response = ResponseData(
        statusCode: 200,
        statusMessage: 'OK',
        protocol: '2',
        bodyBytes: List.filled(100000, 65),
        headers: {
          'content-type': ['text/plain'],
        },
      );
      state.notifyRefresh();
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Workspace menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings…'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Response'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Preview limited'), findsWidgets);
      await tester.tap(find.text('Headers (1)'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Request'));
      await tester.pumpAndSettle();
      // Phone rotation must not select a cramped desktop layout.
      tester.view.physicalSize = const Size(952, 426);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(tester.takeException(), isNull);
      // Landscape with the software keyboard leaves little vertical room.
      tester.view.viewInsets = const FakeViewPadding(bottom: 200);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
      await tester.runAsync(() async {
        await storage.flush();
        await dir.delete(recursive: true);
      });
    });
  }
}
