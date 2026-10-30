import 'dart:io';

/// Loads one bundled script file by its asset key (`assets/js/chai.js`).
/// The app passes `rootBundle.loadString`; plain Dart reads files.
typedef ScriptAssetLoader = Future<String> Function(String key);

/// Where the bundled script files live, relative to the package root.
const scriptAssetDir = 'assets/js';

/// Module name (`require('chai')`, `__awLoad('sandbox')`) to file name in
/// [scriptAssetDir]. The sandbox must load; a missing library only makes
/// its `require()` fail.
const scriptModuleFiles = {
  'sandbox': 'sandbox.js',
  'chai': 'chai.js',
  'lodash': 'lodash.min.js',
  'crypto-js': 'crypto-js.js',
  'moment': 'moment.min.js',
  'uuid': 'uuid.min.js',
  'tv4': 'tv4.js',
  'ajv': 'ajv.min.js',
  'handlebars': 'handlebars.min.js',
};

/// Environment variable naming a folder with the script files, for a CLI
/// installed away from the app bundle.
const scriptAssetsEnvironmentVariable = 'APIWORKBENCH_SCRIPT_ASSETS';

/// The first folder holding `sandbox.js`: [preferred], then
/// [scriptAssetsEnvironmentVariable], then the Flutter bundle around the
/// executable (the app itself, or the CLI in the bundle's `bin` folder),
/// then `assets/js` under the current directory and above the running
/// script (a source checkout).
String? findScriptAssetDir([String? preferred]) {
  final sep = Platform.pathSeparator;
  String join(List<String> parts) => parts.join(sep);
  final exe = File(Platform.resolvedExecutable).parent.path;
  final env = Platform.environment[scriptAssetsEnvironmentVariable];
  const flutterAssets = ['flutter_assets', 'assets', 'js'];
  final candidates = [
    ?preferred,
    if (env != null && env.isNotEmpty) env,
    join([exe, 'data', ...flutterAssets]), // Linux and Windows app
    join([exe, '..', 'data', ...flutterAssets]), // CLI in <bundle>/bin
    join([
      exe,
      '..',
      'Frameworks',
      'App.framework',
      'Resources',
      ...flutterAssets,
    ]),
    join([exe, 'Frameworks', 'App.framework', ...flutterAssets]), // iOS
    join([exe, 'assets', 'js']),
    join([Directory.current.path, 'assets', 'js']),
    if (Platform.script.scheme == 'file')
      join([File.fromUri(Platform.script).parent.parent.path, 'assets', 'js']),
  ];
  for (final dir in candidates) {
    if (File(join([dir, 'sandbox.js'])).existsSync()) return dir;
  }
  return null;
}

/// A loader reading `assets/js/<file>` keys from [dir].
ScriptAssetLoader fileAssetLoader(String dir) => (key) {
  final name = key.split('/').last;
  return File('$dir${Platform.pathSeparator}$name').readAsString();
};
