// Layout sweep: drives every screen, dialog and menu of the real app on the
// Linux embedder (real system fonts, unlike widget tests' Ahem) at phone,
// tablet and desktop sizes in each theme, and fails with a readable list of:
//
//  * every FlutterError (RenderFlex overflows and other layout errors) and
//    every exception, with the size, theme, screen and source location;
//  * interactive controls that overlap each other or stick out of the
//    screen;
//  * touch targets smaller than 44 px on phones and tablets.
//
//   flutter test integration_test/layout_sweep_test.dart -d linux
//
// Phone and tablet sizes run with the Android platform (standard visual
// density and Android typography, as on a real phone), desktop sizes with
// the host platform. All data lives in a temporary directory and requests
// go to a local HTTP server.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:api_workbench/main.dart';
import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/postman_import.dart';
import 'package:api_workbench/services/sound_service.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/ui/help_tip.dart';
import 'package:api_workbench/ui/home_screen.dart';
import 'package:api_workbench/ui/load_test_screen.dart';
import 'package:api_workbench/ui/request_editor.dart';
import 'package:api_workbench/ui/response_view.dart';
import 'package:api_workbench/ui/sidebar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// ---------------------------------------------------------------- configs

/// `--dart-define=SWEEP=320x640` runs only configurations whose name
/// contains that text (for quick iteration); `SWEEP_VERBOSE=true` prints
/// progress and each issue as it is found.
const _only = String.fromEnvironment('SWEEP');
const _verbose = bool.fromEnvironment('SWEEP_VERBOSE');

class _Config {
  const _Config(this.size, this.theme, this.mode, {this.hoverHelp = true});

  final Size size;
  final AppThemeId theme;
  final ThemeModePref mode;
  final bool hoverHelp;

  /// Same rule as HomeScreen.
  bool get desktop => size.width >= 900 && size.height >= 600;

  /// Phones and tablets run as Android (touch, standard density).
  bool get touch => !desktop;

  String get name {
    final t = theme == AppThemeId.graphite ? 'graphite' : 'teal-${mode.name}';
    return '${size.width.toInt()}x${size.height.toInt()} $t'
        '${hoverHelp ? '' : ' (help off)'}';
  }
}

const _sizes = [
  Size(320, 640),
  Size(360, 780),
  Size(412, 915),
  Size(768, 1024),
  Size(900, 700),
  Size(1280, 800),
  Size(1440, 900),
];

final _configs = [
  for (final s in _sizes) ...[
    _Config(s, AppThemeId.teal, ThemeModePref.light),
    _Config(s, AppThemeId.teal, ThemeModePref.dark),
  ],
  // Graphite at one phone and one desktop size, with hover help off so the
  // layouts without the ⓘ icons are covered too.
  const _Config(
    Size(360, 780),
    AppThemeId.graphite,
    ThemeModePref.dark,
    hoverHelp: false,
  ),
  const _Config(
    Size(1280, 800),
    AppThemeId.graphite,
    ThemeModePref.dark,
    hoverHelp: false,
  ),
];

// ---------------------------------------------------------------- data

const _longCollection =
    'Customer Relationship Management Platform — Internal Administration '
    'and Reporting API (v3 beta)';
const _deepFolder =
    'Accounts and Billing Administration/Invoices, Credit Notes and Refund '
    'Processing/Quarterly Reconciliation Reports';
const _kitchenName =
    'Update the billing contact for an enterprise customer account with a '
    'very long request name';
const _longEnv =
    'Production (eu-west-1) — read-only replica used by the customer support '
    'team';
const _longHeader = 'X-A-Very-Long-Custom-Header-Name-For-Distributed-Tracing';

/// A Postman v2.1 collection with nested folders, every body mode, several
/// auth types and scripts that convert to tests and captures.
Map<String, dynamic> _shopApi(String base) => {
  'info': {
    'name': 'Shop API',
    'description': 'All shop endpoints',
    'schema':
        'https://schema.getpostman.com/json/collection/v2.1.0/collection.json',
  },
  'auth': {
    'type': 'bearer',
    'bearer': [
      {'key': 'token', 'value': '{{token}}', 'type': 'string'},
    ],
  },
  'variable': [
    {'key': 'baseUrl', 'value': base},
    {'key': 'pageSize', 'value': 20, 'type': 'number'},
  ],
  'item': [
    {
      'name': 'Auth',
      'auth': {'type': 'noauth'},
      'item': [
        {
          'name': 'Login',
          'event': [
            {
              'listen': 'test',
              'script': {
                'exec': [
                  'pm.test("ok", function () {',
                  '  pm.response.to.have.status(200);',
                  '});',
                  'var jsonData = pm.response.json();',
                  'pm.environment.set("token", jsonData.data.token);',
                  'pm.expect(pm.response.text()).to.include("token");',
                  'console.log(new Date());',
                ],
              },
            },
          ],
          'request': {
            'method': 'POST',
            'header': [
              {'key': 'Content-Type', 'value': 'application/json'},
            ],
            'body': {
              'mode': 'raw',
              'raw': '{"user":"{{user}}","pass":"{{pass}}"}',
              'options': {
                'raw': {'language': 'json'},
              },
            },
            'url': '{{baseUrl}}/auth/login',
          },
        },
      ],
    },
    {
      'name': 'Orders',
      'item': [
        {
          'name': 'Admin',
          'item': [
            {
              'name': 'Get order',
              'request': {
                'method': 'GET',
                'url': {
                  'raw': '{{baseUrl}}/orders/:orderId?expand=true&debug=1',
                  'host': ['{{baseUrl}}'],
                  'path': ['orders', ':orderId'],
                  'query': [
                    {'key': 'expand', 'value': 'true'},
                    {'key': 'debug', 'value': '1', 'disabled': true},
                  ],
                  'variable': [
                    {'key': 'orderId', 'value': '42'},
                  ],
                },
                'description': 'Fetch one order with its items.',
              },
            },
          ],
        },
        {
          'name': 'Upload invoice',
          'request': {
            'method': 'POST',
            'auth': {
              'type': 'apikey',
              'apikey': [
                {'key': 'key', 'value': 'api_key'},
                {'key': 'value', 'value': '{{apiKey}}'},
                {'key': 'in', 'value': 'query'},
              ],
            },
            'body': {
              'mode': 'formdata',
              'formdata': [
                {'key': 'orderId', 'value': '42', 'type': 'text'},
                {
                  'key': 'file',
                  'type': 'file',
                  'src':
                      '/home/someone/Documents/Invoices/2026/Q3/'
                      'enterprise-customer-invoice-final-v2.pdf',
                },
                {'key': 'note', 'value': 'x', 'type': 'text', 'disabled': true},
              ],
            },
            'url': '{{baseUrl}}/orders/upload',
          },
        },
        {
          'name': 'Search (form)',
          'request': {
            'method': 'POST',
            'auth': {
              'type': 'digest',
              'digest': [
                {'key': 'username', 'value': 'u'},
              ],
            },
            'body': {
              'mode': 'urlencoded',
              'urlencoded': [
                {'key': 'q', 'value': 'shoes'},
                {'key': 'page', 'value': '{{pageSize}}'},
              ],
            },
            'url': '{{baseUrl}}/search',
          },
        },
        {
          'name': 'GraphQL',
          'request': {
            'method': 'POST',
            'body': {
              'mode': 'graphql',
              'graphql': {
                'query': '{ orders { id total customer { name } } }',
                'variables': '{"first": 10}',
              },
            },
            'url': '{{baseUrl}}/graphql',
          },
        },
        {
          'name': 'Upload raw',
          'request': {
            'method': 'PUT',
            'body': {
              'mode': 'file',
              'file': {'src': '/tmp/blob.bin'},
            },
            'url': '{{baseUrl}}/blob',
          },
        },
        {
          'name': 'Plain raw',
          'request': {
            'method': 'POST',
            'body': {'mode': 'raw', 'raw': '<order><id>1</id></order>'},
            'url': '{{baseUrl}}/xml',
          },
        },
      ],
    },
    {'name': 'Health', 'request': '{{baseUrl}}/health'},
  ],
};

