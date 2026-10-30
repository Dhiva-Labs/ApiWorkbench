import 'dart:convert';

import 'format.dart';
import 'report.dart';
import 'version.dart';

/// One self-contained HTML page (inline CSS, no scripts, no network): the
/// summary, the failures, and every request with its checks and response.
/// Follows the reader's light or dark setting.
String renderHtml(RunReport r) {
  String e(String s) => xmlEscape(s);
  final b = StringBuffer();
  final failed = r.steps.where((s) => !s.pass).length;
  b.writeln('<!doctype html>');
  b.writeln('<html lang="en"><head><meta charset="utf-8">');
  b.writeln(
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
  );
  b.writeln('<title>${e(r.collectionName)} - run report</title>');
  b.writeln('<style>$_css</style></head><body>');
  b.writeln('<main>');
  b.writeln('<header><h1>${e(r.collectionName)}</h1>');
  b.writeln(
    '<p class="dim">${e(r.startedAt.toUtc().toIso8601String())}'
    '${r.environmentName == null ? '' : ' &middot; environment ${e(r.environmentName!)}'}'
    ' &middot; $cliName $cliVersion</p>',
  );
  b.writeln(
    r.passed
        ? '<p class="verdict ok">Passed</p>'
        : '<p class="verdict bad">Failed: $failed of ${r.sent.length} '
              'requests</p>',
  );
  b.writeln('</header>');

  b.writeln('<section class="cards">');
  void card(String label, int total, int bad) {
    b.writeln(
      '<div class="card"><div class="n${bad > 0 ? ' bad' : ''}">'
      '${bad > 0 ? '$bad / $total' : '$total'}</div>'
      '<div class="dim">$label${bad > 0 ? ' failed' : ''}</div></div>',
    );
  }

  card('iterations', r.iterationsRun, r.iterationsFailed);
  card('requests', r.sent.length, r.requestsFailed);
  card('tests', r.testsTotal, r.testsFailed);
  card('assertions', r.assertionsTotal, r.assertionsFailed);
  b.writeln('</section>');
  b.writeln(
    '<p class="dim">Run time ${formatMs(r.durationMs)} &middot; '
    '${formatBytes(r.receivedBytes)} received &middot; response time '
    'avg ${formatMs(r.avgMs)}, min ${formatMs(r.minMs)}, '
    'max ${formatMs(r.maxMs)}'
    '${r.bailed ? ' &middot; stopped at the first failure (--bail)' : ''}</p>',
  );
  for (final w in r.warnings) {
    b.writeln('<p class="warn">${e(w)}</p>');
  }

  final failures = [
    for (final s in r.steps)
      for (final f in s.failures) (s, f),
  ];
  if (failures.isNotEmpty) {
    b.writeln('<h2>Failures (${failures.length})</h2><ol class="failures">');
    for (final (s, f) in failures) {
      b.writeln(
        '<li><strong>${e(f.type)}</strong> ${e(f.message)}'
        '${f.detail.isEmpty ? '' : '<div>${e(f.detail)}</div>'}'
        '<div class="dim">${e(s.name)}'
        '${s.folder.isEmpty ? '' : ' (${e(folderLabel(s.folder))})'}'
        '${r.iterationsPlanned > 1 ? ', iteration ${s.iteration}' : ''}</div>'
        '</li>',
      );
    }
    b.writeln('</ol>');
  }

  b.writeln('<h2>Requests</h2>');
  b.writeln(
    '<input type="checkbox" id="only-failed"> '
    '<label for="only-failed">Show only failed requests</label>',
  );
  b.writeln('<div class="steps">');
  for (final s in r.steps) {
    final cls = s.skipped
        ? 'skip'
        : s.pass
        ? 'ok'
        : 'bad';
    final status = s.skipped
        ? 'skipped'
        : s.error != null
        ? 'error'
        : '${s.status} ${e(s.statusMessage)}';
    b.writeln('<details class="step $cls"><summary>');
    b.writeln(
      '<span class="dot"></span><span class="method">${e(s.method)}</span> '
      '<span class="name">${e(s.name)}</span> '
      '<span class="dim">${e(status)} &middot; ${formatMs(s.durationMs)} '
      '&middot; ${formatBytes(s.sizeBytes)}'
      '${r.iterationsPlanned > 1 ? ' &middot; iteration ${s.iteration}' : ''}'
      '</span>',
    );
    b.writeln('</summary><div class="body">');
    if (s.folder.isNotEmpty) {
      b.writeln('<p class="dim">${e(folderLabel(s.folder))}</p>');
    }
    b.writeln('<p class="url">${e(s.url)}</p>');
    if (s.error != null) b.writeln('<p class="bad">${e(s.error!)}</p>');
    if (s.scriptError != null) {
      b.writeln('<p class="bad">Script error: ${e(s.scriptError!)}</p>');
    }
    final checks = [...s.assertions, ...s.tests];
    if (checks.isNotEmpty) {
      b.writeln('<ul class="checks">');
      for (final c in checks) {
        b.writeln(
          '<li class="${c.pass ? 'ok' : 'bad'}">${c.pass ? 'pass' : 'FAIL'} '
          '${e(c.name)}${c.message.isEmpty ? '' : ' - ${e(c.message)}'}</li>',
        );
      }
      b.writeln('</ul>');
    }
    for (final l in s.logs) {
      b.writeln('<p class="log">${e(l.message)}</p>');
    }
    if (s.headers.isNotEmpty) {
      b.writeln('<details><summary>Response headers</summary><pre>');
      s.headers.forEach((k, v) {
        for (final value in v) {
          b.writeln('${e(k)}: ${e(value)}');
        }
      });
      b.writeln('</pre></details>');
    }
    final body = s.body;
    if (body != null && body.isNotEmpty) {
      final shown = _prettyBody(body);
      b.writeln(
        '<details><summary>Response body</summary>'
        '<pre>${e(clip(shown, _bodyLimit))}</pre>'
        '${shown.length > _bodyLimit || s.bodyTruncated ? '<p class="dim">Shortened here; the json report has more.</p>' : ''}'
        '</details>',
      );
    }
    b.writeln('</div></details>');
  }
  b.writeln('</div></main></body></html>');
  return b.toString();
}

