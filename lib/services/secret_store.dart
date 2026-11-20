import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'json_store.dart';

/// Where secrets are being kept right now.
enum SecretStorageMode {
  /// The platform keychain: Secret Service on Linux, DPAPI on Windows, the
  /// Keystore on Android, the Keychain on macOS and iOS.
  keychain,

  /// `secrets.json` in the data folder, readable by this user only.
  file,
}

/// What Settings shows about secret storage.
class SecretStorageStatus {
  const SecretStorageStatus({
    required this.mode,
    this.reason,
    this.snapName,
    this.keychainHoldsOlderSecrets = false,
  });

  final SecretStorageMode mode;

  /// Why the keychain is not in use, in the user's terms (file mode only).
  final String? reason;

  /// The snap instance name when running as a snap, for the
  /// `snap connect` command; null otherwise.
  final String? snapName;

  /// File mode only: the keychain was used before and still holds those
  /// secrets; they are read again once it can be reached.
  final bool keychainHoldsOlderSecrets;

  /// The command that lets this snap reach the desktop keychain.
  String? get snapConnectCommand => snapName == null
      ? null
      : 'sudo snap connect $snapName:password-manager-service';
}

/// The platform keychain as the store sees it: string values under string
/// keys. Implementations throw [SecretBackendException] (or anything else)
/// when the keychain cannot be used.
abstract interface class SecretBackend {
  /// Every value this app stored.
  Future<Map<String, String>> readAll();

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// A keychain failure with a message fit for Settings.
class SecretBackendException implements Exception {
  const SecretBackendException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Keeps the secrets taken out of the saved documents (see
/// `secret_fields.dart`): one entry per document, each a map from path to
/// value, stored as one keychain item per document so the keychain holds a
/// handful of items rather than one per field.
///
/// When the keychain cannot be reached (no Secret Service, a snap whose
/// `password-manager-service` plug is not connected, a locked keyring, a
/// timeout, a platform error) the entries go to [fileName] in the data
/// folder instead, which `Storage` writes readable by this user only. The
/// keychain's own items are never deleted in that case: the next start that
/// reaches the keychain merges both, path by path, the file winning, so
/// switching modes never loses a secret. Once merged into the keychain the
/// file is emptied.
///
/// Every keychain call is serialized and bounded by [openTimeout] or
/// [timeout], and nothing here throws: a failure only changes the mode.
class SecretStore {
  SecretStore(
    this._files,
    this._backend, {
    this.timeout = const Duration(seconds: 15),
    Duration? openTimeout,
    this.unavailableReason,
    Map<String, String>? environment,
  }) : openTimeout = openTimeout ?? const Duration(seconds: 90),
       _env = environment ?? Platform.environment;

  /// The fallback file, in the data folder next to the documents.
  static const fileName = 'secrets.json';

  /// Prefix of every keychain key this app writes.
  static const keyPrefix = 'apiworkbench.secrets.';

  final JsonStore _files;
  final SecretBackend? _backend;

  /// Why there is no keychain when [SecretStore] is made without one.
  final String? unavailableReason;
  final Map<String, String> _env;

  /// Upper bound for one keychain write or delete.
  final Duration timeout;

  /// Upper bound for reading the keychain at start. Longer than [timeout]:
  /// the desktop may ask the user to unlock the keyring first.
  final Duration openTimeout;

  SecretStorageMode _mode = SecretStorageMode.file;
  String? _reason;
  bool _keychainUsed = false;

  /// What each entry holds now.
  final Map<String, Map<String, String>> _entries = {};

  /// The encoded form last stored for each entry (in whichever place), so
  /// an unchanged entry costs no keychain call.
  final Map<String, String> _stored = {};

  /// File mode: the entries in [fileName].
  Map<String, Map<String, String>> _fileEntries = {};

  bool _opened = false;
  Future<void> _chain = Future.value();

  SecretStorageStatus get status {
    final snap = _env['SNAP_INSTANCE_NAME'] ?? _env['SNAP_NAME'];
    return SecretStorageStatus(
      mode: _mode,
      reason: _mode == SecretStorageMode.file ? _reason : null,
      snapName: snap == null || snap.isEmpty ? null : snap,
      keychainHoldsOlderSecrets:
          _mode == SecretStorageMode.file && _keychainUsed,
    );
  }

  /// The secrets of document entry [name] (empty before [open]).
  Map<String, String> entry(String name) => Map.of(_entries[name] ?? {});

  /// Every secret value stored, of every entry.
  Set<String> get allValues => {
    for (final e in _entries.values)
      for (final v in e.values)
        if (v.isNotEmpty) v,
  };

  /// Reads the keychain and the fallback file, once.
  Future<void> open() => _serial(_ensureOpen);

  Future<void> _ensureOpen() async {
    if (_opened) return;
    _opened = true;
    await _open();
  }

  Future<void> _open() async {
    final file = await _readFile();
    _fileEntries = file.entries;
    _keychainUsed = file.keychainUsed;
    final backend = _backend;
    Map<String, String>? raw;
    if (backend == null) {
      _fileMode(unavailableReason ?? 'This build has no keychain support.');
    } else {
      try {
        raw = await backend.readAll().timeout(openTimeout);
      } catch (e) {
        _fileMode(_describe(e));
      }
    }
    if (raw == null) {
      _load(_fileEntries);
      for (final e in _fileEntries.entries) {
        _stored[e.key] = _encode(e.value);
      }
      return;
    }
    final fromKeychain = <String, Map<String, String>>{};
    for (final e in raw.entries) {
      if (!e.key.startsWith(keyPrefix)) continue;
      final decoded = _decode(e.value);
      if (decoded == null) continue;
      final name = e.key.substring(keyPrefix.length);
      fromKeychain[name] = decoded;
      _stored[name] = _encode(decoded);
    }
    if (fromKeychain.isNotEmpty) _keychainUsed = true;
    _mode = SecretStorageMode.keychain;
    _reason = null;
    // Path by path, the file wins: it was written while the keychain could
    // not be reached, so it is newer.
    final merged = <String, Map<String, String>>{
      for (final name in {...fromKeychain.keys, ..._fileEntries.keys})
        name: {...?fromKeychain[name], ...?_fileEntries[name]},
    };
    _load(merged);
    if (_fileEntries.isEmpty) return;
    for (final name in _fileEntries.keys) {
      // On failure the file stays as it is, and so do the keychain items.
      if (!await _writeKeychain(name, merged[name]!)) return;
    }
    // Everything is in the keychain now: empty the file.
    _fileEntries = {};
    await _writeFile();
  }

  /// Stores [secrets] as entry [name]. Returns false only when they could
  /// be kept nowhere, in which case the caller must keep them itself.
  Future<bool> put(String name, Map<String, String> secrets) =>
      _serial(() async {
        await _ensureOpen();
        final copy = Map.of(secrets);
        final encoded = _encode(copy);
        // Unchanged, or still nothing to keep: no keychain call.
        if ((_stored[name] ?? _empty) == encoded) {
          _entries[name] = copy;
          return true;
        }
        if (_mode == SecretStorageMode.keychain &&
            await _writeKeychain(name, copy)) {
          _entries[name] = copy;
          return true;
        }
        final before = _fileEntries;
        _fileEntries = {..._fileEntries, name: copy}
          ..removeWhere((_, v) => v.isEmpty);
        if (await _writeFile()) {
          _stored[name] = encoded;
          _entries[name] = copy;
          return true;
        }
        _fileEntries = before;
        return false;
      });

  /// Writes one entry to the keychain; on failure switches to file mode.
  Future<bool> _writeKeychain(String name, Map<String, String> secrets) async {
    final backend = _backend;
    if (backend == null) return false;
    final key = '$keyPrefix$name';
    final encoded = _encode(secrets);
    try {
      if (secrets.isEmpty) {
        await backend.delete(key).timeout(timeout);
      } else {
        await backend.write(key, encoded).timeout(timeout);
      }
    } catch (e) {
      _fileMode(_describe(e));
      return false;
    }
    _stored[name] = encoded;
    if (!_keychainUsed && secrets.isNotEmpty) {
      _keychainUsed = true;
      // Remember it, so a later start without the keychain can say where
      // the secrets are. Best effort.
      await _writeFile();
    }
    return true;
  }

  void _fileMode(String reason) {
    _mode = SecretStorageMode.file;
    _reason = reason;
  }

  void _load(Map<String, Map<String, String>> entries) {
    _entries
      ..clear()
      ..addAll({for (final e in entries.entries) e.key: Map.of(e.value)});
  }

  Future<({Map<String, Map<String, String>> entries, bool keychainUsed})>
  _readFile() async {
    final raw = await _files.readJson(fileName);
    final entries = <String, Map<String, String>>{};
    var used = false;
    if (raw is Map) {
      used = raw['keychain'] == true;
      final e = raw['entries'];
      if (e is Map) {
        for (final x in e.entries) {
          final m = _asStringMap(x.value);
          if (m != null && m.isNotEmpty) entries['${x.key}'] = m;
        }
      }
    }
    return (entries: entries, keychainUsed: used);
  }

  Future<bool> _writeFile() async {
    try {
      await _files.writeJson(fileName, {
        'v': 1,
        if (_keychainUsed) 'keychain': true,
        'entries': _fileEntries,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Runs [step] after every earlier keychain or file step.
  Future<T> _serial<T>(Future<T> Function() step) {
    final done = _chain.then((_) => step());
    _chain = done.then((_) {}, onError: (_) {});
    return done;
  }

  static String _describe(Object e) => switch (e) {
    SecretBackendException() => e.message,
    TimeoutException() => 'The system keychain did not answer in time.',
    _ => 'The system keychain could not be reached.',
  };

  static final _empty = _encode(const {});

  /// Sorted keys, so equal maps encode alike.
  static String _encode(Map<String, String> secrets) {
    final keys = secrets.keys.toList()..sort();
    return jsonEncode({
      'v': 1,
      's': {for (final k in keys) k: secrets[k]},
    });
  }

  static Map<String, String>? _decode(String text) {
    try {
      final j = jsonDecode(text);
      if (j is Map && j['s'] is Map) return _asStringMap(j['s']);
    } catch (_) {}
    return null;
  }

  static Map<String, String>? _asStringMap(Object? m) {
    if (m is! Map) return null;
    return {
      for (final e in m.entries)
        if (e.value is String) '${e.key}': e.value as String,
    };
  }
}
