import 'dart:convert';

import 'load_test.dart';

/// Run summary shared by every report format.
Map<String, dynamic> loadSummary(LoadTestService svc, String title) {
  final c = svc.lastConfig ?? LoadTestConfig();
  final log = svc.log;
  return {
    'title': title,
    'startedAt': svc.startedAt?.toIso8601String(),
    'elapsedMs': svc.elapsedMs,
    'config': {
      'virtualUsers': c.virtualUsers,
      'iterations': c.untilStopped || c.durationSec > 0 ? null : c.iterations,
      'durationSec': c.untilStopped || c.durationSec == 0
          ? null
          : c.durationSec,
      'untilStopped': c.untilStopped,
      'rampUpSec': c.rampUpSec,
      'thinkTimeMs': c.thinkTimeMs,
      'mode': c.parallel ? 'all at once' : 'one by one',
      'savedBodies': c.bodies.label,
    },
    'totals': {
      'requests': svc.total.count,
      'passed': svc.passed,
      'failed': svc.failed,
      'errorRate': svc.errorRate,
      'requestsPerSecond': svc.requestsPerSecond,
      'iterations': svc.iterationsDone,
      ..._latency(svc.total),
    },
    'requests': [
      for (final st in svc.steps)
        {
          'name': st.request.name,
          'method': st.request.method,
          'url': st.request.url,
          'calls': st.count,
          'passed': st.passed,
          'failed': st.failed,
          ..._latency(st.hist),
          'statusCounts': {
            for (final e in st.statusCounts.entries)
              e.key == 0 ? 'error' : '${e.key}': e.value,
          },
          'errors': st.errors,
        },
    ],
    if (log != null) 'loggedCalls': log.count,
    if (log != null && log.bodiesDropped > 0)
      'bodiesDropped': log.bodiesDropped,
  };
}

Map<String, dynamic> _latency(LatencyHistogram h) => {
  'avgMs': double.parse(h.meanMs.toStringAsFixed(1)),
  'minMs': h.minMs,
  'p50Ms': h.percentile(50),
  'p90Ms': h.percentile(90),
  'p95Ms': h.percentile(95),
  'p99Ms': h.percentile(99),
  'maxMs': h.maxMs,
};

/// Summary plus every logged call, including saved response bodies.
Future<String> buildLoadJson(LoadTestService svc, String title) async {
  final b = StringBuffer('{"summary":')
    ..write(jsonEncode(loadSummary(svc, title)))
    ..write(',"calls":[');
  var first = true;
  final log = svc.log;
  if (log != null) {
    await for (final e in log.entries()) {
      if (!first) b.write(',');
      first = false;
      b.write(jsonEncode(e.toJson()));
    }
  }
  b.write(']}');
  return b.toString();
}

/// One row per call; opens in any spreadsheet.
Future<String> buildLoadCsv(LoadTestService svc) async {
  final b = StringBuffer(
    'seq,started_at,offset_ms,vu,iteration,step,request,method,url,'
    'status,duration_ms,size_bytes,result,error\r\n',
  );
  final log = svc.log;
  if (log != null) {
    await for (final e in log.entries()) {
      b.write(
        [
          e.seq,
          e.startedAt.toIso8601String(),
          e.offsetMs,
          e.vu,
          e.iteration,
          e.step,
          _csv(e.name),
          e.method,
          _csv(e.url),
          e.status == 0 ? '' : e.status,
          e.durationMs,
          e.sizeBytes,
          e.pass ? 'pass' : 'fail',
          _csv(e.error ?? ''),
        ].join(','),
      );
      b.write('\r\n');
    }
  }
  return b.toString();
}

String _csv(String v) {
  // Leading =,+,-,@ would run as a formula when opened in a spreadsheet.
  if (v.isNotEmpty && '=+-@'.contains(v[0])) v = "'$v";
  if (!v.contains(RegExp(r'[",\r\n]'))) return v;
  return '"${v.replaceAll('"', '""')}"';
}

