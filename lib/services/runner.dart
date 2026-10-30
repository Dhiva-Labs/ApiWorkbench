import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'console_events.dart';
import 'executor.dart';
import 'http_service.dart';
import 'scripting/script_engine.dart';
import 'var_scopes.dart';

/// Parses user-supplied data rows for data-driven runs.
/// Accepts a JSON array of flat objects: [{"id": 1, "name": "a"}, …].
/// Returns null when the input is not parseable into rows.
List<Map<String, String>>? parseDataRows(String input) {
  final raw = input.trim();
  if (raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List || decoded.isEmpty) return null;
    final rows = <Map<String, String>>[];
    for (final item in decoded) {
      if (item is! Map) return null;
      rows.add({
        for (final e in item.entries) e.key.toString(): _plain(e.value),
      });
    }
    return rows;
  } catch (_) {
    return null;
  }
}

String _plain(Object? v) => v is String
    ? v
    : v == null
    ? ''
    : jsonEncode(v);

class RunResult {
  RunResult({
    required this.request,
    required this.iteration,
    required this.response,
    required this.assertions,
    required this.at,
    this.scriptTests = const [],
    this.scriptError,
    this.skipped = false,
  });

  final RequestModel request;
  final int iteration; // 1-based pass number
  final ResponseData response;
  final List<AssertionResult> assertions;
  final List<ScriptTestResult> scriptTests;
  final String? scriptError;
  final bool skipped;
  final DateTime at;

  /// Success = transport worked, no script failed, every check passed, and
  /// — when the request defines no checks — the status is not 4xx/5xx.
  bool get pass {
    if (skipped) return true;
    if (response.error != null || scriptError != null) return false;
    if (assertions.isEmpty && scriptTests.isEmpty) {
      return response.statusCode < 400;
    }
    return assertions.every((a) => a.pass) && scriptTests.every((t) => t.pass);
  }
}

/// Runs a list of requests sequentially: a fixed number of iterations, or
/// recurring passes on an interval until [stop] is called. Scripts can
/// change the order with `postman.setNextRequest`.
class RunnerService extends ChangeNotifier {
  RunnerService(HttpService http, {this.maxResults = 200, ScriptEngine? engine})
    : assert(maxResults > 0),
      _http = http,
      _executor = RequestExecutor(http, engine: engine);

  final int maxResults;
  bool _disposed = false;
  bool _starting = false;
  int _generation = 0;

  final HttpService _http;
  final RequestExecutor _executor;
  final String _runId = newId();

  /// Jumps allowed per pass, so a setNextRequest loop cannot run forever.
  static const maxStepsPerPass = 10000;

  final List<RunResult> results = [];
  bool running = false;
  int currentIteration = 0;
  DateTime? nextPassAt; // set while waiting between recurring passes

  int total = 0;
  int passed = 0;
  int _totalMs = 0;
  int minMs = 0;
  int maxMs = 0;
  int get failed => total - passed;
  int get avgMs => total == 0 ? 0 : _totalMs ~/ total;

  /// Runs [requests]. Variables come from [scopes] (live: script and
  /// capture writes land in the environment, collection and globals, like
  /// Postman's "keep variable values") or, without scopes, from a copy of
  /// [vars] that the run may change.
  Future<void> start({
    required List<RequestModel> requests,
    Map<String, String> vars = const {},
    VarScopes? scopes,
    CollectionModel? collection,
    int iterations = 1,
    Duration delayBetween = Duration.zero,
    Duration? repeatEvery, // recurring mode: iterate forever until stopped
    List<Map<String, String>>? dataRows, // per-iteration variable overrides
    void Function(ExecResult result, VarScopes scopes)? onResult,
  }) async {
    requests = requests.where((r) => r.kind == RequestKind.http).toList();
    if (_disposed || _starting || requests.isEmpty) return;
    _starting = true;
    final generation = ++_generation;
    if (dataRows != null && dataRows.isNotEmpty && repeatEvery == null) {
      iterations = dataRows.length; // one pass per data row
    }
    final runScopes = scopes ?? VarScopes(session: {...vars});
    running = true;
    results.clear();
    total = passed = _totalMs = minMs = maxMs = 0;
    currentIteration = 0;
    notifyListeners();

    while (running) {
      currentIteration++;
      // Data-driven runs: this iteration's row sits above the environment
      // (rows cycle in recurring mode).
      runScopes.data
        ..clear()
        ..addAll(
          (dataRows == null || dataRows.isEmpty)
              ? const {}
              : dataRows[(currentIteration - 1) % dataRows.length],
        );
      var index = 0;
      var steps = 0;
      while (running && index < requests.length && steps++ < maxStepsPerPass) {
        final req = requests[index];
        final exec = await _executor.execute(
          req,
          ExecContext(
            scopes: runScopes,
            collection: collection,
            tabId: 'runner-$_runId',
            source: 'runner',
            iteration: currentIteration - 1,
            iterationCount: repeatEvery == null ? iterations : 0,
          ),
        );
        if (!running || _disposed || generation != _generation) break;
        onResult?.call(exec, runScopes);
        final res = exec.response;
        // The runner displays metadata and assertions, never response bodies.
        final result = RunResult(
          request: req,
          iteration: currentIteration,
          response: responseSummary(res),
          assertions: exec.assertions,
          scriptTests: exec.scriptTests,
          scriptError: exec.scriptError,
          skipped: exec.skipped,
          at: DateTime.now(),
        );
        total++;
        if (result.pass) passed++;
        _totalMs += res.durationMs;
        if (total == 1 || res.durationMs < minMs) minMs = res.durationMs;
        if (res.durationMs > maxMs) maxMs = res.durationMs;
        if (results.length == maxResults) results.removeAt(0);
        results.add(result);
        notifyListeners();
        if (delayBetween > Duration.zero && running) {
          await Future<void>.delayed(delayBetween);
        }
        index = _nextIndex(requests, index, exec.next);
      }

      final morePlanned = repeatEvery != null || currentIteration < iterations;
      if (!running || !morePlanned) break;

      if (repeatEvery != null) {
        nextPassAt = DateTime.now().add(repeatEvery);
        notifyListeners();
        // Sleep in short slices so Stop reacts quickly.
        while (running && DateTime.now().isBefore(nextPassAt!)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        nextPassAt = null;
      }
    }

    _starting = false;
    if (_disposed) return;
    running = false;
    nextPassAt = null;
    notifyListeners();
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

  void stop() {
    if (!running) return;
    running = false;
    _http.cancel('runner-$_runId');
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    _disposed = true;
    results.clear();
    super.dispose();
  }
}
