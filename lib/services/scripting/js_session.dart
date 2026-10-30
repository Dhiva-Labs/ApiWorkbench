import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:quickjs_ffi/quickjs_ffi.dart';

/// What a run needs from the side that owns the request: variable writes
/// and the requests `pm.sendRequest` makes. Everything is JSON-shaped so a
/// run can live in another isolate.
abstract class JsHost {
  /// `[scope, 's'|'u'|'c', key, value]` rows, in order.
  void applyOps(List<Object?> ops);

  /// Performs one `pm.sendRequest`. Completes with `{'response': {...}}`
  /// or `{'error': message}`; never throws.
  Future<Map<String, Object?>> send(Map<String, Object?> request);
}

/// One run: scripts in order, with the sandbox context from
/// `ScriptCodec.encodeContext`.
class JsJob {
  JsJob({
    required this.scripts,
    required this.context,
    required this.timeoutMs,
  });

  factory JsJob.fromMessage(Map<String, Object?> m) => JsJob(
    scripts: [
      for (final s in m['scripts']! as List<Object?>)
        (code: (s as List)[0] as String, origin: s[1] as String),
    ],
    context: (m['context']! as Map).cast<String, Object?>(),
    timeoutMs: m['timeoutMs']! as int,
  );

  final List<({String code, String origin})> scripts;
  final Map<String, Object?> context;
  final int timeoutMs;

  String get phase => context['phase'] as String? ?? 'prerequest';

  Map<String, Object?> toMessage() => {
    'scripts': [
      for (final s in scripts) [s.code, s.origin],
    ],
    'context': context,
    'timeoutMs': timeoutMs,
  };
}

/// The sandbox and libraries compiled once to bytecode, shared by every run
/// in the isolate that compiled them.
class JsModules {
  JsModules._(this.bytecode, this.problems);

  /// Compiles [sources] (module name → source). Each is wrapped as a
  /// CommonJS factory `(module, exports, require, define, window, self,
  /// global)`. Throws when the sandbox itself does not compile.
  factory JsModules.compile(QuickJs quickJs, Map<String, String> sources) {
    final rt = quickJs.newRuntime();
    final out = <String, JsBytecode>{};
    final problems = <String>[];
    try {
      for (final e in sources.entries) {
        try {
          out[e.key] = rt.compile(
            '(function (module, exports, require, define, window, self, '
            'global) {${e.value}\n})',
            filename: e.key,
          );
        } on FormatException catch (err) {
          if (e.key == 'sandbox') rethrow;
          problems.add('${e.key}: ${err.message}');
        }
      }
    } catch (_) {
      for (final b in out.values) {
        b.dispose();
      }
      rethrow;
    } finally {
      rt.dispose();
    }
    return JsModules._(out, problems);
  }

  final Map<String, JsBytecode> bytecode;

  /// Libraries that did not compile (their `require()` fails).
  final List<String> problems;

  void dispose() {
    for (final b in bytecode.values) {
      b.dispose();
    }
    bytecode.clear();
  }
}

/// Memory one run may use. Generous: a run holds the response body and
/// whatever the script builds from it.
const jsMemoryLimit = 256 << 20;

/// Stack budget of a run in a worker isolate. Dart's own threads have
/// 1 MB stacks; QuickJS throws a RangeError before using more than this.
const jsWorkerStackSize = 512 << 10;

/// Stack budget when running on the caller's isolate, whose thread may be
/// a platform thread with a small stack (512 KB on iOS).
const jsInlineStackSize = 256 << 10;

/// Grace period for collecting tests and logs after a timeout.
const _finishGraceMs = 2000;

