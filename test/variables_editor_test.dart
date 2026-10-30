import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/theme.dart';
import 'package:api_workbench/ui/variables_editor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Key _k(int row, String field) => Key('var.$row.$field');

void main() {
  void size(WidgetTester tester, double w, double h) {
    tester.view.physicalSize = Size(w, h);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// A widget test that runs on [platform] (touch or desktop sizing). The
  /// override is cleared before the test ends, as the binding requires.
  void testOn(
    TargetPlatform platform,
    String name,
    Future<void> Function(WidgetTester tester) body,
  ) => testWidgets(name, (tester) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  Widget host(List<KV> rows, {VoidCallback? onChanged, double textScale = 1}) =>
      MaterialApp(
        theme: buildTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: VariablesEditor(rows: rows, onChanged: onChanged ?? () {}),
        ),
      );

  TextField field(WidgetTester tester, int row, String name) =>
      tester.widget<TextField>(find.byKey(_k(row, name)));

  Future<void> pickMenu(WidgetTester tester, int row, String item) async {
    // The menu is built from the row's latest frame, so settle typing first.
    await tester.pump();
    await tester.tap(find.byKey(_k(row, 'menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(item), warnIfMissed: false);
    await tester.pumpAndSettle();
  }

  TextButton toolbarButton(WidgetTester tester, String label) =>
      tester.widget<TextButton>(
        find.ancestor(
          of: find.text(label),
          matching: find.bySubtype<TextButton>(),
        ),
      );

  group('current values', () {
    testWidgets('typing sets current, clearing restores null', (tester) async {
      size(tester, 800, 800);
      final rows = [KV(key: 'baseUrl', value: 'https://prod')];
      var changes = 0;
      await tester.pumpWidget(host(rows, onChanged: () => changes++));

      // Empty current shows the initial value as its placeholder.
      expect(field(tester, 0, 'current').decoration!.hintText, 'https://prod');

      await tester.enterText(find.byKey(_k(0, 'current')), 'http://localhost');
      expect(rows.single.current, 'http://localhost');
      expect(rows.single.value, 'https://prod');
      expect(rows.single.effective, 'http://localhost');
      expect(changes, greaterThan(0));

      await tester.enterText(find.byKey(_k(0, 'current')), '');
      expect(rows.single.current, isNull);
      expect(rows.single.effective, 'https://prod');
    });

    testWidgets('typing in Initial leaves current alone', (tester) async {
      size(tester, 800, 800);
      final rows = [KV(key: 'a', value: 'one', current: 'local')];
      await tester.pumpWidget(host(rows));

      await tester.enterText(find.byKey(_k(0, 'initial')), 'two');
      expect(rows.single.value, 'two');
      expect(rows.single.current, 'local');
      expect(field(tester, 0, 'current').controller!.text, 'local');
    });

    testWidgets('controllers survive keystrokes and rebuilds', (tester) async {
      size(tester, 800, 800);
      final rows = [KV(key: 'a', value: 'x')];
      await tester.pumpWidget(host(rows));
      final before = field(tester, 0, 'current').controller;
      await tester.enterText(find.byKey(_k(0, 'current')), 'abc');
      await tester.enterText(find.byKey(_k(0, 'current')), 'abcd');
      await tester.enterText(find.byKey(_k(0, 'name')), 'renamed');
      expect(field(tester, 0, 'current').controller, same(before));
      expect(before!.text, 'abcd');
      expect(rows.single.key, 'renamed');
    });

    testWidgets('an existing current value is shown and tinted', (
      tester,
    ) async {
      size(tester, 800, 800);
      await tester.pumpWidget(
        host([
          KV(key: 'a', value: 'x', current: 'y'),
          KV(key: 'b', value: 'x'),
        ]),
      );
      expect(field(tester, 0, 'current').controller!.text, 'y');
      expect(field(tester, 0, 'current').decoration!.fillColor, isNotNull);
      expect(field(tester, 1, 'current').decoration!.fillColor, isNull);
    });

    testWidgets('an empty initial value gives a neutral placeholder', (
      tester,
    ) async {
      size(tester, 800, 800);
      await tester.pumpWidget(host([KV(key: 'a')]));
      expect(
        field(tester, 0, 'current').decoration!.hintText,
        contains('Same'),
      );
    });
  });

  group('reset and persist', () {
    testWidgets('per row: Reset clears current', (tester) async {
      size(tester, 800, 800);
      final rows = [KV(key: 'a', value: 'init', current: 'local')];
      var changes = 0;
      await tester.pumpWidget(host(rows, onChanged: () => changes++));

      await pickMenu(tester, 0, 'Reset');
      expect(rows.single.current, isNull);
      expect(rows.single.value, 'init');
      expect(field(tester, 0, 'current').controller!.text, '');
      expect(field(tester, 0, 'initial').controller!.text, 'init');
      expect(changes, greaterThan(0));
    });

    testWidgets('per row: Persist moves current into initial', (tester) async {
      size(tester, 800, 800);
      final rows = [KV(key: 'a', value: 'init', current: 'local')];
      await tester.pumpWidget(host(rows));

      await pickMenu(tester, 0, 'Persist');
      expect(rows.single.value, 'local');
      expect(rows.single.current, isNull);
      expect(rows.single.effective, 'local');
      expect(field(tester, 0, 'initial').controller!.text, 'local');
      expect(field(tester, 0, 'current').controller!.text, '');
    });

    testWidgets('Reset and Persist are off without a current value', (
      tester,
    ) async {
      size(tester, 800, 800);
      final rows = [KV(key: 'a', value: 'init')];
      await tester.pumpWidget(host(rows));
      await tester.tap(find.byKey(_k(0, 'menu')));
      await tester.pumpAndSettle();
      final off = find.byWidgetPredicate(
        (w) => w is PopupMenuItem && !w.enabled,
      );
      expect(off, findsNWidgets(2));
      await tester.tapAt(const Offset(5, 5)); // close the menu
      await tester.pumpAndSettle();
      expect(rows.single.value, 'init');
    });

    testWidgets('Reset all and Persist all ask first, then apply', (
      tester,
    ) async {
      size(tester, 800, 800);
      final rows = [
        KV(key: 'a', value: 'a0', current: 'a1'),
        KV(key: 'b', value: 'b0'),
        KV(key: 'c', value: 'c0', current: 'c1', enabled: false),
      ];
      await tester.pumpWidget(host(rows));

      // Cancel changes nothing.
      await tester.tap(find.text('Reset all'));
      await tester.pumpAndSettle();
      expect(find.text('Reset current values?'), findsOneWidget);
      expect(find.textContaining('2 variables'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(rows[0].current, 'a1');
      expect(rows[2].current, 'c1');

      // Persist all, confirmed (disabled rows count too).
      await tester.tap(find.text('Persist all'));
      await tester.pumpAndSettle();
      expect(find.text('Persist current values?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Persist all'));
      await tester.pumpAndSettle();
      expect([for (final r in rows) r.value], ['a1', 'b0', 'c1']);
      expect([for (final r in rows) r.current], [null, null, null]);
      expect(field(tester, 0, 'initial').controller!.text, 'a1');
      expect(field(tester, 0, 'current').controller!.text, '');
      // Nothing is left to apply, so the buttons switch off.
      expect(toolbarButton(tester, 'Reset all').onPressed, isNull);
      expect(toolbarButton(tester, 'Persist all').onPressed, isNull);

      rows[1].current = 'b1';
      await tester.pumpWidget(host(rows)); // new widget, same rows
      await tester.tap(find.text('Reset all'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Reset all'));
      await tester.pumpAndSettle();
      expect(rows[1].current, isNull);
      expect(rows[1].value, 'b0');
    });
  });

  group('secret variables', () {
    testWidgets('both value fields are obscured until the eye is pressed', (
      tester,
    ) async {
      size(tester, 800, 800);
      final rows = [
        KV(key: 'token', value: 'initial-secret', current: 'current-secret')
          ..secret = true,
        KV(key: 'plain', value: 'visible'),
      ];
      await tester.pumpWidget(host(rows));

      expect(field(tester, 0, 'initial').obscureText, isTrue);
      expect(field(tester, 0, 'current').obscureText, isTrue);
      expect(field(tester, 1, 'initial').obscureText, isFalse);
      expect(field(tester, 1, 'current').obscureText, isFalse);
      // Plain rows have no eye.
      expect(find.byKey(_k(1, 'eye')), findsNothing);

      await tester.tap(find.byKey(_k(0, 'eye')));
      await tester.pump();
      expect(field(tester, 0, 'initial').obscureText, isFalse);
      expect(field(tester, 0, 'current').obscureText, isFalse);
      expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);

      await tester.tap(find.byKey(_k(0, 'eye')));
      await tester.pump();
      expect(field(tester, 0, 'initial').obscureText, isTrue);
      expect(field(tester, 0, 'current').obscureText, isTrue);
    });

    testWidgets('the placeholder does not give the initial secret away', (
      tester,
    ) async {
      size(tester, 800, 800);
      final rows = [KV(key: 'token', value: 'initial-secret')..secret = true];
      await tester.pumpWidget(host(rows));
      expect(
        field(tester, 0, 'current').decoration!.hintText,
        isNot(contains('initial-secret')),
      );
      await tester.tap(find.byKey(_k(0, 'eye')));
      await tester.pump();
      expect(
        field(tester, 0, 'current').decoration!.hintText,
        'initial-secret',
      );
    });

    testWidgets('the type menu makes a variable secret and back', (
      tester,
    ) async {
      size(tester, 800, 800);
      final rows = [KV(key: 'token', value: 'abc')];
      await tester.pumpWidget(host(rows));
      expect(find.text('Default'), findsOneWidget);

      await tester.tap(find.byKey(_k(0, 'type')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Secret').last);
      await tester.pumpAndSettle();
      expect(rows.single.secret, isTrue);
      expect(field(tester, 0, 'initial').obscureText, isTrue);
      expect(find.byKey(_k(0, 'eye')), findsOneWidget);

      await tester.tap(find.byKey(_k(0, 'type')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Default').last);
      await tester.pumpAndSettle();
      expect(rows.single.secret, isFalse);
      expect(field(tester, 0, 'initial').obscureText, isFalse);
      expect(find.byKey(_k(0, 'eye')), findsNothing);
    });

    testWidgets('on a phone the menu carries the secret switch', (
      tester,
    ) async {
      size(tester, 320, 640);
      final rows = [KV(key: 'token', value: 'abc')];
      await tester.pumpWidget(host(rows));
      expect(find.byKey(_k(0, 'type')), findsNothing);

      await pickMenu(tester, 0, 'Secret');
      expect(rows.single.secret, isTrue);
      expect(field(tester, 0, 'current').obscureText, isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group('rows', () {
    testWidgets('a disabled row is dimmed, editable and left out of kvMap', (
      tester,
    ) async {
      size(tester, 800, 800);
      final rows = [KV(key: 'a', value: '1'), KV(key: 'b', value: '2')];
      await tester.pumpWidget(host(rows));
      expect(kvMap(rows), {'a': '1', 'b': '2'});

      await tester.tap(find.byKey(_k(1, 'enabled')));
      await tester.pump();
      expect(rows[1].enabled, isFalse);
      expect(kvMap(rows), {'a': '1'});
      double opacityOf(int row) => tester
          .widget<Opacity>(
            find
                .ancestor(
                  of: find.byKey(_k(row, 'name')),
                  matching: find.byType(Opacity),
                )
                .first,
          )
          .opacity;
      expect(opacityOf(0), 1);
      expect(opacityOf(1), lessThan(1));

      // Still editable, and still resettable.
      await tester.enterText(find.byKey(_k(1, 'current')), 'x');
      expect(rows[1].current, 'x');
      await pickMenu(tester, 1, 'Reset');
      expect(rows[1].current, isNull);

      await tester.tap(find.byKey(_k(1, 'enabled')));
      await tester.pump();
      expect(kvMap(rows), {'a': '1', 'b': '2'});
    });

    testWidgets('shows values a script wrote and survives removed rows', (
      tester,
    ) async {
      size(tester, 800, 800);
      final rows = [KV(key: 'a', value: '1'), KV(key: 'b', value: '2')];
      await tester.pumpWidget(host(rows));
      expect(field(tester, 0, 'current').controller!.text, '');

      // A script captured a value while the editor was open.
      rows[0].current = 'captured';
      rows[1].value = 'changed';
      await tester.pumpWidget(host(rows));
      expect(field(tester, 0, 'current').controller!.text, 'captured');
      expect(field(tester, 1, 'initial').controller!.text, 'changed');

      // The caller drops a row (an import replaced it).
      rows.removeAt(0);
      await tester.pumpWidget(host(rows));
      await tester.pump();
      expect(field(tester, 0, 'name').controller!.text, 'b');
      expect(tester.takeException(), isNull);
    });

    testWidgets('kvMap uses the current value when one is set', (tester) async {
      final rows = [KV(key: 'a', value: '1', current: '9'), KV(key: 'b')];
      expect(kvMap(rows), {'a': '9', 'b': ''});
    });

    testWidgets('Add variable appends a row, focuses it and calls back', (
      tester,
    ) async {
      size(tester, 800, 800);
      final rows = <KV>[];
      var changes = 0;
      await tester.pumpWidget(host(rows, onChanged: () => changes++));
      expect(find.textContaining('No variables yet'), findsOneWidget);

      await tester.tap(find.text('Add variable'));
      await tester.pumpAndSettle();
      expect(rows, hasLength(1));
      expect(changes, 1);
      expect(find.textContaining('No variables yet'), findsNothing);
      await tester.enterText(find.byKey(_k(0, 'name')), 'token');
      expect(rows.single.key, 'token');
    });

    testWidgets('Delete removes the row and its field state', (tester) async {
      size(tester, 800, 800);
      final rows = [KV(key: 'a', value: '1'), KV(key: 'b', value: '2')];
      await tester.pumpWidget(host(rows));
      await pickMenu(tester, 0, 'Delete');
      expect(rows.map((r) => r.key), ['b']);
      expect(field(tester, 0, 'name').controller!.text, 'b');
      expect(find.byKey(_k(1, 'name')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Description is edited from the menu and shown', (
      tester,
    ) async {
      size(tester, 800, 800);
      final rows = [KV(key: 'a', value: '1')];
      await tester.pumpWidget(host(rows));
      await pickMenu(tester, 0, 'Description…');
      await tester.enterText(find.byType(TextField).last, 'The API root');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(rows.single.description, 'The API root');
      expect(find.text('The API root'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('filter box appears past 8 rows and narrows the list', (
      tester,
    ) async {
      size(tester, 800, 1400);
      final rows = [for (var i = 0; i < 8; i++) KV(key: 'var$i', value: 'v$i')];
      await tester.pumpWidget(host(rows));
      expect(find.byKey(const Key('var.filter')), findsNothing);

      rows
        ..add(KV(key: 'apiToken', value: 'abc', current: 't'))
        ..add(
          KV(key: 'secretKey', value: 'hunter2', current: 'x')..secret = true,
        );
      await tester.pumpWidget(host(rows));
      await tester.pump();
      expect(find.byKey(const Key('var.filter')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('var.filter')), 'token');
      await tester.pump();
      expect(find.byKey(_k(8, 'name')), findsOneWidget);
      expect(find.byKey(_k(0, 'name')), findsNothing);

      // Secret values are not searchable.
      await tester.enterText(find.byKey(const Key('var.filter')), 'hunter2');
      await tester.pump();
      expect(find.textContaining('No variable matches'), findsOneWidget);

      // Bulk actions only touch the matches.
      await tester.enterText(find.byKey(const Key('var.filter')), 'token');
      await tester.pump();
      await tester.tap(find.text('Reset all'));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 matching variable'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Reset all'));
      await tester.pumpAndSettle();
      expect(rows[8].current, isNull);
      expect(rows[9].current, 'x');
    });

    testWidgets('overriddenBy adds a note under the row', (tester) async {
      size(tester, 800, 800);
      final rows = [KV(key: 'a', value: '1'), KV(key: 'b', value: '2')];
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: VariablesEditor(
              rows: rows,
              onChanged: () {},
              overriddenBy: (r) =>
                  r.key == 'a' ? 'the environment "Dev"' : null,
            ),
          ),
        ),
      );
      expect(find.text('Overridden by the environment "Dev"'), findsOneWidget);
    });
  });

  group('layout', () {
    List<KV> sample() => [
      KV(
        key: 'a_remarkably_long_variable_name_that_keeps_going_and_going',
        value: 'https://example.com/api/v1/some/very/long/path?with=query',
        current: 'http://localhost:8080/api/v1/some/very/long/path?x=1',
        description:
            'A long description that explains in detail what this '
            'variable is for and where it is used, over several lines.',
      ),
      KV(key: 'token', value: 'sk-live-0123456789', current: 'sk-test-9876')
        ..secret = true,
      KV(key: 'off', value: 'x', enabled: false),
      KV(key: 'empty'),
    ];

    for (final (w, h, platform) in [
      (320.0, 640.0, TargetPlatform.android),
      (360.0, 640.0, TargetPlatform.android),
      (420.0, 800.0, TargetPlatform.android),
      (560.0, 800.0, TargetPlatform.linux),
      (768.0, 1024.0, TargetPlatform.android),
      (1280.0, 800.0, TargetPlatform.linux),
    ]) {
      testOn(platform, 'no overflow at ${w.toInt()}x${h.toInt()}', (
        tester,
      ) async {
        size(tester, w, h);
        final rows = sample();
        await tester.pumpWidget(host(rows));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(_k(0, 'name')), findsOneWidget);

        // Reveal the secret, open a menu and the type switch if present.
        await tester.tap(find.byKey(_k(1, 'eye')));
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byKey(_k(1, 'menu')));
        await tester.tap(find.byKey(_k(1, 'menu')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tapAt(const Offset(2, 2));
        await tester.pumpAndSettle();
      });
    }

    testWidgets('phone layout stacks name above the two values', (
      tester,
    ) async {
      size(tester, 320, 640);
      await tester.pumpWidget(host(sample()));
      final name = tester.getRect(find.byKey(_k(0, 'name')));
      final initial = tester.getRect(find.byKey(_k(0, 'initial')));
      final current = tester.getRect(find.byKey(_k(0, 'current')));
      expect(initial.top, greaterThanOrEqualTo(name.bottom));
      expect(current.top, greaterThanOrEqualTo(initial.bottom));
    });

    testOn(TargetPlatform.linux, 'desktop layout is one line with a header', (
      tester,
    ) async {
      size(tester, 1280, 800);
      await tester.pumpWidget(host(sample()));
      expect(find.text('Initial value'), findsOneWidget);
      expect(find.text('Current value'), findsOneWidget);
      expect(find.text('Type'), findsOneWidget);
      final name = tester.getRect(find.byKey(_k(0, 'name')));
      final initial = tester.getRect(find.byKey(_k(0, 'initial')));
      final current = tester.getRect(find.byKey(_k(0, 'current')));
      expect(initial.center.dy, closeTo(name.center.dy, 1));
      expect(current.center.dy, closeTo(name.center.dy, 1));
      expect(current.left, greaterThan(initial.right));
    });

    testWidgets('phones keep the bulk actions in a menu', (tester) async {
      size(tester, 320, 640);
      final rows = [
        KV(key: 'a', value: 'a0', current: 'a1'),
        KV(key: 'b', value: 'b0', current: 'b1'),
      ];
      await tester.pumpWidget(host(rows));
      expect(find.text('Reset all'), findsNothing);

      await tester.tap(find.byKey(const Key('var.bulk')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Persist all'));
      await tester.pumpAndSettle();
      expect(find.text('Persist current values?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Persist all'));
      await tester.pumpAndSettle();
      expect([for (final r in rows) r.value], ['a1', 'b1']);
      expect([for (final r in rows) r.current], [null, null]);
      expect(tester.takeException(), isNull);

      // A bigger screen shows the buttons themselves.
      size(tester, 800, 800);
      await tester.pumpWidget(host(rows));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('var.bulk')), findsNothing);
      expect(find.text('Reset all'), findsOneWidget);
    });

    testWidgets('a large text size still fits a 320 px phone', (tester) async {
      size(tester, 320, 640);
      await tester.pumpWidget(host(sample(), textScale: 1.4));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('long lists scroll without building every row', (tester) async {
      size(tester, 360, 640);
      final rows = [
        for (var i = 0; i < 200; i++) KV(key: 'var$i', value: 'value$i'),
      ];
      await tester.pumpWidget(host(rows));
      expect(find.byKey(const Key('var.filter')), findsOneWidget);
      expect(find.byKey(_k(150, 'name')), findsNothing);
      for (var i = 0; i < 40; i++) {
        if (find.byKey(_k(150, 'name')).evaluate().isNotEmpty) break;
        await tester.drag(find.byType(ListView), const Offset(0, -2000));
        await tester.pump();
      }
      expect(find.byKey(_k(150, 'name')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('editGlobals', () {
    late Directory tmp;
    final storages = <Storage>[];

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('aw_vars');
    });

    tearDown(() async {
      storages.clear();
      try {
        await tmp.delete(recursive: true);
      } on FileSystemException {
        // A write from a failed test was still landing; the OS cleans /tmp.
      }
    });

    /// Lets queued saves land. Saves started while the test pumps frames
    /// live in the fake-async zone, so each step needs a frame as well as
    /// real time before it finishes.
    Future<void> settle(WidgetTester tester) async {
      var done = false;
      Future.wait([for (final s in storages) s.flush()]).then((_) {
        done = true;
      });
      for (var i = 0; i < 400 && !done; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      expect(done, isTrue, reason: 'saves did not finish');
    }

    Future<AppState> loadedState(WidgetTester tester) async {
      late AppState state;
      await tester.runAsync(() async {
        final storage = Storage(overrideDir: tmp);
        storages.add(storage);
        state = AppState(storage: storage);
        while (!state.loaded) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      return state;
    }

    Future<void> open(WidgetTester tester, AppState state) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => editGlobals(context, state),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testOn(TargetPlatform.linux, 'edits AppState.globals and saves them', (
      tester,
    ) async {
      size(tester, 1280, 800);
      final state = await loadedState(tester);
      state.globals.add(KV(key: 'region', value: 'eu'));
      await open(tester, state);

      expect(find.text('Globals (1)'), findsOneWidget);
      for (final scope in ['Collection', 'Environment', 'Data', 'Local']) {
        expect(find.text(scope), findsOneWidget);
      }
      expect(find.text('Globals'), findsOneWidget); // the chip
      expect(find.textContaining('higher scope wins'), findsOneWidget);

      await tester.tap(find.text('Add variable'));
      await tester.pumpAndSettle();
      expect(state.globals, hasLength(2));
      expect(find.text('Globals (2)'), findsOneWidget);
      await tester.enterText(find.byKey(_k(1, 'name')), 'token');
      await tester.enterText(find.byKey(_k(1, 'initial')), 'abc');
      await tester.enterText(find.byKey(_k(1, 'current')), 'xyz');
      await tester.tap(find.byKey(_k(1, 'type')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Secret').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(_k(0, 'current')), 'us');

      final token = state.globals[1];
      expect(token.key, 'token');
      expect(token.value, 'abc');
      expect(token.current, 'xyz');
      expect(token.secret, isTrue);
      expect(state.globals[0].current, 'us');
      expect(state.secretValues, containsAll(['abc', 'xyz']));

      await pickMenu(tester, 0, 'Persist');
      expect(state.globals[0].value, 'us');
      expect(state.globals[0].current, isNull);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Globals (2)'), findsNothing);

      // Everything went to disk, with current values and the secret flag.
      await settle(tester);
      late AppState again;
      await tester.runAsync(() async {
        final storage = Storage(overrideDir: tmp);
        storages.add(storage);
        again = AppState(storage: storage);
        while (!again.loaded) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      expect(again.globals.map((v) => v.key), ['region', 'token']);
      expect(again.globals[0].value, 'us');
      expect(again.globals[1].current, 'xyz');
      expect(again.globals[1].secret, isTrue);
    });

    testWidgets('notes variables an environment or collection overrides', (
      tester,
    ) async {
      size(tester, 1280, 800);
      final state = await loadedState(tester);
      state.globals
        ..add(KV(key: 'baseUrl', value: 'g'))
        ..add(KV(key: 'region', value: 'eu'))
        ..add(KV(key: 'only', value: 'g'));
      state.addEnvironment('Dev').variables.add(KV(key: 'baseUrl', value: 'e'));
      state.addCollection('Shop').variables.add(KV(key: 'region', value: 'c'));
      await open(tester, state);
      expect(
        find.text('Overridden by the active environment "Dev"'),
        findsOneWidget,
      );
      expect(
        find.text('Overridden by the variables of collection "Shop"'),
        findsOneWidget,
      );
      await settle(tester);
    });

    for (final (w, h) in [(320.0, 640.0), (360.0, 640.0), (1280.0, 800.0)]) {
      testOn(
        w > 600 ? TargetPlatform.linux : TargetPlatform.android,
        'dialog has no overflow at ${w.toInt()}x${h.toInt()}',
        (tester) async {
          size(tester, w, h);
          final state = await loadedState(tester);
          state.globals
            ..add(
              KV(key: 'token', value: 'sk-live', current: 'sk-test')
                ..secret = true,
            )
            ..add(
              KV(
                key: 'a_long_global_variable_name_for_a_small_screen',
                value: 'https://example.com/a/very/long/path',
                description: 'Describes the variable at some length indeed.',
              ),
            );
          await open(tester, state);
          expect(tester.takeException(), isNull);
          expect(find.text('Globals (2)'), findsOneWidget);
          expect(find.text('Lowest to highest precedence:'), findsOneWidget);
          await tester.tap(find.text('Add variable'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(state.globals, hasLength(3));
          await settle(tester);
        },
      );
    }
  });
}
