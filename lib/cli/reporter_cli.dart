import '../services/console_events.dart';
import 'format.dart';
import 'report.dart';
import 'version.dart';

/// Terminal colors, switched on or off as a whole.
class Ansi {
  const Ansi(this.enabled);
  final bool enabled;

  String _wrap(String code, String s) =>
      enabled ? '\u001B[${code}m$s\u001B[0m' : s;
  String green(String s) => _wrap('32', s);
  String red(String s) => _wrap('31', s);
  String yellow(String s) => _wrap('33', s);
  String dim(String s) => _wrap('2', s);
  String bold(String s) => _wrap('1', s);
}

/// Symbols for the output. Old Windows consoles cannot show the Unicode
/// ones, so they get plain ASCII.
class Glyphs {
  const Glyphs({required this.unicode});
  final bool unicode;

  String get ok => unicode ? '✓' : 'ok';
  String get fail => unicode ? '✗' : 'x';
  String get request => unicode ? '→' : '>';
  String get folder => unicode ? '❏' : '#';
  String get log => unicode ? '»' : '>>';
}

/// Newman-style progress while the run goes (one block per request), then
/// the summary table and the failures.
class CliReporter {
  CliReporter(
    this._out, {
    required bool color,
    required bool unicode,
    required this.verbose,
  }) : a = Ansi(color),
       g = Glyphs(unicode: unicode),
       _unicode = unicode;

  final StringSink _out;
  final bool verbose;
  final Ansi a;
  final Glyphs g;
  final bool _unicode;

  String? _folder;
  bool _first = true;

  void _line([String s = '']) => _out.writeln(s);

  void start(String collection, {String? environment, int rows = 0}) {
    _line(a.bold('$cliName $cliVersion'));
    _line();
    _line(a.bold(collection));
    final extra = [
      if (environment != null) 'environment: $environment',
      if (rows > 0) 'data: $rows rows',
    ];
    if (extra.isNotEmpty) _line(a.dim(extra.join('  ')));
  }

  void iteration(int n, int count) {
    _folder = null;
    _first = true;
    if (count > 1) {
      _line();
      _line(a.bold('Iteration $n/$count'));
    }
  }

  void step(StepResult s) {
    if (_first || s.folder != _folder) {
      _line();
      _first = false;
      if (s.folder.isNotEmpty) {
        _line('${g.folder} ${a.bold(folderLabel(s.folder))}');
      }
      _folder = s.folder;
    }
    final indent = s.folder.isEmpty ? '' : '  ';
    final p = '$indent  ';
    _line('$indent${g.request} ${s.name}');
    if (s.skipped) {
      _line('$p${a.dim('skipped by a pre-request script')}');
      return;
    }
    final String result;
    if (s.error != null) {
      result = a.red('errored');
    } else {
      final text =
          '${s.status}${s.statusMessage.isEmpty ? '' : ' ${s.statusMessage}'}, '
          '${formatBytes(s.sizeBytes)}, ${formatMs(s.durationMs)}';
      result = s.status >= 400 ? a.yellow(text) : text;
    }
    _line('$p${a.dim('${s.method} ${s.url}')} [$result]');

    for (final l in s.logs) {
      _line('$p${_logLine(l)}');
    }
    if (verbose && s.error == null) {
      s.headers.forEach((k, v) {
        for (final value in v) {
          _line('$p${a.dim('< $k: $value')}');
        }
      });
      final body = s.body;
      if (body != null && body.isNotEmpty) {
        for (final line in clip(body, 2000).split('\n')) {
          _line('$p${a.dim('| ${line.trimRight()}')}');
        }
      }
    }
    for (final c in [...s.assertions, ...s.tests]) {
      _check(p, c);
    }
    for (final f in s.failures) {
      if (f.type == 'RequestError' ||
          f.type == 'ScriptError' ||
          f.type == 'StatusError') {
        _line('$p${a.red('${g.fail} ${f.message}')}');
      }
    }
  }

  String _logLine(ConsoleLine l) {
    final text = '${g.log} ${l.message}';
    return switch (l.level) {
      ConsoleLevel.error => a.red(text),
      ConsoleLevel.warn => a.yellow(text),
      _ => a.dim(text),
    };
  }

  void _check(String p, CheckOutcome c) {
    if (c.pass) {
      _line('$p${a.green(g.ok)} ${c.name}');
    } else {
      final why = c.message.isEmpty ? '' : ' - ${c.message}';
      _line('$p${a.red('${g.fail} ${c.name}$why')}');
    }
  }

  /// The summary table, run totals and the failures.
  void finish(RunReport r, {List<String> wrote = const []}) {
    _line();
    _table([
      ['iterations', r.iterationsRun, r.iterationsFailed],
      ['requests', r.sent.length, r.requestsFailed],
      ['tests', r.testsTotal, r.testsFailed],
      ['assertions', r.assertionsTotal, r.assertionsFailed],
    ]);
    _line();
    _line('total run duration: ${formatMs(r.durationMs)}');
    _line('total data received: ${formatBytes(r.receivedBytes)}');
    if (r.sent.isNotEmpty) {
      _line(
        'average response time: ${formatMs(r.avgMs)} '
        '[min: ${formatMs(r.minMs)}, max: ${formatMs(r.maxMs)}]',
      );
    }
    if (r.bailed) {
      _line();
      _line(a.yellow('Stopped at the first failure (--bail).'));
    }

    final failures = [
      for (final s in r.steps)
        for (final f in s.failures) (s, f),
    ];
    if (failures.isNotEmpty) {
      _line();
      _line(a.red(a.bold('FAILURES (${failures.length})')));
      for (var i = 0; i < failures.length; i++) {
        final (s, f) = failures[i];
        final where = [
          '"${s.name}"',
          if (s.folder.isNotEmpty) '(${folderLabel(s.folder)})',
          if (r.iterationsPlanned > 1) 'iteration ${s.iteration}',
        ].join(' ');
        _line();
        _line(
          '${(i + 1).toString().padLeft(3)}. ${a.red(f.type)}  ${f.message}',
        );
        _line('     ${a.dim('in $where')}');
        if (f.detail.isNotEmpty) _line('     ${f.detail}');
      }
    }
    for (final w in wrote) {
      _line();
      _line(w);
    }
    _line();
    _line(
      r.passed
          ? a.green('${g.ok} All checks passed.')
          : a.red('${g.fail} The run failed.'),
    );
  }

  void _table(List<List<Object>> rows) {
    final labelW = rows.map((r) => (r[0] as String).length).reduce(_max);
    const numW = 8;
    final fill = _unicode ? '─' : '-';
    String sep(String l, String m, String r) {
      if (!_unicode) l = m = r = '+';
      return '$l${fill * (labelW + 2)}$m${fill * (numW + 2)}'
          '$m${fill * (numW + 2)}$r';
    }

    final v = _unicode ? '│' : '|';
    String num(String x) => ' ${x.padLeft(numW)} ';
    _line(sep('┌', '┬', '┐'));
    _line('$v${' ' * (labelW + 2)}$v${num('executed')}$v${num('failed')}$v');
    for (final r in rows) {
      _line(sep('├', '┼', '┤'));
      final failed = '${r[2]}'.padLeft(numW);
      _line(
        '$v ${(r[0] as String).padLeft(labelW)} $v${num('${r[1]}')}$v '
        '${(r[2] as int) > 0 ? a.red(failed) : failed} $v',
      );
    }
    _line(sep('└', '┴', '┘'));
  }

  static int _max(int a, int b) => a > b ? a : b;
}
