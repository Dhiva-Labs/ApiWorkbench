import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

/// Creates a new directory under the system temp directory (or [parent])
/// that only this user can open.
///
/// The name is [prefix] plus random characters, so unlike a fixed name in a
/// shared temp directory it cannot be guessed. `Directory.createTemp` makes
/// its directory with the umask's permissions (often group- or
/// world-readable), so on Linux and macOS this calls `mkdtemp`, which
/// creates it with mode 0700 in one step. Windows temp folders are per-user
/// already.
///
/// Throws a [FileSystemException] when no private directory can be made.
Future<Directory> createPrivateDir(String prefix, {Directory? parent}) async =>
    createPrivateDirSync(prefix, parent: parent);

/// [createPrivateDir] for synchronous callers.
Directory createPrivateDirSync(String prefix, {Directory? parent}) {
  final root = parent ?? Directory.systemTemp;
  if (Platform.isWindows) return root.createTempSync(prefix);
  try {
    return Directory(_mkdtemp('${root.path}/${prefix}XXXXXX'));
  } on FileSystemException {
    rethrow;
  } catch (_) {
    // No mkdtemp to call: create, then restrict. Anything that got in
    // before the mode changed means the folder cannot be trusted.
    final dir = root.createTempSync(prefix);
    try {
      if (dir.statSync().mode & 0x3f != 0) {
        Process.runSync('chmod', ['700', dir.path]);
      }
    } catch (_) {}
    if (dir.listSync().isNotEmpty) {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
      throw FileSystemException('Could not create a private folder', dir.path);
    }
    return dir;
  }
}

typedef _MkdtempC = Pointer<Uint8> Function(Pointer<Uint8>);
typedef _MallocC = Pointer<Uint8> Function(IntPtr);
typedef _MallocD = Pointer<Uint8> Function(int);
typedef _FreeC = Void Function(Pointer<Uint8>);
typedef _FreeD = void Function(Pointer<Uint8>);

/// libc `mkdtemp` on [template] (ending in `XXXXXX`); the created path.
String _mkdtemp(String template) {
  final libc = DynamicLibrary.process();
  final mkdtemp = libc.lookupFunction<_MkdtempC, _MkdtempC>('mkdtemp');
  final malloc = libc.lookupFunction<_MallocC, _MallocD>('malloc');
  final free = libc.lookupFunction<_FreeC, _FreeD>('free');
  final bytes = utf8.encode(template);
  final buf = malloc(bytes.length + 1);
  if (buf == nullptr) throw StateError('out of memory');
  try {
    buf.asTypedList(bytes.length + 1)
      ..setAll(0, bytes)
      ..[bytes.length] = 0;
    if (mkdtemp(buf) == nullptr) {
      throw FileSystemException('Could not create a private folder', template);
    }
    return utf8.decode(buf.asTypedList(bytes.length));
  } finally {
    free(buf);
  }
}

/// Deletes what earlier runs left in the system temp directory (or
/// [parent]): directories named [prefix]… that nothing has touched for
/// [maxAge], and the fixed-name directories earlier versions used
/// ([legacyNames]). Best effort: whatever cannot be removed stays.
Future<void> removeStalePrivateDirs(
  String prefix, {
  Directory? parent,
  Duration maxAge = const Duration(days: 1),
  Iterable<String> legacyNames = const [],
}) async {
  final root = parent ?? Directory.systemTemp;
  try {
    final cutoff = DateTime.now().subtract(maxAge);
    await for (final e in root.list(followLinks: false)) {
      final name = e.uri.pathSegments.lastWhere(
        (s) => s.isNotEmpty,
        orElse: () => '',
      );
      if (legacyNames.contains(name)) {
        await _remove(e);
      } else if (name.startsWith(prefix) &&
          e is Directory &&
          (await _lastTouched(e)).isBefore(cutoff)) {
        await _remove(e);
      }
    }
  } catch (_) {}
}

/// When [dir] or anything directly in it last changed.
Future<DateTime> _lastTouched(Directory dir) async {
  var latest = (await dir.stat()).modified;
  try {
    await for (final c in dir.list(followLinks: false)) {
      final m = (await c.stat()).modified;
      if (m.isAfter(latest)) latest = m;
    }
  } catch (_) {}
  return latest;
}

Future<void> _remove(FileSystemEntity e) async {
  try {
    // A link is removed itself, never followed.
    if (e is Link) {
      await e.delete();
    } else {
      await e.delete(recursive: true);
    }
  } catch (_) {}
}
