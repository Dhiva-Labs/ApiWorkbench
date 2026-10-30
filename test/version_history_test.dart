import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/collection_diff.dart';
import 'package:api_workbench/services/json_store.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:api_workbench/services/version_history.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/ui/version_history_dialog.dart';
import 'package:api_workbench/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/state_harness.dart';
import 'support/test_fonts.dart';

/// Counts reads of each document.
class _CountingStore implements JsonStore {
  _CountingStore(this.inner);
  final JsonStore inner;
  final reads = <String>[];
  final writes = <String>[];

  @override
  Future<Object?> readJson(String name) {
    reads.add(name);
    return inner.readJson(name);
  }

  @override
  Future<void> writeJson(String name, Object data) {
    writes.add(name);
    return inner.writeJson(name, data);
  }
}

CollectionModel col({String id = 'c1', List<RequestModel>? requests}) =>
    CollectionModel(
      id: id,
      name: 'API',
      requests:
          requests ??
          [RequestModel(id: 'r1', name: 'List', url: 'https://x/a')],
    );

void main() {
  setUpAll(loadRoboto);

  late Directory tmp;
  late Storage storage;
  late DateTime now;
  late CollectionHistory history;

  CollectionHistory make([JsonStore? store]) =>
      CollectionHistory(store ?? storage)..clock = () => now;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('aw_history');
    storage = Storage(overrideDir: tmp);
    now = DateTime(2026, 10, 31, 12);
    history = make();
  });

  tearDown(() async {
    await storage.flush();
    await tmp.delete(recursive: true);
  });

  Future<List<HistorySnapshot>> snaps([String id = 'c1']) async {
    await history.idle();
    return history.snapshots(id);
  }

  group('recording', () {
    test('the first state is snapshotted at once', () async {
      history.record([col()]);
      final s = await snaps();
      expect(s, hasLength(1));
      expect(s.single.summary, 'Initial snapshot (1 request)');
      expect(s.single.time, now);
      expect(s.single.toCollection().requests.single.name, 'List');
    });

    test('an unchanged collection is not snapshotted again', () async {
      final c = col();
      history.record([c]);
      now = now.add(const Duration(minutes: 5));
      history.record([c]);
      history.record([col()]); // an equal copy has the same JSON
      expect(await snaps(), hasLength(1));
    });

    test(
      'changes inside the throttle wait, and only the latest is kept',
      () async {
        final c = col();
        history.record([c]);
        for (final name in ['one', 'two', 'three']) {
          now = now.add(const Duration(seconds: 10));
          c.requests.first.name = name;
          history.record([c]);
        }
        // 30 seconds after the first snapshot: still just the first.
        expect(await snaps(), hasLength(1));

        // Once the throttle allows, any record writes the waiting state.
        now = now.add(const Duration(seconds: 31));
        history.record([c]);
        final s = await snaps();
        expect(s, hasLength(2));
        expect(s.first.toCollection().requests.first.name, 'three');
        expect(s.first.summary, '1 request changed');
      },
    );

    test(
      'flush writes the waiting state without waiting for the throttle',
      () async {
        final c = col();
        history.record([c]);
        now = now.add(const Duration(seconds: 5));
        c.requests.first.url = 'https://x/b';
        history.record([c]);
        expect(await snaps(), hasLength(1));
        await history.flush();
        final s = await history.snapshots('c1');
        expect(s, hasLength(2));
        expect(s.first.toCollection().requests.first.url, 'https://x/b');
        // Nothing is left waiting.
        await history.flush();
        expect(await history.snapshots('c1'), hasLength(2));
      },
    );

    test('a change that is undone leaves no extra snapshot', () async {
      final c = col();
      history.record([c]);
      now = now.add(const Duration(seconds: 5));
      c.requests.first.name = 'tmp';
      history.record([c]);
      now = now.add(const Duration(seconds: 5));
      c.requests.first.name = 'List';
      history.record([c]);
      await history.flush();
      expect(await snaps(), hasLength(1));
    });

    test('keeps at most 50 snapshots, newest first', () async {
      final c = col();
      for (var i = 0; i < 60; i++) {
        c.requests.first.name = 'v$i';
        history.record([c]);
        now = now.add(const Duration(seconds: 61));
      }
      final s = await snaps();
      expect(s, hasLength(50));
      expect(s.first.toCollection().requests.first.name, 'v59');
      expect(s.last.toCollection().requests.first.name, 'v10');
      // The file holds the same fifty.
      final raw = await storage.readJson('history-c1.json') as Map;
      expect((raw['snapshots'] as List), hasLength(50));
    });

    test('collections have separate histories', () async {
      history.record([col(id: 'a'), col(id: 'b')]);
      expect(await snaps('a'), hasLength(1));
      expect(await snaps('b'), hasLength(1));
      expect(
        File('${tmp.path}/apiworkbench/history-a.json').existsSync(),
        isTrue,
      );
      expect(
        File('${tmp.path}/apiworkbench/history-b.json').existsSync(),
        isTrue,
      );
    });

    test('summaries say what changed against the previous snapshot', () async {
      final c = col(
        requests: [
          RequestModel(id: 'r1', name: 'A'),
          RequestModel(id: 'r2', name: 'B'),
        ],
      );
      history.record([c]);
      Future<String> next(void Function() edit) async {
        now = now.add(const Duration(seconds: 61));
        edit();
        history.record([c]);
        return (await snaps()).first.summary;
      }

      expect(
        await next(() => c.requests.add(RequestModel(id: 'r3', name: 'C'))),
        '1 request added',
      );
      expect(
        await next(() => c.requests.removeWhere((r) => r.id == 'r1')),
        '1 request removed',
      );
      expect(
        await next(() {
          c.requests.first.method = 'POST';
          c.requests.add(RequestModel(id: 'r4'));
          c.requests.add(RequestModel(id: 'r5'));
        }),
        '2 requests added, 1 request changed',
      );
      expect(
        await next(() => c.description = 'Hello'),
        'collection: description',
      );
      expect(
        await next(() {
          c.auth = AuthConfig(type: AuthType.bearer, bearerToken: 'x');
          c.variables.add(KV(key: 'a', value: '1'));
        }),
        'collection: auth, variables',
      );
    });
  });

  group('storage', () {
    test(
      'snapshots survive a restart, and an unchanged collection is not read',
      () async {
        final c = col();
        history.record([c]);
        await history.idle();

        final store = _CountingStore(storage);
        final again = make(store);
        now = now.add(const Duration(hours: 1));
        again.record([c]);
        await again.idle();
        expect(store.reads, ['history-index.json']); // not history-c1.json
        expect(store.writes, isEmpty);

        // The history dialog's read finds the old snapshot.
        expect(await again.snapshots('c1'), hasLength(1));
        expect(store.reads, contains('history-c1.json'));

        // A change reads the file once, and appends to it.
        c.requests.first.name = 'Renamed';
        again.record([c]);
        expect(await again.snapshots('c1'), hasLength(2));
        expect(store.reads.where((r) => r == 'history-c1.json'), hasLength(1));
      },
    );

    test('a corrupt history file starts over instead of failing', () async {
      Directory('${tmp.path}/apiworkbench').createSync(recursive: true);
      File(
        '${tmp.path}/apiworkbench/history-c1.json',
      ).writeAsStringSync('{nope');
      history.record([col()]);
      expect(await snaps(), hasLength(1));
    });

    test('works without a store, in memory', () async {
      final h = CollectionHistory()..clock = () => now;
      h.record([col()]);
      await h.idle();
      expect(await h.snapshots('c1'), hasLength(1));
    });

    test('ids that are not file-safe get a safe file name', () {
      expect(CollectionHistory.fileName('abc-123_X'), 'history-abc-123_X.json');
      final name = CollectionHistory.fileName('../../etc/x');
      expect(name, startsWith('history-'));
      expect(name, endsWith('.json'));
      expect(name.substring(0, name.length - 5), isNot(contains('/')));
      expect(name, isNot(contains('..')));
    });

    test('snapshotNow ignores the throttle but not duplicates', () async {
      final c = col();
      history.record([c]);
      c.requests.first.name = 'Changed';
      final s = await history.snapshotNow(c);
      expect(s!.toCollection().requests.first.name, 'Changed');
      expect(await snaps(), hasLength(2));
      expect(await history.snapshotNow(c), same(s)); // unchanged
      expect(await snaps(), hasLength(2));
    });
  });

  group('diff', () {
    test('lists request fields as readable changes', () {
      final a = col(
        requests: [
          RequestModel(
            id: 'r1',
            name: 'Create',
            method: 'POST',
            url: 'https://x/a',
            headers: [
              KV(key: 'A', value: '1'),
              KV(key: 'B', value: '2'),
            ],
            bodyType: BodyType.json,
            body: '{\n  "a": 1,\n  "b": 2\n}',
          ),
        ],
      );
      final b = CollectionModel.fromJson(a.toJson());
      final r = b.requests.first;
      r.method = 'PUT';
      r.url = 'https://x/b';
      r.headers
        ..removeAt(0)
        ..add(KV(key: 'C', value: '3'));
      r.body = '{\n  "a": 1,\n  "b": 3\n}';
      final d = diffCollections(a, b);
      expect(d.added, isEmpty);
      expect(d.removed, isEmpty);
      final changes = {for (final c in d.changed.single.changes) c.field: c};
      expect(changes.keys, containsAll(['Method', 'URL', 'Headers', 'Body']));
      expect(changes['Method']!.before, ['POST']);
      expect(changes['Method']!.after, ['PUT']);
      expect(changes['Method']!.isInline, isTrue);
      final headers = changes['Headers']!.lines;
      expect(headers.map((l) => '${l.added ? '+' : '-'}${l.text}').toList(), [
        '-A: 1',
        '+C: 3',
      ]);
      final body = changes['Body']!.lines;
      expect(
        body.map((l) => '${l.added ? '+' : '-'}${l.text.trim()}').toList(),
        ['-"b": 2', '+"b": 3'],
      );
      expect(changes['Body']!.isInline, isFalse);
      expect(d.summary, '1 request changed');
    });

    test('never shows secrets, but shows that one changed', () {
      final a = col()
        ..auth = AuthConfig(type: AuthType.bearer, bearerToken: 'old-token-123')
        ..variables.add(KV(key: 'key', value: 'hush-hush-1', secret: true));
      final b = CollectionModel.fromJson(a.toJson())
        ..auth.bearerToken = 'new-token-456';
      b.variables.first.value = 'hush-hush-2';
      final d = diffCollections(a, b);
      final text = [
        for (final c in d.collection) ...[...c.before, ...c.after],
      ].join('\n');
      expect(text, isNot(contains('token-123')));
      expect(text, isNot(contains('token-456')));
      expect(text, isNot(contains('hush')));
      expect(text, contains('Bearer token: $diffMask (updated)'));
      expect(
        d.collection.map((c) => c.field),
        containsAll(['Auth', 'Variables']),
      );
    });

    test('folder settings, request order and moved requests show up', () {
      final a = col(
        requests: [
          RequestModel(id: 'r1', name: 'A'),
          RequestModel(id: 'r2', name: 'B'),
        ],
      )..folders['F'] = FolderMeta(description: 'old');
      final b = CollectionModel.fromJson(a.toJson());
      b.folders['F'] = FolderMeta(description: 'new');
      b.requests
        ..clear()
        ..addAll([
          a.requests[1].clone(sameId: true),
          a.requests[0].clone(sameId: true),
        ]);
      b.requests.first.folder = 'F';
      final d = diffCollections(a, b);
      expect(
        d.collection.map((c) => c.field),
        contains('Folder F: description'),
      );
      expect(d.collection.map((c) => c.field), contains('Request order'));
      expect(d.changed.single.changes.single.field, 'Folder');
    });

    test('line diff handles replaced, inserted and large inputs', () {
      String show(List<DiffLine> l) =>
          l.map((x) => '${x.added ? '+' : '-'}${x.text}').join(' ');
      expect(show(diffLines(['a', 'b', 'c'], ['a', 'x', 'c'])), '-b +x');
      expect(show(diffLines([], ['a'])), '+a');
      expect(show(diffLines(['a', 'b'], ['a'])), '-b');
      expect(
        show(diffLines(['a', 'b', 'c', 'd'], ['b', 'c', 'e'])),
        '-a -d +e',
      );
      final big = [for (var i = 0; i < 3000; i++) 'l$i'];
      final other = [for (var i = 0; i < 3000; i++) 'm$i'];
      final d = diffLines(big, other);
      expect(d, hasLength(6000)); // too large to align: replaced wholesale
      expect(diffLines(big, big), isEmpty);
    });
  });

  group('restore', () {
    late AppState state;

    setUp(() async {
      state = AppState(storage: storage);
      while (!state.loaded) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      state.collectionHistory.clock = () => now;
    });

    test(
      'snapshots the current state first, then swaps the collection in',
      () async {
        final other1 = state.addCollection('First');
        final c = state.addCollection('Main');
        final other2 = state.addCollection('Last');
        c.requests.addAll([
          RequestModel(id: 'a', name: 'Alpha'),
          RequestModel(id: 'b', name: 'Beta'),
        ]);
        state.updateCollections();
        await state.collectionHistory.flush(); // the throttle held this back
        final original = (await state.collectionHistory.snapshots(c.id)).first;

        now = now.add(const Duration(seconds: 90));
        c.requests.removeWhere((r) => r.id == 'a');
        c.requests.first.url = 'https://changed';
        c.name = 'Main v2';
        state.updateCollections();
        await state.collectionHistory.idle();

        final restored = await restoreSnapshot(state, c.id, original);
        expect(restored.name, 'Main');
        expect(restored.requests.map((r) => r.name), ['Alpha', 'Beta']);
        // Same place in the sidebar, and exactly one collection with that id.
        expect(state.collections.map((x) => x.id), [
          other1.id,
          c.id,
          other2.id,
        ]);
        expect(identical(state.collectionById(c.id), restored), isTrue);

        // The state before the restore is in the list.
        final list = await (() async {
          await state.collectionHistory.flush();
          return state.collectionHistory.snapshots(c.id);
        })();
        final names = list.map((s) => s.toCollection().name).toList();
        expect(names.first, 'Main'); // the restored state, newest
        expect(names, contains('Main v2')); // the pre-restore snapshot
        expect(list.length, greaterThanOrEqualTo(3));

        // And it was saved.
        await storage.flush();
        final loaded = await Storage(overrideDir: tmp).loadCollections();
        expect(loaded.map((x) => x.name), ['First', 'Main', 'Last']);
        expect(loaded[1].requests.map((r) => r.name), ['Alpha', 'Beta']);
      },
    );

    test('describeSnapshotTime reads naturally', () {
      final n = DateTime(2026, 10, 31, 15, 0);
      expect(
        describeSnapshotTime(DateTime(2026, 10, 31, 9, 5), now: n),
        'Today, 09:05',
      );
      expect(
        describeSnapshotTime(DateTime(2026, 10, 30, 23, 59), now: n),
        'Yesterday, 23:59',
      );
      expect(
        describeSnapshotTime(DateTime(2026, 10, 2, 8, 0), now: n),
        'Oct 2, 08:00',
      );
      expect(
        describeSnapshotTime(DateTime(2025, 12, 25, 8, 0), now: n),
        'Dec 25 2025, 08:00',
      );
    });
  });

  group('dialog', () {
    final h = StateHarness();
    late CollectionModel c;
    var t = DateTime(2026, 10, 31, 12);

    /// Three snapshots (empty, two requests, one removed and one changed) and
    /// an edit that is still waiting for the throttle.
    Future<void> start(WidgetTester tester) async {
      await h.setUp(tester);
      await tester.runAsync(() async {
        final state = h.state;
        final history = state.collectionHistory..clock = () => t;
        c = state.addCollection('Shop');
        await history.flush();
        t = t.add(const Duration(minutes: 2));
        c.requests.addAll([
          RequestModel(id: 'a', name: 'Alpha', url: 'https://x/a'),
          RequestModel(id: 'b', name: 'Beta', url: 'https://x/b'),
        ]);
        state.updateCollections();
        await history.flush();
        t = t.add(const Duration(minutes: 2));
        c.requests.removeWhere((r) => r.id == 'b');
        c.requests.first.url = 'https://x/changed';
        state.updateCollections();
        await history.flush();
        // Not snapshotted yet: inside the throttle.
        t = t.add(const Duration(seconds: 5));
        c.name = 'Shop v2';
        state.updateCollections();
        await history.idle();
      });
    }

    /// The list loads through file I/O: turns the real event loop until the
    /// spinner is gone.
    Future<void> loaded(WidgetTester tester) async {
      await tester.pump();
      for (var i = 0; i < 200; i++) {
        if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
    }

    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(
        opener(buildTheme(), (ctx) => showVersionHistory(ctx, h.state, c)),
      );
      await tester.tap(find.text('open'));
      await loaded(tester);
    }

    double top(WidgetTester tester, String text) =>
        tester.getTopLeft(find.text(text)).dy;

    testWidgets('lists snapshots newest first with what changed', (
      tester,
    ) async {
      await start(tester);
      await open(tester);

      expect(find.text('Shop v2 history'), findsOneWidget);
      // The waiting edit was written when the dialog opened.
      const newest = 'collection: name';
      const middle = '1 request removed, 1 request changed';
      const first = '2 requests added';
      for (final s in [
        newest,
        middle,
        first,
        'Initial snapshot (0 requests)',
      ]) {
        expect(find.text(s), findsOneWidget, reason: s);
      }
      expect(top(tester, newest), lessThan(top(tester, middle)));
      expect(top(tester, middle), lessThan(top(tester, first)));
      expect(
        top(tester, first),
        lessThan(top(tester, 'Initial snapshot (0 requests)')),
      );
      // Only the newest matches the collection as it is.
      expect(find.text('current'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await h.tearDown(tester);
    });

    testWidgets('shows a collection with no snapshots', (tester) async {
      await h.setUp(tester);
      c = CollectionModel(name: 'Never saved');
      await open(tester);
      expect(find.textContaining('No snapshots yet'), findsOneWidget);
      await h.tearDown(tester);
    });

    testWidgets('a snapshot shows what changed since, field by field', (
      tester,
    ) async {
      await start(tester);
      await open(tester);

      // The snapshot with two requests.
      await tester.tap(find.text('2 requests added'));
      await tester.pumpAndSettle();
      expect(find.text('Changes since', skipOffstage: false), findsNothing);
      expect(find.textContaining('Changes since'), findsOneWidget);
      expect(find.text('COLLECTION'), findsOneWidget);
      expect(find.text('Name'), findsOneWidget); // collection renamed since
      expect(find.textContaining('Shop  →  Shop v2'), findsOneWidget);
      expect(find.text('REMOVED SINCE (1)'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('CHANGED SINCE (1)'), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('url'), findsOneWidget);

      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      expect(find.text('URL'), findsOneWidget);
      expect(find.textContaining('https://x/a'), findsOneWidget);
      expect(find.textContaining('https://x/changed'), findsOneWidget);

      await tester.tap(find.text('All snapshots'));
      await tester.pumpAndSettle();
      expect(find.text('Initial snapshot (0 requests)'), findsOneWidget);
      await h.tearDown(tester);
    });

    testWidgets('the newest snapshot has nothing to restore from', (
      tester,
    ) async {
      await start(tester);
      await open(tester);
      await tester.tap(find.text('collection: name'));
      await tester.pumpAndSettle();
      expect(
        find.text('The collection is the same as this snapshot.'),
        findsOneWidget,
      );
      await h.tearDown(tester);
    });

    testWidgets('restore snapshots the current state first, then swaps', (
      tester,
    ) async {
      await start(tester);
      await open(tester);
      final before = h.state.collections.indexWhere((x) => x.id == c.id);

      await tester.tap(find.text('2 requests added'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore this version'));
      await tester.pumpAndSettle();
      expect(find.text('Restore this version?'), findsOneWidget);
      await tester.tap(find.text('Restore'));
      await tester.pump();
      await h.drain(tester);
      await loaded(tester);

      final restored = h.state.collectionById(c.id)!;
      expect(restored.name, 'Shop');
      expect(restored.requests.map((r) => r.name), ['Alpha', 'Beta']);
      expect(restored.requests.first.url, 'https://x/a');
      expect(h.state.collections.indexOf(restored), before);
      expect(find.textContaining('Restored the version from'), findsOneWidget);

      // Back on the list: the edit that was waiting got its own snapshot
      // before the swap, and the restored state is the newest.
      final names = await tester.runAsync(() async {
        await h.state.collectionHistory.flush();
        final list = await h.state.collectionHistory.snapshots(c.id);
        return [for (final s in list) s.toCollection().name];
      });
      expect(names!.first, 'Shop');
      expect(names, contains('Shop v2'));
      // The restored snapshot and the older one it was restored from.
      expect(find.text('current'), findsNWidgets(2));
      await h.tearDown(tester);
    });

    testWidgets('fits a 320 px phone', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await start(tester);
      await open(tester);

      expect(find.byType(Dialog), findsOneWidget);
      await tester.tap(find.text('2 requests added'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      expect(find.text('URL'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await h.tearDown(tester);
    });
  });
}
