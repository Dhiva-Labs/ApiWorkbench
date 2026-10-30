import 'dart:ffi';

/// The bridge's interface version (`AWQ_VERSION` in src/bridge.c).
const bridgeVersion = 1;

/// The awq_* functions of src/bridge.c, resolved one of two ways: through
/// the code asset the build hook bundles, or from a library file.
abstract class Bridge {
  int version();
  Pointer<Void> create(int memoryLimit, int stackSize);
  void free(Pointer<Void> handle);
  void setDeadline(Pointer<Void> handle, int timeoutMs);
  Pointer<Uint8> eval(
    Pointer<Void> handle,
    Pointer<Uint8> code,
    int length,
    Pointer<Uint8> filename,
    Pointer<Int32> status,
  );
  Pointer<Uint8> runJobs(Pointer<Void> handle, Pointer<Int32> status);
  Pointer<Uint8> compile(
    Pointer<Void> handle,
    Pointer<Uint8> code,
    int length,
    Pointer<Uint8> filename,
    int stripSource,
    Pointer<Int64> outLength,
    Pointer<Int32> status,
  );
  int addModule(
    Pointer<Void> handle,
    Pointer<Uint8> name,
    Pointer<Uint8> bytecode,
    int length,
  );
  void freeBuffer(Pointer<Void> buffer);
}

const _asset = 'package:quickjs_ffi/quickjs_ffi.dart';

@Native<Int32 Function()>(symbol: 'awq_version', assetId: _asset, isLeaf: true)
external int _version();

@Native<Pointer<Void> Function(Int64, Int64)>(
  symbol: 'awq_new',
  assetId: _asset,
)
external Pointer<Void> _create(int memoryLimit, int stackSize);

@Native<Void Function(Pointer<Void>)>(symbol: 'awq_free', assetId: _asset)
external void _free(Pointer<Void> handle);

@Native<Void Function(Pointer<Void>, Int64)>(
  symbol: 'awq_set_deadline',
  assetId: _asset,
  isLeaf: true,
)
external void _setDeadline(Pointer<Void> handle, int timeoutMs);

@Native<
  Pointer<Uint8> Function(
    Pointer<Void>,
    Pointer<Uint8>,
    Int64,
    Pointer<Uint8>,
    Pointer<Int32>,
  )
>(symbol: 'awq_eval', assetId: _asset)
external Pointer<Uint8> _eval(
  Pointer<Void> handle,
  Pointer<Uint8> code,
  int length,
  Pointer<Uint8> filename,
  Pointer<Int32> status,
);

@Native<Pointer<Uint8> Function(Pointer<Void>, Pointer<Int32>)>(
  symbol: 'awq_run_jobs',
  assetId: _asset,
)
external Pointer<Uint8> _runJobs(Pointer<Void> handle, Pointer<Int32> status);

@Native<
  Pointer<Uint8> Function(
    Pointer<Void>,
    Pointer<Uint8>,
    Int64,
    Pointer<Uint8>,
    Int32,
    Pointer<Int64>,
    Pointer<Int32>,
  )
>(symbol: 'awq_compile', assetId: _asset)
external Pointer<Uint8> _compile(
  Pointer<Void> handle,
  Pointer<Uint8> code,
  int length,
  Pointer<Uint8> filename,
  int stripSource,
  Pointer<Int64> outLength,
  Pointer<Int32> status,
);

@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>, Int64)>(
  symbol: 'awq_add_module',
  assetId: _asset,
  isLeaf: true,
)
external int _addModule(
  Pointer<Void> handle,
  Pointer<Uint8> name,
  Pointer<Uint8> bytecode,
  int length,
);

@Native<Void Function(Pointer<Void>)>(
  symbol: 'awq_free_buffer',
  assetId: _asset,
  isLeaf: true,
)
external void _freeBuffer(Pointer<Void> buffer);

/// The library the build hook bundled with the app, `flutter test` or
/// `dart run`. Calling any method throws when no such asset is bundled.
class AssetBridge implements Bridge {
  const AssetBridge();

  @override
  int version() => _version();
  @override
  Pointer<Void> create(int memoryLimit, int stackSize) =>
      _create(memoryLimit, stackSize);
  @override
  void free(Pointer<Void> handle) => _free(handle);
  @override
  void setDeadline(Pointer<Void> handle, int timeoutMs) =>
      _setDeadline(handle, timeoutMs);
  @override
  Pointer<Uint8> eval(
    Pointer<Void> handle,
    Pointer<Uint8> code,
    int length,
    Pointer<Uint8> filename,
    Pointer<Int32> status,
  ) => _eval(handle, code, length, filename, status);
  @override
  Pointer<Uint8> runJobs(Pointer<Void> handle, Pointer<Int32> status) =>
      _runJobs(handle, status);
  @override
  Pointer<Uint8> compile(
    Pointer<Void> handle,
    Pointer<Uint8> code,
    int length,
    Pointer<Uint8> filename,
    int stripSource,
    Pointer<Int64> outLength,
    Pointer<Int32> status,
  ) => _compile(handle, code, length, filename, stripSource, outLength, status);
  @override
  int addModule(
    Pointer<Void> handle,
    Pointer<Uint8> name,
    Pointer<Uint8> bytecode,
    int length,
  ) => _addModule(handle, name, bytecode, length);
  @override
  void freeBuffer(Pointer<Void> buffer) => _freeBuffer(buffer);
}

