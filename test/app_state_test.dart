import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:api_workbench/state/app_state.dart';

void main() {
  late Directory tmp;
  final storages = <Storage>[];

  Future<AppState> loadedState(Directory dir) async {
    final storage = Storage(overrideDir: dir);
    storages.add(storage);
    final state = AppState(storage: storage);
    while (!state.loaded) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return state;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('restflow_state');
  });

  tearDown(() async {
    for (final s in storages) {
      await s.flush();
    }
    storages.clear();
    await tmp.delete(recursive: true);
  });

  test(
    'fresh start: add environment works (regression: unmodifiable list)',
    () async {
      final state = await loadedState(tmp);
      final env = state.addEnvironment('Dev');
      env.variables.add(KV(key: 'base', value: 'https://x'));
      state.updateEnvironment();
      expect(state.environments.single.name, 'Dev');
      expect(state.activeEnvironmentId, env.id);
      expect(state.activeVars['base'], 'https://x');
    },
  );

  test('collections: save active tab, reopen focuses existing tab', () async {
    final state = await loadedState(tmp);
    state.activeTab!.request
      ..name = 'Get users'
      ..url = 'https://x/users';
    final col = state.addCollection('API');
    state.saveActiveTo(col);
    expect(col.requests.single.name, 'Get users');
    expect(state.activeTab!.dirty, isFalse);

    // Opening the saved request again must not create a duplicate tab.
    final tabCount = state.tabs.length;
    state.openRequest(col.requests.single, collectionId: col.id);
    expect(state.tabs.length, tabCount);
  });

  test('tabs: closing the last tab leaves one fresh tab', () async {
    final state = await loadedState(tmp);
    expect(state.tabs.length, 1);
    state.closeTab(0);
    expect(state.tabs.length, 1);
    expect(state.activeTab!.request.url, isEmpty);
  });

  test('state persists across instances', () async {
    final s1 = await loadedState(tmp);
    s1.addCollection('Persisted');
    final env = s1.addEnvironment('Prod');
    s1.setActiveEnvironment(env.id);
    await storages.first.flush();

    final s2 = await loadedState(tmp);
    expect(s2.collections.single.name, 'Persisted');
    expect(s2.activeEnvironment?.name, 'Prod');
  });

  test('import into an existing collection keeps folders and values', () async {
    final state = await loadedState(tmp);
    final target = state.addCollection('Shop')
      ..requests.add(RequestModel(name: 'Existing', folder: 'Orders'))
      ..variables.add(KV(key: 'baseUrl', value: 'https://mine.test'));
    final imported = CollectionModel(
      name: 'Billing API',
      requests: [
        RequestModel(name: 'Invoice', folder: 'Invoices'),
        RequestModel(name: 'Ping'),
      ],
      variables: [
        KV(key: 'baseUrl', value: 'https://theirs.test'),
        KV(key: 'apiKey', value: 'k'),
      ],
    );

    final added = state.addToCollection(target, [imported], folder: 'Orders');
    expect(added, (requests: 2, variables: 1));
    expect(target.requests.map((r) => '${r.folder}|${r.name}'), [
      'Orders|Existing',
      'Orders/Invoices|Invoice',
      'Orders|Ping',
    ]);
    expect(target.variableMap, {
      'baseUrl': 'https://mine.test', // existing value kept
      'apiKey': 'k',
    });

    final grouped = CollectionModel(
      name: 'A/B',
      requests: [RequestModel(name: 'G')],
    );
    state.addToCollection(target, [grouped], groupByCollection: true);
    expect(target.requests.last.folder, 'A∕B');

    await storages.first.flush();
    final reloaded = await loadedState(tmp);
    expect(reloaded.collections.single.requests.length, 4);
    expect(reloaded.collections.single.variables.length, 2);
  });
}
