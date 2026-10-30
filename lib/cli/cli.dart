import 'dart:io';

import '../models/models.dart';
import '../services/cookie_store.dart';
import '../services/http_service.dart';
import '../services/scripting/engine_factory.dart';
import '../services/scripting/script_engine.dart';
import 'errors.dart';
import 'loader.dart';
import 'options.dart';
import 'report.dart';
import 'reporter_cli.dart';
import 'reporter_html.dart';
import 'reporter_json.dart';
import 'reporter_junit.dart';
import 'runner.dart';
import 'version.dart';

export 'version.dart' show cliName, cliVersion;

/// Runs `apiworkbench-cli` with [args] and returns the exit code: 0 when
/// everything passed, 1 when a request or test failed, 2 for wrong
/// arguments or unreadable files.
///
/// [out] and [err] default to stdout and stderr. [engineFactory] makes the
/// script engine (default: this platform's, which may be none). [env] is the
/// process environment (`NO_COLOR`, `WT_SESSION`). [isTerminal] tells the cli
/// reporter that [out] is a terminal that understands colors.
Future<int> runCli(
  List<String> args, {
  StringSink? out,
  StringSink? err,
  ScriptEngine? Function()? engineFactory,
  Map<String, String>? env,
  bool? isTerminal,
}) async {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;
  try {
    final cmd = parseCommandLine(args);
    switch (cmd) {
      case ShowHelp(:final text):
        stdoutSink.write(text);
        return 0;
      case ShowVersion():
        stdoutSink.writeln(cliVersion);
        return 0;
      case Run(:final options):
        final environment = env ?? Platform.environment;
        final terminal =
            isTerminal ??
            (out == null && stdout.hasTerminal && stdout.supportsAnsiEscapes);
        return await _run(
          options,
          out: stdoutSink,
          err: stderrSink,
          engineFactory: engineFactory ?? createScriptEngine,
          color:
              options.color &&
              terminal &&
              (environment['NO_COLOR'] ?? '').isEmpty,
          unicode:
              !Platform.isWindows ||
              environment.containsKey('WT_SESSION') ||
              environment.containsKey('TERM_PROGRAM'),
        );
    }
  } on UsageError catch (e) {
    stderrSink.writeln('$cliName: ${e.message}');
    stderrSink.writeln("Run '$cliName --help' for usage.");
    return 2;
  } on InputError catch (e) {
    stderrSink.writeln('$cliName: ${e.message}');
    return 2;
  }
}

Future<int> _run(
  RunOptions o, {
  required StringSink out,
  required StringSink err,
  required ScriptEngine? Function() engineFactory,
  required bool color,
  required bool unicode,
}) async {
  final input = loadRun(o);

  final engine = engineFactory();
  final warnings = <String>[];
  if (engine == null && _hasScripts(input)) {
    final w =
        'warning: this collection has scripts, but this build of $cliName '
        'has no script engine, so they are skipped.';
    warnings.add(w);
    err.writeln(w);
  }

  // The same transport as the app, with its defaults; TLS and timeouts
  // follow the options. Cookies live for this run only.
  final timeout = o.timeoutRequestMs;
  final http = HttpService()
    ..configure(
      timeout == null
          ? AppSettings(verifySsl: !o.insecure)
          : AppSettings(
              verifySsl: !o.insecure,
              // The run loop enforces the exact limit; these only keep the
              // transport from giving up earlier.
              connectTimeoutS: (timeout / 1000).ceil() + 1,
              receiveTimeoutS: (timeout / 1000).ceil() + 1,
            ),
    )
    ..cookieJar = PersistentCookieJar();

  final reporter = o.reporters.contains('cli')
      ? CliReporter(out, color: color, unicode: unicode, verbose: o.verbose)
      : null;
  reporter?.start(
    input.collection.name,
    environment: input.environmentName,
    rows: input.data.length,
  );

  final RunReport report;
  try {
    report = await CliRunner(http, engine: engine, secrets: _secrets(input))
        .run(
          input,
          RunSettings(
            iterationCount: o.iterationCount,
            delay: Duration(milliseconds: o.delayRequestMs),
            timeout: timeout == null ? null : Duration(milliseconds: timeout),
            bail: o.bail,
          ),
          onIteration: reporter?.iteration,
          onStep: reporter?.step,
          warnings: warnings,
        );
  } finally {
    engine?.dispose();
    http.dispose();
  }

  final wrote = <String>[];
  Object? writeError;
  for (final name in o.reporters) {
    if (name == 'cli') continue;
    final explicit = o.exports[name];
    final path = explicit ?? _defaultPath(name, report.startedAt);
    try {
      final text = switch (name) {
        'json' => renderJson(report),
        'junit' => renderJunit(report),
        _ => renderHtml(report),
      };
      final file = File(path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(text);
      wrote.add('Wrote the $name report to $path');
    } on FileSystemException catch (e) {
      writeError =
          'Cannot write the $name report to $path: '
          '${e.osError?.message ?? e.message}.';
      err.writeln('$cliName: $writeError');
    }
  }

  if (reporter != null) {
    reporter.finish(report, wrote: wrote);
  } else {
    // With only file reporters, say where the default-named files went.
    for (final w in wrote) {
      if (o.exports.length < o.reporters.length) err.writeln(w);
    }
  }
  if (writeError != null) return 2;
  return report.exitCode;
}

String _defaultPath(String reporter, DateTime at) {
  final t = at.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp =
      '${t.year}${two(t.month)}${two(t.day)}-'
      '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  final ext = reporter == 'junit' ? 'xml' : reporter;
  return 'apiworkbench-reports${Platform.pathSeparator}'
      'apiworkbench-run-$stamp.$ext';
}

/// Values of the variables marked secret, which the reports mask.
Set<String> _secrets(LoadedRun input) => {
  for (final list in [
    input.globals,
    input.collection.variables,
    ?input.environment,
  ])
    for (final v in list)
      if (v.secret) ...[
        if (v.value.isNotEmpty) v.value,
        if ((v.current ?? '').isNotEmpty) v.current!,
      ],
};

/// Whether anything that would run holds a script.
bool _hasScripts(LoadedRun input) {
  final c = input.collection;
  bool has(String pre, String test) =>
      pre.trim().isNotEmpty || test.trim().isNotEmpty;
  return has(c.preRequestScript, c.testScript) ||
      c.folders.values.any((f) => has(f.preRequestScript, f.testScript)) ||
      input.requests.any((r) => has(r.preRequestScript, r.testScript));
}
