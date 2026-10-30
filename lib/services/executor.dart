import '../models/models.dart';
import 'assertions.dart';
import 'auth/auth.dart';
import 'captures.dart';
import 'console_events.dart';
import 'http_service.dart';
import 'scripting/script_engine.dart';
import 'var_scopes.dart';

/// Where and how one request runs.
class ExecContext {
  ExecContext({
    required this.scopes,
    this.collection,
    this.tabId = 'exec',
    this.source = 'editor',
    this.iteration = 0,
    this.iterationCount = 1,
    this.runScripts = true,
    this.record = true,
    this.onAuthUpdated,
  });

  final VarScopes scopes;

  /// The collection the request belongs to (for inherited auth, folder and
  /// collection scripts), or null.
  final CollectionModel? collection;
  final String tabId;

  /// Console label: 'editor', 'runner', 'cli', ...
  final String source;
  final int iteration;
  final int iterationCount;
  final bool runScripts;

  /// Report exchanges to the console stream.
  final bool record;

  /// An auth scheme stored new settings (e.g. a refreshed OAuth token) on
  /// the request's or its parent's auth.
  final void Function()? onAuthUpdated;
}

class ExecResult {
  ExecResult({
    required this.response,
    required this.sent,
    this.assertions = const [],
    this.scriptTests = const [],
    this.logs = const [],
    this.scriptError,
    this.next,
    this.visualizer,
    this.skipped = false,
  });

  final ResponseData response;

  /// The request as sent: after pre-request scripts changed it.
  final RequestModel sent;
  final List<AssertionResult> assertions;
  final List<ScriptTestResult> scriptTests;
  final List<ConsoleLine> logs;
  final String? scriptError;
  final NextRequest? next;
  final VisualizerOutput? visualizer;

  /// A pre-request script called `pm.execution.skipRequest()`.
  final bool skipped;

  /// Transport worked, no script failed, every check passed, and — when
  /// there are no checks — the status is not 4xx/5xx.
  bool get pass {
    if (skipped) return true;
    if (response.error != null || scriptError != null) return false;
    if (assertions.isEmpty && scriptTests.isEmpty) {
      return response.statusCode < 400;
    }
    return assertions.every((a) => a.pass) && scriptTests.every((t) => t.pass);
  }
}

/// Runs one request the way Postman does: collection, folder and request
/// pre-request scripts, the send (with inherited auth), then test scripts,
/// declarative tests and captures. Used by the editor, the runner and the
/// CLI.
class RequestExecutor {
  RequestExecutor(this.http, {this.engine});

  final HttpService http;
  ScriptEngine? engine;

  Future<ExecResult> execute(RequestModel request, ExecContext ctx) async {
    final working = request.clone(sameId: true);
    final col = ctx.collection;
    final settings = http.settings;
    final engine = ctx.runScripts && settings.scriptsEnabled
        ? this.engine
        : null;
    final logs = <ConsoleLine>[];
    final tests = <ScriptTestResult>[];
    NextRequest? next;
    VisualizerOutput? visualizer;

    final info = ScriptInfo(
      requestName: request.name,
      requestId: request.id,
      iteration: ctx.iteration,
      iterationCount: ctx.iterationCount,
      collectionName: col?.name ?? '',
    );
    Future<ResponseData> sendFromScript(RequestModel r) => http.send(
      r,
      ctx.scopes.resolve(),
      tabId: '${ctx.tabId}-script',
      record: ctx.record,
      source: 'script',
    );

    if (engine != null) {
      final pre = scriptChain(working, col, ScriptPhase.preRequest);
      if (pre.isNotEmpty) {
        final out = await engine.run(
          pre,
          ScriptContext(
            phase: ScriptPhase.preRequest,
            request: working,
            scopes: ctx.scopes,
            info: info,
            sendRequest: sendFromScript,
            timeoutMs: settings.scriptTimeoutMs,
          ),
        );
        logs.addAll(out.logs);
        tests.addAll(out.tests);
        next = out.next ?? next;
        if (out.error != null) {
          return ExecResult(
            response: ResponseData(
              error: 'Pre-request script failed: ${out.error}',
            ),
            sent: working,
            scriptTests: tests,
            logs: logs,
            scriptError: out.error,
            next: next,
          );
        }
        if (out.skipRequest) {
          return ExecResult(
            response: ResponseData(error: 'Skipped by the pre-request script.'),
            sent: working,
            scriptTests: tests,
            logs: logs,
            next: next,
            skipped: true,
          );
        }
      }
    }

    // Inherit resolves to the live folder/collection auth; a request's own
    // auth is the working copy, whose updates are copied back below.
    final auth = resolveAuth(working, col);
    void authUpdated() {
      if (identical(auth, working.auth)) {
        request.auth.params
          ..clear()
          ..addAll(working.auth.params);
      }
      ctx.onAuthUpdated?.call();
    }

    final res = await http.send(
      working,
      ctx.scopes.resolve(),
      tabId: ctx.tabId,
      auth: auth,
      onAuthUpdated: authUpdated,
      record: ctx.record,
      source: ctx.source,
    );

    String? scriptError;
    if (engine != null && res.error == null) {
      final post = scriptChain(working, col, ScriptPhase.test);
      if (post.isNotEmpty) {
        final finalUrl = Uri.tryParse(res.finalUrl ?? '');
        final out = await engine.run(
          post,
          ScriptContext(
            phase: ScriptPhase.test,
            request: working,
            response: res,
            responseCookies: finalUrl == null
                ? const []
                : (http.cookieJar?.cookiesFor(finalUrl) ?? const []),
            scopes: ctx.scopes,
            info: info,
            sendRequest: sendFromScript,
            timeoutMs: settings.scriptTimeoutMs,
          ),
        );
        logs.addAll(out.logs);
        tests.addAll(out.tests);
        next = out.next ?? next;
        visualizer = out.visualizer;
        scriptError = out.error;
      }
    }

    final assertions = evaluateAssertions(working, res);
    if (res.error == null && working.captures.isNotEmpty) {
      ctx.scopes.capture(captureValues(working.captures, res));
    }
    return ExecResult(
      response: res,
      sent: working,
      assertions: assertions,
      scriptTests: tests,
      logs: logs,
      scriptError: scriptError,
      next: next,
      visualizer: visualizer,
    );
  }
}

/// Scripts for [phase] in Postman's order: collection, folders from the
/// root down, then the request.
List<ScriptSource> scriptChain(
  RequestModel r,
  CollectionModel? c,
  ScriptPhase phase,
) {
  String pick(String pre, String test) =>
      phase == ScriptPhase.preRequest ? pre : test;
  final out = <ScriptSource>[];
  void add(String code, String origin) {
    if (code.trim().isNotEmpty) out.add(ScriptSource(code, origin));
  }

  if (c != null) {
    add(pick(c.preRequestScript, c.testScript), 'Collection ${c.name}');
    for (final path in CollectionModel.folderChain(r.folder)) {
      final f = c.folders[path];
      if (f != null) {
        add(pick(f.preRequestScript, f.testScript), 'Folder $path');
      }
    }
  }
  add(pick(r.preRequestScript, r.testScript), 'Request ${r.name}');
  return out;
}
