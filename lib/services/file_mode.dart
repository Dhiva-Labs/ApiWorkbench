import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

/// Owner-only permissions for the data folder and its files (issue #61).
/// dart:io creates files with the process umask (usually 0644 or 0664), so
/// the mode is set through libc's chmod. Windows keeps per-user ACLs on
/// AppData instead and is left alone, as is any platform where the call is
/// not available.
abstract final class FileMode {
  /// rw------- for files.
  static const privateFile = 0x180; // 0600

  /// rwx------ for folders.
  static const privateDir = 0x1C0; // 0700

  static final _Libc? _libc = _Libc.open();

  /// Whether modes can be set on this platform.
  static bool get supported => _libc != null;

  /// Sets [path]'s permission bits to [mode]. Returns false when that did
  /// not work or is not supported here; callers carry on either way.
  static bool set(String path, int mode) {
    final libc = _libc;
    if (libc == null) return false;
    try {
      return libc.chmod(path, mode) == 0;
    } catch (_) {
      return false;
    }
  }

  /// The permission bits of [path], or null when it cannot be read.
  static int? of(String path) {
    try {
      final s = FileStat.statSync(path);
      if (s.type == FileSystemEntityType.notFound) return null;
      return s.mode & 0x1FF;
    } catch (_) {
      return null;
    }
  }
}

class _Libc {
  _Libc._(this._chmod, this._malloc, this._free);

  final int Function(Pointer<Uint8>, int) _chmod;
  final Pointer<Uint8> Function(int) _malloc;
  final void Function(Pointer<Uint8>) _free;

  static _Libc? open() {
    if (Platform.isWindows) return null;
    try {
      final lib = DynamicLibrary.process();
      // mode_t is 16 bits on Apple platforms and 32 bits elsewhere.
      final chmod = Platform.isMacOS || Platform.isIOS
          ? lib.lookupFunction<
              Int32 Function(Pointer<Uint8>, Uint16),
              int Function(Pointer<Uint8>, int)
            >('chmod')
          : lib.lookupFunction<
              Int32 Function(Pointer<Uint8>, Uint32),
              int Function(Pointer<Uint8>, int)
            >('chmod');
      return _Libc._(
        chmod,
        lib.lookupFunction<
          Pointer<Uint8> Function(IntPtr),
          Pointer<Uint8> Function(int)
        >('malloc'),
        lib.lookupFunction<
          Void Function(Pointer<Uint8>),
          void Function(Pointer<Uint8>)
        >('free'),
      );
    } catch (_) {
      return null;
    }
  }

  int chmod(String path, int mode) {
    final bytes = utf8.encode(path);
    final p = _malloc(bytes.length + 1);
    if (p == nullptr) return -1;
    try {
      p.asTypedList(bytes.length + 1)
        ..setAll(0, bytes)
        ..[bytes.length] = 0;
      return _chmod(p, mode);
    } finally {
      _free(p);
    }
  }
}