/// The same functions looked up in a library opened by path.
class LibraryBridge implements Bridge {
  LibraryBridge(DynamicLibrary lib)
    : _v = lib.lookupFunction<Int32 Function(), int Function()>(
        'awq_version',
        isLeaf: true,
      ),
      _c = lib
          .lookupFunction<
            Pointer<Void> Function(Int64, Int64),
            Pointer<Void> Function(int, int)
          >('awq_new'),
      _f = lib
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('awq_free'),
      _d = lib
          .lookupFunction<
            Void Function(Pointer<Void>, Int64),
            void Function(Pointer<Void>, int)
          >('awq_set_deadline', isLeaf: true),
      _e = lib
          .lookupFunction<
            Pointer<Uint8> Function(
              Pointer<Void>,
              Pointer<Uint8>,
              Int64,
              Pointer<Uint8>,
              Pointer<Int32>,
            ),
            Pointer<Uint8> Function(
              Pointer<Void>,
              Pointer<Uint8>,
              int,
              Pointer<Uint8>,
              Pointer<Int32>,
            )
          >('awq_eval'),
      _j = lib
          .lookupFunction<
            Pointer<Uint8> Function(Pointer<Void>, Pointer<Int32>),
            Pointer<Uint8> Function(Pointer<Void>, Pointer<Int32>)
          >('awq_run_jobs'),
      _k = lib
          .lookupFunction<
            Pointer<Uint8> Function(
              Pointer<Void>,
              Pointer<Uint8>,
              Int64,
              Pointer<Uint8>,
              Int32,
              Pointer<Int64>,
              Pointer<Int32>,
            ),
            Pointer<Uint8> Function(
              Pointer<Void>,
              Pointer<Uint8>,
              int,
              Pointer<Uint8>,
              int,
              Pointer<Int64>,
              Pointer<Int32>,
            )
          >('awq_compile'),
      _m = lib
          .lookupFunction<
            Int32 Function(
              Pointer<Void>,
              Pointer<Uint8>,
              Pointer<Uint8>,
              Int64,
            ),
            int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>, int)
          >('awq_add_module', isLeaf: true),
      _b = lib
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('awq_free_buffer', isLeaf: true);

  final int Function() _v;
  final Pointer<Void> Function(int, int) _c;
  final void Function(Pointer<Void>) _f;
  final void Function(Pointer<Void>, int) _d;
  final Pointer<Uint8> Function(
    Pointer<Void>,
    Pointer<Uint8>,
    int,
    Pointer<Uint8>,
    Pointer<Int32>,
  )
  _e;
  final Pointer<Uint8> Function(Pointer<Void>, Pointer<Int32>) _j;
  final Pointer<Uint8> Function(
    Pointer<Void>,
    Pointer<Uint8>,
    int,
    Pointer<Uint8>,
    int,
    Pointer<Int64>,
    Pointer<Int32>,
  )
  _k;
  final int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>, int) _m;
  final void Function(Pointer<Void>) _b;

  @override
  int version() => _v();
  @override
  Pointer<Void> create(int memoryLimit, int stackSize) =>
      _c(memoryLimit, stackSize);
  @override
  void free(Pointer<Void> handle) => _f(handle);
  @override
  void setDeadline(Pointer<Void> handle, int timeoutMs) =>
      _d(handle, timeoutMs);
  @override
  Pointer<Uint8> eval(
    Pointer<Void> handle,
    Pointer<Uint8> code,
    int length,
    Pointer<Uint8> filename,
    Pointer<Int32> status,
  ) => _e(handle, code, length, filename, status);
  @override
  Pointer<Uint8> runJobs(Pointer<Void> handle, Pointer<Int32> status) =>
      _j(handle, status);
  @override
  Pointer<Uint8> compile(
    Pointer<Void> handle,
    Pointer<Uint8> code,
    int length,
    Pointer<Uint8> filename,
    int stripSource,
    Pointer<Int64> outLength,
    Pointer<Int32> status,
  ) => _k(handle, code, length, filename, stripSource, outLength, status);
  @override
  int addModule(
    Pointer<Void> handle,
    Pointer<Uint8> name,
    Pointer<Uint8> bytecode,
    int length,
  ) => _m(handle, name, bytecode, length);
  @override
  void freeBuffer(Pointer<Void> buffer) => _b(buffer);
}
