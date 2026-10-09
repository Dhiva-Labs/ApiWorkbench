// Renders the real app on the Linux embedder and saves PNGs of the main
// screens in each theme (a widget test would draw text with the Ahem
// placeholder font).
//
//   flutter test integration_test/screenshots_test.dart -d linux
//
// PNGs land in screenshots/ at the repository root.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:api_workbench/main.dart';
import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/postman_import.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/ui/import_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _boundaryKey = ValueKey('screenshot-boundary');

Map<String, dynamic> _collection(String base) => {
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
            'url': '{{baseUrl}}/orders?status=shipped&limit=20',
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
              'raw': '{{baseUrl}}/orders/:orderId?expand=items',
              'variable': [
                {'key': 'orderId', 'value': '42'},
              ],
              'query': [
                {'key': 'expand', 'value': 'items'},
              ],
            },
            'header': [
              {'key': 'Accept', 'value': 'application/json'},
            ],
          },
        },
        {
          'name': 'Update order',
          'request': {'method': 'PUT', 'url': '{{baseUrl}}/orders/42'},
        },
        {
          'name': 'Upload invoice',
          'request': {
            'method': 'POST',
            'url': '{{baseUrl}}/orders/42/invoice',
            'body': {
              'mode': 'formdata',
              'formdata': [
                {'key': 'note', 'value': 'Paid', 'type': 'text'},
                {'key': 'file', 'type': 'file', 'src': '/home/me/invoice.pdf'},
              ],
            },
          },
        },
        {
          'name': 'Cancel order',
          'request': {'method': 'DELETE', 'url': '{{baseUrl}}/orders/42'},
        },
      ],
    },
    {
      'name': 'Health',
      'request': {'method': 'GET', 'url': '{{baseUrl}}/health'},
    },
  ],
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final outDir = Directory('${Directory.current.path}/screenshots');

  testWidgets('screenshots', (tester) async {
    late HttpServer server;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('aw_shots_');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) async {
        await r.drain<void>();
        r.response.headers.contentType = ContentType.json;
        r.response.write(
          const JsonEncoder.withIndent('  ').convert({
            'id': 42,
            'status': 'shipped',
            'customer': {'name': 'Ada Lovelace', 'email': 'ada@example.com'},
            'items': [
              {'sku': 'KB-01', 'name': 'Mechanical keyboard', 'qty': 1},
              {'sku': 'MS-07', 'name': 'Wireless mouse', 'qty': 2},
            ],
            'total': 189.5,
            'currency': 'EUR',
          }),
        );
        await r.response.close();
      });
      await outDir.create(recursive: true);
    });
    final base = 'http://127.0.0.1:${server.port}';

    final state = AppState(storage: Storage(overrideDir: dir));
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    await tester.pumpWidget(
      RepaintBoundary(
        key: _boundaryKey,
        child: ApiWorkbenchApp(state: state),
      ),
    );
    for (var i = 0; i < 50 && !state.loaded; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }

    Future<void> shot(String name) async {
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(_boundaryKey),
      );
      final bytes = await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data!.buffer.asUint8List();
      });
      File('${outDir.path}/$name.png').writeAsBytesSync(bytes!);
    }

    // Empty workspace first (shows the onboarding state).
    state.updateSettings(state.settings..themeMode = ThemeModePref.light);
    await shot('00-empty');

    final report = importApiFile(jsonEncode(_collection(base)));
    state.mergeWorkspace(report.collections, [
      EnvironmentModel(
        name: 'Staging',
        variables: [
          KV(key: 'email', value: 'ada@example.com'),
          KV(key: 'password', value: 's3cret'),
          KV(key: 'token', value: 'tok-123'),
        ],
      ),
    ]);
    state.setActiveEnvironment(state.environments.single.id);
    final col = state.collections.single;
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shop API').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Orders').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Auth').first);
    await tester.pumpAndSettle();

    state.openRequest(
      col.requests.firstWhere((r) => r.name == 'Get order'),
      collectionId: col.id,
    );
    await tester.pumpAndSettle();
    state.updateSettings(state.settings..themeMode = ThemeModePref.light);
    await tester.pumpAndSettle();
    final send = state.sendActive();
    await tester.runAsync(() => send);
    await tester.pumpAndSettle();
    await shot('01-teal-light');

    state.updateSettings(state.settings..themeMode = ThemeModePref.dark);
    await tester.pumpAndSettle();
    await shot('02-teal-dark');

    state.updateSettings(state.settings..theme = AppThemeId.graphite);
    await tester.pumpAndSettle();
    await shot('03-graphite');

    state.updateSettings(
      state.settings
        ..theme = AppThemeId.teal
        ..themeMode = ThemeModePref.light,
    );
    state.openRequest(
      col.requests.firstWhere((r) => r.name == 'Upload invoice'),
      collectionId: col.id,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Body').first);
    await tester.pumpAndSettle();
    await shot('04-form-data');

    await tester.tap(find.text('Import').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Or paste Postman JSON here'),
      jsonEncode(_collection(base)),
    );
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await shot('05-import');

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Started from a folder's "Import into folder".
    showImportDialog(
      tester.element(find.byType(Scaffold).first),
      collectionId: col.id,
      folder: 'Orders',
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Or paste Postman JSON here'),
      jsonEncode({
        'name': 'Refund order',
        'request': {'method': 'POST', 'url': '{{baseUrl}}/orders/42/refund'},
      }),
    );
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await shot('05b-import-into-folder');
    await tester.tap(find.text('Import').last);
    await tester.pumpAndSettle();
    await shot('05c-after-import');
    ScaffoldMessenger.of(
      tester.element(find.byType(Scaffold).first),
    ).hideCurrentSnackBar();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    await shot('06-settings');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.binding.setSurfaceSize(const Size(412, 892));
    await tester.pumpAndSettle();
    await shot('07-phone');
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await shot('08-phone-drawer');

    await tester.runAsync(() async {
      await server.close(force: true);
      await dir.delete(recursive: true);
    });
  });
}
