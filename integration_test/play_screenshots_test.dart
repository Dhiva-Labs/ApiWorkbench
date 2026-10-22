// Renders the real app at a phone size on the Linux embedder and saves the
// Google Play phone screenshots: 1080×1920 PNGs (9:16), the phone layout
// with the drawer and the Request/Response navigation bar, in the Teal theme.
//
//   flutter test integration_test/play_screenshots_test.dart -d linux \
//     --dart-define=CHAOS_MEME_SOUNDS=false
//
// (The Play build leaves the meme clips out, so the define matches it.)
// PNGs land in store/graphics/screenshots/phone/, numbered in display
// order. All data lives in a temporary directory and every request goes to
// a local HTTP server; the names, emails and tokens are made up.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:api_workbench/main.dart';
import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/postman_import.dart';
import 'package:api_workbench/services/sound_service.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/ui/help_tip.dart';
import 'package:api_workbench/ui/load_test_screen.dart';
import 'package:api_workbench/ui/request_editor.dart';
import 'package:api_workbench/ui/response_view.dart';
import 'package:api_workbench/ui/sidebar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _boundaryKey = ValueKey('play-screenshot-boundary');

/// Logical phone surface; × [_pixelRatio] gives exactly 1080×1920.
const _logical = Size(405, 720);
const _pixelRatio = 1080 / 405; // 8 / 3
const _outWidth = 1080;
const _outHeight = 1920;

// ---------------------------------------------------------------- data

/// The demo collection: a Postman v2.1 export, imported the way a user
/// would bring it in.
Map<String, dynamic> _shopApi(String base) => {
  'info': {
    'name': 'Shop API',
    'schema':
        'https://schema.getpostman.com/json/collection/v2.1.0/collection.json',
  },
  'variable': [
    {'key': 'baseUrl', 'value': base},
  ],
  'auth': {
    'type': 'bearer',
    'bearer': [
      {'key': 'token', 'value': '{{token}}'},
    ],
  },
  'item': [
    {
      'name': 'Auth',
      'item': [
        {
          'name': 'Login',
          'event': [
            {
              'listen': 'test',
              'script': {
                'exec': [
                  'pm.response.to.have.status(200);',
                  'var jsonData = pm.response.json();',
                  'pm.environment.set("token", jsonData.token);',
                ],
              },
            },
          ],
          'request': {
            'method': 'POST',
            'url': '{{baseUrl}}/auth/login',
            'body': {
              'mode': 'raw',
              'raw':
                  '{\n  "email": "{{email}}",\n  "password": "{{password}}"\n}',
              'options': {
                'raw': {'language': 'json'},
              },
            },
          },
        },
        {
          'name': 'Refresh token',
          'request': {'method': 'POST', 'url': '{{baseUrl}}/auth/refresh'},
        },
      ],
    },
    {
      'name': 'Orders',
      'item': [
        {
          'name': 'List orders',
          'request': {
            'method': 'GET',
            'url': {
              'raw': '{{baseUrl}}/orders?status=shipped&limit=20',
              'query': [
                {'key': 'status', 'value': 'shipped'},
                {'key': 'limit', 'value': '20'},
              ],
            },
          },
        },
        {
          'name': 'Get order',
          'event': [
            {
              'listen': 'test',
              'script': {
                'exec': [
                  'pm.response.to.have.status(200);',
                  'pm.expect(pm.response.json().status).to.eql("shipped");',
                  'pm.expect(pm.response.responseTime).to.be.below(500);',
                ],
              },
            },
          ],
          'request': {
            'method': 'GET',
            'url': {
              'raw':
                  '{{baseUrl}}/orders/:orderId?expand=items'
                  '&include=customer,shipping&currency=EUR&debug=true',
              'variable': [
                {'key': 'orderId', 'value': '1042'},
              ],
              'query': [
                {'key': 'expand', 'value': 'items'},
                {'key': 'include', 'value': 'customer,shipping'},
                {'key': 'currency', 'value': 'EUR'},
                {'key': 'debug', 'value': 'true', 'disabled': true},
              ],
            },
            'header': [
              {'key': 'Accept', 'value': 'application/json'},
              {'key': 'X-Request-Id', 'value': r'{{$guid}}'},
            ],
          },
        },
        {
          'name': 'Create order',
          'event': [
            {
              'listen': 'test',
              'script': {
                'exec': [
                  'pm.response.to.have.status(201);',
                  'pm.environment.set("orderId", pm.response.json().id);',
                ],
              },
            },
          ],
          'request': {
            'method': 'POST',
            'url': '{{baseUrl}}/orders',
            'body': {
              'mode': 'raw',
              // Short enough to show whole in the phone's body editor.
              'raw': [
                '{',
                '  "customerId": 7,',
                '  "items": [',
                '    { "sku": "KB-01", "qty": 1 },',
                '    { "sku": "MS-07", "qty": 2 }',
                '  ],',
                '  "shipTo": "Ada Lovelace, London",',
                '  "coupon": "{{coupon}}",',
                '  "giftWrap": false',
                '}',
              ].join('\n'),
              'options': {
                'raw': {'language': 'json'},
              },
            },
          },
        },
        {
          'name': 'Update order',
          'request': {'method': 'PUT', 'url': '{{baseUrl}}/orders/1042'},
        },
        {
          'name': 'Cancel order',
          'request': {'method': 'DELETE', 'url': '{{baseUrl}}/orders/1042'},
        },
      ],
    },
    {
      'name': 'Health',
      'request': {'method': 'GET', 'url': '{{baseUrl}}/health'},
    },
  ],
};

