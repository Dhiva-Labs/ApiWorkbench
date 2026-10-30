import 'package:args/args.dart';

import 'errors.dart';
import 'version.dart';

export 'errors.dart' show UsageError;

/// Names of the reporters `-r` accepts.
const reporterNames = ['cli', 'json', 'junit', 'html'];

/// Everything `apiworkbench-cli run` was asked to do.
class RunOptions {
  RunOptions({
    required this.file,
    this.collection,
    this.environment,
    this.globals,
    this.envVars = const {},
    this.globalVars = const {},
    this.iterationData,
    this.iterationCount,
    this.folders = const [],
    this.delayRequestMs = 0,
    this.timeoutRequestMs,
    this.bail = false,
    this.insecure = false,
    this.reporters = const ['cli'],
    this.exports = const {},
    this.color = true,
    this.verbose = false,
  });

  /// Workspace export or Postman file to run.
  final String file;

  /// Name (or id) of the collection to run when [file] holds several.
  final String? collection;

  /// Environment file, or the name of an environment inside [file].
  final String? environment;
  final String? globals;
  final Map<String, String> envVars;
  final Map<String, String> globalVars;
  final String? iterationData;

  /// Null: one iteration per data row, or one without data.
  final int? iterationCount;
  final List<String> folders;
  final int delayRequestMs;
  final int? timeoutRequestMs;
  final bool bail;
  final bool insecure;
  final List<String> reporters;

  /// Reporter name → file path, for the reporters given one.
  final Map<String, String> exports;
  final bool color;
  final bool verbose;
}

/// What the command line asked for, before any file is read.
sealed class Command {
  const Command();
}

class ShowHelp extends Command {
  const ShowHelp(this.text);
  final String text;
}

class ShowVersion extends Command {
  const ShowVersion();
}

class Run extends Command {
  const Run(this.options);
  final RunOptions options;
}

ArgParser _runParser() => ArgParser(usageLineLength: 88)
  ..addOption(
    'collection',
    valueHelp: 'name',
    help:
        'Which collection to run when the file has several (name or id).\n'
        'Needed only for a workspace export or Postman dump.',
  )
  ..addSeparator('Variables:')
  ..addOption(
    'environment',
    abbr: 'e',
    valueHelp: 'file',
    help:
        'Environment to use: a Postman environment or ApiWorkbench workspace '
        'file, or the name of an environment inside the input file.',
  )
  ..addOption(
    'globals',
    abbr: 'g',
    valueHelp: 'file',
    help: 'Postman globals file (or a file with one environment).',
  )
  ..addMultiOption(
    'env-var',
    valueHelp: 'key=value',
    help: 'Set an environment variable, over the file\'s. Repeatable.',
  )
  ..addMultiOption(
    'global-var',
    valueHelp: 'key=value',
    help: 'Set a global variable, over the file\'s. Repeatable.',
  )
  ..addOption(
    'iteration-data',
    abbr: 'd',
    valueHelp: 'file',
    help:
        'CSV or JSON data file: one iteration per row, each column a '
        '{{variable}}.',
  )
  ..addSeparator('Run control:')
  ..addOption(
    'iteration-count',
    abbr: 'n',
    valueHelp: 'count',
    help:
        'How many times to run the collection. With a data file the default '
        'is one per row; more than the rows cycles through them.',
  )
  ..addMultiOption(
    'folder',
    valueHelp: 'path',
    help:
        'Run only this folder (and the folders inside it), like "Orders" or '
        '"Orders/Refunds". Repeatable.',
  )
  ..addOption(
    'delay-request',
    valueHelp: 'ms',
    help: 'Wait this long after each request.',
    defaultsTo: '0',
  )
  ..addOption(
    'timeout-request',
    valueHelp: 'ms',
    help: 'Give up on a request after this long (default: the app\'s limits).',
  )
  ..addFlag(
    'bail',
    negatable: false,
    help: 'Stop the run at the first failed request.',
  )
  ..addFlag(
    'insecure',
    negatable: false,
    help: 'Accept self-signed or invalid TLS certificates.',
  )
  ..addSeparator('Output:')
  ..addMultiOption(
    'reporters',
    abbr: 'r',
    valueHelp: reporterNames.join(','),
    help: 'Reporters to use, comma separated.',
    defaultsTo: const ['cli'],
    splitCommas: true,
  )
  ..addOption(
    'reporter-json-export',
    valueHelp: 'file',
    help: 'Where the json reporter writes (implies -r json).',
  )
  ..addOption(
    'reporter-junit-export',
    valueHelp: 'file',
    help: 'Where the junit reporter writes (implies -r junit).',
  )
  ..addOption(
    'reporter-html-export',
    valueHelp: 'file',
    help: 'Where the html reporter writes (implies -r html).',
  )
  ..addFlag(
    'color',
    defaultsTo: true,
    help: 'Use colors in the cli reporter (when writing to a terminal).',
  )
  ..addFlag(
    'verbose',
    negatable: false,
    help: 'Show response headers and bodies in the cli reporter.',
  )
  ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');

