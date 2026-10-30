/// Named JSON documents in the app's data folder. Services persist through
/// this so they stay free of Flutter (the CLI uses them too).
abstract interface class JsonStore {
  /// The decoded document, or null when it doesn't exist or is corrupt.
  Future<Object?> readJson(String name);

  /// Atomically replaces the document. Writes to one name are serialized.
  Future<void> writeJson(String name, Object data);
}
