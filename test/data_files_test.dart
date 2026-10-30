import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/data_files.dart';
import 'package:api_workbench/services/http_service.dart';
import 'package:api_workbench/services/runner.dart';
import 'package:api_workbench/services/scripting/script_engine.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/theme.dart';
import 'package:api_workbench/ui/runner_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// Answers every script run with a fixed outcome.
class _OutcomeEngine implements ScriptEngine {
  _OutcomeEngine(this.outcome);
  final ScriptOutcome Function() outcome;

  @override
  Future<ScriptOutcome> run(List<ScriptSource> s, ScriptContext c) async =>
      outcome();

  @override
  void dispose() {}
}

void main() {
  // flutter_test answers every HttpClient with a canned 400; these tests talk
  // to a local server.
  setUp(() => HttpOverrides.global = null);

  group('CSV', () {
    test('header row, rows as maps of strings', () {
      final rows = parseCsv('id,name\n1,Ada\n2,Linus\n');
      expect(rows, [
        {'id': '1', 'name': 'Ada'},
        {'id': '2', 'name': 'Linus'},
      ]);
    });

    test('quoted fields keep commas, quotes, line breaks and edge spaces', () {
      final rows = parseCsv(
        'a,b,c\n'
        '"x, y","say ""hi""","line1\nline2"\n'
        '"  padded  ",plain,""\n',
      );
      expect(rows[0], {'a': 'x, y', 'b': 'say "hi"', 'c': 'line1\nline2'});
      expect(rows[1], {'a': '  padded  ', 'b': 'plain', 'c': ''});
    });

    test('CRLF, LF and CR line endings, with or without a final one', () {
      final want = [
        {'a': '1', 'b': '2'},
        {'a': '3', 'b': '4'},
      ];
      expect(parseCsv('a,b\r\n1,2\r\n3,4\r\n'), want);
      expect(parseCsv('a,b\n1,2\n3,4'), want);
      expect(parseCsv('a,b\r1,2\r3,4'), want);
      // A line break inside quotes stays as it was written.
      expect(parseCsv('a\n"x\r\ny"\n').single['a'], 'x\r\ny');
    });

    test('a byte-order mark is dropped, from text and from bytes', () {
      expect(parseCsv('﻿id,name\n1,Ada').single.keys, ['id', 'name']);
      final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode('id\n7')];
      expect(parseDataFile(decodeDataBytes(bytes)).single, {'id': '7'});
    });

    test('UTF-16 files with a byte-order mark decode', () {
      List<int> utf16le(String s) => [
        0xFF,
        0xFE,
        for (final u in s.codeUnits) ...[u & 0xFF, u >> 8],
      ];
      final text = decodeDataBytes(utf16le('id,name\n1,Zoë\n'));
      expect(parseCsv(text).single, {'id': '1', 'name': 'Zoë'});
    });

    test('blank lines and an empty trailing line are skipped', () {
      expect(parseCsv('a,b\n\n1,2\n\n\n3,4\n\n').length, 2);
      // A quoted empty value on its own line is still a row.
      expect(parseCsv('a\n""\nx\n').map((r) => r['a']), ['', 'x']);
    });

    test('short rows are padded; empty header columns are dropped', () {
      expect(parseCsv('a,b,c\n1\n1,2,3'), [
        {'a': '1', 'b': '', 'c': ''},
        {'a': '1', 'b': '2', 'c': '3'},
      ]);
      expect(parseCsv('a,,b,\n1,x,2,\n').single, {'a': '1', 'b': '2'});
    });

    test('header names are trimmed and values are not', () {
      expect(parseCsv(' id , name \n 1 , Ada ').single, {
        'id': ' 1 ',
        'name': ' Ada ',
      });
    });

    test('a quote in the middle of an unquoted value is literal', () {
      expect(parseCsv('a\n5" pipe').single['a'], '5" pipe');
    });

    test('header only gives no rows; empty input is an error', () {
      expect(parseCsv('id,name\n'), isEmpty);
      expect(() => parseCsv(''), throwsFormatException);
    });

    test('tab-separated values with the delimiter option', () {
      expect(parseCsv('a\tb\n1\t"x\ty"', delimiter: '\t').single, {
        'a': '1',
        'b': 'x\ty',
      });
    });

    test('malformed input throws with the line number', () {
      expect(
        () => parseCsv('a,b\n1,"never closed\n2,3\n'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('Line 2'), contains('never closed')),
          ),
        ),
      );
      expect(
        () => parseCsv('a,b\n"x"y,2'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Line 2'),
          ),
        ),
      );
      expect(
        () => parseCsv('a,b\n1,2,3'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('3 values but the header has 2'),
          ),
        ),
      );
      expect(
        () => parseCsv('id,name,id\n1,a,2'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('"id"'), contains('columns 1 and 3')),
          ),
        ),
      );
    });

    test('extra empty values past the header are tolerated', () {
      expect(parseCsv('a,b\n1,2,,\n').single, {'a': '1', 'b': '2'});
    });
  });

  group('JSON', () {
    test('an array of objects, values as strings', () {
      final rows = parseJsonRows(
        '[{"id": 1, "ok": true, "name": "a", "none": null, "n": 1.5, '
        '"obj": {"x": 1}, "list": [1, 2]}]',
      );
      expect(rows.single, {
        'id': '1',
        'ok': 'true',
        'name': 'a',
        'none': '',
        'n': '1.5',
        'obj': '{"x":1}',
        'list': '[1,2]',
      });
    });

    test('a single object is one row; a BOM is ignored', () {
      expect(parseJsonRows('﻿{"a": "1"}'), [
        {'a': '1'},
      ]);
    });

    test('errors say what is wrong', () {
      expect(
        () => parseJsonRows('[{"a": 1}, 5]'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Item 2'),
          ),
        ),
      );
      expect(() => parseJsonRows('"text"'), throwsFormatException);
      expect(
        () => parseJsonRows('[{"a": '),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('not valid JSON'),
          ),
        ),
      );
    });
  });

  group('auto-detection', () {
    test('JSON by its first character, CSV otherwise', () {
      expect(readDataFile('[{"a":"1"}]').format, DataFormat.json);
      expect(readDataFile('  \n {"a":"1"}').format, DataFormat.json);
      expect(readDataFile('a,b\n1,2').format, DataFormat.csv);
    });

    test('the file name decides when it has an extension', () {
      expect(
        readDataFile('a\n1', fileName: 'Users.CSV').format,
        DataFormat.csv,
      );
      expect(
        readDataFile('[{"a":1}]', fileName: 'x.json').format,
        DataFormat.json,
      );
      expect(readDataFile('a\tb\n1\t2', fileName: 'x.tsv').rows.single, {
        'a': '1',
        'b': '2',
      });
    });

    test('columns follow the file; JSON columns are the union of keys', () {
      expect(readDataFile('b,a\n1,2').columns, ['b', 'a']);
      expect(readDataFile('[{"x":1},{"y":2,"x":3}]').columns, ['x', 'y']);
    });

    test('empty files and files without rows are readable errors', () {
      for (final text in ['', '  \n ', '﻿']) {
        expect(
          () => readDataFile(text),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('empty'),
            ),
          ),
        );
      }
      expect(
        () => readDataFile('id,name\n'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('no data rows'),
          ),
        ),
      );
      expect(() => readDataFile('[]'), throwsFormatException);
    });

    test('a large CSV parses quickly', () {
      final b = StringBuffer('id,name,email\n');
      for (var i = 0; i < 50000; i++) {
        b.writeln('$i,"User $i","user$i@example.com"');
      }
      final sw = Stopwatch()..start();
      final rows = parseDataFile(b.toString());
      expect(rows.length, 50000);
      expect(rows.last['email'], 'user49999@example.com');
      expect(sw.elapsedMilliseconds, lessThan(5000));
    });
  });

  group('runner with data files', () {
    late HttpServer server;
    late String base;
    final seen = <String>[];

    setUp(() async {
      seen.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((req) {
        seen.add('${req.uri.path}?${req.uri.query}');
        req.response
          ..headers.contentType = ContentType.json
          ..write('{"ok":true}')
          ..close();
      });
    });
    tearDown(() => server.close(force: true));

    Future<void> done(RunnerService r) async {
      while (r.running) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test(
      'each CSV row is an iteration with its columns as {{variables}}',
      () async {
        final rows = parseDataFile(
          'id,name\n1,Ada\n2,"Linus, T"\n3,"say ""hi"""\n',
          fileName: 'users.csv',
        );
        final runner = RunnerService(HttpService());
        await runner.start(
          requests: [
            RequestModel(
              name: 'Get',
              url: '$base/users/{{id}}?name={{name}}',
              assertions: [
                AssertionModel(kind: AssertKind.statusEquals, expected: '200'),
              ],
            ),
          ],
          dataRows: rows,
        );
        await done(runner);
        expect(runner.results.length, 3);
        expect(runner.results.every((r) => r.pass), isTrue);
        expect(runner.results.map((r) => r.iteration), [1, 2, 3]);
        expect(seen, [
          '/users/1?name=Ada',
          '/users/2?name=Linus,%20T',
          '/users/3?name=say%20%22hi%22',
        ]);
        runner.dispose();
      },
    );

    test('values from a data file win over the environment', () async {
      final runner = RunnerService(HttpService());
      await runner.start(
        requests: [RequestModel(url: '$base/{{who}}')],
        vars: {'who': 'environment'},
        dataRows: parseDataFile('who\nfile'),
      );
      await done(runner);
      expect(seen, ['/file?']);
      runner.dispose();
    });
  });

  group('runner screen', () {
    testWidgets('previews pasted CSV and runs one iteration per row', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      late HttpServer server;
      late Directory dir;
      final seen = <String>[];
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('aw_runner_');
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) {
          seen.add(req.uri.path);
          req.response
            ..headers.contentType = ContentType.json
            ..write('{"ok":true}')
            ..close();
        });
      });

      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (_) => AppState(storage: Storage(overrideDir: dir)),
          child: MaterialApp(
            theme: buildTheme(),
            home: RunnerScreen(
              title: 'Demo',
              requests: [
                RequestModel(
                  name: 'Ping',
                  url: 'http://127.0.0.1:${server.port}/{{id}}',
                ),
              ],
            ),
          ),
        ),
      );

      // Data panel: pasted CSV, preview, row count.
      await tester.tap(find.text('Data'));
      await tester.pumpAndSettle();
      expect(find.text('Load data file'), findsOneWidget);
      expect(find.text('Keep variable values'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField).last,
        'id,name\na,Ada\nb,Bo',
      );
      await tester.pump();
      expect(find.textContaining('CSV: 2 rows, 2 columns'), findsOneWidget);
      expect(find.text('Preview: 2 rows'), findsOneWidget);
      expect(find.text('Ada'), findsOneWidget);
      expect(find.text('Data (2 rows)'), findsOneWidget);

      // A bad row is reported, not run.
      await tester.enterText(find.byType(TextField).last, 'id,name\na,1,2,3');
      await tester.pump();
      expect(find.textContaining('Line 2'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField).last,
        'id,name\na,Ada\nb,Bo',
      );
      await tester.pump();

      await tester.tap(find.text('Run'));
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 300));
        if (find.textContaining('Showing 2 of 2').evaluate().isNotEmpty) break;
      }
      expect(find.textContaining('Showing 2 of 2'), findsOneWidget);
      expect(seen, ['/a', '/b']);
      expect(tester.takeException(), isNull);

      await tester.runAsync(() async {
        await server.close(force: true);
        await dir.delete(recursive: true);
      });
    });

    testWidgets('the data panel fits a 320 px phone', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late Directory dir;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('aw_runner_narrow_');
      });
      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (_) => AppState(storage: Storage(overrideDir: dir)),
          child: MaterialApp(
            theme: buildTheme(),
            home: RunnerScreen(
              title: 'A long collection name for a small screen',
              requests: [RequestModel(name: 'Ping', url: 'http://x/{{id}}')],
            ),
          ),
        ),
      );
      await tester.tap(find.text('Data'));
      await tester.pumpAndSettle();
      final header = List.generate(12, (i) => 'column_number_$i').join(',');
      final row = List.generate(12, (i) => 'a long value $i').join(',');
      await tester.enterText(
        find.byType(TextField).last,
        '$header\n${List.filled(30, row).join('\n')}',
      );
      await tester.pump();
      expect(find.text('Preview: first 20 of 30 rows'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => dir.delete(recursive: true));
    });

    testWidgets('lists script tests and script errors in each result', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      late HttpServer server;
      late Directory dir;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('aw_runner_scripts_');
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) {
          req.response
            ..headers.contentType = ContentType.json
            ..write('{}')
            ..close();
        });
      });
      var runs = 0;
      final engine = _OutcomeEngine(
        () => ++runs == 1
            ? ScriptOutcome(
                tests: [
                  const ScriptTestResult('status is 200', true),
                  const ScriptTestResult('has id', false, error: 'no id'),
                ],
              )
            : ScriptOutcome(error: 'ReferenceError: nope'),
      );
      final url = 'http://127.0.0.1:${server.port}/';
      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (_) => AppState(storage: Storage(overrideDir: dir)),
          child: MaterialApp(
            theme: buildTheme(),
            home: RunnerScreen(
              title: 'Scripts',
              engine: engine,
              requests: [
                RequestModel(name: 'One', url: url, testScript: 'x'),
                RequestModel(name: 'Two', url: url, testScript: 'y'),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('Run'));
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 300));
        if (find.textContaining('Showing 2 of 2').evaluate().isNotEmpty) {
          break;
        }
      }
      // Newest first: Two (script error), then One (1 of 2 tests passed).
      expect(find.textContaining('1/2 tests'), findsOneWidget);
      await tester.tap(find.text('One'));
      await tester.pumpAndSettle();
      expect(find.text('✓ status is 200'), findsOneWidget);
      expect(find.text('✗ has id — no id'), findsOneWidget);
      await tester.tap(find.text('Two'));
      await tester.pumpAndSettle();
      expect(find.text('Script error: ReferenceError: nope'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await server.close(force: true);
        await dir.delete(recursive: true);
      });
    });

    testWidgets(
      'keeps captured values only while "Keep variable values" is on',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        late HttpServer server;
        late Directory dir;
        await tester.runAsync(() async {
          dir = await Directory.systemTemp.createTemp('aw_runner_keep_');
          server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server.listen((req) {
            req.response
              ..headers.contentType = ContentType.json
              ..write('{"token":"abc"}')
              ..close();
          });
        });
        final collection = CollectionModel(
          name: 'Col',
          requests: [
            RequestModel(
              name: 'Login',
              url: 'http://127.0.0.1:${server.port}/login',
              captures: {'token': 'body.token'},
            ),
          ],
        );
        late AppState state;
        Future<void> run({required bool keep}) async {
          // Built and loaded in real time; loading the (empty) folder would
          // otherwise replace the collection set below.
          state = (await tester.runAsync(() async {
            final s = AppState(storage: Storage(overrideDir: dir));
            while (!s.loaded) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
            return s;
          }))!;
          state.collections = [collection];
          // A fresh screen (and runner) for each run.
          await tester.pumpWidget(const SizedBox());
          await tester.pumpWidget(
            ChangeNotifierProvider.value(
              value: state,
              child: MaterialApp(
                theme: buildTheme(),
                home: RunnerScreen(
                  title: 'Col',
                  requests: collection.requests,
                  collectionId: collection.id,
                ),
              ),
            ),
          );
          if (!keep) {
            await tester.tap(find.text('Keep variable values'));
            await tester.pump();
          }
          await tester.tap(find.text('Run'));
          for (var i = 0; i < 40; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)),
            );
            await tester.pump(const Duration(milliseconds: 300));
            if (find.textContaining('Showing 1 of 1').evaluate().isNotEmpty) {
              break;
            }
          }
          expect(find.textContaining('Showing 1 of 1'), findsOneWidget);
        }

        await run(keep: false);
        expect(collection.variables, isEmpty);
        await run(keep: true);
        expect(collection.variables.map((v) => v.key), ['token']);
        expect(collection.variables.single.effective, 'abc');

        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await server.close(force: true);
          await dir.delete(recursive: true);
        });
      },
    );
  });
}
