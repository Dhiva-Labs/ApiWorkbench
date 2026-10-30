import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/models.dart';
import 'collection_diff.dart';
import 'json_store.dart';

/// A saved copy of one collection at a point in time.
class HistorySnapshot {
  const HistorySnapshot({
    required this.time,
    required this.hash,
    required this.summary,
    required this.json,
  });

  /// When the collection was in this state.
  final DateTime time;

  /// MD5 of [json]; two snapshots with the same hash are the same state.
  final String hash;

  /// What changed since the snapshot before this one, e.g. `2 requests
  /// added, 1 request changed`.
  final String summary;

  /// The collection as JSON text. Kept as text so fifty snapshots stay
  /// cheap in memory and are only parsed when compared or restored.
  final String json;

  /// A fresh copy of the collection as it was.
  CollectionModel toCollection() =>
      CollectionModel.fromJson(jsonDecode(json) as Map<String, dynamic>);

  Map<String, dynamic> toJson() => {
    't': time.millisecondsSinceEpoch,
    'h': hash,
    's': summary,
    'c': json,
  };

  static HistorySnapshot? fromJson(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    final t = j['t'];
    final h = j['h'];
    final c = j['c'];
    if (t is! num || h is! String || c is! String) return null;
    return HistorySnapshot(
      time: DateTime.fromMillisecondsSinceEpoch(t.toInt()),
      hash: h,
      summary: j['s'] as String? ?? '',
      json: c,
    );
  }
}

class _Pending {
  _Pending(this.json, this.hash, this.time);
  final String json;
  final String hash;
  final DateTime time;
}

class _Track {
  /// Hash of the newest state [CollectionHistory.record] has seen, so an
  /// unchanged collection costs one hash and no I/O.
  String? seenHash;

  /// Oldest first. Null until the file is read.
  List<HistorySnapshot>? snaps;

  /// The latest state, waiting for the throttle to allow a snapshot.
  _Pending? pending;

  /// Work on this collection runs in order, one step at a time.
  Future<void> chain = Future.value();
}

/// Local snapshots of collections as they change (issue #35).
///
/// [record] is called after every save. It snapshots a collection only
/// when its JSON really changed, at most once per [minInterval]; a change
/// that arrives sooner waits as the collection's "latest" and is written
/// by the next [record] the throttle allows, or by [flush]. At most
/// [maxSnapshots] are kept per collection, in `history-<id>.json`. Files
/// are read only for collections that changed or that the history dialog
/// opens.
///
/// There is no timer, so a change that is still waiting when the app quits
/// is not written; call [flush] when the app is paused or closing to keep
/// it.
class CollectionHistory {
  CollectionHistory([this._store]);

  final JsonStore? _store;

  /// The time source. Tests replace it.
  DateTime Function() clock = DateTime.now;

  /// The least time between two automatic snapshots of one collection.
  Duration minInterval = const Duration(seconds: 60);

  /// Older snapshots are dropped beyond this many.
  int maxSnapshots = 50;

  static const _indexFile = 'history-index.json';

  final Map<String, _Track> _tracks = {};

  /// Collection id → hash of its newest written snapshot. Lets a restart
  /// tell that a collection is unchanged without reading its file.
  Map<String, String>? _index;
  Future<void>? _indexLoad;

  /// The file holding [collectionId]'s snapshots. Ids are normally UUIDs;
  /// anything else (from an imported file) is made safe for a file name.
  static String fileName(String collectionId) {
    final safe = collectionId.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
    final name = safe == collectionId
        ? safe
        : '$safe-${_hash(collectionId).substring(0, 8)}';
    return 'history-$name.json';
  }

  static String _hash(String s) => md5.convert(utf8.encode(s)).toString();

  /// The hash a snapshot of [c] would have right now; equal to a
  /// [HistorySnapshot.hash] when [c] is in that snapshot's state.
  static String hashOf(CollectionModel c) => _hash(jsonEncode(c.toJson()));

  /// Called after collections are saved; takes throttled snapshots.
  void record(List<CollectionModel> collections) {
    final now = clock();
    for (final c in collections) {
      final json = jsonEncode(c.toJson());
      final hash = _hash(json);
      final t = _tracks.putIfAbsent(c.id, _Track.new);
      if (t.seenHash == hash) {
        // Unchanged, but a change that had to wait may be allowed now.
        if (t.pending != null) {
          _enqueue(t, () => _writeIfAllowed(c.id, t, now));
        }
        continue;
      }
      t.seenHash = hash;
      _enqueue(t, () => _observe(c.id, t, json, hash, now));
    }
  }

  /// Writes every collection's waiting latest state now, whatever the
  /// throttle says, and completes when all writes are done.
  Future<void> flush() async {
    for (final e in _tracks.entries) {
      final t = e.value;
      _enqueue(t, () async {
        if (t.pending != null) await _commit(e.key, t);
      });
    }
    await idle();
  }

