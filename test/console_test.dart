import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/console_events.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/state/console_log.dart';
import 'package:api_workbench/theme.dart';
import 'package:api_workbench/ui/console_panel.dart';
import 'package:api_workbench/ui/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

const _secret = 'SECRET-TOKEN-12345';

int _n = 0;

ExchangeRecord _exchange({
  String method = 'GET',
  String url = 'http://api.test/users',
  int status = 200,
  String message = 'OK',
  int hop = 0,
  String source = 'editor',
  List<MapEntry<String, String>>? requestHeaders,
  Map<String, List<String>> responseHeaders = const {
    'content-type': ['application/json'],
  },
  Object? requestBody,
  Object? responseBody = const {'name': 'Ada', 'id': 7},
  bool responseTruncated = false,
  int? size,
  int durationMs = 42,
  String? error,
  String? protocol,
}) {
  List<int>? bytes(Object? o) =>
      o == null ? null : utf8.encode(o is String ? o : jsonEncode(o));
  final res = bytes(responseBody);
  return ExchangeRecord(
    id: 'e${_n++}',
    at: DateTime(2026, 10, 31, 12, 0, 1, 123),
    source: source,
    tabId: 't',
    hop: hop,
    method: method,
    url: Uri.parse(url),
    requestHeaders: requestHeaders ?? [const MapEntry('Accept', '*/*')],
    requestBody: bytes(requestBody),
    status: status,
    statusMessage: message,
    responseHeaders: responseHeaders,
    responseBody: res,
    responseBodyTruncated: responseTruncated,
    responseSize: size ?? res?.length ?? 0,
    durationMs: durationMs,
    error: error,
    protocol: protocol,
  );
}

ConsoleLine _line(
  String text, {
  ConsoleLevel level = ConsoleLevel.log,
  String source = '',
}) => ConsoleLine(
  level,
  text,
  at: DateTime(2026, 10, 31, 12, 0, 2),
  source: source,
);

