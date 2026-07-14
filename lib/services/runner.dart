import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'assertions.dart';
import 'http_service.dart';

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

String _plain(Object? v) =>
    v is String ? v : v == null ? '' : jsonEncode(v);

class RunResult {
  RunResult({
    required this.request,
    required this.iteration,
    required this.response,
    required this.assertions,
    required this.at,
  });

  final RequestModel request;
  final int iteration; // 1-based pass number
  final ResponseData response;
  final List<AssertionResult> assertions;
  final DateTime at;

  /// Success = transport worked, every assertion passed, and — when the
  /// request defines no assertions — the status is not 4xx/5xx.
  bool get pass {
    if (response.error != null) return false;
    if (assertions.isNotEmpty) return assertions.every((a) => a.pass);
    return response.statusCode < 400;
  }
}

/// Runs a list of requests sequentially: a fixed number of iterations, or
/// recurring passes on an interval until [stop] is called.
class RunnerService extends ChangeNotifier {
  RunnerService(this._http);

  final HttpService _http;
  final String _runId = newId();

  final List<RunResult> results = [];
  bool running = false;
  int currentIteration = 0;
  DateTime? nextPassAt; // set while waiting between recurring passes

  int get passed => results.where((r) => r.pass).length;
  int get failed => results.length - passed;

  int get avgMs => results.isEmpty
      ? 0
      : results.map((r) => r.response.durationMs).reduce((a, b) => a + b) ~/
          results.length;

  int get minMs => results.isEmpty
      ? 0
      : results.map((r) => r.response.durationMs).reduce((a, b) => a < b ? a : b);

  int get maxMs => results.isEmpty
      ? 0
      : results.map((r) => r.response.durationMs).reduce((a, b) => a > b ? a : b);

  Future<void> start({
    required List<RequestModel> requests,
    required Map<String, String> vars,
    int iterations = 1,
    Duration delayBetween = Duration.zero,
    Duration? repeatEvery, // recurring mode: iterate forever until stopped
    List<Map<String, String>>? dataRows, // per-iteration variable overrides
  }) async {
    if (running || requests.isEmpty) return;
    if (dataRows != null && dataRows.isNotEmpty && repeatEvery == null) {
      iterations = dataRows.length; // one pass per data row
    }
    running = true;
    results.clear();
    currentIteration = 0;
    notifyListeners();

    while (running) {
      currentIteration++;
      // Data-driven runs: merge this iteration's row over the environment
      // (rows cycle in recurring mode).
      final iterVars = (dataRows == null || dataRows.isEmpty)
          ? vars
          : {...vars, ...dataRows[(currentIteration - 1) % dataRows.length]};
      for (final req in requests) {
        if (!running) break;
        final res = await _http.send(req, iterVars, tabId: 'runner-$_runId');
        if (!running) break; // stopped mid-flight: drop the cancelled result
        results.add(RunResult(
          request: req,
          iteration: currentIteration,
          response: res,
          assertions: evaluateAssertions(req, res),
          at: DateTime.now(),
        ));
        notifyListeners();
        if (delayBetween > Duration.zero && running) {
          await Future<void>.delayed(delayBetween);
        }
      }

      final morePlanned =
          repeatEvery != null || currentIteration < iterations;
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

    running = false;
    nextPassAt = null;
    notifyListeners();
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
    super.dispose();
  }
}
