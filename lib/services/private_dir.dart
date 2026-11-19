import 'dart:io';

/// Creates a new directory under the system temp directory (or [parent])
/// that only this user can open.
///
/// The name is [prefix] plus random characters, so unlike a fixed name in a
/// shared temp directory it cannot be guessed. On Linux and macOS the mode is
/// 0700. Windows temp folders are per-user already.
Future<Directory> createPrivateDir(String prefix, {Directory? parent}) async {
  final dir = await (parent ?? Directory.systemTemp).createTemp(prefix);
  if (!Platform.isWindows) await _restrict(dir);
  return dir;
}

/// `mkdtemp` already creates 0700; this only repairs a directory that came
/// out wider (an unusual file system), and never fails the caller.
Future<void> _restrict(Directory dir) async {
  try {
    final mode = (await dir.stat()).mode;
    if (mode & 0x3f != 0) await Process.run('chmod', ['700', dir.path]);
  } catch (_) {}
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
