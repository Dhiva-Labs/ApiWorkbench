import 'dart:async';

import 'package:api_workbench/services/secret_store.dart';

/// An in-memory keychain that can be made to fail or hang.
class FakeKeychain implements SecretBackend {
  final Map<String, String> items = {};

  /// readAll throws, like a locked keyring or a snap without the plug.
  bool failReads = false;

  /// write and delete throw.
  bool failWrites = false;

  /// While set, every call waits for it (a keychain that does not answer).
  Completer<void>? hold;

  int reads = 0;
  int writes = 0;
  int deletes = 0;

  Future<void> _wait() async {
    final h = hold;
    if (h != null) await h.future;
  }

  @override
  Future<Map<String, String>> readAll() async {
    reads++;
    await _wait();
    if (failReads) {
      throw const SecretBackendException('The keychain is locked.');
    }
    return Map.of(items);
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
    await _wait();
    if (failWrites) {
      throw const SecretBackendException('The keychain refused the write.');
    }
    items[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deletes++;
    await _wait();
    if (failWrites) {
      throw const SecretBackendException('The keychain refused the write.');
    }
    items.remove(key);
  }
}
