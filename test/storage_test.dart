import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/storage.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('restflow_test');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('collections, environments and history round trip through disk',
      () async {
    final s = Storage(overrideDir: tmp);

    final col = CollectionModel(name: 'API', requests: [
      RequestModel(name: 'Get users', method: 'GET', url: 'https://x/u'),
    ]);
    await s.saveCollections([col]);

    final env = EnvironmentModel(
        name: 'Dev', variables: [KV(key: 'base', value: 'https://x')]);
    await s.saveEnvironments([env], env.id);

    await s.saveHistory([
      HistoryEntry(
          request: RequestModel(url: 'https://x'),
          statusCode: 200,
          durationMs: 42,
          at: DateTime.now()),
    ]);

    // Fresh instance = fresh read from disk.
    final s2 = Storage(overrideDir: tmp);
    final cols = await s2.loadCollections();
    expect(cols.single.name, 'API');
    expect(cols.single.requests.single.name, 'Get users');

    final (envs, activeId) = await s2.loadEnvironments();
    expect(envs.single.variables.single.key, 'base');
    expect(activeId, env.id);

    final hist = await s2.loadHistory();
    expect(hist.single.statusCode, 200);
  });

  test('corrupt file is treated as empty, not a crash', () async {
    await File('${tmp.path}/apiworkbench/collections.json')
        .create(recursive: true)
        .then((f) => f.writeAsString('{not json'));
    final s = Storage(overrideDir: tmp);
    expect(await s.loadCollections(), isEmpty);
  });
}
