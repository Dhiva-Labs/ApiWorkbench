import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'assertions.dart';
import 'captures.dart';
import 'http_service.dart';
import 'load_log.dart';

export 'load_log.dart';

/// Fixed-size latency histogram: memory stays constant however many requests
/// are recorded (1 ms resolution < 1 s, 10 ms < 10 s, 100 ms < 130 s).
class LatencyHistogram {
  static const _size = 3101;
  final Int32List _buckets = Int32List(_size);
  int count = 0;
  int sumMs = 0;
  int minMs = 0;
  int maxMs = 0;

  static int _index(int ms) {
    if (ms < 1000) return ms < 0 ? 0 : ms;
    if (ms < 10000) return 1000 + (ms - 1000) ~/ 10;
    if (ms < 130000) return 1900 + (ms - 10000) ~/ 100;
    return _size - 1;
  }

  static int _valueOf(int index) {
    if (index < 1000) return index;
    if (index < 1900) return 1000 + (index - 1000) * 10;
    return 10000 + (index - 1900) * 100;
  }

  void record(int ms) {
    _buckets[_index(ms)]++;
    if (count == 0 || ms < minMs) minMs = ms;
    if (ms > maxMs) maxMs = ms;
    count++;
    sumMs += ms;
  }

  double get meanMs => count == 0 ? 0 : sumMs / count;

  /// Approximate [p]th percentile (0–100) in ms.
  int percentile(double p) {
    if (count == 0) return 0;
    final target = max(1, (count * p / 100).ceil());
    var seen = 0;
    for (var i = 0; i < _size; i++) {
      seen += _buckets[i];
      if (seen >= target) return min(_valueOf(i), maxMs);
    }
    return maxMs;
  }
}

/// One request in a load test plus the values to capture from its response.
class LoadStep {
  LoadStep(this.request, {this.enabled = true, Map<String, String>? extract})
    : extract = extract ?? {};

  final RequestModel request;
  bool enabled;

  /// Variable name → source: `body.<path>` (or a bare JSON path such as
  /// `data.items[0].id`), `header.<name>` or `status`. Captured values are
  /// available to later steps as `{{name}}`.
  Map<String, String> extract;
}

class LoadTestConfig {
  LoadTestConfig({
    this.virtualUsers = 5,
    this.iterations = 10,
    this.durationSec = 0,
    this.rampUpSec = 0,
    this.thinkTimeMs = 0,
    this.parallel = false,
    this.stopOnFailure = true,
    this.untilStopped = false,
    this.recordLog = true,
    this.bodies = BodyCapture.failures,
  });

  static const maxVirtualUsers = 1000;

  /// Concurrent simulated users.
  int virtualUsers;

  /// Rounds per user; ignored when [durationSec] > 0.
  int iterations;
  int durationSec;

  /// Users start staggered across this many seconds.
  int rampUpSec;

  /// Pause after each step (sequential) or iteration (parallel).
  int thinkTimeMs;

  /// Fire every step of an iteration at once instead of one by one.
  bool parallel;

  /// Sequential mode: abandon the iteration at the first failing step.
  bool stopOnFailure;

  /// Keep repeating iterations until Stop is pressed (ignores [iterations]
  /// and [durationSec]).
  bool untilStopped;

  /// Write every call to a log that can be saved as a report.
  bool recordLog;

  /// Which response bodies the log keeps (only when [recordLog]).
  BodyCapture bodies;
}

class StepStats {
  StepStats(this.request);
  final RequestModel request;
  final hist = LatencyHistogram();
  int passed = 0;
  int failed = 0;
  final statusCounts = <int, int>{};
  final errors = <String, int>{};

  int get count => hist.count;

  void _record(int status, int ms, bool pass, String? error) {
    hist.record(ms);
    pass ? passed++ : failed++;
    statusCounts[status] = (statusCounts[status] ?? 0) + 1;
    // Keep a handful of distinct messages so memory stays bounded.
    if (error != null && (errors.containsKey(error) || errors.length < 5)) {
      errors[error] = (errors[error] ?? 0) + 1;
    }
  }
}

/// Runs a collection as N concurrent virtual users. Results are aggregated
/// into histograms and counters only, so memory is flat for any run length;
/// listeners are notified at most ~4 times a second.
class LoadTestService extends ChangeNotifier {
  LoadTestService(this._settings, {this.logDir});

  final AppSettings _settings;

  /// Where call logs are written; defaults to the system temp directory.
  final Directory? logDir;
  HttpService? _http;
  final String _runId = newId();
  bool _disposed = false;

