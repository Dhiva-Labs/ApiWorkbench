import 'dart:async';

import '../models/models.dart';
import '../services/console_events.dart';
import '../services/doc_export.dart' show maskSecrets;
import '../services/executor.dart';
import '../services/http_service.dart';
import '../services/scripting/script_engine.dart';
import '../services/var_scopes.dart';
import 'loader.dart';
import 'report.dart';

/// How a run is paced and when it stops.
class RunSettings {
  const RunSettings({
    this.iterationCount,
    this.delay = Duration.zero,
    this.timeout,
    this.bail = false,
  });

  /// Null: one iteration per data row, or a single one without data.
  final int? iterationCount;

  /// Wait after each request.
  final Duration delay;

  /// Longest a request may take (null: the HTTP service's own limits).
  final Duration? timeout;

  /// Stop at the first failed request.
  final bool bail;
}

/// Runs a collection like the app's collection runner (the same executor,
/// variable scopes, data rows and `setNextRequest`), without Flutter.
class CliRunner {
  CliRunner(this.http, {this.engine, this.secrets = const {}});

  final HttpService http;
  final ScriptEngine? engine;

  /// Values of secret variables, masked in everything the run reports.
  final Set<String> secrets;

  /// Jumps allowed per pass, so a setNextRequest loop cannot run forever.
  static const maxStepsPerPass = 10000;
  static const _tabId = 'cli-run';

  Future<RunReport> run(
    LoadedRun input,
    RunSettings settings, {
    void Function(int iteration, int count)? onIteration,
    void Function(StepResult step)? onStep,
    List<String> warnings = const [],
  }) async {
    final executor = RequestExecutor(http, engine: engine);
    final scopes = VarScopes(
      globals: input.globals,
      collection: input.collection.variables,
      environment: input.environment,
    );
    final requests = input.requests;
    final data = input.data;
    final iterations =
        settings.iterationCount ?? (data.isEmpty ? 1 : data.length);
    final steps = <StepResult>[];
    final startedAt = DateTime.now();
    final clock = Stopwatch()..start();
    var bailed = false;

    passes:
    for (var iteration = 1; iteration <= iterations; iteration++) {
      // This iteration's data row sits above the environment; rows cycle
      // when more iterations than rows are asked for.
      scopes.data
        ..clear()
        ..addAll(data.isEmpty ? const {} : data[(iteration - 1) % data.length]);
      onIteration?.call(iteration, iterations);

      var index = 0;
      var jumps = 0;
      while (index < requests.length && jumps++ < maxStepsPerPass) {
        final req = requests[index];
        final fallbackUrl = substituteVars(req.url, scopes.resolve());
        var timedOut = false;
        Timer? timer;
        final limit = settings.timeout;
        if (limit != null) {
          timer = Timer(limit, () {
            timedOut = true;
            http.cancel(_tabId);
            http.cancel('$_tabId-script');
          });
        }
        final ExecResult exec;
        try {
          exec = await executor.execute(
            req,
            ExecContext(
              scopes: scopes,
              collection: input.collection,
              tabId: _tabId,
              source: 'cli',
              iteration: iteration - 1,
              iterationCount: iterations,
              record: false,
            ),
          );
        } finally {
          timer?.cancel();
        }
        final step = _step(
          req,
          exec,
          iteration,
          fallbackUrl,
          timedOut ? limit : null,
        );
        steps.add(step);
        onStep?.call(step);

        if (settings.bail && !step.pass) {
          bailed = true;
          break passes;
        }
        if (settings.delay > Duration.zero) {
          await Future<void>.delayed(settings.delay);
        }
        index = _nextIndex(requests, index, exec.next);
      }
    }
    clock.stop();
    return RunReport(
      collectionId: input.collection.id,
      collectionName: input.collection.name,
      environmentName: input.environmentName,
      startedAt: startedAt,
      durationMs: clock.elapsedMilliseconds,
      iterationsPlanned: iterations,
      steps: steps,
      bailed: bailed,
      warnings: warnings,
    );
  }

  String _m(String s) => maskSecrets(s, secrets);

  StepResult _step(
    RequestModel req,
    ExecResult exec,
    int iteration,
    String fallbackUrl,
    Duration? timedOut,
  ) {
    final res = exec.response;
    String? error = res.error;
    if (timedOut != null && error != null) {
      error = 'The request timed out after ${timedOut.inMilliseconds} ms.';
    }
    final text = res.error == null && !exec.skipped ? res.bodyText : null;
    final limit = StepResult.bodyLimit;
    final truncated = text != null && text.length > limit;
    return StepResult(
      iteration: iteration,
      id: req.id,
      name: req.name,
      folder: req.folder,
      method: req.method.toUpperCase(),
      url: _m(res.finalUrl ?? fallbackUrl),
      at: DateTime.now(),
      status: res.statusCode,
      statusMessage: res.statusMessage,
      durationMs: res.durationMs,
      sizeBytes: res.sizeBytes,
      headers: {
        for (final e in res.headers.entries)
          e.key: [for (final v in e.value) _m(v)],
      },
      body: text == null
          ? null
          : _m(truncated ? text.substring(0, limit) : text),
      bodyTruncated: truncated,
      error: error == null ? null : _m(error),
      assertions: [
        for (final a in exec.assertions)
          CheckOutcome(_assertionName(a.assertion), a.pass, _m(a.message)),
      ],
      tests: [
        for (final t in exec.scriptTests)
          CheckOutcome(_m(t.name), t.pass, _m(t.error ?? '')),
      ],
      scriptError: exec.scriptError == null ? null : _m(exec.scriptError!),
      skipped: exec.skipped,
      logs: [
        for (final l in exec.logs)
          ConsoleLine(l.level, _m(l.message), at: l.at, source: l.source),
      ],
    );
  }

  static String _assertionName(AssertionModel a) {
    final base = a.kind.hasTarget
        ? '${a.kind.label} ${a.target}'
        : a.kind.label;
    return a.expected.isEmpty ? base : '$base ${a.expected}';
  }

  /// Index of the request after [current]: the one named (or with the id)
  /// in [next], past the end for `setNextRequest(null)` or an unknown name.
  static int _nextIndex(
    List<RequestModel> requests,
    int current,
    NextRequest? next,
  ) {
    if (next == null) return current + 1;
    if (next.stop) return requests.length;
    final byName = requests.indexWhere((r) => r.name == next.nameOrId);
    if (byName >= 0) return byName;
    final byId = requests.indexWhere((r) => r.id == next.nameOrId);
    return byId >= 0 ? byId : requests.length;
  }
}
