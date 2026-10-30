import 'dart:convert';

import 'package:api_workbench/services/protocols/message_log.dart';
import 'package:api_workbench/theme.dart';
import 'package:api_workbench/ui/protocols/message_log_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MessageLog', () {
    test('keeps only the newest entries once it is full', () {
      final log = MessageLog(capacity: 50);
      for (var i = 1; i <= 120; i++) {
        log.add(Direction.received, text: 'm$i');
      }
      expect(log.length, 50);
      expect(log.dropped, 70);
      expect(log[0].text, 'm71');
      expect(log[49].text, 'm120');
      expect(log[0].seq, 71); // sequence numbers keep counting
      expect(MessageLog().capacity, 2000);
    });

    test('notifies on add and clear', () {
      final log = MessageLog();
      var n = 0;
      void listener() => n++;
      log.addListener(listener);
      log.add(Direction.sent, text: 'a');
      log.clear();
      expect(n, 2);
      expect(log.isEmpty, isTrue);
      expect(log.dropped, 0);
      log.removeListener(listener);
      log.add(Direction.sent, text: 'b');
      expect(n, 2);
    });

    test('filters by direction and search text', () {
      final log = MessageLog()
        ..add(Direction.sent, text: 'hello world', title: 'chat')
        ..add(Direction.received, text: 'HELLO back', meta: {'QoS': '1'})
        ..add(Direction.system, text: 'Connected')
        ..add(Direction.received, bytes: Uint8List.fromList([0xde, 0xad]));
      expect(log.filtered().length, 4);
      expect(log.filtered(query: 'hello').map((e) => e.seq), [1, 2]);
      expect(log.filtered(query: ' CHAT ').map((e) => e.seq), [1]);
      expect(log.filtered(query: 'qos 1').map((e) => e.seq), [2]);
      expect(log.filtered(query: 'de ad').map((e) => e.seq), [4]);
      expect(log.filtered(query: '3q0=').map((e) => e.seq), [4]); // base64
      expect(log.filtered(directions: {Direction.received}).map((e) => e.seq), [
        2,
        4,
      ]);
      expect(
        log.filtered(query: 'hello', directions: {Direction.sent}).length,
        1,
      );
    });

    test('exports the log as text', () {
      final log = MessageLog()
        ..add(Direction.sent, label: 'text', text: '{"a":1}')
        ..add(
          Direction.received,
          label: 'message',
          title: 'a/b',
          text: 'x',
          meta: {'QoS': '1'},
        );
      final text = log.export(BinaryFormat.hex);
      expect(text, contains('SENT text'));
      expect(text, contains('"a": 1'));
      expect(text, contains('RECEIVED message a/b QoS=1 (1 B)'));
      expect(
        log.export(BinaryFormat.hex, only: [log[1]]),
        isNot(contains('SENT')),
      );
    });
  });

  group('LogEntry', () {
    test('sizes count bytes, not characters', () {
      final e = LogEntry(seq: 1, direction: Direction.sent, text: 'héllo');
      expect(e.size, 6);
      expect(
        LogEntry(seq: 2, direction: Direction.sent, bytes: Uint8List(300)).size,
        300,
      );
    });

    test('JSON is pretty-printed, other text is left alone', () {
      final json = LogEntry(
        seq: 1,
        direction: Direction.received,
        text: '{"a":[1,2],"b":{"c":null}}',
      );
      expect(json.prettyText, contains('\n  "a": ['));
      expect(json.body(BinaryFormat.hex), json.prettyText);
      final plain = LogEntry(seq: 2, direction: Direction.received, text: 'hi');
      expect(plain.prettyText, isNull);
      expect(plain.body(BinaryFormat.hex), 'hi');
      final bad = LogEntry(
        seq: 3,
        direction: Direction.received,
        text: '{oops',
      );
      expect(bad.prettyText, isNull);
      expect(bad.body(BinaryFormat.hex), '{oops');
      expect(prettyJson('  [1, 2] '), '[\n  1,\n  2\n]');
      expect(prettyJson('42'), isNull);
    });

    test('previews are one line and bounded', () {
      final long = LogEntry(
        seq: 1,
        direction: Direction.received,
        text: 'line one\n   line two\n${'x' * 500}',
      );
      final p = long.preview(BinaryFormat.hex, max: 40);
      expect(p, isNot(contains('\n')));
      expect(p.length, 41);
      expect(p, endsWith('…'));
      expect(p, startsWith('line one line two'));
    });

    test('binary entries show as hex or base64', () {
      final e = LogEntry(
        seq: 1,
        direction: Direction.received,
        bytes: Uint8List.fromList(utf8.encode('Hello, World! 0123456789')),
      );
      expect(e.isBinary, isTrue);
      expect(e.body(BinaryFormat.base64), base64.encode(e.bytes!));
      final dump = e.body(BinaryFormat.hex);
      expect(
        dump,
        startsWith('0000  48 65 6c 6c 6f 2c 20 57 6f 72 6c 64 21 20 30 31'),
      );
      expect(dump, contains('Hello, World! 01'));
      expect(dump.split('\n'), hasLength(2));
      expect(e.preview(BinaryFormat.hex), startsWith('48 65 6c 6c 6f'));
      expect(
        e.preview(BinaryFormat.base64),
        'SGVsbG8sIFdvcmxkISAwMTIzNDU2Nzg5',
      );
    });

    test('helpers format times and sizes', () {
      expect(formatClock(DateTime(2026, 1, 2, 3, 4, 5, 6)), '03:04:05.006');
      expect(formatSize(12), '12 B');
      expect(formatSize(2048), '2.0 KB');
      expect(formatSize(3 * 1024 * 1024), '3.0 MB');
      expect(hexLine([0, 255, 16]), '00 ff 10');
    });
  });

  group('MessageLogView', () {
    late MessageLog log;
    late LogViewState view;
    final copied = <String>[];

    setUp(() {
      copied.clear();
      log = MessageLog()
        ..add(Direction.system, text: 'Connected')
        ..add(Direction.sent, label: 'text', text: '{"type":"ping","n":1}')
        ..add(
          Direction.received,
          label: 'message',
          title: 'sensors/a',
          text: 'pong',
          meta: {'QoS': '1', 'retain': 'false'},
        )
        ..add(
          Direction.received,
          label: 'binary',
          bytes: Uint8List.fromList([1, 2, 3]),
        );
      view = LogViewState();
    });

    Future<void> pumpView(WidgetTester tester, {double width = 700}) async {
      tester.view.physicalSize = Size(width, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
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
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => MessageLogView(
                log: log,
                view: view,
                header: const Text('header'),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('lists entries with topic, QoS and retain', (tester) async {
      await pumpView(tester);
      expect(find.text('header'), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('sensors/a'), findsOneWidget);
      expect(find.text('QoS 1'), findsOneWidget);
      expect(find.text('retain false'), findsOneWidget);
      expect(find.text('4 messages'), findsOneWidget);
      expect(find.text('01 02 03'), findsOneWidget);
    });

    testWidgets('expanding a JSON message shows it indented', (tester) async {
      await pumpView(tester);
      expect(find.textContaining('"type": "ping"'), findsNothing);
      await tester.tap(find.text('{"type":"ping","n":1}'));
      await tester.pump();
      expect(find.textContaining('  "type": "ping",'), findsOneWidget);
      await tester.tap(find.byType(SelectableText));
      await tester.pump();
      expect(find.textContaining('  "type": "ping",'), findsOneWidget);
    });

    testWidgets('search narrows the list', (tester) async {
      await pumpView(tester);
      await tester.enterText(find.byType(TextField), 'sensors');
      await tester.pump();
      expect(find.text('sensors/a'), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
      expect(find.text('1 of 4 messages'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'nothing like this');
      await tester.pump();
      expect(
        find.text('No messages match the search or filter.'),
        findsOneWidget,
      );
    });

    testWidgets('filters by direction', (tester) async {
      await pumpView(tester);
      await tester.tap(find.byIcon(Icons.filter_alt_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('System notes'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Connected'), findsNothing);
      expect(find.text('3 of 4 messages'), findsOneWidget);
    });

    testWidgets('copies one message and the whole log', (tester) async {
      await pumpView(tester);
      await tester.tap(find.byIcon(Icons.copy_outlined).at(1));
      await tester.pump();
      expect(copied.single, contains('"type": "ping"'));
      await tester.tap(find.byIcon(Icons.copy_all_outlined));
      await tester.pump();
      expect(copied.last, contains('SYSTEM'));
      expect(copied.last, contains('RECEIVED message sensors/a'));
      expect(copied.last, contains('pong'));
    });

    testWidgets('switches binary between hex and base64', (tester) async {
      await pumpView(tester);
      expect(find.text('01 02 03'), findsOneWidget);
      await tester.tap(find.text('HEX'));
      await tester.pump();
      expect(find.text('AQID'), findsOneWidget);
      expect(view.binary, BinaryFormat.base64);
    });

    testWidgets('clears the log', (tester) async {
      await pumpView(tester);
      await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
      await tester.pump();
      expect(log.isEmpty, isTrue);
      expect(find.text('Nothing yet.'), findsOneWidget);
    });

    testWidgets('follows new messages until the user scrolls up', (
      tester,
    ) async {
      for (var i = 0; i < 80; i++) {
        log.add(Direction.received, text: 'filler $i');
      }
      await pumpView(tester);
      await tester.pumpAndSettle();
      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      expect(
        scrollable.position.pixels,
        scrollable.position.maxScrollExtent,
        reason: 'starts at the newest message',
      );

      // A new message while following keeps the view at the bottom.
      log.add(Direction.received, text: 'newest');
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: MessageLogView(log: log, view: view),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('newest'), findsOneWidget);
      expect(scrollable.position.pixels, scrollable.position.maxScrollExtent);

      // Scrolling up to read turns following off.
      await tester.drag(find.byType(ListView), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(view.autoScroll, isFalse);
      final readingAt = scrollable.position.pixels;
      log.add(Direction.received, text: 'while reading');
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: MessageLogView(log: log, view: view),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(scrollable.position.pixels, readingAt);

      // The button follows again.
      await tester.tap(find.byIcon(Icons.vertical_align_bottom));
      await tester.pumpAndSettle();
      expect(view.autoScroll, isTrue);
      expect(scrollable.position.pixels, scrollable.position.maxScrollExtent);
    });

    for (final width in [320.0, 360.0]) {
      testWidgets('fits at ${width.toInt()} px', (tester) async {
        for (var i = 0; i < 6; i++) {
          log.add(
            Direction.received,
            label: 'message',
            title: 'a/very/long/topic/name/that/keeps/going/and/going/$i',
            text: 'payload ${'long ' * 30}',
            meta: {'QoS': '2', 'retain': 'true', 'id': 'abcdef$i'},
          );
        }
        await pumpView(tester, width: width);
        await tester.tap(find.textContaining('payload long').first);
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  });
}