  bool running = false;
  bool stopping = false;
  String? error;

  LatencyHistogram _total = LatencyHistogram();
  LatencyHistogram get total => _total;
  List<StepStats> steps = [];
  int iterationsDone = 0;
  int activeUsers = 0;
  int plannedRequests = 0;
  int durationMs = 0;
  bool untilStopped = false;

  /// The last run's call log (null when logging was off). Kept until the
  /// next run or [dispose] so it can be exported after the run.
  LoadLog? log;
  String? logError;
  DateTime? startedAt;
  LoadTestConfig? lastConfig;
  int _seq = 0;

  /// Completed requests / failures per second (oldest first), last 120 s.
  final List<int> perSecond = [];
  final List<int> errorsPerSecond = [];
  static const timelineSeconds = 120;

  final _clock = Stopwatch();
  Timer? _ticker;
  final Set<String> _activeTabs = {};

  int get elapsedMs => _clock.elapsedMilliseconds;
  int get passed => steps.fold(0, (s, x) => s + x.passed);
  int get failed => steps.fold(0, (s, x) => s + x.failed);
  double get requestsPerSecond =>
      elapsedMs <= 0 ? 0 : total.count * 1000 / elapsedMs;
  double get errorRate => total.count == 0 ? 0 : failed / total.count;

  /// 0–1 completion, or null when unknown.
  double? get progress {
    if (!running) return total.count == 0 ? 0 : 1;
    if (untilStopped) return null;
    if (plannedRequests > 0) return min(1, total.count / plannedRequests);
    if (durationMs > 0) return min(1, elapsedMs / durationMs);
    return null;
  }