/// One request using every editor feature, with long names and values.
RequestModel _kitchenSink(String base) => RequestModel(
  name: _kitchenName,
  method: 'PATCH',
  url:
      '$base/json?tenant={{aVeryLongVariableNameUsedForTenantScopedRequests}}'
      '&expand=contacts,addresses,invoices',
  folder: _deepFolder,
  params: [
    KV(
      key: 'tenant',
      value: '{{aVeryLongVariableNameUsedForTenantScopedRequests}}',
    ),
    KV(key: 'expand', value: 'contacts,addresses,invoices'),
    KV(key: 'debug', value: 'true', enabled: false),
    KV(
      key: 'aQueryParameterWithAnExtremelyLongNameThatDoesNotFit',
      value: 'and-a-value-that-is-also-much-too-long-for-a-phone-0123456789',
    ),
  ],
  headers: [
    KV(key: 'Accept', value: 'application/json'),
    KV(key: 'X-Request-Id', value: r'{{$guid}}'),
    KV(key: _longHeader, value: '00-4bf92f3577b34da6a3ce929d0e0e4736-01'),
  ],
  bodyType: BodyType.json,
  body: const JsonEncoder.withIndent('  ').convert({
    'contact': {
      'name': 'Ada Lovelace',
      'email': 'ada.lovelace@enterprise-customer.example.com',
      'phone': '+44 20 7946 0958',
    },
    'notes': 'A long single-line note ' * 6,
  }),
  graphqlVariables: '{"first": 10, "after": "Y3Vyc29yOjEwMA=="}',
  formFields: [
    KV(key: 'note', value: 'Paid in full'),
    KV(
      key: 'invoice',
      value:
          '/home/someone/Documents/Invoices/2026/Q3/enterprise-customer-'
          'invoice-final-v2.pdf',
      isFile: true,
    ),
    KV(key: 'attachment', isFile: true),
  ],
  authType: AuthType.basic,
  basicUser: 'billing-admin@enterprise-customer.example.com',
  basicPassword: 's3cret',
  bearerToken: '{{token}}',
  apiKeyName: 'X-API-Key',
  apiKeyValue: '{{apiKey}}',
  assertions: [
    AssertionModel(expected: '2xx'),
    AssertionModel(
      kind: AssertKind.bodyContains,
      expected: '"name": "Ada Lovelace"',
    ),
    AssertionModel(
      kind: AssertKind.jsonEquals,
      target: 'customer.addresses[0].postalCode.extendedFormat',
      expected: 'SW1A 1AA',
    ),
    AssertionModel(kind: AssertKind.headerContains, target: _longHeader),
    AssertionModel(
      kind: AssertKind.timeBelow,
      expected: '1500',
      enabled: false,
    ),
  ],
  captures: {
    'token': 'body.data.token',
    'contactId': 'body.contact.id',
    'etag': 'header.ETag',
  },
  description:
      'Updates the billing contact of an enterprise customer. Needs a token '
          'from Login and the tenant id. ' *
      4,
  preRequestScript: [
    'const ts = Date.now();',
    'pm.environment.set("requestedAt", ts);',
    'pm.variables.set("aVeryLongVariableNameUsedForTenantScopedRequests", '
        '"tenant-0000-1111-2222-3333");',
  ].join('\n'),
  testScript: [
    'pm.test("updated", function () {',
    '  pm.response.to.have.status(200);',
    '  pm.expect(pm.response.json().contact.name).to.eql("Ada Lovelace");',
    '});',
  ].join('\n'),
);

CollectionModel _longCollectionModel(String base) => CollectionModel(
  name: _longCollection,
  variables: [
    KV(key: 'baseUrl', value: base),
    KV(
      key: 'aVeryLongVariableNameUsedForTenantScopedRequests',
      value: 'tenant-0000-1111-2222-3333-4444-5555-6666',
    ),
  ],
  requests: [
    _kitchenSink(base),
    RequestModel(
      name:
          'Generate the quarterly reconciliation report for every European '
          'subsidiary and email it to finance',
      method: 'OPTIONS',
      url:
          '$base/reports/quarterly?region=eu&subsidiaries=all&format=pdf'
          '&include=credit-notes,refunds,adjustments',
      folder: _deepFolder,
    ),
    RequestModel(
      name: 'Search',
      method: 'QUERY',
      url: '$base/search',
      folder: 'Accounts and Billing Administration',
    ),
    RequestModel(name: 'Purge cache', method: 'DELETE', url: '$base/cache'),
    RequestModel(name: 'Head check', method: 'HEAD', url: '$base/json'),
  ],
);

List<EnvironmentModel> _environments(String base) => [
  EnvironmentModel(
    name: _longEnv,
    variables: [
      KV(key: 'baseUrl', value: base),
      KV(
        key: 'token',
        value:
            'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.'
            'dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U',
      ),
      KV(key: 'apiKey', value: 'ak_live_0123456789abcdef'),
      KV(key: 'user', value: 'support@enterprise-customer.example.com'),
      KV(key: 'pass', value: 's3cret', enabled: false),
      for (var i = 0; i < 8; i++)
        KV(key: 'featureFlag$i', value: 'enabled-for-region-eu-west-$i'),
    ],
  ),
  EnvironmentModel(
    name: 'Local',
    variables: [KV(key: 'baseUrl', value: base)],
  ),
  EnvironmentModel(name: 'Staging'),
];

List<HistoryEntry> _history(String base) => [
  for (final (code, path, ms) in [
    (200, '/json', 85),
    (201, '/orders', 120),
    (404, '/missing/a/very/long/path/that/keeps/going/and/going', 12),
    (500, '/error', 1450),
    (0, '/offline', 0),
    (302, '/redirect?to=somewhere-far-away-on-the-internet', 33),
  ])
    HistoryEntry(
      request: RequestModel(
        method: code == 201 ? 'POST' : 'GET',
        url: '$base$path',
      ),
      statusCode: code,
      durationMs: ms,
      at: DateTime.now().subtract(Duration(minutes: ms)),
    ),
];

