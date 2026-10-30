import 'package:quickjs_ffi/quickjs_ffi.dart';

import 'quickjs_engine.dart';
import 'script_assets.dart';
import 'script_engine.dart';

export 'script_assets.dart' show ScriptAssetLoader;

/// The script engine for this platform (QuickJS-ng), or null when its native
/// library or the bundled script files can't be found. Scripts are then
/// kept but not run.
///
/// - [libraryPath]: load the native library from this file instead of the
///   one the build hook bundles (a CLI built without hooks can also set
///   `QUICKJS_FFI_LIBRARY`).
/// - [loadAsset]: how to read `assets/js/*` (the app passes
///   `rootBundle.loadString`). Without it the files are read from
///   [assetDir], `APIWORKBENCH_SCRIPT_ASSETS`, the Flutter bundle next to
///   the executable or `assets/js` in the current directory.
/// - [isolate]: run scripts in a worker isolate (the default) or on the
///   caller's isolate.
ScriptEngine? createScriptEngine({
  String? libraryPath,
  ScriptAssetLoader? loadAsset,
  String? assetDir,
  bool isolate = true,
}) {
  final quickJs = QuickJs.tryOpen(path: libraryPath);
  if (quickJs == null) return null;
  var loader = loadAsset;
  if (loader == null) {
    final dir = findScriptAssetDir(assetDir);
    if (dir == null) return null;
    loader = fileAssetLoader(dir);
  }
  return QuickJsScriptEngine(quickJs, loader, useIsolate: isolate);
}