/// A second export, pasted into the import dialog for its preview.
Map<String, dynamic> _paymentsApi() => {
  'info': {
    'name': 'Payments API',
    'schema':
        'https://schema.getpostman.com/json/collection/v2.1.0/collection.json',
  },
  'variable': [
    {'key': 'baseUrl', 'value': 'https://payments.example.com/v2'},
  ],
  'item': [
    {
      'name': 'Customers',
      'item': [
        {
          'name': 'List customers',
          'request': {'method': 'GET', 'url': '{{baseUrl}}/customers'},
        },
        {
          'name': 'Create customer',
          'event': [
            {
              'listen': 'test',
              'script': {
                'exec': [
                  'pm.response.to.have.status(201);',
                  'pm.environment.set("customerId", pm.response.json().id);',
                ],
              },
            },
          ],
          'request': {
            'method': 'POST',
            'url': '{{baseUrl}}/customers',
            'body': {
              'mode': 'raw',
              'raw': '{"name": "Grace Hopper", "email": "grace@example.com"}',
              'options': {
                'raw': {'language': 'json'},
              },
            },
          },
        },
      ],
    },
    {
      'name': 'Payments',
      'item': [
        {
          'name': 'Create payment',
          'event': [
            {
              'listen': 'test',
              'script': {
                'exec': [
                  'pm.response.to.have.status(201);',
                  'pm.expect(pm.response.json().status).to.eql("succeeded");',
                  'pm.expect(pm.response.responseTime).to.be.below(800);',
                  'pm.environment.set("paymentId", pm.response.json().id);',
                ],
              },
            },
          ],
          'request': {
            'method': 'POST',
            'url': '{{baseUrl}}/payments',
            'body': {
              'mode': 'raw',
              'raw': '{"amount": 4200, "currency": "EUR"}',
              'options': {
                'raw': {'language': 'json'},
              },
            },
          },
        },
        {
          'name': 'Refund payment',
          'request': {
            'method': 'POST',
            'url': '{{baseUrl}}/payments/:id/refund',
          },
        },
        {
          'name': 'Get payment',
          'request': {'method': 'GET', 'url': '{{baseUrl}}/payments/:id'},
        },
      ],
    },
    {
      'name': 'Webhooks',
      'item': [
        {
          'name': 'Register webhook',
          'request': {
            'method': 'POST',
            'url': '{{baseUrl}}/webhooks',
            'body': {
              'mode': 'urlencoded',
              'urlencoded': [
                {'key': 'url', 'value': 'https://hooks.example.com/pay'},
                {'key': 'events', 'value': 'payment.succeeded'},
              ],
            },
          },
        },
      ],
    },
  ],
};