// ---------------------------------------------------------------- server

Future<HttpServer> _startServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    await req.drain<void>();
    final res = req.response;
    res.headers.set(
      _longHeader.toLowerCase(),
      '00-${'4bf92f3577b34da6' * 4}-01',
    );
    res.headers.set(
      'set-cookie',
      'session=${'abcdef0123456789' * 6}; Path=/; HttpOnly; Secure; '
          'SameSite=Strict; Max-Age=31536000',
    );
    switch (req.uri.path) {
      case '/large':
        res.headers.contentType = ContentType.json;
        res.write(
          jsonEncode({
            'items': [
              for (var i = 0; i < 3000; i++)
                {
                  'id': i,
                  'name': 'Item number $i',
                  'tags': ['a', 'b', 'c'],
                },
            ],
          }),
        );
      case '/error':
        res.statusCode = 500;
        res.headers.contentType = ContentType.json;
        res.write(
          jsonEncode({
            'error': 'Internal Server Error',
            'trace':
                'java.lang.NullPointerException: ${'at com.example.' * 20}',
          }),
        );
      case '/missing':
        res.statusCode = 404;
        res.headers.contentType = ContentType.html;
        res.write('<html><body><h1>Not Found</h1></body></html>');
      case '/text':
        res.headers.contentType = ContentType.text;
        res.write('token=${'x' * 3000}\n${'word ' * 400}');
      case '/slow':
        await Future<void>.delayed(const Duration(milliseconds: 700));
        res.headers.contentType = ContentType.json;
        res.write('{"slow": true}');
      default:
        res.headers.contentType = ContentType.json;
        res.write(
          jsonEncode({
            'data': {
              'token': 'tok-123',
              'user': {'id': 7, 'role': 'admin'},
            },
            'contact': {'id': 99, 'name': 'Ada Lovelace'},
            'customer': {
              'addresses': [
                {
                  'postalCode': {'extendedFormat': 'SW1A 1AA'},
                  'line1': 'A very long street name that goes on and on',
                },
              ],
            },
            'longValue': 'z' * 400,
          }),
        );
    }
    try {
      await res.close();
    } catch (_) {
      // Clients cancelled by the test may disconnect first.
    }
  });
  return server;
}

// ---------------------------------------------------------------- sweep

/// One problem found by the sweep.
class _Issue {
  _Issue(this.where, this.kind, this.message, this.location);

  final String where;
  final String kind;
  final String message;
  final String location;

  /// Groups the same root cause across sizes and themes.
  String get key =>
      '$kind|${message.replaceAll(RegExp(r'\d+(\.\d+)?'), '#')}|$location';
}

class _Sweep {
  _Sweep(this.tester, this.base, this.offlineUrl, this.tmp);

  final WidgetTester tester;
  final String base;
  final String offlineUrl;
  final Directory tmp;

  final issues = <_Issue>[];
  final _seen = <String>{};
  final coverage = <String, Set<String>>{};
  var checks = 0;
  final _geometryTime = Stopwatch();
  final _settleTime = Stopwatch();

  late _Config cfg;
  late AppState state;
  String where = 'setup';
  String _screen = 'setup';

  // -------------------------------------------------------------- reporting

  void issue(String kind, String message, [String location = '']) {
    final i = _Issue(where, kind, message, location);
    if (_seen.add('${i.where}|${i.key}')) {
      issues.add(i);
      if (_verbose) debugPrint('  ! ${i.where}: [$kind] $message $location');
    }
  }

  void onFlutterError(FlutterErrorDetails d) {
    final text = d.toString();
    final first = d.exceptionAsString().trim().split('\n').first;
    final locs = <String>[];
    for (final m in RegExp(
      r'(\w+)?[ \w]*:?file://\S*?/(lib/\S+?\.dart:\d+:\d+)',
    ).allMatches(text)) {
      final loc = '${m.group(1) ?? ''} ${m.group(2)}'.trim();
      if (!locs.contains(loc)) locs.add(loc);
      if (locs.length == 2) break;
    }
    if (locs.isEmpty) {
      final frame = (d.stack?.toString() ?? '')
          .split('\n')
          .where((l) => l.contains('package:api_workbench/'))
          .take(1)
          .map((l) => l.replaceAll(RegExp(r'^#\d+\s+'), '').trim());
      locs.addAll(frame);
    }
    issue('FlutterError', first, locs.join(' ← '));
  }

  String report() {
    final groups = <String, List<_Issue>>{};
    for (final i in issues) {
      groups.putIfAbsent(i.key, () => []).add(i);
    }
    final b = StringBuffer(
      '${issues.length} layout issue(s) in ${groups.length} distinct '
      'place(s):\n',
    );
    var n = 0;
    for (final g in groups.values) {
      n++;
      final i = g.first;
      b.writeln('\n$n. [${i.kind}] ${i.message}');
      if (i.location.isNotEmpty) b.writeln('   at ${i.location}');
      final wheres = g.map((x) => x.where).toList();
      for (final w in wheres.take(6)) {
        b.writeln('   - $w');
      }
      if (wheres.length > 6) b.writeln('   … and ${wheres.length - 6} more');
    }
    return b.toString();
  }

  // -------------------------------------------------------------- driving