  Future<void> start({
    required List<LoadStep> plan,
    required LoadTestConfig config,
    required Map<String, String> vars,
  }) async {
    if (running || _disposed) return;
    final active = plan.where((s) => s.enabled).toList();
    error = active.isEmpty ? 'Enable at least one request.' : null;
    if (active.isEmpty) {
      notifyListeners();
      return;
    }

    // A dedicated client so a load run never disturbs open tabs (their
    // cancel tokens or connection pool).
    _http = HttpService()..configure(_settings);
    await log?.delete();
    log = null;
    logError = null;
    if (config.recordLog) {
      try {
        log = await LoadLog.create(
          logDir ??
              Directory(
                '${Directory.systemTemp.path}${Platform.pathSeparator}'
                'apiworkbench-load',
              ),
          config.bodies,
        );
      } catch (e) {
        logError = 'Request log is off: could not create it ($e).';
      }
    }
    if (_disposed) {
      await log?.delete();
      return;
    }
    running = true;
    startedAt = DateTime.now();
    lastConfig = config;
    _seq = 0;
    stopping = false;
    steps = [for (final s in active) StepStats(s.request)];
    _total = LatencyHistogram();
    iterationsDone = 0;
    perSecond.clear();
    errorsPerSecond.clear();
    _timelineStart = 0;
    final users = config.virtualUsers.clamp(1, LoadTestConfig.maxVirtualUsers);
    untilStopped = config.untilStopped;
    durationMs = untilStopped ? 0 : max(0, config.durationSec) * 1000;
    plannedRequests = untilStopped || durationMs > 0
        ? 0
        : users * max<int>(1, config.iterations) * active.length;
    _clock
      ..reset()
      ..start();
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!_disposed) notifyListeners();
    });
    notifyListeners();

    try {
      await Future.wait([
        for (var u = 1; u <= users; u++) _user(u, users, active, config, vars),
      ]);
    } finally {
      _clock.stop();
      _ticker?.cancel();
      _http?.dispose();
      _http = null;
      // Not awaited: readers of the log wait for the close themselves.
      unawaited(log?.close().catchError((_) {}));
      running = false;
      if (!_disposed) notifyListeners();
    }
  }

  bool _keepGoing(int iteration, LoadTestConfig c) {
    if (!running || stopping || _disposed) return false;
    if (untilStopped) return true;
    if (durationMs > 0) return elapsedMs < durationMs;
    return iteration < max(1, c.iterations);
  }

  Future<void> _user(
    int vu,
    int users,
    List<LoadStep> plan,
    LoadTestConfig c,
    Map<String, String> envVars,
  ) async {
    if (c.rampUpSec > 0 && users > 1) {
      await _sleep(c.rampUpSec * 1000 * (vu - 1) ~/ users);
    }
    activeUsers++;
    try {
      for (var it = 0; _keepGoing(it, c); it++) {
        final vars = {...envVars, 'vu': '$vu', 'iteration': '${it + 1}'};
        if (c.parallel) {
          await Future.wait([
            for (var i = 0; i < plan.length; i++)
              _execute(i, plan[i], vars, 'load-$_runId-$vu-$i', vu, it + 1),
          ]);
          await _sleep(c.thinkTimeMs);
        } else {
          for (var i = 0; i < plan.length; i++) {
            if (stopping) break;
            final ok = await _execute(
              i,
              plan[i],
              vars,
              'load-$_runId-$vu',
              vu,
              it + 1,
            );
            if (!ok && c.stopOnFailure) break;
            await _sleep(c.thinkTimeMs);
          }
        }
        iterationsDone++;
      }
    } finally {
      activeUsers--;
    }
  }

  Future<void> _sleep(int ms) async {
    if (ms <= 0) return;
    final end = elapsedMs + ms;
    while (!stopping && elapsedMs < end) {
      await Future<void>.delayed(
        Duration(milliseconds: min(200, end - elapsedMs)),
      );
    }
  }

  Future<bool> _execute(
    int index,
    LoadStep step,
    Map<String, String> vars,
    String tabId,
    int vu,
    int iteration,
  ) async {
    final http = _http;
    if (http == null) return false;
    final sentAt = DateTime.now();
    _activeTabs.add(tabId);
    final res = await http.send(step.request, vars, tabId: tabId);
    _activeTabs.remove(tabId);
    if (_disposed) return false;
    // A stop cancels in-flight requests; don't count those as failures.
    if (stopping && res.error != null) return false;

    final assertions = evaluateAssertions(step.request, res);
    final pass =
        res.error == null &&
        (assertions.isNotEmpty
            ? assertions.every((a) => a.pass)
            : res.statusCode < 400);
    String? err = res.error;
    if (err == null && !pass) {
      final firstFail = assertions.where((a) => !a.pass).firstOrNull;
      err = firstFail != null
          ? 'Test failed: ${firstFail.assertion.kind.label} — ${firstFail.message}'
          : 'HTTP ${res.statusCode}';
    }
    if (err != null && err.length > 160) err = '${err.substring(0, 160)}…';

    steps[index]._record(res.statusCode, res.durationMs, pass, err);
    _total.record(res.durationMs);
    _bump(pass);
    final l = log;
    if (l != null) {
      final b = l.wantsBody(pass) && res.bodyBytes.isNotEmpty
          ? l.takeBody(res.bodyBytes)
          : (body: null, truncated: false);
      l.add(
        LoadLogEntry(
          seq: ++_seq,
          offsetMs: elapsedMs,
          startedAt: sentAt,
          vu: vu,
          iteration: iteration,
          step: index + 1,
          name: step.request.name,
          method: step.request.method,
          url: res.finalUrl ?? step.request.url,
          status: res.statusCode,
          durationMs: res.durationMs,
          sizeBytes: res.sizeBytes,
          pass: pass,
          error: err,
          contentType: res.contentType,
          body: b.body,
          bodyTruncated: b.truncated,
        ),
      );
    }
    if (pass && step.extract.isNotEmpty) _extract(step, res, vars);
    return pass;
  }

  void _extract(LoadStep step, ResponseData res, Map<String, String> vars) {
    vars.addAll(captureValues(step.extract, res));
  }

  void _bump(bool pass) {
    final second = elapsedMs ~/ 1000;
    var offset = second - _timelineStart;
    while (perSecond.length <= offset) {
      perSecond.add(0);
      errorsPerSecond.add(0);
    }
    perSecond[offset]++;
    if (!pass) errorsPerSecond[offset]++;
    final excess = perSecond.length - timelineSeconds;
    if (excess > 0) {
      perSecond.removeRange(0, excess);
      errorsPerSecond.removeRange(0, excess);
      _timelineStart += excess;
      offset -= excess;
    }
  }

  /// Run-relative second that `perSecond[0]` represents.
  int get timelineStart => _timelineStart;
  int _timelineStart = 0;

  /// Lets in-flight requests be cancelled and stops new ones from starting.
  void stop() {
    if (!running || stopping) return;
    stopping = true;
    for (final id in _activeTabs.toList()) {
      _http?.cancel(id);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    _disposed = true;
    _ticker?.cancel();
    // The run's own finally closes the sink; deleting here drops the file.
    log?.delete();
    super.dispose();
  }
}
