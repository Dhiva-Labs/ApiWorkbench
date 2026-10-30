import 'format.dart';
import 'report.dart';

/// JUnit XML that CI systems (Jenkins, GitLab, GitHub test reporters, ...)
/// read: one test suite per request sent, one test case per assertion and
/// script test. A request without checks is one case, "Status code below
/// 400", so every request shows up. A request that got no response is an
/// error; a failed check is a failure.
String renderJunit(RunReport r) {
  final suites = StringBuffer();
  var tests = 0, failures = 0, errors = 0, skipped = 0;
  for (final s in r.steps) {
    final cases = _cases(r, s);
    final suiteTests = cases.length;
    final suiteFailures = cases.where((c) => c.kind == _Kind.failure).length;
    final suiteErrors = cases.where((c) => c.kind == _Kind.error).length;
    final suiteSkipped = cases.where((c) => c.kind == _Kind.skipped).length;
    tests += suiteTests;
    failures += suiteFailures;
    errors += suiteErrors;
    skipped += suiteSkipped;
    final suiteName = r.iterationsPlanned > 1
        ? '${s.name} [iteration ${s.iteration}]'
        : s.name;
    suites.writeln(
      '  <testsuite name="${xmlEscape(suiteName)}" tests="$suiteTests" '
      'failures="$suiteFailures" errors="$suiteErrors" '
      'skipped="$suiteSkipped" time="${seconds(s.durationMs)}" '
      'timestamp="${s.at.toUtc().toIso8601String()}">',
    );
    for (var i = 0; i < cases.length; i++) {
      final c = cases[i];
      // The request's time goes on its first case, so the cases add up.
      final time = seconds(i == 0 ? s.durationMs : 0);
      final open =
          '    <testcase classname="${xmlEscape(_classname(r, s))}" '
          'name="${xmlEscape(c.name)}" time="$time"';
      switch (c.kind) {
        case _Kind.pass:
          suites.writeln('$open/>');
        case _Kind.skipped:
          suites.writeln(
            '$open><skipped message="${xmlEscape(c.text)}"/>'
            '</testcase>',
          );
        case _Kind.failure || _Kind.error:
          final tag = c.kind == _Kind.failure ? 'failure' : 'error';
          suites.writeln(
            '$open><$tag message="${xmlEscape(clip(c.text, 300))}" '
            'type="${xmlEscape(c.type)}">${xmlEscape(c.text)}</$tag>'
            '</testcase>',
          );
      }
    }
    suites.writeln('  </testsuite>');
  }
  return '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<testsuites name="${xmlEscape(r.collectionName)}" tests="$tests" '
      'failures="$failures" errors="$errors" skipped="$skipped" '
      'time="${seconds(r.durationMs)}">\n$suites</testsuites>\n';
}

enum _Kind { pass, failure, error, skipped }

class _Case {
  const _Case(this.name, this.kind, {this.type = '', this.text = ''});
  final String name;
  final _Kind kind;
  final String type;
  final String text;
}

/// "Collection.Folder.Sub", the grouping JUnit viewers show.
String _classname(RunReport r, StepResult s) => [
  r.collectionName,
  if (s.folder.isNotEmpty) ...s.folder.split('/'),
].join('.');

List<_Case> _cases(RunReport r, StepResult s) {
  if (s.skipped) {
    return [
      _Case('Request', _Kind.skipped, text: 'Skipped by a pre-request script.'),
    ];
  }
  final out = <_Case>[];
  if (s.error != null) {
    out.add(
      _Case('Request', _Kind.error, type: 'RequestError', text: s.error!),
    );
  }
  if (s.scriptError != null && !(s.error ?? '').contains(s.scriptError!)) {
    out.add(
      _Case('Script', _Kind.error, type: 'ScriptError', text: s.scriptError!),
    );
  }
  for (final a in s.assertions) {
    out.add(
      a.pass
          ? _Case(a.name, _Kind.pass)
          : _Case(
              a.name,
              _Kind.failure,
              type: 'AssertionError',
              text: a.message.isEmpty ? a.name : a.message,
            ),
    );
  }
  for (final t in s.tests) {
    out.add(
      t.pass
          ? _Case(t.name, _Kind.pass)
          : _Case(
              t.name,
              _Kind.failure,
              type: 'TestError',
              text: t.message.isEmpty ? t.name : t.message,
            ),
    );
  }
  if (s.assertions.isEmpty && s.tests.isEmpty && s.error == null) {
    final ok = s.status < 400;
    out.add(
      ok
          ? const _Case('Status code below 400', _Kind.pass)
          : _Case(
              'Status code below 400',
              _Kind.failure,
              type: 'StatusError',
              text: 'The status was ${s.status} ${s.statusMessage}'.trim(),
            ),
    );
  }
  return out;
}
