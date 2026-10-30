/// QuickJS-ng, compiled from source by this package's build hook, behind a
/// small C bridge (src/bridge.c).
///
/// Values cross into Dart as JSON text only. The context has the ECMAScript
/// built-ins (plus `atob`, `btoa` and `performance`) and `__awLoad(name)`,
/// which instantiates bytecode registered with [JsRuntime.addModule]. There
/// is no std/os module: scripts can't reach files, processes or the network.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

import 'src/bindings.dart';

/// The native library could not be loaded.
class QuickJsUnavailable implements Exception {
  QuickJsUnavailable(this.message);
  final String message;

  @override
  String toString() => 'QuickJS is not available: $message';
}

/// The outcome of [JsRuntime.eval] or [JsRuntime.runJobs].
class JsResult {
  const JsResult.value(String this.json) : error = null, timedOut = false;
  const JsResult.error(String this.error, {this.timedOut = false})
    : json = null;

  /// JSON text of the completion value (`null` for undefined).
  final String? json;

  /// `Name: message` and the stack of an uncaught exception.
  final String? error;

  /// The deadline set with [JsRuntime.setDeadline] interrupted the code.
  final bool timedOut;

  bool get ok => error == null;

  /// The completion value decoded from JSON.
  Object? get value => json == null ? null : jsonDecode(json!);
}

/// Bytecode from [JsRuntime.compile], in native memory so any number of
/// runtimes can load it without copying. Free it with [dispose] once no
/// runtime that registered it is alive.
class JsBytecode {
  JsBytecode._(this._bridge, this._pointer, this.length);

  final Bridge _bridge;
  Pointer<Uint8> _pointer;
  final int length;

  bool get isDisposed => _pointer == nullptr;

  void dispose() {
    if (isDisposed) return;
    _bridge.freeBuffer(_pointer.cast());
    _pointer = nullptr;
  }
}

/// A loaded bridge library.
class QuickJs {
  QuickJs._(this._bridge, this.location);

  final Bridge _bridge;

  /// `asset` for the library the build hook bundled, else its file path.
  final String location;

  /// Environment variable naming a library file to use when the build
  /// hook's asset is not bundled (a CLI built without hooks, for example).
  static const libraryEnvironmentVariable = 'QUICKJS_FFI_LIBRARY';

  /// Loads the bridge from [path], or else the bundled code asset, then
  /// [libraryEnvironmentVariable], then the usual places next to the
  /// executable. Throws [QuickJsUnavailable] when none loads.
  static QuickJs open({String? path}) {
    final tried = <String>[];
    if (path != null) return _openPath(path, tried) ?? _fail(tried);
    try {
      const bridge = AssetBridge();
      if (bridge.version() == bridgeVersion) return QuickJs._(bridge, 'asset');
      tried.add('asset: interface version ${bridge.version()}');
    } catch (e) {
      tried.add('asset: $e');
    }
    final env = Platform.environment[libraryEnvironmentVariable];
    for (final p in [if (env != null && env.isNotEmpty) env, ...candidates()]) {
      final q = _openPath(p, tried);
      if (q != null) return q;
    }
    return _fail(tried);
  }

  /// [open], or null when the library can't be loaded.
  static QuickJs? tryOpen({String? path}) {
    try {
      return open(path: path);
    } on QuickJsUnavailable {
      return null;
    }
  }

  /// Where a bundled app keeps the library, relative to its executable:
  /// next to it, or in the app bundle around a CLI that lives in the
  /// bundle's `bin` folder.
  static List<String> candidates() {
    final exe = File(Platform.resolvedExecutable).parent.path;
    String join(List<String> parts) => parts.join(Platform.pathSeparator);
    if (Platform.isWindows) {
      return [
        join([exe, 'quickjs_ffi.dll']),
        join([exe, '..', 'quickjs_ffi.dll']),
        join([exe, '..', 'lib', 'quickjs_ffi.dll']),
      ];
    }
    if (Platform.isMacOS) {
      return [
        join([exe, '..', 'Frameworks', 'quickjs_ffi.framework', 'quickjs_ffi']),
        join([exe, 'libquickjs_ffi.dylib']),
        join([exe, '..', 'lib', 'libquickjs_ffi.dylib']),
      ];
    }
    return [
      join([exe, 'lib', 'libquickjs_ffi.so']),
      join([exe, 'libquickjs_ffi.so']),
      join([exe, '..', 'lib', 'libquickjs_ffi.so']),
    ];
  }

  static QuickJs? _openPath(String path, List<String> tried) {
    try {
      final bridge = LibraryBridge(DynamicLibrary.open(path));
      final v = bridge.version();
      if (v == bridgeVersion) return QuickJs._(bridge, path);
      tried.add('$path: interface version $v');
    } catch (e) {
      tried.add('$path: $e');
    }
    return null;
  }

