import 'dart:async';
import 'dart:isolate';

import 'package:quickjs_ffi/quickjs_ffi.dart';

import 'js_session.dart';
import 'script_assets.dart';
import 'script_codec.dart';
import 'script_engine.dart';

/// Runs Postman scripts on QuickJS-ng.
///
/// By default the scripts run in a worker isolate, so a slow or runaway
/// script never blocks the caller (the UI). The worker compiles the sandbox
/// and libraries once; every run then gets a fresh runtime with a memory
/// limit, a stack limit and the [ScriptContext.timeoutMs] deadline.
/// Variable writes and `pm.sendRequest` travel back to the caller's isolate,
/// which owns the variable lists and the HTTP client.
class QuickJsScriptEngine implements ScriptEngine {
  QuickJsScriptEngine(this._quickJs, this._loadAsset, {this.useIsolate = true});

  final QuickJs _quickJs;
  final ScriptAssetLoader _loadAsset;

  /// Run in a worker isolate (true) or on the caller's isolate.
  final bool useIsolate;

  /// Extra time a worker gets past a run's own deadline before it is
  /// considered stuck and replaced.
  static const watchdogGrace = Duration(seconds: 5);

  Future<Map<String, String>>? _sources;
  Future<_Worker>? _worker;
  _Worker? _live;
  JsModules? _inlineModules;
  int _inlineRuns = 0;
  bool _disposed = false;
  int _runSeq = 0;

  /// The library in use: `asset` (bundled by the build hook) or a path.
  String get libraryLocation => _quickJs.location;

  Future<Map<String, String>> _loadSources() => _sources ??= () async {
    final out = <String, String>{};
    for (final e in scriptModuleFiles.entries) {
      try {
        out[e.key] = await _loadAsset('$scriptAssetDir/${e.value}');
      } catch (_) {
        if (e.key == 'sandbox') {
          _sources = null; // let a later run try again
          rethrow;
        }
      }
    }
    return out;
  }();

  @override
  Future<ScriptOutcome> run(
    List<ScriptSource> scripts,
    ScriptContext ctx,
  ) async {
    if (scripts.isEmpty) return ScriptOutcome();
    if (_disposed) return ScriptOutcome(error: 'The script engine is closed.');
    final codec = ScriptCodec(ctx);
    final job = JsJob(
      scripts: [for (final s in scripts) (code: s.code, origin: s.origin)],
      context: codec.encodeContext(),
      timeoutMs: ctx.timeoutMs,
    );
    Map<String, Object?> result;
    try {
      result = useIsolate
          ? await _runInWorker(job, codec)
          : await _runInline(job, codec);
    } catch (e) {
      return ScriptOutcome(error: 'The script engine failed: $e');
    }
    return codec.outcome(result);
  }

  Future<Map<String, Object?>> _runInline(JsJob job, ScriptCodec codec) async {
    final sources = await _loadSources();
    if (_disposed) throw StateError('closed');
    final modules = _inlineModules ??= JsModules.compile(_quickJs, sources);
    _inlineRuns++;
    try {
      return await runJsJob(
        _quickJs,
        modules,
        job,
        codec,
        stackSize: jsInlineStackSize,
      );
    } finally {
      // A run's runtime loads the bytecode lazily, so it is freed only once
      // no run is left.
      if (--_inlineRuns == 0 && _disposed) _freeInlineModules();
    }
  }

  void _freeInlineModules() {
    _inlineModules?.dispose();
    _inlineModules = null;
  }

  Future<_Worker> _ensureWorker() {
    final existing = _worker;
    if (existing != null) return existing;
    final started = () async {
      final sources = await _loadSources();
      return _live = await _Worker.spawn(
        _quickJs.location == 'asset' ? null : _quickJs.location,
        sources,
      );
    }();
    _worker = started;
    // A failed start is not kept: the next run tries again.
    started.then(
      (_) {},
      onError: (Object _) {
        if (identical(_worker, started)) _worker = null;
      },
    );
    return started;
  }

