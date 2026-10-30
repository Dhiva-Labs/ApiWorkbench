import 'dart:convert';
import 'dart:math';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/theme.dart';
import 'package:api_workbench/ui/kv_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The fields bulk edit round-trips (the rest comes from the previous rows).
String sig(KV r) => jsonEncode([r.key, r.value, r.enabled, r.isFile]);

List<String> sigs(List<KV> rows) => rows.map(sig).toList();

void main() {
  group('bulk text format', () {
    test('writes one key: value line per row', () {
      final rows = [
        KV(key: 'Accept', value: 'application/json'),
        KV(key: 'X-Debug', value: '1', enabled: false),
        KV(key: 'empty'),
      ];
      expect(
        kvToBulkText(rows),
        'Accept: application/json\n// X-Debug: 1\nempty:',
      );
    });

    test('file rows are written as key: @path', () {
      final rows = [
        KV(key: 'title', value: 'Hi'),
        KV(key: 'avatar', value: '/home/me/photo.png', isFile: true),
        KV(key: 'old', value: 'C:\\x\\y.txt', isFile: true, enabled: false),
      ];
      expect(
        kvToBulkText(rows, allowFiles: true),
        'title: Hi\navatar: @/home/me/photo.png\n// old: @C:\\x\\y.txt',
      );
    });

    test('reads lines, // for disabled rows, and ignores blank lines', () {
      final rows = kvFromBulkText(
        'Accept: application/json\n'
        '\n'
        '   \n'
        '// X-Debug: 1\n'
        '//X-Other:2\r\n'
        'Authorization:Bearer a:b\n'
        'lonely\n',
      );
      expect(sigs(rows), [
        sig(KV(key: 'Accept', value: 'application/json')),
        sig(KV(key: 'X-Debug', value: '1', enabled: false)),
        sig(KV(key: 'X-Other', value: '2', enabled: false)),
        sig(KV(key: 'Authorization', value: 'Bearer a:b')),
        sig(KV(key: 'lonely')),
      ]);
    });

    test('splits at the first colon only, so URLs and times stay whole', () {
      final rows = kvFromBulkText(
        'Referer: https://a.dev:8080/x?y=1\nat: 12:30',
      );
      expect(rows[0].value, 'https://a.dev:8080/x?y=1');
      expect(rows[1].value, '12:30');
    });

    test('@ means a file only where files are allowed', () {
      final plain = kvFromBulkText('mention: @ada');
      expect(plain.single.isFile, isFalse);
      expect(plain.single.value, '@ada');
      final form = kvFromBulkText('avatar: @/tmp/a.png', allowFiles: true);
      expect(form.single.isFile, isTrue);
      expect(form.single.value, '/tmp/a.png');
    });

    test('indented and CRLF text reads the same', () {
      final rows = kvFromBulkText('  a: 1\r\n\t// b: 2\r\n');
      expect(sigs(rows), [
        sig(KV(key: 'a', value: '1')),
        sig(KV(key: 'b', value: '2', enabled: false)),
      ]);
    });
  });

  group('round trips', () {
    final tricky = <KV>[
      KV(key: 'plain', value: 'v'),
      KV(key: 'off', value: 'x', enabled: false),
      KV(key: 'colon:key', value: 'a:b:c'),
      KV(key: ':leading', value: ''),
      KV(key: 'trailing:', value: ':'),
      KV(key: '//slashes', value: '//not a comment'),
      KV(key: '//off', value: '1', enabled: false),
      KV(key: ' padded ', value: '  both  '),
      KV(key: '\tTab', value: '\tTab'),
      KV(key: r'back\slash', value: r'C:\new\table\\'),
      KV(key: r'ends\', value: r'ends\'),
      KV(key: r'\:', value: r'\n \r \\ \@ \/ \ '),
      KV(key: 'multi\nline', value: 'a\nb\r\nc\rd'),
      KV(key: 'at', value: '@looks like a file'),
      KV(key: r'at2', value: r'\@x'),
      KV(key: '', value: ''),
      KV(key: '', value: 'no key'),
      KV(key: '', value: '', enabled: false),
      KV(key: 'ünï', value: '✓ 😀'),
      KV(key: 'dup', value: '1'),
      KV(key: 'dup', value: '2', enabled: false),
    ];

    test('enabled, disabled and blank rows survive unchanged', () {
      final back = kvFromBulkText(kvToBulkText(tricky), previous: tricky);
      expect(sigs(back), sigs(tricky));
    });

    test('file rows and text rows survive when files are allowed', () {
      final rows = [
        ...tricky,
        KV(key: 'file', value: '/tmp/a b.png', isFile: true),
        KV(
          key: 'off file',
          value: r'C:\new\r.png',
          isFile: true,
          enabled: false,
        ),
        KV(key: 'empty file', value: '', isFile: true),
        KV(key: 'at path', value: '@odd', isFile: true),
        KV(key: 'slash path', value: r'\\server\share\f', isFile: true),
      ];
      final text = kvToBulkText(rows, allowFiles: true);
      final back = kvFromBulkText(text, previous: rows, allowFiles: true);
      expect(sigs(back), sigs(rows));
      // And again from the parsed rows: the text is stable.
      expect(kvToBulkText(back, allowFiles: true), text);
    });

    test('random rows made of awkward characters', () {
      final rnd = Random(7);
      const alphabet = [
        'a',
        'b',
        'n',
        'r',
        ' ',
        '\t',
        ':',
        '/',
        r'\',
        '@',
        '\n',
        '\r',
        '/',
        r'\',
        ':',
        'é',
        '😀',
      ];
      String word() => List.generate(
        rnd.nextInt(6),
        (_) => alphabet[rnd.nextInt(alphabet.length)],
      ).join();
      for (final files in [false, true]) {
        for (var round = 0; round < 400; round++) {
          final rows = [
            for (var i = 0; i < 1 + rnd.nextInt(4); i++)
              KV(
                key: word(),
                value: word(),
                enabled: rnd.nextBool(),
                isFile: files && rnd.nextBool(),
              ),
          ];
          final text = kvToBulkText(rows, allowFiles: files);
          final back = kvFromBulkText(text, allowFiles: files);
          expect(
            sigs(back),
            sigs(rows),
            reason: 'files=$files text=${jsonEncode(text)}',
          );
        }
      }
    });

    test('text is stable: parse then write gives the same text', () {
      const text = 'a: 1\n// b: 2\nc:\n: x';
      expect(kvToBulkText(kvFromBulkText(text)), text);
    });
  });

  group('keeping what the text does not show', () {
    test(
      'description, secret and current stay with the row whose key matches',
      () {
        final prev = [
          KV(
            key: 'token',
            value: 'old',
            description: 'API token',
            secret: true,
            current: 'cur',
          ),
          KV(key: 'region', value: 'eu', description: 'Where'),
        ];
        final rows = kvFromBulkText(
          'region: us\ntoken: new\nbrand-new: 1',
          previous: prev,
        );
        expect(rows.map((r) => r.key), ['region', 'token', 'brand-new']);
        expect(rows[0].value, 'us');
        expect(rows[0].description, 'Where');
        expect(rows[1].secret, isTrue);
        expect(rows[1].current, 'cur');
        expect(rows[1].description, 'API token');
        expect(rows[2].description, '');
        expect(rows[2].secret, isFalse);
      },
    );

    test('repeated keys pair up in order', () {
      final prev = [
        KV(key: 'a', value: '1', description: 'first'),
        KV(key: 'a', value: '2', description: 'second'),
      ];
      final rows = kvFromBulkText('a: 1\na: 2', previous: prev);
      expect(rows.map((r) => r.description), ['first', 'second']);
    });

    test('a removed key takes its description with it', () {
      final prev = [KV(key: 'a', description: 'x')];
      final rows = kvFromBulkText('b: 1', previous: prev);
      expect(rows.single.description, '');
    });

    test('previous rows are not modified', () {
      final prev = [KV(key: 'a', value: '1', description: 'x')];
      kvFromBulkText('a: 2', previous: prev);
      expect(prev.single.value, '1');
    });
  });

  group('KVEditor bulk edit toggle', () {
    Widget host(Widget child) => MaterialApp(
      theme: buildTheme(),
      home: Scaffold(body: child),
    );

    Future<void> setSize(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    final bulkField = find.byKey(const ValueKey('kv-bulk-text'));

    testWidgets('opens a text view with the rows and closes back to them', (
      tester,
    ) async {
      final rows = [
        KV(key: 'Accept', value: 'application/json'),
        KV(key: 'X-Debug', value: '1', enabled: false),
      ];
      var changes = 0;
      await tester.pumpWidget(
        host(KVEditor(rows: rows, onChanged: () => changes++)),
      );
      expect(find.text('Bulk edit'), findsOneWidget);
      await tester.tap(find.text('Bulk edit'));
      await tester.pump();
      expect(bulkField, findsOneWidget);
      expect(
        tester.widget<TextField>(bulkField).controller!.text,
        'Accept: application/json\n// X-Debug: 1',
      );
      expect(find.text('Key-value edit'), findsOneWidget);
      await tester.tap(find.text('Key-value edit'));
      await tester.pump();
      expect(bulkField, findsNothing);
      expect(find.text('Add row'), findsOneWidget);
      expect(changes, 0);
    });

    testWidgets(
      'switching to bulk edit and back changes nothing and is not a change',
      (tester) async {
        final rows = [
          KV(key: 'a', value: '1', description: 'note', secret: true),
          KV(key: 'b', value: '2', enabled: false),
          KV(key: 'f', value: '/tmp/x', isFile: true),
          KV(),
        ];
        final before = jsonEncode(rows.map((r) => r.toJson()).toList());
        final firstRow = rows.first;
        var changes = 0;
        await tester.pumpWidget(
          host(
            KVEditor(rows: rows, allowFiles: true, onChanged: () => changes++),
          ),
        );
        await tester.tap(find.text('Bulk edit'));
        await tester.pump();
        await tester.tap(find.text('Key-value edit'));
        await tester.pump();
        expect(changes, 0);
        expect(jsonEncode(rows.map((r) => r.toJson()).toList()), before);
        expect(identical(rows.first, firstRow), isTrue);
      },
    );

    testWidgets(
      'typing updates the rows as you go and reports one change per edit',
      (tester) async {
        final rows = [
          KV(key: 'a', value: '1', description: 'note'),
          KV(key: 'b', value: '2'),
        ];
        var changes = 0;
        await tester.pumpWidget(
          host(KVEditor(rows: rows, onChanged: () => changes++)),
        );
        await tester.tap(find.text('Bulk edit'));
        await tester.pump();
        await tester.enterText(bulkField, 'a: 10\n// b: 2\nc: 3');
        await tester.pump();
        expect(changes, 1);
        expect(sigs(rows), [
          sig(KV(key: 'a', value: '10')),
          sig(KV(key: 'b', value: '2', enabled: false)),
          sig(KV(key: 'c', value: '3')),
        ]);
        expect(rows.first.description, 'note');
      },
    );

    testWidgets(
      'a key passing through half-typed states keeps its description',
      (tester) async {
        final rows = [KV(key: 'Authorization', value: 'x', description: 'who')];
        await tester.pumpWidget(host(KVEditor(rows: rows, onChanged: () {})));
        await tester.tap(find.text('Bulk edit'));
        await tester.pump();
        await tester.enterText(bulkField, 'Author: x');
        await tester.pump();
        expect(rows.single.description, '');
        await tester.enterText(bulkField, 'Authorization: y');
        await tester.pump();
        expect(rows.single.key, 'Authorization');
        expect(rows.single.value, 'y');
        expect(rows.single.description, 'who');
      },
    );

    testWidgets(
      'editing in text shows up in the table and file rows stay file rows',
      (tester) async {
        final rows = [KV(key: 'avatar', value: '/tmp/a.png', isFile: true)];
        await tester.pumpWidget(
          host(KVEditor(rows: rows, allowFiles: true, onChanged: () {})),
        );
        await tester.tap(find.text('Bulk edit'));
        await tester.pump();
        expect(
          tester.widget<TextField>(bulkField).controller!.text,
          'avatar: @/tmp/a.png',
        );
        await tester.enterText(bulkField, 'avatar: @/tmp/b.png\nname: Ada');
        await tester.tap(find.text('Key-value edit'));
        await tester.pump();
        expect(rows.length, 2);
        expect(rows[0].isFile, isTrue);
        expect(rows[0].value, '/tmp/b.png');
        expect(rows[1].isFile, isFalse);
        expect(find.widgetWithText(TextField, 'name'), findsOneWidget);
        expect(find.widgetWithText(TextField, 'Ada'), findsOneWidget);
        expect(find.widgetWithText(TextField, '/tmp/b.png'), findsOneWidget);
      },
    );

    testWidgets('bulkEdit: false hides the toggle', (tester) async {
      await tester.pumpWidget(
        host(KVEditor(rows: [KV()], bulkEdit: false, onChanged: () {})),
      );
      expect(find.text('Bulk edit'), findsNothing);
    });

    testWidgets('a description column is shown and edited per row', (
      tester,
    ) async {
      final rows = [KV(key: 'a', value: '1', description: 'first')];
      var changes = 0;
      await tester.pumpWidget(
        host(
          KVEditor(
            rows: rows,
            showDescription: true,
            keyHelp: 'k',
            valueHelp: 'v',
            descriptionHelp: 'd',
            onChanged: () => changes++,
          ),
        ),
      );
      expect(find.text('Description'), findsWidgets);
      await tester.enterText(find.widgetWithText(TextField, 'first'), 'second');
      expect(rows.single.description, 'second');
      expect(changes, 1);
    });

    for (final size in [
      const Size(320, 640),
      const Size(360, 640),
      const Size(1280, 800),
    ]) {
      testWidgets(
        'fits ${size.width.toInt()} px wide with files and descriptions, in both views',
        (tester) async {
          await setSize(tester, size);
          final rows = [
            KV(
              key: 'a-rather-long-field-name',
              value: 'a value ' * 6,
              description: 'note ' * 6,
            ),
            KV(
              key: 'file',
              value: '/home/me/some/deep/folder/photo.png',
              isFile: true,
            ),
            KV(key: 'off', value: 'x', enabled: false),
          ];
          await tester.pumpWidget(
            host(
              KVEditor(
                rows: rows,
                allowFiles: true,
                showDescription: true,
                keyHelp: 'k',
                valueHelp: 'v',
                descriptionHelp: 'd',
                onChanged: () {},
              ),
            ),
          );
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('Bulk edit'));
          await tester.pump();
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('Key-value edit'));
          await tester.pump();
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('can be placed inside another scroll view', (tester) async {
      final rows = [KV(key: 'a', value: '1')];
      await tester.pumpWidget(
        host(
          SingleChildScrollView(
            child: KVEditor(rows: rows, scrollable: false, onChanged: () {}),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Bulk edit'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(bulkField, findsOneWidget);
    });
  });
}
