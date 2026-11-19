import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import 'json_store.dart';
import 'keychain_backend.dart';
import 'secret_fields.dart';
import 'secret_store.dart';
import 'version_history.dart';

/// Persists collections, environments and history as JSON files inside the
/// platform's application-support directory. Works on all six platforms.
///
/// Credentials never reach those files (issue #61): they are taken out of
/// every document before it is written and kept by [secrets], in the system
/// keychain or, without one, in a fallback file.
class Storage implements JsonStore {
  /// [overrideDir] puts the data folder elsewhere (tests). Unless a
  /// [keychain] is given as well, its secrets stay in the fallback file, so
  /// tests never reach the real keychain.
  Storage({
    Directory? overrideDir,
    SecretBackend? keychain,
    this.keychainTimeout,
  }) : _override = overrideDir,
       _keychain = keychain ?? (overrideDir == null ? KeychainBackend() : null);

  final Directory? _override; // used by tests to avoid platform channels
  final SecretBackend? _keychain;

  /// Upper bound for each keychain call, for tests; null keeps
  /// [SecretStore]'s defaults.
  final Duration? keychainTimeout;

  /// Where the secrets of every document are kept.
  late final SecretStore secrets = SecretStore(
    this,
    _keychain,
    timeout: keychainTimeout ?? const Duration(seconds: 15),
    openTimeout: keychainTimeout,
    unavailableReason: _keychain == null
        ? 'This data folder keeps its secrets in a file.'
        : null,
  );

  // The folder itself is kept, not a pending future: widget tests start
  // AppState in a fake-async zone, where such a future may never complete
  // for a caller in the real zone.
  Directory? _dir;

  Future<Directory> _base() async {
    if (_dir != null) return _dir!;
    final d = _override ?? await getApplicationSupportDirectory();
    final dir = await Directory(
      '${d.path}/apiworkbench',
    ).create(recursive: true);
    return _dir ??= dir;
  }

  Future<File> _file(String name) async =>
      File('${(await _base()).path}/$name');

  Future<void>? _opening;

  /// Prepares the data folder and the secret store, and moves secrets out
  /// of files written before they had one. Loading calls it; it never
  /// throws.
  Future<void> open() => _opening ??= () async {
    try {
      final dir = await _base();
      await secrets.open();
      await _scrubVersionHistory(dir);
    } catch (_) {
      // A data folder that cannot be prepared reads as empty, as before.
    }
  }();