  static Never _fail(List<String> tried) =>
      throw QuickJsUnavailable(tried.join('; '));

  /// A fresh runtime with one context. [memoryLimit] and [stackSize] are in
  /// bytes. The stack budget must fit in the calling thread's stack, which
  /// is 1 MB for Dart's own threads; QuickJS throws a RangeError instead of
  /// overflowing it.
  JsRuntime newRuntime({
    int memoryLimit = 128 << 20,
    int stackSize = 512 << 10,
  }) {
    final h = _bridge.create(memoryLimit, stackSize);
    if (h == nullptr) throw StateError('QuickJS runtime allocation failed');
    return JsRuntime._(this, h);
  }
}

/// One QuickJS runtime and context. Not thread-safe: use it from one
/// isolate at a time.
class JsRuntime {
  JsRuntime._(this._owner, this._handle);

  final QuickJs _owner;
  Pointer<Void> _handle;
  final List<JsBytecode> _modules = [];

  Bridge get _b => _owner._bridge;
  bool get isDisposed => _handle == nullptr;

  void _check() {
    if (isDisposed) throw StateError('JsRuntime is disposed');
  }

  /// Interrupts evaluation [timeoutMs] from now (uncatchable for the
  /// script); 0 clears the deadline.
  void setDeadline(int timeoutMs) {
    _check();
    _b.setDeadline(_handle, timeoutMs);
  }

  /// Evaluates [code] as a global script.
  JsResult eval(String code, {String filename = '<eval>'}) {
    _check();
    return using((arena) {
      final src = _utf8(code, arena);
      final name = _utf8(filename, arena);
      final status = arena<Int32>();
      final out = _b.eval(_handle, src.$1, src.$2, name.$1, status);
      return _result(out, status.value);
    });
  }

  /// Runs pending promise jobs until none are left. Null when they all ran;
  /// an error result when one failed outright (the deadline passed).
  JsResult? runJobs() {
    _check();
    return using((arena) {
      final status = arena<Int32>();
      final out = _b.runJobs(_handle, status);
      if (status.value == 0) return null;
      return _result(out, status.value);
    });
  }

  /// Compiles [code] (a global script) to bytecode without running it.
  /// Loading that bytecode with `__awLoad` yields its completion value.
  /// Throws a [FormatException] with the syntax error.
  JsBytecode compile(
    String code, {
    String filename = '<compile>',
    bool stripSource = true,
  }) {
    _check();
    return using((arena) {
      final src = _utf8(code, arena);
      final name = _utf8(filename, arena);
      final length = arena<Int64>();
      final status = arena<Int32>();
      final out = _b.compile(
        _handle,
        src.$1,
        src.$2,
        name.$1,
        stripSource ? 1 : 0,
        length,
        status,
      );
      if (status.value != 0) {
        throw FormatException(_take(out) ?? 'compile failed');
      }
      return JsBytecode._(_b, out, length.value);
    });
  }

  /// Makes [bytecode] loadable as `__awLoad(name)` in this runtime. The
  /// bytecode is not copied, so it must outlive this runtime.
  void addModule(String name, JsBytecode bytecode) {
    _check();
    if (bytecode.isDisposed) throw StateError('bytecode is disposed');
    using((arena) {
      final n = _utf8(name, arena);
      if (_b.addModule(_handle, n.$1, bytecode._pointer, bytecode.length) ==
          0) {
        throw StateError('out of memory registering $name');
      }
    });
    _modules.add(bytecode);
  }

  void dispose() {
    if (isDisposed) return;
    _b.free(_handle);
    _handle = nullptr;
    _modules.clear();
  }

  JsResult _result(Pointer<Uint8> out, int status) {
    final text = _take(out) ?? '';
    return switch (status) {
      0 => JsResult.value(text),
      2 => JsResult.error(text, timedOut: true),
      _ => JsResult.error(text),
    };
  }

  /// Copies a NUL-terminated UTF-8 buffer from the bridge and frees it.
  String? _take(Pointer<Uint8> p) {
    if (p == nullptr) return null;
    try {
      var n = 0;
      while (p[n] != 0) {
        n++;
      }
      return utf8.decode(p.asTypedList(n), allowMalformed: true);
    } finally {
      _b.freeBuffer(p.cast());
    }
  }

  static (Pointer<Uint8>, int) _utf8(String s, Arena arena) {
    final bytes = utf8.encode(s);
    final p = arena<Uint8>(bytes.length + 1);
    final view = p.asTypedList(bytes.length + 1);
    view.setAll(0, bytes);
    view[bytes.length] = 0;
    return (p, bytes.length);
  }
}