Map<String, dynamic> _order() => {
  'id': 1042,
  'number': 'SO-2026-1042',
  'status': 'shipped',
  'customer': {'id': 7, 'name': 'Ada Lovelace', 'email': 'ada@example.com'},
  'items': [
    {'sku': 'KB-01', 'name': 'Mechanical keyboard', 'qty': 1, 'price': 129.0},
    {'sku': 'MS-07', 'name': 'Wireless mouse', 'qty': 2, 'price': 30.25},
  ],
  'total': 189.5,
  'currency': 'EUR',
  'paid': true,
  'shippedAt': '2026-10-20T14:32:00Z',
  'tracking': 'https://track.example.com/1Z999AA10123456784',
};

/// Status and JSON body for each endpoint of the demo server.
(int, Object?) _route(String method, String path) => switch ((method, path)) {
  ('POST', '/auth/login') => (
    200,
    {
      'token': 'demo-token-not-real',
      'expiresIn': 3600,
      'user': {'id': 7, 'name': 'Ada Lovelace'},
    },
  ),
  ('POST', '/auth/refresh') => (
    200,
    {'token': 'demo-token-not-real', 'expiresIn': 3600},
  ),
  ('GET', '/orders') => (
    200,
    {
      'orders': [
        for (final (id, total) in [(1042, 189.5), (1038, 54.0), (1031, 12.9)])
          {'id': id, 'status': 'shipped', 'total': total, 'currency': 'EUR'},
      ],
      'next': null,
    },
  ),
  ('POST', '/orders') => (
    201,
    {
      'id': 1043,
      'status': 'pending',
      'total': 189.5,
      'currency': 'EUR',
      'createdAt': '2026-10-22T09:15:04Z',
    },
  ),
  ('GET', '/orders/1042') || ('PUT', '/orders/1042') => (200, _order()),
  // A shipped order can no longer be cancelled: the runner shows it failing.
  ('DELETE', '/orders/1042') => (
    409,
    {
      'error': 'order_already_shipped',
      'message': 'Order SO-2026-1042 has shipped and cannot be cancelled.',
    },
  ),
  ('GET', '/health') => (200, {'status': 'ok', 'version': '3.8.1'}),
  _ => (404, {'error': 'not_found'}),
};

/// Answers like a small hosted API: a few tens of milliseconds, with the
/// occasional slower call so the load-test percentiles spread out.
Future<HttpServer> _startServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final random = math.Random(7);
  var count = 0;
  server.listen((req) async {
    await req.drain<void>();
    final r = random.nextDouble();
    await Future<void>.delayed(
      Duration(milliseconds: 24 + (r * r * r * 150).round()),
    );
    final (status, body) = _route(req.method, req.uri.path);
    final res = req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json;
    res.headers
      ..set('cache-control', 'no-store')
      ..set('server', 'shop-api')
      ..set('x-request-id', 'req_${(0x5f3a00 + count++).toRadixString(16)}');
    if (body != null) res.write(jsonEncode(body));
    try {
      await res.close();
    } catch (_) {
      // A client cancelled mid-response.
    }
  });
  return server;
}