  /// Completes when every queued step has finished.
  Future<void> idle() => Future.wait([for (final t in _tracks.values) t.chain]);

  /// The snapshots of [collectionId], newest first.
  Future<List<HistorySnapshot>> snapshots(String collectionId) {
    final t = _tracks.putIfAbsent(collectionId, _Track.new);
    final done = Completer<List<HistorySnapshot>>();
    _enqueue(t, () async {
      try {
        await _ensureLoaded(collectionId, t);
        done.complete(t.snaps!.reversed.toList());
      } catch (_) {
        done.complete(const []);
      }
    });
    return done.future;
  }

  /// Snapshots [c] as it is now, ignoring the throttle. Returns the new
  /// snapshot, or the newest one when [c] has not changed since.
  Future<HistorySnapshot?> snapshotNow(CollectionModel c) {
    final json = jsonEncode(c.toJson());
    final hash = _hash(json);
    final now = clock();
    final t = _tracks.putIfAbsent(c.id, _Track.new);
    t.seenHash = hash;
    final done = Completer<HistorySnapshot?>();
    _enqueue(t, () async {
      try {
        await _ensureLoaded(c.id, t);
        final last = t.snaps!.isEmpty ? null : t.snaps!.last;
        if (last != null && last.hash == hash) {
          t.pending = null;
          done.complete(last);
          return;
        }
        t.pending = _Pending(json, hash, now);
        await _commit(c.id, t);
        done.complete(t.snaps!.last);
      } catch (_) {
        done.complete(null);
      }
    });
    return done.future;
  }

  void _enqueue(_Track t, Future<void> Function() step) {
    // History must never break saving, so a failed step is dropped.
    t.chain = t.chain.then((_) async {
      try {
        await step();
      } catch (_) {}
    });
  }

  Future<void> _loadIndex() => _indexLoad ??= () async {
    final raw = await _store?.readJson(_indexFile);
    _index = {
      if (raw is Map<String, dynamic>)
        for (final e in raw.entries)
          if (e.value is String) e.key: e.value as String,
    };
  }();

  Future<void> _ensureLoaded(String id, _Track t) async {
    if (t.snaps != null) return;
    final raw = await _store?.readJson(fileName(id));
    final list = raw is Map<String, dynamic> ? raw['snapshots'] : null;
    t.snaps = [
      if (list is List<dynamic>)
        for (final e in list) ?HistorySnapshot.fromJson(e),
    ];
  }

  Future<void> _observe(
    String id,
    _Track t,
    String json,
    String hash,
    DateTime now,
  ) async {
    await _loadIndex();
    if (t.snaps == null) {
      // Same as the newest snapshot on disk: nothing to read or write.
      if (_index![id] == hash) return;
      await _ensureLoaded(id, t);
    }
    final last = t.snaps!.isEmpty ? null : t.snaps!.last;
    if (last != null && last.hash == hash) {
      t.pending = null;
      return;
    }
    t.pending = _Pending(json, hash, now);
    await _writeIfAllowed(id, t, now);
  }

  Future<void> _writeIfAllowed(String id, _Track t, DateTime now) async {
    if (t.pending == null || t.snaps == null) return;
    final last = t.snaps!.isEmpty ? null : t.snaps!.last;
    if (last == null || now.difference(last.time) >= minInterval) {
      await _commit(id, t);
    }
  }

  /// Turns the waiting latest state into a snapshot and saves the file.
  Future<void> _commit(String id, _Track t) async {
    final p = t.pending;
    if (p == null) return;
    await _ensureLoaded(id, t);
    t.pending = null;
    final snaps = t.snaps!;
    final prev = snaps.isEmpty ? null : snaps.last;
    snaps.add(
      HistorySnapshot(
        time: p.time,
        hash: p.hash,
        summary: _summarize(prev, p.json),
        json: p.json,
      ),
    );
    if (snaps.length > maxSnapshots) {
      snaps.removeRange(0, snaps.length - maxSnapshots);
    }
    final store = _store;
    if (store == null) return;
    await store.writeJson(fileName(id), {
      'v': 1,
      'snapshots': [for (final s in snaps) s.toJson()],
    });
    await _loadIndex();
    _index![id] = p.hash;
    await store.writeJson(_indexFile, _index!);
  }

  static String _summarize(HistorySnapshot? prev, String json) {
    try {
      final now = CollectionModel.fromJson(
        jsonDecode(json) as Map<String, dynamic>,
      );
      if (prev == null) {
        final n = now.requests.length;
        return 'Initial snapshot ($n request${n == 1 ? '' : 's'})';
      }
      return diffCollections(prev.toCollection(), now).summary;
    } catch (_) {
      return 'Changed';
    }
  }
}
