import 'dart:convert';

import 'report.dart';
import 'version.dart';

/// The full run as JSON: summary, every execution with its response and
/// checks, and the failures.
String renderJson(RunReport r) =>
    '${const JsonEncoder.withIndent('  ').convert(reportToJson(r))}\n';

Map<String, Object?> reportToJson(RunReport r) {
  Map<String, int> counts(int total, int failed) => {
    'total': total,
    'executed': total,
    'failed': failed,
  };
  return {
    'tool': cliName,
    'version': cliVersion,
    'collection': {'id': r.collectionId, 'name': r.collectionName},
    'environment': r.environmentName,
    'startedAt': r.startedAt.toUtc().toIso8601String(),
    'durationMs': r.durationMs,
    'passed': r.passed,
    'stoppedEarly': r.bailed,
    'summary': {
      'iterations': {
        'planned': r.iterationsPlanned,
        'executed': r.iterationsRun,
        'failed': r.iterationsFailed,
      },
      'requests': counts(r.sent.length, r.requestsFailed),
      'tests': counts(r.testsTotal, r.testsFailed),
      'assertions': counts(r.assertionsTotal, r.assertionsFailed),
      'receivedBytes': r.receivedBytes,
      'responseTimeMs': {'average': r.avgMs, 'min': r.minMs, 'max': r.maxMs},
    },
    'executions': [for (final s in r.steps) _step(s)],
    'failures': [
      for (final s in r.steps)
        for (final f in s.failures)
          {
            'iteration': s.iteration,
            'request': s.name,
            'folder': s.folder,
            'type': f.type,
            'message': f.message,
            if (f.detail.isNotEmpty) 'detail': f.detail,
          },
    ],
    'warnings': r.warnings,
  };
}

Map<String, Object?> _step(StepResult s) => {
  'iteration': s.iteration,
  'id': s.id,
  'name': s.name,
  'folder': s.folder,
  'at': s.at.toUtc().toIso8601String(),
  'passed': s.pass,
  'skipped': s.skipped,
  'request': {'method': s.method, 'url': s.url},
  'response': s.skipped
      ? null
      : {
          'code': s.status,
          'status': s.statusMessage,
          'responseTimeMs': s.durationMs,
          'sizeBytes': s.sizeBytes,
          'headers': s.headers,
          'body': s.body,
          'bodyTruncated': s.bodyTruncated,
          'error': s.error,
        },
  'assertions': [for (final a in s.assertions) _check(a)],
  'tests': [for (final t in s.tests) _check(t)],
  'scriptError': s.scriptError,
  'logs': [
    for (final l in s.logs) {'level': l.level.name, 'message': l.message},
  ],
};

Map<String, Object?> _check(CheckOutcome c) => {
  'name': c.name,
  'passed': c.pass,
  if (c.message.isNotEmpty) 'message': c.message,
};
