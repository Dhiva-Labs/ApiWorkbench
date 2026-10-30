import 'dart:io' show Cookie;

import '../../models/models.dart';
import '../console_events.dart';
import '../var_scopes.dart';

enum ScriptPhase { preRequest, test }

/// One script to run, with where it came from for messages.
class ScriptSource {
  const ScriptSource(this.code, this.origin);
  final String code;

  /// 'Collection', 'Folder Orders', 'Request', ...
  final String origin;
}

/// Facts about the running request (`pm.info`).
class ScriptInfo {
  const ScriptInfo({
    required this.requestName,
    required this.requestId,
    this.iteration = 0,
    this.iterationCount = 1,
    this.collectionName = '',
  });

  final String requestName;
  final String requestId;

  /// 0-based, like Postman.
  final int iteration;
  final int iterationCount;
  final String collectionName;
}

/// Everything a script can see and change.
class ScriptContext {
  ScriptContext({
    required this.phase,
    required this.request,
    required this.scopes,
    required this.info,
    this.response,
    this.responseCookies = const [],
    this.sendRequest,
    this.timeoutMs = 10000,
  });

  final ScriptPhase phase;

  /// The request about to be sent. Pre-request scripts may change it
  /// (`pm.request.headers.add(...)`, URL, body, auth).
  final RequestModel request;
  final VarScopes scopes;
  final ScriptInfo info;

  /// Test phase only.
  final ResponseData? response;

  /// Cookies the jar holds for the response URL (`pm.cookies`).
  final List<Cookie> responseCookies;

  /// `pm.sendRequest`: sends a request built by the script. Null when the
  /// host can't send (then the script gets an error).
  final Future<ResponseData> Function(RequestModel request)? sendRequest;
  final int timeoutMs;
}

/// A `pm.test` result.
class ScriptTestResult {
  const ScriptTestResult(this.name, this.pass, {this.error, this.origin = ''});
  final String name;
  final bool pass;
  final String? error;
  final String origin;
}

/// `pm.visualizer.set(template, data, options)`: rendered HTML.
class VisualizerOutput {
  const VisualizerOutput(this.html);
  final String html;
}

/// `postman.setNextRequest(...)` / `pm.execution.setNextRequest(...)`.
class NextRequest {
  const NextRequest.named(this.nameOrId) : stop = false;
  const NextRequest.stop() : nameOrId = null, stop = true;

  final String? nameOrId;

  /// `setNextRequest(null)`: end the run after this request.
  final bool stop;
}

class ScriptOutcome {
  ScriptOutcome({
    List<ScriptTestResult>? tests,
    List<ConsoleLine>? logs,
    this.error,
    this.next,
    this.visualizer,
    this.skipRequest = false,
  }) : tests = tests ?? [],
       logs = logs ?? [];

  final List<ScriptTestResult> tests;
  final List<ConsoleLine> logs;

  /// Uncaught exception or timeout, with the script's origin.
  String? error;
  NextRequest? next;
  VisualizerOutput? visualizer;

  /// `pm.execution.skipRequest()` in a pre-request script.
  bool skipRequest;
}

/// Runs Postman-style scripts. Implementations must not let scripts reach
/// the file system or network except through [ScriptContext.sendRequest].
abstract class ScriptEngine {
  /// Runs [scripts] in order in one sandbox, sharing state like Postman.
  Future<ScriptOutcome> run(List<ScriptSource> scripts, ScriptContext ctx);

  void dispose();
}
