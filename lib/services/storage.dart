import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/models.dart';

/// Persists collections, environments and history as JSON files inside the
/// platform's application-support directory. Works on all six platforms.
class Storage {
  Storage({Directory? overrideDir}) : _override = overrideDir;

  final Directory? _override; // used by tests to avoid platform channels
  Directory? _dir;

  Future<Directory> _base() async {
    if (_dir != null) return _dir!;
    final d = _override ?? await getApplicationSupportDirectory();
    _dir = await Directory('${d.path}/apiworkbench').create(recursive: true);
    return _dir!;
  }

  Future<File> _file(String name) async => File('${(await _base()).path}/$name');

  Future<dynamic> _readJson(String name) async {
    try {
      final f = await _file(name);
      if (!await f.exists()) return null;
      return jsonDecode(await f.readAsString());
    } catch (_) {
      return null; // Corrupt file: start fresh rather than crash.
    }
  }

  // Serialize writes per file: saves fire on every keystroke in some editors,
  // and two concurrent atomic writes would race on the shared .tmp path.
  final Map<String, Future<void>> _writeQueue = {};

  Future<void> _writeJson(String name, Object data) {
    final payload = jsonEncode(data); // snapshot now, write later
    final prev = _writeQueue[name] ?? Future.value();
    final next = prev.then((_) async {
      final f = await _file(name);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(payload, flush: true);
      await tmp.rename(f.path);
    });
    // Keep the chain alive even if one write fails.
    _writeQueue[name] = next.catchError((_) {});
    return next;
  }

  /// Waits for all queued writes to land (used by tests and shutdown paths).
  Future<void> flush() => Future.wait(_writeQueue.values.toList());

  Future<List<CollectionModel>> loadCollections() async {
    final j = await _readJson('collections.json') as List<dynamic>?;
    return (j ?? [])
        .map((e) => CollectionModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveCollections(List<CollectionModel> c) =>
      _writeJson('collections.json', c.map((e) => e.toJson()).toList());

  Future<(List<EnvironmentModel>, String?)> loadEnvironments() async {
    final j = await _readJson('environments.json') as Map<String, dynamic>?;
    // NB: must be growable — AppState adds environments to this list.
    if (j == null) return (<EnvironmentModel>[], null);
    final envs = (j['environments'] as List<dynamic>? ?? [])
        .map((e) => EnvironmentModel.fromJson(e as Map<String, dynamic>))
        .toList();
    return (envs, j['activeId'] as String?);
  }

  Future<void> saveEnvironments(
          List<EnvironmentModel> envs, String? activeId) =>
      _writeJson('environments.json', {
        'environments': envs.map((e) => e.toJson()).toList(),
        'activeId': activeId,
      });

  Future<List<HistoryEntry>> loadHistory() async {
    final j = await _readJson('history.json') as List<dynamic>?;
    return (j ?? [])
        .map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveHistory(List<HistoryEntry> h) =>
      _writeJson('history.json', h.map((e) => e.toJson()).toList());

  Future<AppSettings> loadSettings() async {
    final j = await _readJson('settings.json') as Map<String, dynamic>?;
    return j == null ? AppSettings() : AppSettings.fromJson(j);
  }

  Future<void> saveSettings(AppSettings s) =>
      _writeJson('settings.json', s.toJson());
}
