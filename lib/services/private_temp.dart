import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

/// Creates a new directory under the system temp directory that only the
/// current user can open, named [prefix] plus random characters.
///
/// `Directory.createTemp` makes its directory with the umask's permissions
/// (often group- or world-readable), so on POSIX systems this calls
/// `mkdtemp`, which creates it with mode 0700 in one step. On Windows the
/// temp directory is already private to the user.
///
/// Throws a [FileSystemException] when no private directory can be made.
Directory createPrivateTempDir(String prefix) {
  if (Platform.isWindows) return Directory.systemTemp.createTempSync(prefix);
  try {
    return Directory(_mkdtemp('${Directory.systemTemp.path}/${prefix}XXXXXX'));
  } on FileSystemException {
    rethrow;
  } catch (_) {
    // No mkdtemp to call: create, then restrict and check.
    final dir = Directory.systemTemp.createTempSync(prefix);
    try {
      Process.runSync('chmod', ['700', dir.path]);
    } catch (_) {}
    if (dir.statSync().mode & 0x1FF != 0x1C0 || dir.listSync().isNotEmpty) {
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
