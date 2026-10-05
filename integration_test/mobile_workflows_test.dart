import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/main.dart' as app;
import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/http_service.dart';
import 'package:api_workbench/services/runner.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:api_workbench/services/sound_service.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/ui/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;
  late String base;

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      if (request.uri.path == '/slow') {
        await Future<void>.delayed(const Duration(seconds: 3));
      }
      request.response.headers.contentType = ContentType.json;
      request.response.headers.set('x-device-test', 'android');
      if (request.uri.path == '/status') request.response.statusCode = 422;
      request.response.write(
        jsonEncode({
          'method': request.method,
          'query': request.uri.queryParameters,
          'body': body,
          'authorization': request.headers.value('authorization'),
          'message': 'device-response-ok',
          if (request.uri.path == '/large') 'data': 'x' * (2 * 1024 * 1024),
        }),
      );
      try {
        await request.response.close();
      } catch (_) {
        // Cancellation tests deliberately disconnect before the fixture replies.
      }
    });
  });
  tearDownAll(() => server.close(force: true));

  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(done(), isTrue, reason: 'Timed out waiting for device workflow');
  }

  Finder urlField() => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.keyboardType == TextInputType.url,
  );

  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> hideKeyboard(WidgetTester tester) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Android: edit, send, response, save, history, settings, cancellation and restart',
    (tester) async {
      app.main();
      await tester.pump();
      final state = tester.element(find.byType(HomeScreen)).read<AppState>();
      await until(tester, () => state.loaded);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      debugPrint('DEVICE CHECK: cold launch and mobile navigation');

      await tester.enterText(urlField(), '$base/echo?name=phone');
      await hideKeyboard(tester);
      await tester.tap(find.text('Send'));
      await until(tester, () => !state.activeTab!.loading);
      expect(state.activeTab!.response!.statusCode, 200);
      expect(state.activeTab!.response!.bodyText, contains('phone'));
      await tap(tester, find.text('Response'));
      expect(find.textContaining('device-response-ok'), findsWidgets);
      await tap(tester, find.text('Raw'));
      expect(find.textContaining('device-response-ok'), findsWidgets);
      await tap(tester, find.textContaining('Headers ('));
      expect(find.text('x-device-test'), findsOneWidget);
      await tap(tester, find.byTooltip('Copy body'));
      expect(
        (await Clipboard.getData(Clipboard.kTextPlain))!.text,
        contains('phone'),
      );
      debugPrint(
        'DEVICE CHECK: GET, query, pretty/raw, headers and native clipboard',
      );

      await tap(tester, find.text('Request'));
      await tap(tester, find.byTooltip('More'));
      await tap(tester, find.text('Save to collection…'));
      Finder labeled(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      );
      await tester.enterText(labeled('Request name'), 'Android device smoke');
      final newCollection = find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            (w.decoration?.labelText ?? '').contains('collection'),
      );
      await tester.enterText(newCollection, 'Device QA');
      await hideKeyboard(tester);
      await tap(tester, find.widgetWithText(FilledButton, 'Save'));
      expect(state.collections.any((c) => c.name == 'Device QA'), isTrue);
      await tap(tester, find.byTooltip('Open navigation menu'));
      expect(find.text('Device QA'), findsWidgets);
      await tap(tester, find.byTooltip('History'));
      expect(find.textContaining('/echo?name=phone'), findsWidgets);
      Navigator.of(tester.element(find.byType(HomeScreen))).pop();
      await tester.pumpAndSettle();
      debugPrint('DEVICE CHECK: collection save and history drawer');

      await tap(tester, find.byTooltip('Workspace menu'));
      await tap(tester, find.text('Settings…'));
      expect(find.text('Verify TLS certificates'), findsOneWidget);
      await tap(tester, find.widgetWithText(FilledButton, 'Save'));
      debugPrint('DEVICE CHECK: settings open/save');

      // Populate rich request data, then send it through the real editor button.
      state.newTab(
        RequestModel(
          url: '$base/echo',
          method: 'POST',
          bodyType: BodyType.json,
          body: '{"hello":"android"}',
          authType: AuthType.bearer,
          bearerToken: 'device-token',
          assertions: [
            AssertionModel(kind: AssertKind.statusEquals, expected: '200'),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send'));
      await until(tester, () => !state.activeTab!.loading);
      final echoed = jsonDecode(state.activeTab!.response!.bodyText) as Map;
      expect(echoed['method'], 'POST');
      expect(echoed['body'], '{"hello":"android"}');
      expect(echoed['authorization'], 'Bearer device-token');
      expect(state.activeTab!.assertionResults.single.pass, isTrue);
      await tap(tester, find.text('Response'));
      await tap(tester, find.text('Tests (1/1)'));
      expect(find.textContaining('expected 200, got 200'), findsOneWidget);
      debugPrint('DEVICE CHECK: POST JSON, bearer auth and assertion results');

      await tap(tester, find.text('Request'));
      await tester.enterText(urlField(), '$base/status');
      await hideKeyboard(tester);
      await tester.tap(find.text('Send'));
      await until(tester, () => !state.activeTab!.loading);
      expect(state.activeTab!.response!.statusCode, 422);
      await tap(tester, find.text('Response'));
      expect(find.textContaining('422'), findsWidgets);
      debugPrint('DEVICE CHECK: HTTP error response');

      await tap(tester, find.text('Request'));
      await tester.enterText(urlField(), '$base/slow');
      await hideKeyboard(tester);
      await tester.tap(find.text('Send'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Cancel'));
      await until(tester, () => !state.activeTab!.loading);
      expect(state.activeTab!.response!.error, contains('cancelled'));
      await tap(tester, find.text('Response'));
      expect(find.text('Request cancelled.'), findsOneWidget);
      debugPrint('DEVICE CHECK: in-flight cancellation and error view');

      await tap(tester, find.text('Request'));
      await tester.enterText(urlField(), '$base/large');
      await hideKeyboard(tester);
      await tester.tap(find.text('Send'));
      await until(tester, () => !state.activeTab!.loading);
      expect(
        state.activeTab!.response!.sizeBytes,
        greaterThan(2 * 1024 * 1024),
      );
      await tap(tester, find.text('Response'));
      expect(find.textContaining('Preview limited'), findsWidgets);
      await tap(tester, find.text('Request'));
      await tap(tester, find.text('Response'));
      debugPrint('DEVICE CHECK: 2 MiB response and repeated navigation');

      // Fresh state reads the actual Android app-support storage, not mocks.
      final restored = AppState();
      await until(tester, () => restored.loaded);
      expect(restored.collections.any((c) => c.name == 'Device QA'), isTrue);
      expect(restored.history, isNotEmpty);
      restored.dispose();
      expect(tester.takeException(), isNull);
      debugPrint('DEVICE CHECK: persistent collections/history reload');
    },
  );

  testWidgets(
    'Android: runner remains bounded through 240 real HTTP requests',
    (tester) async {
      final http = HttpService();
      final runner = RunnerService(http);
      await runner.start(
        requests: [RequestModel(url: '$base/echo')],
        vars: {},
        iterations: 240,
      );
      expect(runner.total, 240);
      expect(runner.passed, 240);
      expect(runner.results.length, 200);
      expect(runner.results.every((r) => r.response.bodyBytes.isEmpty), isTrue);
      runner.dispose();
      http.dispose();
      // Exercise path_provider/storage plugins independently of the UI tree.
      expect(await Storage().loadSettings(), isA<AppSettings>());
      debugPrint(
        'DEVICE CHECK: 240 requests, 200 retained summaries, 240 passes',
      );
    },
  );
  testWidgets(
    'Android: HTTPS adapters, timeout, connection error and native sound bridge',
    (tester) async {
      final http = HttpService();
      for (final version in HttpVersionPref.values) {
        http.configure(
          AppSettings(
            httpVersion: version,
            connectTimeoutS: 15,
            receiveTimeoutS: 15,
          ),
        );
        final response = await http.send(
          RequestModel(url: 'https://postman-echo.com/get?device=android'),
          {},
          tabId: 'https-check',
        );
        expect(
          response.error,
          isNull,
          reason: '${version.name}: ${response.error}',
        );
        expect(response.statusCode, 200);
        expect(response.bodyText, contains('android'));
        debugPrint('DEVICE CHECK: HTTPS through ${version.name} adapter');
      }
      http.configure(
        AppSettings(httpVersion: HttpVersionPref.v1, receiveTimeoutS: 1),
      );
      final timeout = await http.send(
        RequestModel(url: '$base/slow'),
        {},
        tabId: 'timeout',
      );
      expect(timeout.error, contains('too long'));
      final unavailable = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final closedPort = unavailable.port;
      await unavailable.close(force: true);
      final offline = await http.send(
        RequestModel(url: 'http://127.0.0.1:$closedPort/'),
        {},
        tabId: 'offline',
      );
      expect(offline.error, contains('Connection failed'));
      final path = await SoundService().resolvePath('tada');
      expect(path, isNotNull);
      await const MethodChannel(
        'apiworkbench/sound',
      ).invokeMethod<void>('play', {'path': path});
      http.dispose();
      debugPrint(
        'DEVICE CHECK: response timeout, connection failure and native audio invocation',
      );
    },
  );
}