/// Characters of a response body shown per request.
const _bodyLimit = 20000;

String _prettyBody(String body) {
  final t = body.trimLeft();
  if (t.startsWith('{') || t.startsWith('[')) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(body));
    } catch (_) {}
  }
  return body;
}

const _css = '''
:root{--bg:#f7f8fa;--card:#fff;--text:#1d2330;--dim:#5d6678;--line:#dde1e8;--ok:#1a7f45;--bad:#c4302b;--warn:#9a6700}
@media (prefers-color-scheme:dark){:root{--bg:#14171c;--card:#1d2128;--text:#e6e9ef;--dim:#9aa3b2;--line:#323844;--ok:#4cc27f;--bad:#ff6b66;--warn:#e0b341}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
main{max-width:1000px;margin:0 auto;padding:20px 16px 48px}
h1{margin:0;font-size:1.5rem;overflow-wrap:anywhere}
h2{margin:28px 0 10px;font-size:1.15rem}
.dim{color:var(--dim)}
.ok{color:var(--ok)}.bad{color:var(--bad)}.warn{color:var(--warn)}
.verdict{display:inline-block;margin:6px 0 0;padding:2px 12px;border-radius:99px;border:1px solid currentColor;font-weight:600}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:10px;margin:18px 0 10px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 14px}
.card .n{font-size:1.6rem;font-weight:700}
.failures{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 12px 10px 34px}
.failures li{margin:8px 0;overflow-wrap:anywhere}
.step{background:var(--card);border:1px solid var(--line);border-radius:8px;margin:6px 0}
.step>summary{cursor:pointer;padding:8px 12px;display:flex;flex-wrap:wrap;gap:4px 10px;align-items:baseline}
.step .dot{width:10px;height:10px;border-radius:50%;background:var(--ok);align-self:center}
.step.bad .dot{background:var(--bad)}.step.skip .dot{background:var(--dim)}
.method{font-weight:700;font-size:.8rem}
.name{font-weight:600;overflow-wrap:anywhere}
.step .body{padding:0 14px 12px;border-top:1px solid var(--line)}
.url{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:.85rem;overflow-wrap:anywhere}
.checks{list-style:none;margin:8px 0;padding:0;font-size:.9rem}
.checks li{margin:2px 0;overflow-wrap:anywhere}
.log{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:.82rem;color:var(--dim);margin:2px 0}
pre{margin:6px 0;padding:10px;border:1px solid var(--line);border-radius:6px;overflow:auto;max-height:420px;font-size:.8rem}
details details{margin-top:8px}
#only-failed:checked~.steps .step.ok,#only-failed:checked~.steps .step.skip{display:none}
''';
