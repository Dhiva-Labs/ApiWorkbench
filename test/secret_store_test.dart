import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/file_mode.dart';
import 'package:api_workbench/services/secret_store.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:api_workbench/services/version_history.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/theme.dart';
import 'package:api_workbench/ui/app_menu.dart';
import 'package:api_workbench/ui/settings/secret_storage_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_keychain.dart';
import 'support/secret_fixtures.dart';
import 'support/state_harness.dart';
import 'support/temp_dir.dart';

void main() {
  late Directory tmp;
  late Directory data;
  late FakeKeychain keychain;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('aw_secrets');
    data = Directory('${tmp.path}/apiworkbench');
    keychain = FakeKeychain();
  });

  tearDown(() => deleteTempDir(tmp));

  Storage storage({
    FakeKeychain? with_,
    bool noKeychain = false,
    Duration timeout = const Duration(seconds: 10),
  }) => Storage(
    overrideDir: tmp,
    keychain: noKeychain ? null : (with_ ?? keychain),
    keychainTimeout: timeout,
  );

  /// Every fixture secret that appears in a file of the data folder.
  List<String> leakedOnDisk() {
    final found = <String>{};
    for (final f in data.listSync().whereType<File>()) {
      if (f.path.endsWith('secrets.json')) continue;
      final text = f.readAsStringSync();
      for (final s in fixtureSecrets) {
        if (text.contains(s)) found.add('$s in ${f.uri.pathSegments.last}');
      }
    }
    return found.toList();
  }

  Future<void> saveAll(Storage s) async {
    await s.saveCollections([secretCollection()]);
    await s.saveEnvironments([secretEnvironment()], 'env-1');
    await s.saveGlobals(secretGlobals());
    await s.saveSettings(secretSettings());
    await s.flush();
  }

  Future<void> expectAllBack(Storage s) async {
    final cols = await s.loadCollections();
    expect(
      jsonEncode(cols.map((c) => c.toJson()).toList()),
      jsonEncode([secretCollection().toJson()]),
    );
    final (envs, active) = await s.loadEnvironments();
    expect(jsonEncode(envs.single.toJson()), jsonEncode(secretEnvironment()));
    expect(active, 'env-1');
    expect(
      jsonEncode(await s.loadGlobals()),
      jsonEncode(secretGlobals().map((g) => g.toJson()).toList()),
    );
    final settings = await s.loadSettings();
    expect(settings.network.proxyPassword, 'proxy-pass-0014');
    expect(settings.network.clientCerts.single.passphrase, 'cert-pass-0015');
  }

  /// Writes the documents the way 1.4.0 did: every secret in plain JSON.
  void writeLegacyFiles() {
    data.createSync(recursive: true);
    void put(String name, Object json) =>
        File('${data.path}/$name').writeAsStringSync(jsonEncode(json));
    put('collections.json', [secretCollection().toJson()]);
    put('environments.json', {
      'environments': [secretEnvironment().toJson()],
      'activeId': 'env-1',
    });
    put('globals.json', [for (final g in secretGlobals()) g.toJson()]);
    put('settings.json', secretSettings().toJson());
    put('history.json', [
      HistoryEntry(
        request: secretCollection().requests.first..examples = [],
        statusCode: 200,
        durationMs: 12,
        at: DateTime(2026, 11, 1),
      ).toJson(),
    ]);
    final snapJson = jsonEncode(secretCollection().toJson());
    put(CollectionHistory.fileName('col-1'), {
      'v': 1,
      'snapshots': [
        {
          't': 1,
          'h': 'legacy',
          's': 'Initial snapshot (2 requests)',
          'c': snapJson,
        },
      ],
    });
    put(CollectionHistory.indexFile, {'col-1': 'legacy'});
  }

  group('with a keychain', () {
    test('saved files hold no secrets; the keychain holds them', () async {
      await saveAll(storage());
      expect(leakedOnDisk(), isEmpty);
      expect(keychain.items.keys, {
        'apiworkbench.secrets.collections',
        'apiworkbench.secrets.environments',
        'apiworkbench.secrets.globals',
        'apiworkbench.secrets.settings',
      });
      expect(File('${data.path}/secrets.json').existsSync(), isTrue);
      final marker = jsonDecode(
        File('${data.path}/secrets.json').readAsStringSync(),
      );
      expect(marker['entries'], isEmpty);
      expect(marker['keychain'], isTrue);

      final again = storage();
      await expectAllBack(again);
      expect(again.secrets.status.mode, SecretStorageMode.keychain);
    });

    test('one keychain item per document, however many requests', () async {
      final c = CollectionModel(
        name: 'Many',
        requests: [
          for (var i = 0; i < 200; i++)
            RequestModel(bearerToken: 'token-$i', basicPassword: 'pw-$i'),
        ],
      );
      final s = storage();
      await s.saveCollections([c]);
      await s.flush();
      expect(keychain.items, hasLength(1));
      final back = await storage().loadCollections();
      expect(back.single.requests[150].bearerToken, 'token-150');
    });

    test('an unchanged save makes no keychain call', () async {
      final s = storage();
      await s.saveCollections([secretCollection()]);
      final writes = keychain.writes;
      for (var i = 0; i < 5; i++) {
        await s.saveCollections([secretCollection()..name = 'Renamed $i']);
      }
      await s.flush();
      expect(keychain.writes, writes);
    });
  });

  group('migration from 1.4', () {
    test(
      'moves plaintext secrets into the keychain, then strips the files',
      () async {
        writeLegacyFiles();
        final s = storage();
        await expectAllBack(s);
        final history = await s.loadHistory();
        await s.flush();

        expect(leakedOnDisk(), isEmpty);
        expect(keychain.items, hasLength(4));
        expect(history.single.request.url, 'https://api.example.com/orders');
        expect(history.single.request.auth.params['accessToken'], '');

        // A second start finds nothing left to move.
        final writes = keychain.writes;
        final again = storage();
        await expectAllBack(again);
        await again.loadHistory();
        await again.flush();
        expect(keychain.writes, writes);
        expect(leakedOnDisk(), isEmpty);
      },
    );

    test('scrubs collection version history and rehashes it', () async {
      writeLegacyFiles();
      final s = storage();
      await s.open();
      await s.flush();
      final file = jsonDecode(
        File(
          '${data.path}/${CollectionHistory.fileName('col-1')}',
        ).readAsStringSync(),
      );
      expect(file['v'], CollectionHistory.formatVersion);
      final snap = HistorySnapshot.fromJson(file['snapshots'][0])!;
      expect(fixtureSecrets.where(snap.json.contains), isEmpty);
      // The hash is that of the collection as it is: an unchanged
      // collection takes no new snapshot.
      expect(snap.hash, CollectionHistory.hashOf(secretCollection()));
      final index = jsonDecode(
        File('${data.path}/${CollectionHistory.indexFile}').readAsStringSync(),
      );
      expect(index['col-1'], snap.hash);
    });

    test(
      'a keychain write failure moves the secrets to the file instead',
      () async {
        writeLegacyFiles();
        keychain.failWrites = true;
        final s = storage();
        await expectAllBack(s);
        await s.loadHistory();
        await s.flush();
        expect(s.secrets.status.mode, SecretStorageMode.file);
        expect(leakedOnDisk(), isEmpty);
        final file = File('${data.path}/secrets.json').readAsStringSync();
        expect(file, contains('col-bearer-0001'));
        expect(keychain.items, isEmpty);
      },
    );

    test(
      'when the secrets fit nowhere the old files stay as they were',
      () async {
        writeLegacyFiles();
        keychain.failWrites = true;
        // The fallback file cannot be written either.
        Directory('${data.path}/secrets.json').createSync();
        final s = storage();
        await expectAllBack(s);
        await s.flush();
        final cols = File('${data.path}/collections.json').readAsStringSync();
        expect(cols, contains('col-bearer-0001'));
        expect(cols, contains('oauth-refresh-0004'));
        // Saving later keeps them too rather than dropping them.
        await s.saveCollections([secretCollection()]);
        await s.flush();
        expect(
          File('${data.path}/collections.json').readAsStringSync(),
          contains('col-bearer-0001'),
        );
      },
    );
  });

  group('without a keychain', () {
    test('secrets go to an owner-only file and come back', () async {
      keychain.failReads = true;
      final s = storage();
      await s.open();
      expect(s.secrets.status.mode, SecretStorageMode.file);
      expect(s.secrets.status.reason, 'The keychain is locked.');
      await saveAll(s);
      expect(leakedOnDisk(), isEmpty);
      final file = File('${data.path}/secrets.json');
      expect(file.readAsStringSync(), contains('proxy-pass-0014'));
      if (FileMode.supported) {
        expect(FileMode.of(file.path), FileMode.privateFile);
      }
      await expectAllBack(storage());
    });

    test('a keychain that does not answer does not hold up loading', () async {
      keychain.hold = Completer<void>();
      final s = storage(timeout: const Duration(milliseconds: 100));
      final watch = Stopwatch()..start();
      await s.loadCollections();
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(s.secrets.status.mode, SecretStorageMode.file);
      expect(s.secrets.status.reason, contains('did not answer'));
      keychain.hold!.complete();
    });

    test('switching between modes never loses a secret', () async {
      // 1. The keychain works: the collection token goes there.
      final first = storage();
      await first.saveCollections([secretCollection()]);
      await first.flush();

      // 2. Next start, the keychain is unreachable. The token cannot be
      // read; a new environment secret is saved meanwhile.
      keychain.failReads = true;
      keychain.failWrites = true;
      final second = storage();
      final cols = await second.loadCollections();
      expect(cols.single.auth.bearerToken, '');
      expect(second.secrets.status.keychainHoldsOlderSecrets, isTrue);
      await second.saveCollections(cols);
      await second.saveEnvironments([secretEnvironment()], 'env-1');
      await second.flush();
      expect(keychain.items.keys, ['apiworkbench.secrets.collections']);

      // 3. The keychain is back: both are there, and the file is emptied.
      keychain.failReads = false;
      keychain.failWrites = false;
      final third = storage();
      final back = await third.loadCollections();
      final (envs, _) = await third.loadEnvironments();
      await third.flush();
      expect(back.single.auth.bearerToken, 'col-bearer-0001');
      expect(envs.single.variables.last.current, 'env-current-0012');
      expect(third.secrets.status.mode, SecretStorageMode.keychain);
      expect(keychain.items, hasLength(2));
      final file = jsonDecode(
        File('${data.path}/secrets.json').readAsStringSync(),
      );
      expect(file['entries'], isEmpty);
    });

    test('tests and other override folders never use a keychain', () async {
      final s = storage(noKeychain: true);
      await saveAll(s);
      expect(s.secrets.status.mode, SecretStorageMode.file);
      expect(leakedOnDisk(), isEmpty);
      await expectAllBack(storage(noKeychain: true));
    });
  });

  group('collection version history', () {
    test(
      'snapshots keep no secrets; a restore keeps the current ones',
      () async {
        final s = storage();
        final history = CollectionHistory(s)
          ..clock = () => DateTime(2026, 11, 3);
        final c = secretCollection();
        history.record([c]);
        await history.idle();
        final snaps = await history.snapshots('col-1');
        expect(fixtureSecrets.where(snaps.single.json.contains), isEmpty);

        // A refreshed token is no new state.
        c.requests.first.auth.params['accessToken'] = 'refreshed-token';
        final again = await history.snapshotNow(c);
        expect(again!.hash, snaps.single.hash);

        final restored = snaps.single.toCollection(secretsFrom: c);
        expect(
          restored.requests.first.auth.params['accessToken'],
          'refreshed-token',
        );
        expect(restored.auth.bearerToken, 'col-bearer-0001');
        await s.flush();
        expect(leakedOnDisk(), isEmpty);
      },
    );
  });

  group('file permissions', () {
    test(
      'the data folder is 0700 and every file 0600, old ones included',
      () async {
        data.createSync(recursive: true);
        final old = File('${data.path}/cookies.json')..writeAsStringSync('[]');
        Process.runSync('chmod', ['0664', old.path]);
        Process.runSync('chmod', ['0755', data.path]);
        final s = storage();
        await saveAll(s);
        await s.saveHistory([]);
        await s.flush();
        expect(FileMode.of(data.path), FileMode.privateDir);
        for (final f in data.listSync().whereType<File>()) {
          expect(FileMode.of(f.path), FileMode.privateFile, reason: f.path);
        }
      },
      skip: Platform.isWindows ? 'no POSIX modes on Windows' : false,
    );
  });

  group('request history', () {
    test('saved entries keep no credentials; memory keeps them', () async {
      final s = storage();
      await s.saveEnvironments([secretEnvironment()], 'env-1');
      final request = secretCollection().requests.first..examples = [];
      request.url = 'https://api.example.com/orders?token=env-current-0012';
      final entries = [
        HistoryEntry(
          request: request,
          statusCode: 200,
          durationMs: 5,
          at: DateTime(2026, 11, 2),
        ),
      ];
      await s.saveHistory(entries);
      await s.flush();
      final text = File('${data.path}/history.json').readAsStringSync();
      expect(fixtureSecrets.where(text.contains), isEmpty);
      expect(text, contains('keep-me-header'));
      expect(
        entries.single.request.auth.params['accessToken'],
        'oauth-access-0003',
      );
      final back = await storage().loadHistory();
      expect(back.single.request.url, 'https://api.example.com/orders?token=');
    });
  });

  group('app state and settings', () {
    testWidgets('AppState reports where secrets are kept', (tester) async {
      late AppState state;
      await tester.runAsync(() async {
        state = AppState(storage: storage());
        while (!state.loaded) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      expect(state.secretStorage.mode, SecretStorageMode.keychain);
      await tester.runAsync(() async {
        await state.flushPending();
      });
      state.dispose();
    });

    for (final width in [390.0, 1280.0]) {
      testWidgets('Settings shows the notice at ${width.toInt()} px', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final h = StateHarness();
        await h.setUp(tester); // a test data folder: the fallback file
        await tester.pumpWidget(
          ChangeNotifierProvider<AppState>.value(
            value: h.state,
            child: MaterialApp(
              theme: buildTheme(),
              home: Builder(
                builder: (c) => Scaffold(
                  body: TextButton(
                    onPressed: () => showSettingsDialog(c),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        final notice = find.textContaining(
          'Secrets are stored in a local file',
        );
        await tester.scrollUntilVisible(
          notice,
          200,
          scrollable: find.byType(Scrollable).last,
        );
        expect(notice, findsOneWidget);
        expect(tester.takeException(), isNull);
        await h.tearDown(tester);
      });
    }

    testWidgets('the notice names the snap connect command', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SecretStorageNotice(
              status: SecretStorageStatus(
                mode: SecretStorageMode.file,
                reason: 'No Secret Service could be reached.',
                snapName: 'apiworkbench',
                keychainHoldsOlderSecrets: true,
              ),
            ),
          ),
        ),
      );
      expect(
        find.textContaining(
          'Secrets are stored in a local file because no '
          'system keychain is available.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('sudo snap connect apiworkbench:password-manager-service'),
        findsOneWidget,
      );
      expect(find.textContaining('still in the keychain'), findsOneWidget);
    });

    testWidgets('the keychain notice is one quiet line', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SecretStorageNotice(
              status: SecretStorageStatus(mode: SecretStorageMode.keychain),
            ),
          ),
        ),
      );
      expect(find.textContaining('not in the workspace files'), findsOneWidget);
      expect(find.textContaining('snap connect'), findsNothing);
    });
  });
}