  Future<Map<String, Object?>> _runInWorker(
    JsJob job,
    ScriptCodec codec,
  ) async {
    final worker = await _ensureWorker();
    if (_disposed) throw StateError('closed');
    final runId = ++_runSeq;
    final port = ReceivePort();
    final done = Completer<Map<String, Object?>>();
    worker.isolate.addOnExitListener(port.sendPort, response: const ['exit']);

    // The worker enforces the deadline itself; this only catches a worker
    // that stopped answering (stuck in native code, or dead).
    final watchdog = Timer(
      Duration(milliseconds: job.timeoutMs) + watchdogGrace,
      () {
        if (done.isCompleted) return;
        _retire(worker);
        done.completeError(
          'the script did not finish within ${job.timeoutMs} ms and its '
          'engine was restarted',
        );
      },
    );
    port.listen((msg) {
      if (msg is! List || msg.isEmpty || done.isCompleted) return;
      switch (msg[0]) {
        case 'ops':
          codec.applyOps(msg[1] as List<Object?>);
        case 'send':
          final id = msg[1];
          codec.send((msg[2] as Map).cast<String, Object?>()).then((res) {
            worker.commands.send(['response', runId, id, res]);
          });
        case 'done':
          done.complete((msg[1] as Map).cast<String, Object?>());
        case 'failed':
          done.completeError(msg[1] as Object);
        case 'exit':
          _retire(worker);
          done.completeError('the script engine stopped unexpectedly');
      }
    });
    worker.commands.send(['run', runId, port.sendPort, job.toMessage()]);
    try {
      return await done.future;
    } finally {
      watchdog.cancel();
      worker.isolate.removeOnExitListener(port.sendPort);
      port.close();
    }
  }

  /// Drops [worker] so the next run starts a fresh one.
  void _retire(_Worker worker) {
    worker.isolate.kill(priority: Isolate.immediate);
    if (identical(_live, worker)) {
      _live = null;
      _worker = null;
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final w = _worker;
    _worker = null;
    _live = null;
    w?.then(
      (w) => w.isolate.kill(priority: Isolate.immediate),
      onError: (Object _) {},
    );
    if (_inlineRuns == 0) _freeInlineModules();
  }
}

class _Worker {
  _Worker(this.isolate, this.commands);

  final Isolate isolate;
  final SendPort commands;

  static Future<_Worker> spawn(
    String? libraryPath,
    Map<String, String> sources,
  ) async {
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(
      _workerMain,
      [ready.sendPort, libraryPath, sources],
      debugName: 'scripts',
      errorsAreFatal: false,
    );
    final first = await ready.first;
    ready.close();
    if (first is SendPort) return _Worker(isolate, first);
    isolate.kill(priority: Isolate.immediate);
    throw StateError('$first');
  }
}

/// The worker isolate: compiles the modules once, then serves runs. Runs
/// may overlap (one waiting on a request while another computes); each has
/// its own runtime.
Future<void> _workerMain(List<Object?> args) async {
  final ready = args[0]! as SendPort;
  final libraryPath = args[1] as String?;
  final sources = (args[2]! as Map).cast<String, String>();
  final QuickJs quickJs;
  final JsModules modules;
  try {
    quickJs = QuickJs.open(path: libraryPath);
    modules = JsModules.compile(quickJs, sources);
  } catch (e) {
    ready.send('the script engine could not start: $e');
    return;
  }
  final commands = ReceivePort();
  final hosts = <int, _WorkerHost>{};
  ready.send(commands.sendPort);
  await for (final msg in commands) {
    if (msg is! List || msg.isEmpty) continue;
    switch (msg[0]) {
      case 'run':
        final runId = msg[1] as int;
        final reply = msg[2] as SendPort;
        final host = hosts[runId] = _WorkerHost(reply);
        () async {
          try {
            final job = JsJob.fromMessage(
              (msg[3] as Map).cast<String, Object?>(),
            );
            reply.send(['done', await runJsJob(quickJs, modules, job, host)]);
          } catch (e) {
            reply.send(['failed', '$e']);
          } finally {
            hosts.remove(runId);
          }
        }();
      case 'response':
        hosts[msg[1]]?.answer(
          msg[2] as int,
          (msg[3] as Map).cast<String, Object?>(),
        );
    }
  }
}

class _WorkerHost implements JsHost {
  _WorkerHost(this.reply);

  final SendPort reply;
  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  int _seq = 0;

  @override
  void applyOps(List<Object?> ops) => reply.send(['ops', ops]);

  @override
  Future<Map<String, Object?>> send(Map<String, Object?> request) {
    final id = ++_seq;
    final c = _pending[id] = Completer<Map<String, Object?>>();
    reply.send(['send', id, request]);
    return c.future;
  }

  void answer(int id, Map<String, Object?> result) =>
      _pending.remove(id)?.complete(result);
}