/// Runs [job] on a fresh runtime and returns the sandbox's `finish()`
/// result plus `error` (null when every script ran cleanly).
///
/// Scripts run one after another; each is driven until nothing is pending:
/// promise jobs, `pm.sendRequest` calls ([host] performs them) and timers.
/// The job's wall-clock budget covers all of it.
Future<Map<String, Object?>> runJsJob(
  QuickJs quickJs,
  JsModules modules,
  JsJob job,
  JsHost host, {
  int stackSize = jsWorkerStackSize,
}) async {
  final rt = quickJs.newRuntime(
    memoryLimit: jsMemoryLimit,
    stackSize: stackSize,
  );
  final clock = Stopwatch()..start();
  final errors = <String>[];
  var timedOut = false;
  int remaining() => job.timeoutMs - clock.elapsedMilliseconds;

  /// Evaluates [code] under the run's deadline; throws [_Stop] on a timeout
  /// or a failure of the sandbox itself.
  Object? call(String code, {String file = 'sandbox'}) {
    final left = remaining();
    if (left <= 0) throw const _Stop.timeout();
    rt.setDeadline(left);
    final r = rt.eval(code, filename: file);
    if (r.timedOut) throw const _Stop.timeout();
    if (!r.ok) throw _Stop(r.error!);
    return r.value;
  }

  String timeoutMessage(String origin) =>
      '$origin: the script did not finish within ${job.timeoutMs} ms and '
      'was stopped';

  try {
    for (final e in modules.bytecode.entries) {
      rt.addModule(e.key, e.value);
    }
    call(
      '(function () {'
      'var m = { exports: {} };'
      "__awLoad('sandbox').call(globalThis, m, m.exports);"
      "Object.defineProperty(globalThis, '__aw', { value: m.exports });"
      'return m.exports.init(${jsonEncode(job.context)});'
      '})()',
    );

    for (final script in job.scripts) {
      final origin = script.origin;
      try {
        call('__aw.begin(${jsonEncode(origin)})');
        // The script runs as the body of an async function: its own scope,
        // top-level await, and the line numbers of the editor (the wrapper
        // adds nothing before line 1).
        final left = remaining();
        if (left <= 0) throw const _Stop.timeout();
        rt.setDeadline(left);
        final r = rt.eval(
          '__aw.track((async function () {${script.code}\n})())',
          filename: origin,
        );
        if (r.timedOut) throw const _Stop.timeout();
        if (!r.ok) {
          // A syntax error: the script never started.
          errors.add('$origin: ${_describe(r.error!, origin)}');
        } else {
          await _drive(rt, host, call, remaining);
        }
        final end = call('__aw.end()')! as Map;
        final error = end['error'] as String?;
        if (error != null) errors.add('$origin: $error');
        if (end['skip'] == true) break;
        // A failed pre-request script stops the chain: the request will
        // not be sent, so later scripts must not run their side effects.
        if (errors.isNotEmpty && job.phase == 'prerequest') break;
      } on _Stop catch (s) {
        if (s.timeout) {
          timedOut = true;
          errors.add(timeoutMessage(origin));
        } else {
          errors.add('$origin: ${_describe(s.message, origin)}');
        }
        break;
      }
    }

    // After a timeout the context is still usable; collect what it has.
    rt.setDeadline(timedOut ? _finishGraceMs : max(remaining(), 1) + 1000);
    final fin = rt.eval('__aw.finish()', filename: 'sandbox');
    final Map<String, Object?> out = fin.ok
        ? (fin.value! as Map).cast<String, Object?>()
        : {'tests': const [], 'logs': const []};
    final ops = out.remove('ops');
    if (ops is List && ops.isNotEmpty) host.applyOps(ops);
    out['error'] = errors.isEmpty ? null : errors.join('\n');
    return out;
  } on _Stop catch (s) {
    // The sandbox itself failed to start.
    return {
      'tests': const [],
      'logs': const [],
      'error': s.timeout
          ? 'Scripts did not start within ${job.timeoutMs} ms'
          : 'Script sandbox failed: ${s.message}',
    };
  } finally {
    rt.dispose();
  }
}

/// Runs promise jobs, hands queued requests to [host] and fires timers
/// until the current script has nothing pending.
Future<void> _drive(
  JsRuntime rt,
  JsHost host,
  Object? Function(String code, {String file}) call,
  int Function() remaining,
) async {
  final inFlight = <int>{};
  final arrived = <(int, Map<String, Object?>)>[];
  Completer<void>? wake;

  while (true) {
    final left = remaining();
    if (left <= 0) throw const _Stop.timeout();
    rt.setDeadline(left);
    final jobs = rt.runJobs();
    if (jobs != null) {
      if (jobs.timedOut) throw const _Stop.timeout();
      throw _Stop(jobs.error!);
    }

    final poll = call('__aw.poll()')! as Map;
    final ops = poll['ops'] as List?;
    if (ops != null && ops.isNotEmpty) host.applyOps(ops);
    for (final q in (poll['requests'] as List? ?? const [])) {
      final m = q as Map;
      final id = m['id'] as int;
      inFlight.add(id);
      host.send((m['request'] as Map).cast<String, Object?>()).then((res) {
        arrived.add((id, res));
        final w = wake;
        if (w != null && !w.isCompleted) w.complete();
      });
    }

    if (arrived.isNotEmpty) {
      final batch = List.of(arrived);
      arrived.clear();
      for (final (id, res) in batch) {
        inFlight.remove(id);
        call('__aw.resolve($id, ${jsonEncode(res)})');
      }
      continue;
    }

    final timer = (poll['timer'] as num?)?.toInt();
    if (inFlight.isEmpty && timer == null) return;
    if (timer == 0) {
      call('__aw.fireTimers()');
      continue;
    }

    final waitMs = min(timer ?? left, remaining());
    if (waitMs <= 0) throw const _Stop.timeout();
    final w = wake = Completer<void>();
    final sleep = Timer(Duration(milliseconds: waitMs), () {
      if (!w.isCompleted) w.complete();
    });
    await w.future;
    sleep.cancel();
    wake = null;
    if (timer != null) call('__aw.fireTimers()');
  }
}

class _Stop implements Exception {
  const _Stop(this.message) : timeout = false;
  const _Stop.timeout() : message = 'timed out', timeout = true;

  final String message;
  final bool timeout;
}

/// The first line of a QuickJS error, with the script line it points at.
String _describe(String error, String origin) {
  final lines = error.split('\n');
  final head = lines.first.trim();
  final at = error.indexOf('$origin:');
  if (at < 0) return head;
  final m = RegExp(
    r'^(\d+)',
  ).firstMatch(error.substring(at + origin.length + 1));
  return m == null ? head : '$head (line ${m.group(1)})';
}