  Future<void> settle() async {
    _settleTime.start();
    try {
      await tester.pumpAndSettle(
        const Duration(milliseconds: 1),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 20),
      );
    } finally {
      _settleTime.stop();
    }
  }

  /// Pumps with real time passing until [done] or about [seconds].
  Future<void> pumpUntil(bool Function() done, {int seconds = 20}) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (!done()) {
      if (DateTime.now().isAfter(end)) {
        throw StateError('timed out waiting on $_screen');
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  bool has(Finder f) {
    try {
      return f.evaluate().isNotEmpty;
    } on StateError {
      return false; // `.first` of nothing
    }
  }

  /// Taps the first match after scrolling it into view, and records an
  /// issue when something else would receive the tap (a covered control).
  Future<void> tap(Finder f, {bool settleAfter = true}) async {
    final target = f.first;
    await bringIntoView(target);
    final center = tester.getCenter(target);
    final ro = tester.renderObject(target);
    final hit = tester.hitTestOnBinding(center);
    if (!hit.path.any((e) => e.target == ro)) {
      final top = hit.path.isEmpty ? null : hit.path.first.target;
      final creator = top is RenderObject ? top.debugCreator : null;
      issue(
        'Covered',
        'tap on ${_describe(target.evaluate().first)} '
            '${_r(tester.getRect(target))} lands on '
            '${top.runtimeType} ($creator)',
      );
    }
    await tester.tapAt(center);
    if (settleAfter) await settle();
  }

  /// Scrolls [target] into view only where it is not already visible.
  /// (tester.ensureVisible aligns it in every enclosing scroll view, which
  /// also slides a TabBarView page sideways off its page boundary.)
  Future<void> bringIntoView(Finder target) async {
    if (has(target)) {
      final ro = tester.renderObject(target);
      if (ro is RenderBox && ro.hasSize) {
        final vis = _visible(ro, _root);
        final full = _rectOf(ro, _root);
        final screen = Offset.zero & cfg.size;
        if (vis == full && screen.intersect(full) == full) return;
      }
    }
    // Three passes with a frame between them: a lazy list only estimates
    // its length until it has laid out the rows near the target.
    for (final policy in [
      ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
    ]) {
      if (!has(target)) return;
      await Scrollable.ensureVisible(
        tester.element(target),
        alignmentPolicy: policy,
      );
      await tester.pump();
    }
  }

  /// Scrolls the vertical scroll views in [within] until [f] is built and
  /// visible (lazy lists do not build far-away children).
  Future<void> reveal(Finder f, {required Finder within}) async {
    if (!has(f)) {
      final scrollables = find
          .descendant(of: within, matching: find.byType(Scrollable))
          .evaluate()
          .where((e) {
            final st = (e as StatefulElement).state as ScrollableState;
            return st.position.axis == Axis.vertical &&
                e.findAncestorWidgetOfExactType<EditableText>() == null;
          })
          .toList();
      for (final e in scrollables) {
        final pos = ((e as StatefulElement).state as ScrollableState).position;
        pos.jumpTo(0);
        await tester.pump();
        while (!has(f) && pos.pixels < pos.maxScrollExtent) {
          pos.jumpTo(
            math.min(
              pos.pixels + pos.viewportDimension * 0.8,
              pos.maxScrollExtent,
            ),
          );
          await tester.pump();
        }
        if (has(f)) break;
      }
    }
    if (!has(f)) return;
    await bringIntoView(f.first);
    await settle();
  }

  /// Closes a dialog with its [label] button on desktop, or the close
  /// button of the full-screen version on phones.
  Future<void> dismiss(String label) async {
    final button = find.text(label);
    if (has(button)) {
      await tap(button.last);
    } else {
      await tap(find.byType(CloseButton).last);
    }
  }

  Future<void> popTop() async {
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await settle();
  }

  Future<void> enter(Finder f, String text) async {
    await bringIntoView(f.first);
    await tester.enterText(f.first, text);
    await settle();
  }

  Future<void> recover() async {
    try {
      tester.view.resetViewInsets();
      FocusManager.instance.primaryFocus?.unfocus();
      if (has(find.byType(Navigator))) {
        tester
            .state<NavigatorState>(find.byType(Navigator).first)
            .popUntil((r) => r.isFirst);
      }
      await settle();
      closeDrawer();
      await tester.pump(const Duration(milliseconds: 50));
      await settle();
    } catch (_) {
      // Best effort: the next flow reports whatever is still wrong.
    }
  }

  void closeDrawer() {
    for (final e in find.byType(Scaffold, skipOffstage: false).evaluate()) {
      final s = (e as StatefulElement).state as ScaffoldState;
      if (s.isDrawerOpen) s.closeDrawer();
    }
  }

  /// Runs a group of steps; an exception is recorded and the UI reset so
  /// the rest of the sweep still runs.
  Future<void> flow(String name, Future<void> Function() body) async {
    final started = DateTime.now();
    try {
      await body();
      if (_verbose) {
        debugPrint(
          '  ${cfg.name} › $name: '
          '${DateTime.now().difference(started).inMilliseconds} ms',
        );
      }
    } catch (e, st) {
      where = '${cfg.name} › $_screen';
      final frame = st
          .toString()
          .split('\n')
          .where(
            (l) =>
                l.contains('layout_sweep_test.dart') ||
                l.contains('package:api_workbench/'),
          )
          .take(1)
          .join();
      issue(
        'Exception',
        '$name: ${e.toString().split('\n').first}',
        frame.replaceAll(RegExp(r'^#\d+\s+'), '').trim(),
      );
      if (_verbose) {
        final top = _topLayer();
        final texts = top == null
            ? const <String>[]
            : find
                  .descendant(
                    of: find.byElementPredicate((x) => x == top),
                    matching: find.byType(Text),
                  )
                  .evaluate()
                  .map((x) => (x.widget as Text).data ?? '')
                  .where((t) => t.isNotEmpty)
                  .take(40)
                  .toList();
        debugPrint('    top layer texts: ${texts.join(' | ')}');
      }
      await recover();
    }
  }

  /// Performs [action], lets the UI settle and checks the result (also with
  /// the software keyboard open on touch sizes when [keyboard] is set).
  Future<void> show(
    String screen,
    Future<void> Function() action, {
    bool keyboard = false,
    bool settleAfter = true,
    bool scroll = true,
  }) async {
    _screen = screen;
    where = '${cfg.name} › $screen';
    await action();
    if (settleAfter) {
      await settle();
    } else {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await check(screen, scroll: scroll && settleAfter);
    if (keyboard && cfg.touch) {
      final kb = '$screen + keyboard';
      _screen = kb;
      where = '${cfg.name} › $kb';
      tester.view.viewInsets = FakeViewPadding(
        bottom: (cfg.size.height * 0.42).roundToDouble(),
      );
      await settle();
      await check(kb);
      tester.view.resetViewInsets();
      await settle();
      _screen = screen;
      where = '${cfg.name} › $screen';
    }
  }

  Future<void> check(String screen, {bool scroll = true}) async {
    checks++;
    coverage.putIfAbsent(cfg.name, () => <String>{}).add(screen);
    geometry();
    if (scroll) await scrollThrough();
  }

  // -------------------------------------------------------------- geometry

  static bool _isControl(Widget w) =>
      w is ButtonStyleButton ||
      w is IconButton ||
      w is PopupMenuButton ||
      w is Checkbox ||
      w is Switch ||
      w is Radio ||
      w is RawChip ||
      w is TextField ||
      w is DropdownButton ||
      w is SegmentedButton ||
      w is TabBar ||
      (w is ListTile && (w.onTap != null || w.onLongPress != null)) ||
      (w is InkResponse && (w.onTap != null || w.onLongPress != null));

  /// Built-in controls (buttons, fields, chips…) whose inner ink wells and
  /// buttons are parts of themselves rather than separate targets.
  static bool _isCompound(Widget w) => w is! InkResponse && _isControl(w);

  Element? _topLayer() {
    final scopes = find
        .byWidgetPredicate(
          (w) => w.runtimeType.toString().startsWith('_ModalScope'),
        )
        .evaluate()
        .toList();
    if (scopes.isEmpty) return null;
    final top = scopes.last;
    final drawers = find
        .descendant(
          of: find.byElementPredicate((e) => e == top),
          matching: find.byType(Drawer),
        )
        .evaluate();
    return drawers.isEmpty ? top : drawers.first;
  }

  RenderBox get _root =>
      tester.renderObject<RenderBox>(find.byType(ApiWorkbenchApp));

  Rect _rectOf(RenderBox box, RenderBox root) => MatrixUtils.transformRect(
    box.getTransformTo(root),
    Offset.zero & box.size,
  );

  /// The part of [box] not clipped away by scroll views and clips.
  Rect _visible(RenderBox box, RenderBox root) {
    var rect = _rectOf(box, root);
    RenderObject? p = box.parent;
    while (p != null && p != root) {
      if (p is RenderBox &&
          (p is RenderAbstractViewport ||
              p is RenderClipRect ||
              p is RenderClipRRect ||
              p is RenderClipPath)) {
        rect = rect.intersect(_rectOf(p, root));
        if (rect.width <= 0 || rect.height <= 0) return Rect.zero;
      }
      p = p.parent;
    }
    return rect;
  }

  static String _describe(Element e) {
    final w = e.widget;
    String? label = switch (w) {
      IconButton(:final tooltip) => tooltip,
      PopupMenuButton(:final tooltip) => tooltip,
      TextField(:final decoration) =>
        decoration?.labelText ?? decoration?.hintText,
      _ => null,
    };
    if (w is Text) label = w.data;
    if (label == null) {
      void visit(Element c) {
        if (label != null) return;
        final cw = c.widget;
        if (cw is Text) {
          label = cw.data ?? cw.textSpan?.toPlainText();
        } else if (cw is Tooltip) {
          label = cw.message ?? cw.richMessage?.toPlainText();
        } else if (cw is Icon) {
          label = 'icon ${cw.icon?.codePoint.toRadixString(16)}';
        }
        c.visitChildren(visit);
      }

      e.visitChildren(visit);
    }
    final l = (label ?? '').replaceAll('\n', ' ');
    final short = l.length > 48 ? '${l.substring(0, 45)}…' : l;
    return '${w.runtimeType.toString().split('<').first}'
        '${short.isEmpty ? '' : ' "$short"'}';
  }

  void geometry() {
    _geometryTime.start();
    try {
      _geometry();
    } finally {
      _geometryTime.stop();
    }
  }

  void _geometry() {
    final top = _topLayer();
    if (top == null) return;
    final root = _root;
    final screen = Offset.zero & cfg.size;
    final controls = <(Element, Rect, RenderBox)>[];
    final all = find
        .descendant(
          of: find.byElementPredicate((e) => e == top),
          matching: find.byWidgetPredicate(_isControl),
        )
        .evaluate();
    for (final e in all) {
      var internal = false;
      e.visitAncestorElements((a) {
        if (a == top) return false;
        if (_isCompound(a.widget)) {
          internal = true;
          return false;
        }
        return true;
      });
      if (internal) continue;
      final ro = e.renderObject;
      if (ro is! RenderBox || !ro.hasSize || !ro.attached) continue;
      final vis = _visible(ro, root);
      if (vis.isEmpty) continue;
      controls.add((e, vis, ro));
    }

    for (final (e, vis, ro) in controls) {
      if (vis.left < screen.left - 0.5 ||
          vis.top < screen.top - 0.5 ||
          vis.right > screen.right + 0.5 ||
          vis.bottom > screen.bottom + 0.5) {
        issue(
          'Off screen',
          '${_describe(e)} at ${_r(vis)} is outside ${_r(screen)}',
        );
      }
      if (cfg.touch) {
        final w = e.widget;
        final exempt = w is TextField || w is TabBar;
        final s = ro.size;
        if (!exempt && math.min(s.width, s.height) < 44 - 0.5) {
          issue(
            'Touch target',
            '${_describe(e)} is ${s.width.toStringAsFixed(0)}×'
                '${s.height.toStringAsFixed(0)} px (< 44)',
          );
        }
      }
    }

    for (var i = 0; i < controls.length; i++) {
      for (var j = i + 1; j < controls.length; j++) {
        final (a, ra, _) = controls[i];
        final (b, rb, _) = controls[j];
        final o = ra.intersect(rb);
        if (o.width <= 1 || o.height <= 1) continue;
        if (_related(a, b)) continue;
        issue(
          'Overlap',
          '${_describe(a)} ${_r(ra)} overlaps ${_describe(b)} ${_r(rb)}',
        );
      }
    }
  }

  static bool _related(Element a, Element b) {
    bool isAncestor(Element anc, Element of) {
      var found = false;
      of.visitAncestorElements((x) {
        if (x == anc) {
          found = true;
          return false;
        }
        return true;
      });
      return found;
    }

    return isAncestor(a, b) || isAncestor(b, a);
  }

  static String _r(Rect r) =>
      '(${r.left.toStringAsFixed(0)},${r.top.toStringAsFixed(0)} '
      '${r.width.toStringAsFixed(0)}×${r.height.toStringAsFixed(0)})';

  /// Scrolls every vertical scroll view of the top layer to its end in
  /// steps (lazy lists only lay out what is near the viewport), checking
  /// geometry on the way, then back to the top.
  Future<void> scrollThrough() async {
    final top = _topLayer();
    if (top == null) return;
    final scrollables = find
        .descendant(
          of: find.byElementPredicate((e) => e == top),
          matching: find.byType(Scrollable),
        )
        .evaluate()
        .map((e) => (e as StatefulElement).state as ScrollableState)
        .where(
          (s) =>
              s.position.axis == Axis.vertical &&
              s.position.hasContentDimensions &&
              s.position.maxScrollExtent > 0,
        )
        .where(
          (s) =>
              s.context.findAncestorWidgetOfExactType<EditableText>() == null,
        )
        .toList();
    for (final s in scrollables) {
      if (!s.mounted) continue;
      final pos = s.position;
      var steps = 0;
      while (pos.pixels < pos.maxScrollExtent - 0.5 && steps < 12) {
        final step = math.max(
          pos.viewportDimension * 0.9,
          pos.maxScrollExtent / 10,
        );
        pos.jumpTo(math.min(pos.pixels + step, pos.maxScrollExtent));
        await tester.pump();
        geometry();
        steps++;
        if (!s.mounted) break;
      }
      if (s.mounted && pos.pixels != 0) {
        pos.jumpTo(0);
        await tester.pump();
      }
    }
  }

  // -------------------------------------------------------------- app

  Future<AppState> newState({required bool seeded}) async {
    final dir = await Directory(
      '${tmp.path}/${cfg.name.replaceAll(RegExp(r'\W+'), '_')}'
      '${seeded ? '_seeded' : '_empty'}',
    ).create(recursive: true);
    final soundDir = Directory('${dir.path}/apiworkbench/sounds');
    await soundDir.create(recursive: true);
    if (seeded) {
      await File('${soundDir.path}/sounds.json').writeAsString(
        jsonEncode([
          {
            'id': 'u1.mp3',
            'name':
                'a-really-long-imported-sound-file-name-from-myinstants-sad-'
                'violin-airhorn-remix-final.mp3',
          },
          {'id': 'u2.mp3', 'name': 'bruh.mp3'},
        ]),
      );
    }
    final s = AppState(
      storage: Storage(overrideDir: dir),
      sounds: SoundService(overrideDir: dir),
    );
    for (var i = 0; i < 200 && !s.loaded; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (!s.loaded) throw StateError('AppState did not load');
    s.updateSettings(
      s.settings
        ..theme = cfg.theme
        ..themeMode = cfg.mode
        ..hoverHelp = cfg.hoverHelp,
    );
    if (seeded) {
      final report = importApiFile(jsonEncode(_shopApi(base)));
      s.mergeWorkspace([
        ...report.collections,
        _longCollectionModel(base),
      ], _environments(base));
      s.setActiveEnvironment(s.environments.first.id);
      s.history.addAll(_history(base));
      s.notifyRefresh();
    }
    return s;
  }

  Future<void> pumpApp(AppState s) async {
    state = s;
    await tester.pumpWidget(ApiWorkbenchApp(state: s));
    await settle();
    final mq = MediaQuery.sizeOf(tester.element(find.byType(HomeScreen)));
    if (mq != cfg.size) {
      issue('Viewport', 'MediaQuery size $mq != requested ${cfg.size}');
    }
    final layoutOk = cfg.desktop
        ? !has(find.byType(NavigationBar))
        : has(find.byType(NavigationBar));
    if (!layoutOk) issue('Viewport', 'wrong layout for ${cfg.size}');
  }

  Future<void> unpump() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    final s = state;
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    s.dispose();
  }

  // -------------------------------------------------------------- finders

  Finder get editorTabBar => find.descendant(
    of: find.byType(RequestEditor),
    matching: find.byType(TabBar),
  );

  Finder get responseTabBar => find.descendant(
    of: find.byType(ResponseView),
    matching: find.byType(TabBar),
  );

  Future<void> editorTab(int i) async {
    DefaultTabController.of(tester.element(editorTabBar)).index = i;
    await settle();
  }

  Future<void> responseTab(int i) async {
    DefaultTabController.of(tester.element(responseTabBar)).index = i;
    await settle();
  }

  Finder get urlField => find.byWidgetPredicate(
    (w) => w is TextField && w.keyboardType == TextInputType.url,
  );

  Future<void> openDrawer() async {
    await tap(find.byTooltip('Open navigation menu'));
  }

  /// Shows a side panel section (desktop) or drawer section (touch).
  Future<void> showSection(SidebarSection s) async {
    if (cfg.desktop) {
      final panel = find.byType(Sidebar);
      if (has(panel) && tester.widget<Sidebar>(panel).section == s) return;
      await tap(
        find.text(switch (s) {
          SidebarSection.collections => 'Collections',
          SidebarSection.environments => 'Envs',
          SidebarSection.history => 'History',
        }).first,
      );
    } else {
      if (!has(find.byType(Drawer))) await openDrawer();
      await tap(find.byTooltip(s.label));
    }
  }

  Future<void> leaveDrawer() async {
    closeDrawer();
    await settle();
  }

  /// Expands every collection and folder in the tree.
  Future<void> expandTree() async {
    for (final name in [
      'Shop API',
      'Auth',
      'Orders',
      'Admin',
      _longCollection,
      'Accounts and Billing Administration',
      'Invoices, Credit Notes and Refund Processing',
      'Quarterly Reconciliation Reports',
    ]) {
      final f = inPanel(find.text(name));
      if (!has(f)) await reveal(f, within: find.byType(Sidebar));
      if (!has(f)) continue;
      // Expanded rows show their chevron turned down; tap only closed ones,
      // since a drawer or panel can keep its expanded rows.
      final chevron = find.descendant(
        of: find.ancestor(of: f.first, matching: find.byType(InkWell)).first,
        matching: find.byType(AnimatedRotation),
      );
      if (has(chevron) && tester.widget<AnimatedRotation>(chevron).turns > 0) {
        continue;
      }
      await tap(f.first);
    }
  }

  /// [f] within the side panel or drawer (the editor behind a drawer can
  /// show the same text, such as the Auth tab).
  Finder inPanel(Finder f) =>
      find.descendant(of: find.byType(Sidebar), matching: f);

  Future<void> mobileSection(String label) async {
    if (cfg.desktop) return;
    await tap(find.text(label).last);
  }

  // -------------------------------------------------------------- flows

  Future<void> run() async {
    // Empty workspace: onboarding states.
    await pumpApp(await newState(seeded: false));
    await flow('empty states', () async {
      await show('empty · home', () async {});
      await show(
        'empty · collections',
        () => showSection(SidebarSection.collections),
      );
      await show(
        'empty · environments',
        () => showSection(SidebarSection.environments),
      );
      await show('empty · history', () => showSection(SidebarSection.history));
      if (cfg.touch) {
        await leaveDrawer();
        await show('empty · response', () => mobileSection('Response'));
        await mobileSection('Request');
      } else {
        await showSection(SidebarSection.collections);
      }
    });
    await unpump();

    // Seeded workspace.
    await pumpApp(await newState(seeded: true));
    final shop = state.collections.first;
    final long = state.collections.last;
    final kitchen = long.requests.first;

    await flow('sections', () async {
      await show('home', () async {});
      await show('collections tree', () async {
        await showSection(SidebarSection.collections);
        await expandTree();
      });
      await show(
        'collection menu',
        () => tap(find.byTooltip('Collection actions').first),
      );
      await show(
        'collection variables',
        () => tap(find.text('Variables').last),
        keyboard: true,
      );
      await dismiss('Done');
      await show(
        'long collection menu',
        () => tap(find.byTooltip('Collection actions').last),
      );
      await show(
        'rename collection',
        () => tap(find.text('Rename').last),
        keyboard: true,
      );
      await dismiss('Cancel');
      await tap(find.byTooltip('Collection actions').last);
      await show('delete collection', () => tap(find.text('Delete').last));
      await dismiss('Cancel');
      await show(
        'folder menu',
        () => tap(find.byTooltip('Folder actions').last),
      );
      await show('import into folder', () async {
        await tap(find.text('Import into folder').last);
        await enter(
          find.widgetWithText(TextField, 'Or paste Postman JSON here'),
          jsonEncode({
            'name': 'Refund order with a long name for the import summary',
            'request': {
              'method': 'POST',
              'url': '{{baseUrl}}/orders/42/refund',
            },
          }),
        );
        await tap(find.text('Add').last);
      }, keyboard: true);
      await dismiss('Cancel');
      await show(
        'request menu',
        () => tap(find.byTooltip('Request actions').last),
      );
      await popTop();
      await show(
        'new collection prompt',
        () => tap(find.byTooltip('Create a collection')),
        keyboard: true,
      );
      await dismiss('Cancel');

      await show(
        'environments',
        () => showSection(SidebarSection.environments),
      );
      await show(
        'environment editor',
        () => tap(find.byTooltip("Edit this environment's variables").first),
        keyboard: true,
      );
      await dismiss('Done');
      await show(
        'new environment prompt',
        () => tap(find.byTooltip('Create an environment')),
      );
      await dismiss('Cancel');
      await show('history', () => showSection(SidebarSection.history));
      if (cfg.desktop) {
        // Re-clicking the active item hides the side panel.
        await show('panel hidden', () => tap(find.text('History').first));
        await tap(find.text('Collections').first);
      } else {
        await leaveDrawer();
      }
      await show(
        'environment picker',
        () => tap(find.byType(EnvironmentPicker)),
      );
      await popTop();
    });

    await flow('request editor', () async {
      await show('open request from tree', () async {
        await showSection(SidebarSection.collections);
        await expandTree();
        await tap(inPanel(find.text(_kitchenName)).first);
        if (cfg.touch) await leaveDrawer();
      });
      final tabs = [
        'params',
        'headers',
        'body',
        'auth',
        'tests',
        'captures',
        'docs',
      ];
      for (var i = 0; i < tabs.length; i++) {
        await show('editor · ${tabs[i]}', () => editorTab(i), keyboard: i != 5);
      }
      await editorTab(2);
      for (final t in BodyType.values) {
        await show(
          'body · ${t.label}',
          () => tap(find.widgetWithText(ChoiceChip, t.label)),
          keyboard: t == BodyType.formData || t == BodyType.graphql,
        );
      }
      await tap(find.widgetWithText(ChoiceChip, BodyType.json.label));
      await editorTab(3);
      for (final t in AuthType.values) {
        if (t == AuthType.values.first) {
          await show(
            'auth dropdown',
            () => tap(find.byType(DropdownButtonFormField<AuthType>)),
          );
        } else {
          await tap(find.byType(DropdownButtonFormField<AuthType>));
        }
        await show(
          'auth · ${t.label}',
          () => tap(find.text(t.label).last),
          keyboard: t == AuthType.apiKey,
        );
      }
      await tap(find.byType(DropdownButtonFormField<AuthType>));
      await tap(find.text(AuthType.basic.label).last);
      await editorTab(4);
      await show(
        'assertion kind menu',
        () => tap(find.byType(DropdownButtonFormField<AssertKind>).first),
      );
      await popTop();
      await editorTab(6);
      await show('docs · script expanded', () async {
        await reveal(
          find.text('Test script'),
          within: find.byType(RequestEditor),
        );
        await tap(find.text('Test script'));
      });
      await editorTab(0);
      await show('more menu', () => tap(find.byTooltip('More')));
      await show(
        'save dialog',
        () => tap(find.text('Save to collection…')),
        keyboard: true,
      );
      await dismiss('Cancel');
      await tap(find.byTooltip('More'));
      await show(
        'import cURL dialog',
        () => tap(find.text('Import cURL…')),
        keyboard: true,
      );
      await dismiss('Cancel');
      await show(
        'rename request',
        () => tap(
          find.descendant(
            of: find.byType(RequestEditor),
            matching: find.text(_kitchenName),
          ),
        ),
        keyboard: true,
      );
      await dismiss('Cancel');
      await show('url field focused', () => tap(urlField), keyboard: true);
      FocusManager.instance.primaryFocus?.unfocus();
      await settle();
    });

    await flow('fixture requests', () async {
      for (final r in shop.requests) {
        await show('request · ${r.name} · body', () async {
          state.openRequest(r, collectionId: shop.id);
          await settle();
          await editorTab(2);
        });
      }
    });

    await flow('responses', () async {
      Future<void> send(String name, String path, {String? url}) async {
        state.newTab(
          RequestModel(
            name: name,
            url: url ?? '$base$path',
            assertions: [
              AssertionModel(expected: '200'),
              AssertionModel(
                kind: AssertKind.jsonEquals,
                target: 'data.user.role',
                expected: 'admin',
              ),
              AssertionModel(
                kind: AssertKind.headerContains,
                target: 'Content-Type',
                expected: 'json',
              ),
            ],
          ),
        );
        await settle();
        await tester.runAsync(() => state.sendActive());
        await settle();
      }

      await send('JSON response', '/json');
      await mobileSection('Response');
      await show('response · pretty', () async {});
      await show('response · raw', () => responseTab(1));
      await show('response · headers', () => responseTab(2));
      await show('response · tests', () => responseTab(3));
      await show('response · chaos status bar', () async {
        state.updateSettings(state.settings..chaosMode = true);
      });
      state.updateSettings(state.settings..chaosMode = false);
      await settle();
      for (final (name, path, url) in [
        ('Large response', '/large', null),
        ('Server error', '/error', null),
        ('Not found', '/missing', null),
        ('Plain text', '/text', null),
        ('Offline', '', offlineUrl),
      ]) {
        await mobileSection('Request');
        await send(name, path, url: url);
        await mobileSection('Response');
        await show('response · $name', () async {});
      }
      await mobileSection('Request');
      // Loading state (spinner, progress bar, Cancel button).
      state.newTab(RequestModel(name: 'Slow', url: '$base/slow'));
      await settle();
      final pending = state.sendActive();
      await show('request · sending', () async {}, settleAfter: false);
      if (cfg.touch) {
        await show(
          'response · loading',
          () => tap(find.text('Response').last, settleAfter: false),
          settleAfter: false,
        );
      }
      await tester.runAsync(() => pending);
      await settle();
      await mobileSection('Request');
      await show(
        'history after sends',
        () => showSection(SidebarSection.history),
      );
      if (cfg.touch) await leaveDrawer();
      if (cfg.desktop) await showSection(SidebarSection.collections);
    });

    await flow('settings and chaos', () async {
      if (cfg.desktop) {
        await show(
          'settings',
          () => tap(find.text('Settings').first),
          keyboard: true,
        );
      } else {
        await show(
          'workspace menu',
          () => tap(find.byTooltip('Workspace menu')),
        );
        await show(
          'settings',
          () => tap(find.text('Settings…')),
          keyboard: true,
        );
      }
      await show('settings · chaos on', () => tap(find.text('🎲 Chaos')));
      await show('chaos dialog', () async {
        await tap(find.text('Configure sounds…'), settleAfter: false);
        await pumpUntil(() => has(find.text('Chaos Mode')));
        await settle();
      });
      await dismiss('Done');
      state.updateSettings(state.settings..chaosMode = false);
      await settle();
      if (cfg.desktop) {
        await show('mode toggle chaos', () async {
          state.updateSettings(state.settings..chaosMode = true);
        });
        state.updateSettings(state.settings..chaosMode = false);
        await settle();
      }
    });

    await flow('import dialog', () async {
      if (cfg.desktop) {
        await show('import', () => tap(find.text('Import').first));
      } else {
        await tap(find.byTooltip('Workspace menu'));
        await show(
          'import',
          () => tap(find.text('Import (Postman, workspace)…')),
        );
      }
      await show('import · summary', () async {
        final paste = find.widgetWithText(
          TextField,
          'Or paste Postman JSON here',
        );
        await enter(paste, jsonEncode(_shopApi(base)));
        await tap(find.text('Add').last);
        await enter(
          paste,
          jsonEncode({
            'name': 'Staging with a long environment name for the summary',
            'values': [
              {'key': 'baseUrl', 'value': base},
            ],
          }),
        );
        await tap(find.text('Add').last);
      }, keyboard: true);
      await show(
        'import · destination menu',
        () => tap(find.byType(DropdownButtonFormField<String>).last),
      );
      await show(
        'import · into existing',
        () => tap(find.textContaining('Existing: Customer').last),
      );
      await dismiss('Cancel');
    });

    await flow('runner', () async {
      if (cfg.touch) await showSection(SidebarSection.collections);
      await tap(find.byTooltip('Collection actions').first);
      await show('runner', () => tap(find.text('Run collection').last));
      await show('runner · data + recurring', () async {
        await tap(find.text('Data'));
        await enter(
          find.byWidgetPredicate(
            (w) =>
                w is TextField &&
                (w.decoration?.hintText ?? '').startsWith('JSON array'),
          ),
          '[{"userId": "1"}, {"userId": "2"}]',
        );
        await tap(find.byType(Switch).first);
      }, keyboard: true);
      await tap(find.byType(Switch).first);
      await enter(
        find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              (w.decoration?.hintText ?? '').startsWith('JSON array'),
        ),
        '',
      );
      await show('runner · results', () async {
        await tap(find.widgetWithText(FilledButton, 'Run'), settleAfter: false);
        await pumpUntil(
          () =>
              has(find.textContaining('Showing')) &&
              has(find.widgetWithText(FilledButton, 'Run')),
        );
        await settle();
      });
      await show(
        'runner · result expanded',
        () => tap(find.byType(ExpansionTile).first),
      );
      await popTop();
    });

    await flow('load test', () async {
      if (cfg.touch) await showSection(SidebarSection.collections);
      await tap(find.byTooltip('Collection actions').first);
      await show(
        'load test',
        () => tap(find.text('Load test collection').last),
        keyboard: true,
      );
      await enter(find.widgetWithText(TextFormField, 'Parallel users'), '1');
      await enter(find.widgetWithText(TextFormField, 'Iterations / user'), '2');
      // Long enough for the sweep to see the run going.
      await enter(find.widgetWithText(TextFormField, 'Think time (ms)'), '40');
      await tap(find.text('All'));
      await show('load test · results', () async {
        await tap(find.widgetWithText(FilledButton, 'Run'), settleAfter: false);
        await pumpUntil(() => has(find.text('Stop')), seconds: 10);
        await pumpUntil(
          () => has(find.widgetWithText(FilledButton, 'Run')),
          seconds: 60,
        );
        await settle();
        await reveal(
          find.textContaining('Finished in'),
          within: find.byType(LoadTestScreen),
        );
      });
      await show('load test · saved body', () async {
        final icon = find.byIcon(Icons.description_outlined);
        await reveal(icon, within: find.byType(LoadTestScreen));
        await tap(icon);
      });
      await show('load test · save report menu', () async {
        await reveal(
          find.text('Save report'),
          within: find.byType(LoadTestScreen),
        );
        await tap(find.text('Save report'));
      });
      await popTop();
      await popTop();
      if (cfg.touch) await leaveDrawer();
    });

    await flow('kitchen-sink load test', () async {
      state.openRequest(kitchen, collectionId: long.id);
      await settle();
      await tap(find.byTooltip('More'));
      await show(
        'load test · single request',
        () => tap(find.text('Load test (parallel calls)…')),
      );
      await popTop();
    });

    await unpump();
  }
}

/// Mirrors SidebarSection without depending on its import order.
enum SidebarSectionName { collections, environments, history }

void main() {
  // Only frames the test pumps: no extra frames to fade pointer traces.
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;

  testWidgets(
    'layout sweep: no overflow, overlap or tiny touch targets anywhere',
    (tester) async {
      late HttpServer server;
      late Directory tmp;
      late String offlineUrl;
      await tester.runAsync(() async {
        tmp = await Directory.systemTemp.createTemp('aw_sweep_');
        server = await _startServer();
        final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        offlineUrl = 'http://127.0.0.1:${closed.port}/offline';
        await closed.close(force: true);
      });
      final sweep = _Sweep(
        tester,
        'http://127.0.0.1:${server.port}',
        offlineUrl,
        tmp,
      );
      final started = DateTime.now();
      final previousOnError = FlutterError.onError;
      FlutterError.onError = sweep.onFlutterError;
      // Animations (dialogs, pages, ink splashes) 50× faster: the sweep
      // checks settled layouts, which do not depend on animation speed.
      timeDilation = 0.02;
      try {
        for (final c in _configs.where((c) => c.name.contains(_only))) {
          if (_verbose) debugPrint('CONFIG ${c.name}');
          sweep.cfg = c;
          sweep.where = '${c.name} › setup';
          tester.view.physicalSize = c.size;
          tester.view.devicePixelRatio = 1;
          if (c.touch) {
            // A status bar and a gesture navigation bar, as on a phone.
            tester.view.padding = const FakeViewPadding(top: 24, bottom: 16);
            tester.view.viewPadding = const FakeViewPadding(
              top: 24,
              bottom: 16,
            );
          } else {
            tester.view.resetPadding();
            tester.view.resetViewPadding();
          }
          debugDefaultTargetPlatformOverride = c.touch
              ? TargetPlatform.android
              : null;
          await sweep.run();
        }
      } finally {
        FlutterError.onError = previousOnError;
        timeDilation = 1.0;
        debugDefaultTargetPlatformOverride = null;
        hoverHelpEnabled.value = true;
        tester.view.reset();
        await tester.runAsync(() async {
          await server.close(force: true);
          try {
            await tmp.delete(recursive: true);
          } catch (_) {}
        });
      }

      final secs = DateTime.now().difference(started).inSeconds;
      final screens = <String>{for (final s in sweep.coverage.values) ...s};
      debugPrint(
        'LAYOUT SWEEP: ${sweep.coverage.length} configurations × '
        '${screens.length} distinct screens, ${sweep.checks} checks '
        'in ${secs}s',
      );
      for (final e in sweep.coverage.entries) {
        debugPrint('  ${e.key}: ${e.value.length} screens');
      }
      if (_verbose) {
        debugPrint(
          '  time in geometry checks ${sweep._geometryTime.elapsed.inSeconds}s, '
          'settling ${sweep._settleTime.elapsed.inSeconds}s',
        );
      }
      if (sweep.issues.isNotEmpty) fail(sweep.report());
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