ArgParser _parser() => ArgParser(usageLineLength: 88)
  ..addFlag('version', negatable: false, help: 'Print the version.')
  ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.')
  ..addCommand('run', _runParser());

/// The text of `--help`.
String usageText() {
  final run = _runParser();
  return '''
$cliName $cliVersion
Run an ApiWorkbench or Postman collection from the command line.

Usage:
  $cliName run <file> [options]
  $cliName --version

<file> is an ApiWorkbench workspace export, or a Postman collection,
environment or data export.

Options of "run":
${run.usage}

Exit codes:
  0  every request and test passed
  1  a request or test failed
  2  wrong arguments, or a file that cannot be read

Examples:
  $cliName run shop.json -e staging.json -d users.csv
  $cliName run workspace.json --collection "Shop API" --folder Orders --bail
  $cliName run shop.json -r cli,junit --reporter-junit-export results.xml
''';
}

/// Reads the command line. Throws [UsageError] for anything wrong.
Command parseCommandLine(List<String> args) {
  final ArgResults top;
  try {
    top = _parser().parse(args);
  } on FormatException catch (e) {
    throw UsageError(e.message);
  }
  if (top['help'] == true) return ShowHelp(usageText());
  if (top['version'] == true) return const ShowVersion();
  final cmd = top.command;
  if (cmd == null) {
    if (top.rest.isNotEmpty) {
      throw UsageError('Unknown command "${top.rest.first}".');
    }
    throw UsageError('Missing command. Use: $cliName run <file>');
  }
  if (cmd['help'] == true) return ShowHelp(usageText());

  if (cmd.rest.isEmpty) {
    throw UsageError('Missing the collection file. Use: $cliName run <file>');
  }
  if (cmd.rest.length > 1) {
    throw UsageError(
      'Expected one file to run, got ${cmd.rest.length}: '
      '${cmd.rest.join(', ')}.',
    );
  }

  final reporters = <String>[];
  for (final r in cmd['reporters'] as List<String>) {
    final name = r.trim().toLowerCase();
    if (name.isEmpty) continue;
    if (!reporterNames.contains(name)) {
      throw UsageError(
        'Unknown reporter "$r". Choose from: ${reporterNames.join(', ')}.',
      );
    }
    if (!reporters.contains(name)) reporters.add(name);
  }
  final exports = <String, String>{};
  for (final name in ['json', 'junit', 'html']) {
    final path = cmd['reporter-$name-export'] as String?;
    if (path == null) continue;
    if (path.trim().isEmpty) {
      throw UsageError('--reporter-$name-export needs a file name.');
    }
    exports[name] = path;
    if (!reporters.contains(name)) reporters.add(name);
  }
  if (reporters.isEmpty) reporters.add('cli');

  int? number(String name, {int min = 0}) {
    final raw = cmd[name] as String?;
    if (raw == null) return null;
    final n = int.tryParse(raw.trim());
    if (n == null || n < min) {
      throw UsageError(
        '--$name needs a whole number${min > 0 ? ' of at least $min' : ''}, '
        'got "$raw".',
      );
    }
    return n;
  }

  return Run(
    RunOptions(
      file: cmd.rest.single,
      collection: cmd['collection'] as String?,
      environment: cmd['environment'] as String?,
      globals: cmd['globals'] as String?,
      envVars: _pairs('env-var', cmd['env-var'] as List<String>),
      globalVars: _pairs('global-var', cmd['global-var'] as List<String>),
      iterationData: cmd['iteration-data'] as String?,
      iterationCount: number('iteration-count', min: 1),
      folders: [
        for (final f in cmd['folder'] as List<String>)
          if (f.trim().isNotEmpty) f,
      ],
      delayRequestMs: number('delay-request') ?? 0,
      timeoutRequestMs: number('timeout-request', min: 1),
      bail: cmd['bail'] == true,
      insecure: cmd['insecure'] == true,
      reporters: reporters,
      exports: exports,
      color: cmd['color'] == true,
      verbose: cmd['verbose'] == true,
    ),
  );
}

Map<String, String> _pairs(String option, List<String> values) {
  final out = <String, String>{};
  for (final v in values) {
    final eq = v.indexOf('=');
    if (eq <= 0) {
      throw UsageError('--$option needs key=value, got "$v".');
    }
    out[v.substring(0, eq).trim()] = v.substring(eq + 1);
  }
  return out;
}