  @override
  Future<dynamic> readJson(String name) async {
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

  @override
  Future<void> writeJson(String name, Object data) {
    final payload = jsonEncode(data); // snapshot now, write later
    return _enqueue(name, () => _writeText(name, payload));
  }

  Future<void> _enqueue(String name, Future<void> Function() job) {
    final prev = _writeQueue[name] ?? Future.value();
    final next = prev.then((_) => job());
    // Keep the chain alive even if one write fails.
    _writeQueue[name] = next.catchError((_) {});
    return next;
  }

  /// Replaces [name] atomically.
  Future<void> _writeText(String name, String payload) async {
    final f = await _file(name);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(payload, flush: true);
    await tmp.rename(f.path);
  }

  /// Waits for all queued writes to land (used by tests and shutdown paths).
  Future<void> flush() => Future.wait(_writeQueue.values.toList());

  /// Saves [json] as [name] without its secrets, which go to [secrets]
  /// first. Should the secrets fit nowhere, the document is written with
  /// them, as older versions did, rather than lose them.
  Future<void> _saveDoc(String name, SecretDoc doc, Object json) {
    final copy = deepCopyJson(json)!;
    final found = doc.extract(copy);
    final stripped = jsonEncode(copy); // snapshot now, write later
    return _enqueue(name, () async {
      if (await secrets.put(doc.entry, found)) {
        return _writeText(name, stripped);
      }
      final full = jsonDecode(stripped);
      doc.fill(full, found);
      return _writeText(name, jsonEncode(full));
    });
  }

  /// Reads [name] with its secrets put back. `found` is true when the file
  /// still held secrets of its own.
  Future<(Object?, bool)> _loadDoc(String name, SecretDoc doc) async {
    await open();
    final raw = await readJson(name);
    if (raw == null) return (null, false);
    return (raw as Object, doc.fill(raw, secrets.entry(doc.entry)));
  }

  /// After [_loadDoc]: moves secrets still in the file into the store, and
  /// drops stored ones the document no longer has. The file is rewritten
  /// only once the store has the secrets.
  Future<void> _settle(String name, SecretDoc doc, Object json, bool found) {
    if (!found) {
      final now = doc.extract(deepCopyJson(json));
      final stored = secrets.entry(doc.entry);
      if (now.length == stored.length &&
          now.entries.every((e) => stored[e.key] == e.value)) {
        return Future.value();
      }
    }
    return _saveDoc(name, doc, json);
  }

  Future<List<CollectionModel>> loadCollections() async {
    const name = 'collections.json';
    final (j, found) = await _loadDoc(name, SecretDoc.collections);
    if (j is! List) return [];
    final cols = j
        .map((e) => CollectionModel.fromJson(e as Map<String, dynamic>))
        .toList();
    await _settle(name, SecretDoc.collections, j, found);
    return cols;
  }

  Future<void> saveCollections(List<CollectionModel> c) => _saveDoc(
    'collections.json',
    SecretDoc.collections,
    c.map((e) => e.toJson()).toList(),
  );

  Future<(List<EnvironmentModel>, String?)> loadEnvironments() async {
    const name = 'environments.json';
    final (j, found) = await _loadDoc(name, SecretDoc.environments);
    // NB: must be growable — AppState adds environments to this list.
    if (j is! Map<String, dynamic>) return (<EnvironmentModel>[], null);
    final envs = (j['environments'] as List<dynamic>? ?? [])
        .map((e) => EnvironmentModel.fromJson(e as Map<String, dynamic>))
        .toList();
    await _settle(name, SecretDoc.environments, j, found);
    return (envs, j['activeId'] as String?);
  }

  Future<void> saveEnvironments(
    List<EnvironmentModel> envs,
    String? activeId,
  ) => _saveDoc('environments.json', SecretDoc.environments, {
    'environments': envs.map((e) => e.toJson()).toList(),
    'activeId': activeId,
  });

  /// Request history keeps no credentials: auth secrets, credential headers
  /// and stored secret values are blanked in what is written, and in files
  /// from older versions when they are read. The entries in memory keep
  /// theirs until the app closes.
  Future<List<HistoryEntry>> loadHistory() async {
    await open();
    final j = await readJson('history.json');
    if (j is! List) return [];
    final changed = _scrubHistory(j);
    final entries = j
        .map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>))
        .toList();
    if (changed) await writeJson('history.json', j);
    return entries;
  }

  Future<void> saveHistory(List<HistoryEntry> h) {
    final j = deepCopyJson(h.map((e) => e.toJson()).toList()) as List;
    _scrubHistory(j);
    return writeJson('history.json', j);
  }

  bool _scrubHistory(List<dynamic> entries) {
    final known = secrets.allValues;
    var changed = false;
    for (final e in entries) {
      final r = e is Map ? e['request'] : null;
      if (r is Map<String, dynamic> && scrubHistoryRequest(r, known)) {
        changed = true;
      }
    }
    return changed;
  }

  Future<AppSettings> loadSettings() async {
    const name = 'settings.json';
    final (j, found) = await _loadDoc(name, SecretDoc.settings);
    if (j is! Map<String, dynamic>) return AppSettings();
    final s = AppSettings.fromJson(j);
    await _settle(name, SecretDoc.settings, j, found);
    return s;
  }

  Future<void> saveSettings(AppSettings s) =>
      _saveDoc('settings.json', SecretDoc.settings, s.toJson());

  Future<List<KV>> loadGlobals() async {
    const name = 'globals.json';
    final (j, found) = await _loadDoc(name, SecretDoc.globals);
    if (j is! List) return [];
    final globals = j
        .map((e) => KV.fromJson(e as Map<String, dynamic>))
        .toList();
    await _settle(name, SecretDoc.globals, j, found);
    return globals;
  }

  Future<void> saveGlobals(List<KV> g) => _saveDoc(
    'globals.json',
    SecretDoc.globals,
    g.map((e) => e.toJson()).toList(),
  );

  /// Collection version history files written before snapshots left out
  /// secrets: drops the secrets from every snapshot and rehashes it.
  Future<void> _scrubVersionHistory(Directory dir) async {
    final names = <String>[];
    try {
      for (final e in dir.listSync(followLinks: false)) {
        final n = p.basename(e.path);
        if (e is File &&
            n.startsWith('history-') &&
            n.endsWith('.json') &&
            n != CollectionHistory.indexFile) {
          names.add(n);
        }
      }
    } catch (_) {
      return;
    }
    final newest = <String, String>{}; // file name → newest snapshot hash
    for (final name in names) {
      final raw = await readJson(name);
      if (raw is! Map || raw['v'] == CollectionHistory.formatVersion) continue;
      final list = raw['snapshots'];
      if (list is! List) continue;
      final snaps = [
        for (final s in list)
          if (HistorySnapshot.fromJson(s) case final snap?)
            snap.withoutSecrets(),
      ];
      await writeJson(name, {
        'v': CollectionHistory.formatVersion,
        'snapshots': [for (final s in snaps) s.toJson()],
      });
      if (snaps.isNotEmpty) newest[name] = snaps.last.hash;
    }
    if (newest.isEmpty) return;
    final index = await readJson(CollectionHistory.indexFile);
    if (index is! Map) return;
    final next = <String, dynamic>{
      for (final e in index.entries) '${e.key}': e.value,
    };
    var changed = false;
    for (final id in next.keys.toList()) {
      final h = newest[CollectionHistory.fileName(id)];
      if (h != null && next[id] != h) {
        next[id] = h;
        changed = true;
      }
    }
    if (changed) await writeJson(CollectionHistory.indexFile, next);
  }
}
