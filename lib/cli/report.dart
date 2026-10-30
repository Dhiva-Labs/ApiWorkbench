import '../services/console_events.dart';

/// One declarative assertion or one `pm.test`, with its outcome.
class CheckOutcome {
  const CheckOutcome(this.name, this.pass, this.message);

  /// "Status equals", "JSON field equals data.id", or the test's name.
  final String name;
  final bool pass;

  /// Why it failed or what it found; may be empty.
  final String message;
}

/// What went wrong in a step, for the failures list and the JUnit file.
class Failure {
  const Failure(this.type, this.message, {this.detail = ''});

  /// RequestError, ScriptError, AssertionError, TestError or StatusError.
  final String type;
  final String message;
  final String detail;
}

/// One request sent in one iteration.
class StepResult {
  StepResult({
    required this.iteration,
    required this.id,
    required this.name,
    required this.folder,
    required this.method,
    required this.url,
    required this.at,
    this.status = 0,
    this.statusMessage = '',
    this.durationMs = 0,
    this.sizeBytes = 0,
    this.headers = const {},
    this.body,
    this.bodyTruncated = false,
    this.error,
    this.assertions = const [],
    this.tests = const [],
    this.scriptError,
    this.skipped = false,
    this.logs = const [],
  });

  /// 1-based.
  final int iteration;
  final String id;
  final String name;

  /// Folder path ('' at the top).
  final String folder;
  final String method;
  final String url;
  final DateTime at;
  final int status;
  final String statusMessage;
  final int durationMs;
  final int sizeBytes;
  final Map<String, List<String>> headers;

  /// Response text, up to [bodyLimit] characters; null when none came back.
  final String? body;
  final bool bodyTruncated;

  /// No response: network error, timeout, a request that cannot be built, or
  /// a pre-request script that failed.
  final String? error;
  final List<CheckOutcome> assertions;
  final List<CheckOutcome> tests;
  final String? scriptError;
  final bool skipped;
  final List<ConsoleLine> logs;

  /// Response text kept per step in the reports.
  static const bodyLimit = 1024 * 1024;

  bool get hasResponse => error == null && !skipped;

  /// Same rule as the app's runner: no transport or script error, every
  /// check passed, and with no checks a status below 400.
  bool get pass {
    if (skipped) return true;
    if (error != null || scriptError != null) return false;
    if (assertions.isEmpty && tests.isEmpty) return status < 400;
    return assertions.every((a) => a.pass) && tests.every((t) => t.pass);
  }

  /// What failed, in the order a reader wants it.
  List<Failure> get failures {
    if (pass) return const [];
    final out = <Failure>[];
    if (error != null) out.add(Failure('RequestError', error!));
    if (scriptError != null && !(error ?? '').contains(scriptError!)) {
      out.add(Failure('ScriptError', scriptError!));
    }
    for (final a in assertions.where((a) => !a.pass)) {
      out.add(Failure('AssertionError', a.name, detail: a.message));
    }
    for (final t in tests.where((t) => !t.pass)) {
      out.add(Failure('TestError', t.name, detail: t.message));
    }
    if (out.isEmpty) {
      final shown = '$status $statusMessage'.trim();
      out.add(
        Failure(
          'StatusError',
          'The status was $shown and the request has no tests.',
        ),
      );
    }
    return out;
  }
}

/// A finished run: the steps and the numbers reporters show.
class RunReport {
  RunReport({
    required this.collectionId,
    required this.collectionName,
    required this.environmentName,
    required this.startedAt,
    required this.durationMs,
    required this.iterationsPlanned,
    required this.steps,
    required this.bailed,
    this.warnings = const [],
  });

  final String collectionId;
  final String collectionName;
  final String? environmentName;
  final DateTime startedAt;
  final int durationMs;
  final int iterationsPlanned;
  final List<StepResult> steps;

  /// The run stopped early because `--bail` met a failure.
  final bool bailed;
  final List<String> warnings;

  /// Iterations that sent at least one request.
  int get iterationsRun => steps.map((s) => s.iteration).toSet().length;

  int get iterationsFailed =>
      steps.where((s) => !s.pass).map((s) => s.iteration).toSet().length;

  /// Requests that were sent (skipped ones are not).
  List<StepResult> get sent => [
    for (final s in steps)
      if (!s.skipped) s,
  ];

  int get requestsFailed => sent.where((s) => !s.pass).length;

  int get testsTotal => steps.fold(0, (n, s) => n + s.tests.length);
  int get testsFailed =>
      steps.fold(0, (n, s) => n + s.tests.where((t) => !t.pass).length);
  int get assertionsTotal => steps.fold(0, (n, s) => n + s.assertions.length);
  int get assertionsFailed =>
      steps.fold(0, (n, s) => n + s.assertions.where((a) => !a.pass).length);

  int get receivedBytes => steps.fold(0, (n, s) => n + s.sizeBytes);

  /// Response times of the requests that got a response.
  List<int> get _times => [
    for (final s in sent)
      if (s.hasResponse) s.durationMs,
  ];
  int get avgMs =>
      _times.isEmpty ? 0 : _times.reduce((a, b) => a + b) ~/ _times.length;
  int get minMs => _times.isEmpty ? 0 : _times.reduce((a, b) => a < b ? a : b);
  int get maxMs => _times.isEmpty ? 0 : _times.reduce((a, b) => a > b ? a : b);

  /// The run passed when no step failed.
  bool get passed => steps.every((s) => s.pass);

  /// 0 when everything passed, 1 when something failed.
  int get exitCode => passed ? 0 : 1;
}