// ---------------------------------------------------------------- test

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final outDir = Directory(
    '${Directory.current.path}/store/graphics/screenshots/phone',
  );

  testWidgets('Google Play phone screenshots', (tester) async {
    expect(
      kChaosMemeSounds,
      isFalse,
      reason:
          'Run with --dart-define=CHAOS_MEME_SOUNDS=false, like the Play '
          'build.',
    );
    late HttpServer server;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('aw_play_shots_');
      server = await _startServer();
      await outDir.create(recursive: true);
      for (final f in outDir.listSync().whereType<File>()) {
        if (f.path.endsWith('.png')) f.deleteSync();
      }
    });
    final base = 'http://127.0.0.1:${server.port}';

    // A phone: Android platform (touch density and typography), no window
    // decorations.
    tester.view.physicalSize = _logical;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = FakeViewPadding.zero;
    tester.view.viewPadding = FakeViewPadding.zero;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    final state = AppState(
      storage: Storage(overrideDir: dir),
      sounds: SoundService(overrideDir: dir),
    );

    Future<void> settle() => tester.pumpAndSettle(
      const Duration(milliseconds: 16),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 30),
    );

    /// Pumps with real time passing (HTTP, timers) until [done].
    Future<void> waitFor(bool Function() done, {int seconds = 60}) async {
      final end = DateTime.now().add(Duration(seconds: seconds));
      while (!done()) {
        if (DateTime.now().isAfter(end)) throw StateError('timed out');
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    bool has(Finder f) => f.evaluate().isNotEmpty;

    Future<void> tap(Finder f) async {
      await tester.tap(f.first);
      await settle();
    }

    Future<void> send() async {
      final pending = state.sendActive();
      await tester.runAsync(() => pending);
      await settle();
    }

    final written = <String>[];
    Future<void> shot(String name) async {
      FocusManager.instance.primaryFocus?.unfocus();
      await settle();
      expect(tester.takeException(), isNull, reason: name);
      expect(find.byType(SnackBar), findsNothing, reason: name);
      expect(find.textContaining('meme_'), findsNothing, reason: name);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(_boundaryKey),
      );
      expect(boundary.size, _logical, reason: name);
      final bytes = await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: _pixelRatio);
        expect(image.width, _outWidth, reason: name);
        expect(image.height, _outHeight, reason: name);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        return data!.buffer.asUint8List();
      });
      File('${outDir.path}/$name.png').writeAsBytesSync(bytes!);
      written.add(name);
    }

    void theme(ThemeModePref mode) => state.updateSettings(
      state.settings
        ..theme = AppThemeId.teal
        ..themeMode = mode
        ..chaosMode = false,
    );

    Finder inPanel(Finder f) =>
        find.descendant(of: find.byType(Sidebar), matching: f);

    Future<void> editorTab(int i) async {
      final bar = find.descendant(
        of: find.byType(RequestEditor),
        matching: find.byType(TabBar),
      );
      DefaultTabController.of(tester.element(bar)).index = i;
      await settle();
    }

    Future<void> responseTab(int i) async {
      final bar = find.descendant(
        of: find.byType(ResponseView),
        matching: find.byType(TabBar),
      );
      DefaultTabController.of(tester.element(bar)).index = i;
      await settle();
    }

    Future<void> section(String label) => tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text(label),
      ),
    );

    void closeDrawer() {
      for (final e in find.byType(Scaffold, skipOffstage: false).evaluate()) {
        final s = (e as StatefulElement).state as ScaffoldState;
        if (s.isDrawerOpen) s.closeDrawer();
      }
    }

    Future<void> openTree() async {
      if (!has(find.byType(Drawer))) {
        await tap(find.byTooltip('Open navigation menu'));
      }
      for (final name in ['Shop API', 'Auth', 'Orders']) {
        final row = inPanel(find.text(name));
        final chevron = find.descendant(
          of: find
              .ancestor(of: row.first, matching: find.byType(InkWell))
              .first,
          matching: find.byType(AnimatedRotation),
        );
        if (has(chevron) &&
            tester.widget<AnimatedRotation>(chevron).turns > 0) {
          continue; // already open
        }
        await tap(row);
      }
    }

    try {
      await tester.pumpWidget(
        RepaintBoundary(
          key: _boundaryKey,
          child: ApiWorkbenchApp(state: state),
        ),
      );
      await waitFor(() => state.loaded, seconds: 20);
      theme(ThemeModePref.light);
      await settle();

      final report = importApiFile(jsonEncode(_shopApi(base)));
      state.mergeWorkspace(report.collections, [
        EnvironmentModel(
          name: 'Staging',
          variables: [
            KV(key: 'email', value: 'ada@example.com'),
            KV(key: 'password', value: 'not-a-real-password'),
            KV(key: 'token', value: 'demo-token-not-real'),
            KV(key: 'coupon', value: 'WELCOME10'),
          ],
        ),
        EnvironmentModel(name: 'Local'),
      ]);
      state.setActiveEnvironment(
        state.environments.firstWhere((e) => e.name == 'Staging').id,
      );
      final shop = state.collections.single;
      RequestModel req(String name) =>
          shop.requests.firstWhere((r) => r.name == name);
      // More checks on Get order than its Postman script carried over.
      req('Get order').assertions.addAll([
        AssertionModel(
          kind: AssertKind.headerContains,
          target: 'Content-Type',
          expected: 'json',
        ),
        AssertionModel(
          kind: AssertKind.jsonEquals,
          target: 'customer.email',
          expected: 'ada@example.com',
        ),
        AssertionModel(
          kind: AssertKind.jsonEquals,
          target: 'items[0].sku',
          expected: 'KB-01',
        ),
        AssertionModel(
          kind: AssertKind.bodyContains,
          expected: 'Mechanical keyboard',
        ),
      ]);
      state.updateCollections();

      // Two open tabs, Get order first (the strip does not scroll to the
      // active tab), and no leftover empty tab.
      state.openRequest(req('Get order'), collectionId: shop.id);
      state.openRequest(req('Create order'), collectionId: shop.id);
      while (state.tabs.first.request.name == 'Untitled request') {
        state.closeTab(0);
      }
      await settle();

      // Create order: send it so its tab has a response, then its body.
      state.selectTab(1);
      await settle();
      await send();
      await editorTab(2);
      await shot('05-json-body-editor');

      // Get order: the request, its response and its test results.
      state.selectTab(0);
      await settle();
      await send();
      await editorTab(0);
      await shot('01-request-editor');

      await section('Response');
      await responseTab(0);
      await shot('02-response-json');

      theme(ThemeModePref.dark);
      await responseTab(3);
      await shot('03-test-results-dark');
      await responseTab(0);
      await section('Request');

      // The drawer with the collection tree.
      theme(ThemeModePref.light);
      await openTree();
      await shot('04-collections-drawer');

      // Runner on the Orders folder (its results fit on one screen), dark.
      theme(ThemeModePref.dark);
      await settle();
      await tap(inPanel(find.byTooltip('Folder actions')).at(1));
      await tap(find.text('Run folder').last);
      await tap(find.widgetWithText(FilledButton, 'Run'));
      await waitFor(
        () =>
            has(find.textContaining('Showing')) &&
            has(find.widgetWithText(FilledButton, 'Run')),
      );
      await settle();
      await shot('06-collection-runner-dark');
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await settle();
      closeDrawer();
      await settle();

      // Load test of Get order, back in light.
      theme(ThemeModePref.light);
      await settle();
      await tap(find.byTooltip('More'));
      await tap(find.text('Load test (parallel calls)…'));
      Future<void> field(String label, String value) async {
        final f = find.widgetWithText(TextFormField, label);
        await tester.ensureVisible(f);
        await tester.enterText(f, value);
        await settle();
      }

      await field('Parallel users', '25');
      await field('Duration (s)', '6');
      await field('Ramp-up (s)', '2');
      FocusManager.instance.primaryFocus?.unfocus();
      await settle();
      final run = find.widgetWithText(FilledButton, 'Run');
      await tester.ensureVisible(run);
      await tap(run);
      await waitFor(() => has(find.text('Stop')), seconds: 10);
      await waitFor(() => has(find.widgetWithText(FilledButton, 'Run')));
      await settle();
      // The Results card at the top of the screen, with a margin above it.
      final resultsTitle = find.descendant(
        of: find.byType(LoadTestScreen),
        matching: find.text('Results'),
      );
      await Scrollable.ensureVisible(tester.element(resultsTitle));
      await settle();
      final list = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(LoadTestScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      list.position.jumpTo(
        (list.position.pixels - 36).clamp(0, list.position.maxScrollExtent),
      );
      await settle();
      await shot('07-load-test-results');
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await settle();

      // Postman import preview.
      await tap(find.byTooltip('Workspace menu'));
      await tap(find.text('Import (Postman, workspace)…'));
      await tester.enterText(
        find.widgetWithText(TextField, 'Or paste Postman JSON here'),
        jsonEncode(_paymentsApi()),
      );
      await tap(find.text('Add').last);
      await shot('08-postman-import');
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await settle();

      debugPrint('PLAY SCREENSHOTS: ${written.join(', ')} → ${outDir.path}');
    } finally {
      debugDefaultTargetPlatformOverride = null;
      hoverHelpEnabled.value = true;
      tester.view.reset();
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        state.dispose();
        await server.close(force: true);
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