void main() {
  group('ConsoleLog', () {
    test('keeps the newest entries within its capacity', () {
      final log = ConsoleLog(capacity: 10);
      var notified = 0;
      log.addListener(() => notified++);
      log.addLines([for (var i = 0; i < 25; i++) _line('line $i')]);
      expect(log.entries, hasLength(10));
      expect((log.entries.first as LineEntry).line.message, 'line 15');
      expect((log.entries.last as LineEntry).line.message, 'line 24');
      expect(log.dropped, 15);
      expect(notified, 1);

      for (var i = 0; i < 5; i++) {
        log.addExchange(_exchange());
      }
      expect(log.entries, hasLength(10));
      expect(log.dropped, 20);
    });

    test('numbers entries in arrival order, surviving trims', () {
      final log = ConsoleLog(capacity: 3);
      for (var i = 0; i < 6; i++) {
        log.addLines([_line('$i')]);
      }
      expect(log.entries.map((e) => e.seq).toList(), [4, 5, 6]);
    });

    test('clear empties it and resets the dropped count', () {
      final log = ConsoleLog(capacity: 2);
      log.addLines([_line('a'), _line('b'), _line('c')]);
      expect(log.dropped, 1);
      final v = log.version;
      log.clear();
      expect(log.entries, isEmpty);
      expect(log.dropped, 0);
      expect(log.version, greaterThan(v));
    });

    test('a byte budget bounds memory held by captured bodies', () {
      final log = ConsoleLog(capacity: 1000, byteBudget: 1024 * 1024);
      final big = 'x' * (300 * 1024);
      for (var i = 0; i < 20; i++) {
        log.addExchange(
          _exchange(url: 'http://api.test/$i', responseBody: big),
        );
      }
      // 300 KB bodies: only about three fit in 1 MB.
      expect(log.entries.length, lessThanOrEqualTo(4));
      expect(log.dropped, greaterThanOrEqualTo(16));
      expect((log.entries.last as ExchangeEntry).record.url.path, '/19');

      // One entry bigger than the budget is still kept: it is the newest.
      final tiny = ConsoleLog(byteBudget: 10);
      tiny.addExchange(_exchange(responseBody: big));
      expect(tiny.entries, hasLength(1));
    });

    test('counts per filter', () {
      final log = ConsoleLog()
        ..addExchange(_exchange())
        ..addExchange(_exchange(status: 404, message: 'Not Found'))
        ..addExchange(_exchange(status: 0, error: 'Connection failed'))
        ..addLines([
          _line('hi'),
          _line('bad', level: ConsoleLevel.error),
          _line('careful', level: ConsoleLevel.warn),
        ]);
      final c = log.counts();
      expect((c.all, c.network, c.logs, c.errors), (6, 3, 3, 3));
    });

    test('filters', () {
      final log = ConsoleLog()
        ..addExchange(_exchange(url: 'http://api.test/ok'))
        ..addExchange(_exchange(url: 'http://api.test/missing', status: 404))
        ..addExchange(_exchange(url: 'http://api.test/boom', status: 503))
        ..addExchange(
          _exchange(url: 'http://api.test/down', status: 0, error: 'refused'),
        )
        ..addLines([
          _line('plain'),
          _line('warned', level: ConsoleLevel.warn),
          _line('broken', level: ConsoleLevel.error),
        ]);
      List<String> names(ConsoleFilter f) => [
        for (final e in log.view(filter: f))
          switch (e) {
            ExchangeEntry(:final record) => record.url.path,
            LineEntry(:final line) => line.message,
          },
      ];
      expect(names(ConsoleFilter.all), hasLength(7));
      expect(names(ConsoleFilter.network), [
        '/ok',
        '/missing',
        '/boom',
        '/down',
      ]);
      expect(names(ConsoleFilter.logs), ['plain', 'warned', 'broken']);
      expect(names(ConsoleFilter.errors), [
        '/missing',
        '/boom',
        '/down',
        'broken',
      ]);
    });

    test('search covers URL, status, headers, bodies and log text', () {
      final log = ConsoleLog()
        ..addExchange(
          _exchange(
            url: 'http://api.test/orders?id=991',
            requestHeaders: [const MapEntry('X-Trace', 'trace-abc')],
            responseBody: {'customer': 'Grace Hopper'},
          ),
        )
        ..addExchange(
          _exchange(
            url: 'http://api.test/other',
            status: 418,
            message: "I'm a teapot",
          ),
        )
        ..addLines([_line('loaded the cache', source: 'Pre-request: Warm up')]);
      List<ConsoleEntry> find(String q) => log.view(query: q);
      expect(find('orders?id=991'), hasLength(1));
      expect(find('GET'), hasLength(2));
      expect(find('418'), hasLength(1));
      expect(find('teapot'), hasLength(1));
      expect(find('TRACE-ABC'), hasLength(1), reason: 'case-insensitive');
      expect(find('grace hopper'), hasLength(1), reason: 'bodies');
      expect(find('content-type'), hasLength(2), reason: 'response headers');
      expect(find('warm up'), hasLength(1), reason: 'line source');
      expect(find('cache'), hasLength(1));
      expect(find('nothing like this'), isEmpty);
      expect(find('  '), hasLength(3), reason: 'blank means no search');
      expect(find('cache').single, isA<LineEntry>());
      expect(log.view(filter: ConsoleFilter.network, query: 'cache'), isEmpty);
    });

    test('search cannot find a secret value', () {
      final log = ConsoleLog()
        ..addExchange(_exchange(url: 'http://api.test/x?key=$_secret'))
        ..addLines([_line('token is $_secret')]);
      expect(log.view(query: _secret), hasLength(2));
      expect(log.view(query: _secret, secrets: {_secret}), isEmpty);
      expect(log.view(query: '/x?key=', secrets: {_secret}), hasLength(1));
    });
  });

  group('text for copying', () {
    test('an exchange lists headers and pretty bodies', () {
      final text = consoleEntryText(
        ExchangeEntry(
          _exchange(
            method: 'POST',
            url: 'http://api.test/users',
            status: 201,
            message: 'Created',
            hop: 1,
            protocol: '2',
            requestHeaders: [
              const MapEntry('Content-Type', 'application/json'),
              const MapEntry('Authorization', 'Bearer $_secret'),
            ],
            requestBody: '{"name":"Ada"}',
            responseHeaders: {
              'set-cookie': ['a=1', 'b=2'],
            },
          ),
        ),
        secrets: {_secret},
      );
      expect(text, contains('POST http://api.test/users'));
      expect(text, contains('201 Created'));
      expect(text, contains('HTTP/2'));
      expect(text, contains('hop 1'));
      expect(text, contains('Content-Type: application/json'));
      expect(text, contains('set-cookie: a=1'));
      expect(text, contains('set-cookie: b=2'));
      expect(text, contains('  "name": "Ada"'), reason: 'pretty JSON');
      expect(text, contains('  "id": 7'));
      expect(text, isNot(contains(_secret)));
      expect(text, contains('Bearer ••••••'));
    });

    test('lines carry level and source', () {
      final text = consoleEntryText(
        LineEntry(
          _line('boom', level: ConsoleLevel.error, source: 'Test: Get user'),
        ),
      );
      expect(text, contains('ERROR (Test: Get user): boom'));
    });

    test('copying many entries cuts bodies but keeps every entry', () {
      final entries = [
        for (var i = 0; i < 3; i++)
          ExchangeEntry(
            _exchange(url: 'http://api.test/$i', responseBody: 'y' * 50000),
          ),
      ];
      final all = consoleText(entries, bodyLimit: 100);
      for (var i = 0; i < 3; i++) {
        expect(all, contains('http://api.test/$i'));
      }
      expect(all.length, lessThan(5000));
      expect(all, contains('cut for copying'));
      expect(consoleText(entries).length, greaterThan(150000));
    });

    test(
      'bodies: JSON is pretty, binary is a placeholder, truncation is noted',
      () {
        expect(describeBody(utf8.encode('{"a":[1,2]}')).json, isTrue);
        expect(describeBody(utf8.encode('{"a":[1,2]}')).text, contains('\n'));
        expect(
          describeBody(utf8.encode('{"a":')).json,
          isFalse,
          reason: 'invalid JSON stays as it is',
        );
        expect(
          describeBody(utf8.encode('{"a":1}'), truncated: true).json,
          isFalse,
          reason: 'a cut-off document is shown raw',
        );
        final bin = describeBody([
          0x89,
          0x50,
          0x4e,
          0x47,
          0,
          0,
          0,
          13,
          0xff,
          0xfe,
        ]);
        expect(bin.binary, isTrue);
        expect(bin.text, contains('binary'));
        expect(
          describeBody(
            'héllo wörld'.codeUnits.isEmpty ? null : utf8.encode('héllo wörld'),
          ).binary,
          isFalse,
        );
        expect(describeBody(null).text, '');
        expect(describeBody(const []).text, '');

        final cut = consoleEntryText(
          ExchangeEntry(
            _exchange(
              responseBody: 'z' * 100,
              responseTruncated: true,
              size: 900000,
            ),
          ),
        );
        expect(cut, contains('truncated at 256.0 KB'));
        expect(cut, contains('full size 878.9 KB'));
      },
    );

    test('formatters', () {
      expect(formatDuration(42), '42 ms');
      expect(formatDuration(1500), '1.50 s');
      expect(formatSize(12), '12 B');
      expect(formatSize(2048), '2.0 KB');
      expect(formatSize(3 * 1024 * 1024), '3.00 MB');
      expect(protocolLabel('1.1'), 'HTTP/1.1');
      expect(protocolLabel('3'), 'HTTP/3');
      expect(protocolLabel('HTTP/2'), 'HTTP/2');
      expect(protocolLabel(null), 'not reported');
    });
  });

  group('console panel', () {
    late Directory dir;
    late AppState state;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('aw_console_');
    });
    tearDown(() async {
      state.dispose();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    Future<void> pumpPanel(
      WidgetTester tester,
      Size size, {
      bool docked = false,
      void Function(AppState)? seed,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      state = AppState(storage: Storage(overrideDir: dir));
      seed?.call(state);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            theme: buildTheme(),
            home: Scaffold(body: ConsolePanel(onClose: docked ? () {} : null)),
          ),
        ),
      );
      await tester.pump();
    }

    void seedMixed(AppState s) {
      s.console
        ..addExchange(_exchange(url: 'http://api.test/users/1', protocol: '2'))
        ..addExchange(
          _exchange(
            method: 'POST',
            url: 'http://api.test/login',
            status: 302,
            message: 'Found',
            responseHeaders: {
              'location': ['/home'],
            },
            responseBody: '',
          ),
        )
        ..addExchange(
          _exchange(
            url: 'http://api.test/home',
            hop: 1,
            source: 'runner',
            responseBody: {'ok': true},
          ),
        )
        ..addExchange(
          _exchange(
            url:
                'http://api.test/${'very-long-path-segment/' * 12}end?q=${'x' * 80}',
            status: 500,
            message: 'Internal Server Error',
            responseBody: 'plain text failure',
          ),
        )
        ..addExchange(
          _exchange(
            url: 'http://down.test/',
            status: 0,
            message: '',
            error: 'Connection failed: refused',
            responseBody: null,
          ),
        )
        ..addLines([
          _line('hello from a script', source: 'Pre-request: Get user'),
          _line('FYI', level: ConsoleLevel.info),
          _line('careful now', level: ConsoleLevel.warn),
          _line('it broke ${'badly ' * 40}', level: ConsoleLevel.error),
          _line('details', level: ConsoleLevel.debug),
        ]);
    }

    for (final (size, docked) in [
      (const Size(360, 640), false),
      (const Size(1280, 800), true),
    ]) {
      testWidgets('renders rows and opened details at ${size.width.toInt()}', (
        tester,
      ) async {
        await pumpPanel(tester, size, docked: docked, seed: seedMixed);

        // The list opens on the newest entries.
        expect(find.text('hello from a script'), findsOneWidget);
        expect(find.text('WARN'), findsOneWidget);
        expect(find.text('ERROR'), findsOneWidget);
        expect(find.text('Error'), findsOneWidget);
        expect(find.byKey(const Key('console-follow')), findsOneWidget);

        // Open a long, multi-line log line.
        await tester.tap(find.textContaining('it broke'));
        await tester.pumpAndSettle();

        // Open the failed request: its error is spelled out.
        await _reveal(tester, find.text('Error'));
        await tester.tap(find.text('Error'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Connection failed: refused'), findsWidgets);

        await _reveal(tester, find.text('500 Internal Server Error'));
        expect(find.text('500 Internal Server Error'), findsOneWidget);

        // Open the first exchange.
        await _reveal(tester, find.textContaining('/users/1'));
        expect(find.text('200 OK'), findsWidgets);
        await tester.tap(find.textContaining('/users/1'));
        await tester.pumpAndSettle();
        expect(find.text('Network'), findsWidgets);
        await _reveal(tester, find.text('Response body').first);
        expect(find.text('HTTP/2'), findsOneWidget);
        expect(find.text('Request headers (1)'), findsWidgets);
        expect(find.text('Response headers (1)'), findsWidgets);
        expect(find.text('Request body'), findsWidgets);
        expect(find.textContaining('"name": "Ada"'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('redirect hops are marked and indented', (tester) async {
      await pumpPanel(tester, const Size(1280, 800), seed: seedMixed);
      expect(find.byIcon(Icons.subdirectory_arrow_right), findsOneWidget);
      final first = tester.getTopLeft(find.textContaining('/users/1')).dx;
      final hop = tester.getTopLeft(find.textContaining('/home')).dx;
      expect(hop, greaterThan(first));
    });

    testWidgets('filter chips narrow the list and show counts', (tester) async {
      await pumpPanel(tester, const Size(1280, 800), seed: seedMixed);
      expect(find.text('All 10'), findsOneWidget);
      expect(find.text('Network 5'), findsOneWidget);
      expect(find.text('Logs 5'), findsOneWidget);
      expect(find.text('Errors 3'), findsOneWidget);

      await tester.tap(find.byKey(const Key('console-filter-logs')));
      await tester.pump();
      expect(find.textContaining('/users/1'), findsNothing);
      expect(find.text('hello from a script'), findsOneWidget);

      await tester.tap(find.byKey(const Key('console-filter-errors')));
      await tester.pump();
      expect(find.text('500 Internal Server Error'), findsOneWidget);
      expect(find.text('ERROR'), findsOneWidget);
      expect(find.text('200 OK'), findsNothing);
      expect(find.text('hello from a script'), findsNothing);
      expect(find.textContaining('Showing 3 of 10'), findsOneWidget);

      await tester.tap(find.byKey(const Key('console-filter-network')));
      await tester.pump();
      expect(find.text('hello from a script'), findsNothing);
      expect(find.text('200 OK'), findsNWidgets(2));

      await tester.tap(find.byKey(const Key('console-filter-all')));
      await tester.pump();
      expect(find.text('200 OK'), findsNWidgets(2));
      expect(find.text('hello from a script'), findsOneWidget);
    });

    testWidgets('search filters as you type, and clears', (tester) async {
      await pumpPanel(tester, const Size(360, 640), seed: seedMixed);
      await tester.enterText(find.byKey(const Key('console-search')), 'login');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('302 Found'), findsOneWidget);
      expect(find.text('200 OK'), findsNothing);
      expect(find.textContaining('Showing 1 of 10'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('console-search')), 'zzz');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('No entries match'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pump();
      expect(find.textContaining('Showing'), findsNothing);
      expect(find.text('hello from a script'), findsOneWidget);
    });

    testWidgets('the toolbar clears the console', (tester) async {
      await pumpPanel(tester, const Size(1280, 800), seed: seedMixed);
      await tester.tap(find.byKey(const Key('console-clear')));
      await tester.pump();
      expect(state.console.entries, isEmpty);
      expect(find.textContaining('Nothing yet'), findsOneWidget);
    });

    testWidgets('secret values are hidden everywhere the console shows text', (
      tester,
    ) async {
      await pumpPanel(
        tester,
        const Size(1280, 800),
        seed: (s) {
          s.console
            ..addExchange(
              _exchange(
                url: 'http://api.test/me?key=$_secret',
                requestHeaders: [
                  const MapEntry('Authorization', 'Bearer $_secret'),
                ],
                requestBody: {'token': _secret},
                responseHeaders: {
                  'x-echo': [_secret],
                },
                responseBody: {'you_sent': _secret},
              ),
            )
            ..addExchange(
              _exchange(status: 0, error: 'bad $_secret', responseBody: null),
            )
            ..addLines([
              _line('using $_secret now', source: 'Script $_secret'),
            ]);
        },
      );
      // Not a secret yet: everything is visible.
      expect(_screenText(tester), contains(_secret));

      state.globals = [KV(key: 'token', value: _secret, secret: true)];
      state.notifyRefresh();
      await tester.pump();
      expect(_screenText(tester), isNot(contains(_secret)));
      expect(find.textContaining('/me?key=••••••'), findsOneWidget);

      // Open everything: still hidden.
      await tester.tap(find.textContaining('/me?key='));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('using'));
      await tester.pumpAndSettle();
      final text = _screenText(tester);
      expect(text, isNot(contains(_secret)));
      expect(text, contains('Bearer ••••••'));
      expect(text, contains('"token": "••••••"'));
      expect(text, contains('using •••••• now'));

      // Copying masks too.
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.tap(find.byKey(const Key('console-copy-all')));
      await tester.pump();
      expect(copied, isNotNull);
      expect(copied, isNot(contains(_secret)));
      expect(copied, contains('Bearer ••••••'));
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('short secrets are left alone, as in docs', (tester) async {
      await pumpPanel(
        tester,
        const Size(1280, 800),
        seed: (s) {
          s.globals = [KV(key: 'pin', value: 'abc', secret: true)];
          s.console.addLines([_line('abc stays')]);
        },
      );
      expect(find.text('abc stays'), findsOneWidget);
    });

    testWidgets('copies one entry and all entries', (tester) async {
      await pumpPanel(tester, const Size(1280, 800), seed: seedMixed);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await tester.tap(find.textContaining('/users/1'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('console-copy-entry')));
      await tester.pump();
      expect(copied, contains('GET http://api.test/users/1'));
      expect(copied, contains('Accept: */*'));
      expect(copied, contains('"name": "Ada"'));
      expect(copied, isNot(contains('/login')));

      await tester.tap(find.byKey(const Key('console-copy-all')));
      await tester.pump();
      expect(copied, contains('/users/1'));
      expect(copied, contains('/login'));
      expect(copied, contains('hello from a script'));
      expect(copied, contains('ERROR'));
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('a thousand entries stay virtualized', (tester) async {
      await pumpPanel(
        tester,
        const Size(1280, 800),
        seed: (s) {
          for (var i = 0; i < 700; i++) {
            s.console.addExchange(_exchange(url: 'http://api.test/item/$i'));
          }
          s.console.addLines([for (var i = 0; i < 2500; i++) _line('line $i')]);
        },
      );
      expect(state.console.entries, hasLength(1000));
      expect(state.console.dropped, 2200);
      expect(find.text('line 2499'), findsOneWidget);
      expect(find.text('line 1500'), findsNothing);
      expect(find.byType(InkWell).evaluate().length, lessThan(60));
      expect(
        find.textContaining('2200 older entries were dropped'),
        findsOneWidget,
      );
    });

    testWidgets('follows the newest entry until the user scrolls away', (
      tester,
    ) async {
      await pumpPanel(
        tester,
        const Size(1280, 800),
        seed: (s) => s.console.addLines([
          for (var i = 0; i < 100; i++) _line('line $i'),
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.text('line 99'), findsOneWidget);
      expect(find.byKey(const Key('console-jump')), findsNothing);

      // New output keeps the newest in view.
      state.console.addLines([_line('line 100')]);
      await tester.pumpAndSettle();
      expect(find.text('line 100'), findsOneWidget);

      // Scroll up: following stops, the button appears.
      await tester.drag(find.byType(ListView), const Offset(0, 600));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('console-jump')), findsOneWidget);
      expect(find.text('line 100'), findsNothing);

      state.console.addLines([_line('line 101')]);
      await tester.pumpAndSettle();
      expect(find.text('line 101'), findsNothing, reason: 'the view stays put');
      expect(find.byKey(const Key('console-jump')), findsOneWidget);

      // Jump to latest.
      await tester.tap(find.byKey(const Key('console-jump')));
      await tester.pumpAndSettle();
      expect(find.text('line 101'), findsOneWidget);
      expect(find.byKey(const Key('console-jump')), findsNothing);
    });

    testWidgets('long bodies are cut until asked for', (tester) async {
      await pumpPanel(
        tester,
        const Size(1280, 800),
        seed: (s) => s.console.addExchange(
          _exchange(
            responseBody: 'abcdefghij' * 5000,
            responseTruncated: true,
            size: 2 * 1024 * 1024,
          ),
        ),
      );
      await tester.tap(find.textContaining('/users'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Show more'), findsOneWidget);
      expect(
        find.textContaining('Response body truncated at 256.0 KB'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.textContaining('Show more'));
      await tester.pump();
      await tester.tap(find.textContaining('Show more'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Show more'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('showConsolePage opens the console on its own page', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      state = AppState(storage: Storage(overrideDir: dir));
      seedMixed(state);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            theme: buildTheme(),
            home: Builder(
              builder: (c) => Scaffold(
                body: TextButton(
                  onPressed: () => showConsolePage(c),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Console'), findsOneWidget); // the app bar title
      expect(find.text('hello from a script'), findsOneWidget);
      await _reveal(tester, find.text('302 Found'));
      await tester.tap(find.text('302 Found'));
      await tester.pumpAndSettle();
      await _reveal(tester, find.text('Request headers (1)'));
      expect(find.text('Request headers (1)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the docked console can be resized by dragging', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        state = AppState(storage: Storage(overrideDir: dir));
        while (!state.loaded) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      state.console.addLines([_line('hello')]);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(theme: buildTheme(), home: const HomeScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ConsolePanel), findsNothing);

      await tester.tap(find.text('Console'));
      await tester.pumpAndSettle();
      expect(find.byType(ConsolePanel), findsOneWidget);
      double height() => tester.getSize(find.byType(ConsolePanel)).height;
      expect(height(), 220);

      // The splitter sits right above the panel.
      Offset handle() =>
          tester.getTopLeft(find.byType(ConsolePanel)) + const Offset(300, -4);
      await tester.dragFrom(handle(), const Offset(0, -100));
      await tester.pump();
      expect(height(), 320);

      await tester.dragFrom(handle(), const Offset(0, -2000));
      await tester.pump();
      // It stops where the editor and response above still fit.
      expect(height(), 460);

      await tester.dragFrom(handle(), const Offset(0, 2000));
      await tester.pump();
      expect(height(), 120);
      expect(find.text('hello'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('empty console explains itself', (tester) async {
      await pumpPanel(tester, const Size(360, 640));
      expect(find.textContaining('Nothing yet'), findsOneWidget);
    });
  });
}

/// The console list opens scrolled to the newest entry; scrolls back to
/// [target] and makes it fully visible.
Future<void> _reveal(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    -150,
    scrollable: find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first,
    maxScrolls: 300,
  );
  await tester.ensureVisible(target);
  await tester.pump();
}

/// Every piece of text on screen, including selectable and rich text.
String _screenText(WidgetTester tester) {
  final b = StringBuffer();
  for (final w in tester.widgetList<RichText>(find.byType(RichText))) {
    b.writeln(w.text.toPlainText());
  }
  for (final w in tester.widgetList<EditableText>(find.byType(EditableText))) {
    b.writeln(w.controller.text);
  }
  return b.toString();
}
