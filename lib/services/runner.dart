import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'assertions.dart';
import 'captures.dart';
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
  RunnerService(this._http, {this.maxResults = 200}) : assert(maxResults > 0);

  final int maxResults;
  bool _disposed = false;
  bool _starting = false;
  int _generation = 0;

  final HttpService _http;
  final String _runId = newId();

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

  Future<void> start({
    required List<RequestModel> requests,
    required Map<String, String> vars,
    int iterations = 1,
    Duration delayBetween = Duration.zero,
    Duration? repeatEvery, // recurring mode: iterate forever until stopped
    List<Map<String, String>>? dataRows, // per-iteration variable overrides
  }) async {
    if (_disposed || _starting || requests.isEmpty) return;
    _starting = true;
    final generation = ++_generation;
    if (dataRows != null && dataRows.isNotEmpty && repeatEvery == null) {
      iterations = dataRows.length; // one pass per data row
    }
    running = true;
    results.clear();
    total = passed = _totalMs = minMs = maxMs = 0;
    currentIteration = 0;
    notifyListeners();

    while (running) {
      currentIteration++;
      // Data-driven runs: merge this iteration's row over the environment
      // (rows cycle in recurring mode).
      // Copied per iteration: captured values chain into later requests of
      // the same pass without leaking into the next data row.
      final iterVars = (dataRows == null || dataRows.isEmpty)
          ? {...vars}
          : {...vars, ...dataRows[(currentIteration - 1) % dataRows.length]};
      for (final req in requests) {
        if (!running) break;
        final res = await _http.send(req, iterVars, tabId: 'runner-$_runId');
        if (!running || _disposed || generation != _generation) break;
        final assertions = evaluateAssertions(req, res);
        if (res.error == null && req.captures.isNotEmpty) {
          iterVars.addAll(captureValues(req.captures, res));
        }
        // The runner displays metadata and assertions, never response bodies.
        final summary = ResponseData(
          statusCode: res.statusCode,
          statusMessage: res.statusMessage,
          durationMs: res.durationMs,
          error: res.error,
          protocol: res.protocol,
        );
        final result = RunResult(
          request: req,
          iteration: currentIteration,
          response: summary,
          assertions: assertions,
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
