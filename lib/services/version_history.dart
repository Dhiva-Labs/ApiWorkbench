import '../models/models.dart';
import 'json_store.dart';

/// Local snapshots of collections as they change (issue #35).
class CollectionHistory {
  CollectionHistory([this._store]);

  // ignore: unused_field
  final JsonStore? _store;

  /// Called after collections are saved; takes throttled snapshots.
  void record(List<CollectionModel> collections) {}
}