/// A self-contained HTML report: summary, per-request latency, the call log
/// (first [maxRows] rows) and saved response bodies (first [maxBodies]).
Future<String> buildLoadHtml(
  LoadTestService svc,
  String title, {
  int maxRows = 5000,
  int maxBodies = 300,
}) async {
  final s = loadSummary(svc, title);
  final t = s['totals'] as Map<String, dynamic>;
  final cfg = s['config'] as Map<String, dynamic>;
  const esc = HtmlEscape();
  String e(Object? v) => esc.convert('${v ?? ''}');
  String n(num v) => v.toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );

  final rows = StringBuffer();
  final bodies = StringBuffer();
  var rowCount = 0;
  var bodyCount = 0;
  final log = svc.log;
  if (log != null) {
    await for (final c in log.entries()) {
      if (rowCount < maxRows) {
        rowCount++;
        final anchor = c.body != null && bodyCount < maxBodies
            ? ' <a href="#b${c.seq}">body</a>'
            : '';
        rows.write(
          '<tr class="${c.pass ? '' : 'fail'}"><td>${c.seq}</td>'
          '<td>${(c.offsetMs / 1000).toStringAsFixed(3)}</td>'
          '<td>${c.vu}</td><td>${c.iteration}</td>'
          '<td>${e(c.method)} ${e(c.name)}</td>'
          '<td>${c.status == 0 ? 'ERR' : c.status}</td>'
          '<td>${c.durationMs}</td><td>${n(c.sizeBytes)}</td>'
          '<td>${c.pass ? 'pass' : 'fail'}$anchor</td>'
          '<td>${e(c.error)}</td></tr>',
        );
      }
      if (c.body != null && bodyCount < maxBodies) {
        bodyCount++;
        bodies.write(
          '<details id="b${c.seq}"><summary>#${c.seq} · '
          '${e(c.method)} ${e(c.name)} · '
          '${c.status == 0 ? 'ERR' : c.status} · ${c.durationMs} ms'
          '${c.bodyTruncated ? ' · first 64 KB' : ''}</summary>'
          '<pre>${e(c.body)}</pre></details>',
        );
      }
    }
  }

  final perRequest = StringBuffer();
  for (final r in (s['requests'] as List).cast<Map<String, dynamic>>()) {
    final codes = (r['statusCounts'] as Map).entries
        .map((x) => '${x.key} ×${n(x.value as int)}')
        .join(', ');
    perRequest.write(
      '<tr><td>${e(r['method'])} ${e(r['name'])}<div class="dim">'
      '${e(r['url'])}</div></td><td>${n(r['calls'] as int)}</td>'
      '<td>${n(r['failed'] as int)}</td><td>${r['avgMs']}</td>'
      '<td>${r['p50Ms']}</td><td>${r['p95Ms']}</td><td>${r['p99Ms']}</td>'
      '<td>${r['maxMs']}</td><td>${e(codes)}</td></tr>',
    );
    for (final err in (r['errors'] as Map).entries) {
      perRequest.write(
        '<tr class="fail"><td colspan="9">${e(err.key)} '
        '(×${err.value})</td></tr>',
      );
    }
  }

  final profile = [
    '${cfg['virtualUsers']} parallel users',
    if (cfg['untilStopped'] == true)
      'repeated until stopped'
    else if (cfg['durationSec'] != null)
      'for ${cfg['durationSec']} s'
    else
      '${cfg['iterations']} iterations each',
    'requests ${cfg['mode']}',
    if ((cfg['rampUpSec'] as int) > 0) 'ramp-up ${cfg['rampUpSec']} s',
    if ((cfg['thinkTimeMs'] as int) > 0) 'think time ${cfg['thinkTimeMs']} ms',
  ].join(' · ');
  final logged = s['loggedCalls'] as int?;
  String tile(String k, String v, [bool alert = false]) =>
      '<div class="tile${alert ? ' alert' : ''}"><span>$k</span><b>$v</b></div>';

  return '''<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Load test report · ${e(title)}</title>
<style>
:root{--bg:#f7f7f8;--fg:#1d1d22;--dim:#6b6b76;--card:#fff;--line:#e3e3e8;--bad:#c62828;--badbg:#fdecec}
@media (prefers-color-scheme:dark){:root{--bg:#141418;--fg:#e8e8ee;--dim:#9a9aa6;--card:#1d1d23;--line:#2e2e37;--bad:#ef6b6b;--badbg:#3a1d20}}
body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 system-ui,sans-serif}
main{max-width:1100px;margin:0 auto;padding:24px 16px}
h1{font-size:22px;margin:0 0 4px}h2{font-size:16px;margin:28px 0 10px}
.dim{color:var(--dim);font-size:12px}
.tiles{display:flex;flex-wrap:wrap;gap:10px;margin-top:16px}
.tile{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:9px 12px;min-width:110px}
.tile span{display:block;font-size:12px;color:var(--dim)}.tile b{font-size:18px;font-variant-numeric:tabular-nums}
.tile.alert{border-color:var(--bad)}.tile.alert b{color:var(--bad)}
.wrap{overflow-x:auto;background:var(--card);border:1px solid var(--line);border-radius:8px}
table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums;font-size:13px}
th,td{padding:6px 10px;border-bottom:1px solid var(--line);text-align:left;white-space:nowrap}
th{color:var(--dim);font-weight:600;position:sticky;top:0;background:var(--card)}
tr.fail td{background:var(--badbg)}a{color:inherit}
details{background:var(--card);border:1px solid var(--line);border-radius:8px;margin:6px 0;padding:6px 10px}
summary{cursor:pointer;font-size:13px}pre{white-space:pre-wrap;word-break:break-all;font-size:12px;max-height:400px;overflow:auto}
</style></head><body><main>
<h1>Load test · ${e(title)}</h1>
<div class="dim">Started ${e(s['startedAt'])} · ran ${(svc.elapsedMs / 1000).toStringAsFixed(1)} s · ${e(profile)}</div>
<div class="tiles">
${tile('Requests', n(t['requests'] as int))}
${tile('Req / sec', (t['requestsPerSecond'] as double).toStringAsFixed(1))}
${tile('Failed', '${n(t['failed'] as int)} (${((t['errorRate'] as double) * 100).toStringAsFixed(1)}%)', (t['failed'] as int) > 0)}
${tile('Avg', '${t['avgMs']} ms')}
${tile('p50', '${t['p50Ms']} ms')}
${tile('p95', '${t['p95Ms']} ms')}
${tile('p99', '${t['p99Ms']} ms')}
${tile('Max', '${t['maxMs']} ms')}
</div>
<h2>Per request (latency in ms)</h2>
<div class="wrap"><table><tr><th>Request</th><th>Calls</th><th>Failed</th><th>Avg</th><th>p50</th><th>p95</th><th>p99</th><th>Max</th><th>Status codes</th></tr>
$perRequest</table></div>
${logged == null ? '' : '''<h2>Call log</h2>
<div class="dim">${rowCount < logged ? 'First ${n(rowCount)} of ${n(logged)} calls; the CSV and JSON exports contain every call.' : '${n(logged)} calls.'} Time is seconds since the run started.</div>
<div class="wrap" style="max-height:600px;margin-top:8px"><table><tr><th>#</th><th>Time</th><th>User</th><th>Iter</th><th>Request</th><th>Status</th><th>ms</th><th>Bytes</th><th>Result</th><th>Error</th></tr>
$rows</table></div>'''}
${bodyCount == 0 ? '' : '''<h2>Saved responses</h2>
<div class="dim">${bodyCount >= maxBodies ? 'First $maxBodies saved responses; the JSON export contains all of them. ' : ''}Bodies are capped at 64 KB each.</div>
$bodies'''}
</main></body></html>
''';
}
