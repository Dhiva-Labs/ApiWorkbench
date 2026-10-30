import 'dart:convert';

import '../models/models.dart';
import 'doc_export.dart' show maskSecrets;

/// Shown in place of a secret. The same mask `doc_export.dart` uses.
const docMask = '••••••';

/// A whole collection as one self-contained HTML page: inline styles, light
/// and dark colours, a table of contents and a badge per method.
///
/// Everything from the collection is HTML-escaped. Secrets are masked: the
/// values in [secrets] (use `AppState.secretValues`) wherever they appear,
/// auth tokens and passwords, secret variables and the values of headers
/// that carry credentials. [generatedAt] is only for the footer.
String buildCollectionHtml(
  CollectionModel c, {
  Set<String> secrets = const {},
  DateTime? generatedAt,
}) => _renderHtml(_DocBuilder(c, secrets).build(), generatedAt);

/// The same content as [buildCollectionHtml], as Markdown.
String buildCollectionMarkdown(
  CollectionModel c, {
  Set<String> secrets = const {},
  DateTime? generatedAt,
}) => _renderMarkdown(_DocBuilder(c, secrets).build(), generatedAt);

// ---------------------------------------------------------------------------
// Document model: both renderers walk the same blocks.
// ---------------------------------------------------------------------------

sealed class _Block {
  const _Block();
}

class _Heading extends _Block {
  const _Heading(this.level, this.text, this.anchor, {this.badge});
  final int level;
  final String text;
  final String anchor;

  /// A method (or protocol) badge shown before the text.
  final String? badge;
}

/// Plain text, optionally led by a bold label.
class _Para extends _Block {
  const _Para(this.text, {this.label});
  final String text;
  final String? label;
}

class _Bullets extends _Block {
  const _Bullets(this.items, {this.label});
  final List<String> items;
  final String? label;
}

/// A request URL.
class _Url extends _Block {
  const _Url(this.text);
  final String text;
}

class _Table extends _Block {
  const _Table(this.label, this.columns, this.rows, {this.off = const {}});
  final String label;
  final List<String> columns;
  final List<List<String>> rows;

  /// Indexes of rows that are switched off.
  final Set<int> off;
}

class _Code extends _Block {
  const _Code(this.text, {this.lang = '', this.label});
  final String text;
  final String lang;
  final String? label;
}

/// Collapsed code, e.g. a script.
class _Details extends _Block {
  const _Details(this.summary, this.text);
  final String summary;
  final String text;
}

/// The title line of an example, with its status.
class _ExampleTitle extends _Block {
  const _ExampleTitle(this.name, this.status);
  final String name;
  final int status;
}

class _Doc {
  _Doc(this.title, this.blocks, this.requestCount);
  final String title;
  final List<_Block> blocks;
  final int requestCount;
}

// ---------------------------------------------------------------------------
// Collection → blocks
// ---------------------------------------------------------------------------

class _Node {
  _Node(this.name, this.path);
  final String name;
  final String path;
  final List<Object> children = [];
}

class _DocBuilder {
  _DocBuilder(this.c, this.secrets);

  final CollectionModel c;
  final Set<String> secrets;
  final List<_Block> blocks = [];
  var _anchors = 0;

  String m(String s) => maskSecrets(s, secrets);
  String _anchor() => 'sec-${++_anchors}';

  _Doc build() {
    blocks.add(_Heading(1, m(c.name), 'top'));
    if (c.description.trim().isNotEmpty) {
      blocks.add(_Para(m(c.description.trim())));
    }
    final auth = _authBlock('Auth', c.auth);
    if (auth != null) blocks.add(auth);
    _scripts(c.preRequestScript, c.testScript);
    _variables();

    final root = _Node(c.name, '');
    final index = <String, _Node>{'': root};
    for (final r in c.requests) {
      var parent = root;
      var path = '';
      if (r.folder.isNotEmpty) {
        for (final seg in r.folder.split('/')) {
          path = path.isEmpty ? seg : '$path/$seg';
          final p = parent;
          parent = index.putIfAbsent(path, () {
            final n = _Node(seg, path);
            p.children.add(n);
            return n;
          });
        }
      }
      parent.children.add(r);
    }
    for (final child in root.children) {
      _emit(child, 0);
    }
    return _Doc(m(c.name), blocks, c.requests.length);
  }

  void _emit(Object node, int depth) {
    if (node is _Node) {
      blocks.add(_Heading(_level(2 + depth), m(node.name), _anchor()));
      final meta = c.folders[node.path];
      if (meta != null) {
        if (meta.description.trim().isNotEmpty) {
          blocks.add(_Para(m(meta.description.trim())));
        }
        final auth = _authBlock('Folder auth', meta.auth);
        if (auth != null) blocks.add(auth);
        _scripts(meta.preRequestScript, meta.testScript);
      }
      for (final child in node.children) {
        _emit(child, depth + 1);
      }
    } else if (node is RequestModel) {
      _request(node, depth);
    }
  }

  int _level(int l) => l > 6 ? 6 : l;

  void _variables() {
    final vars = [
      for (final v in c.variables)
        if (v.enabled && v.key.isNotEmpty) v,
    ];
    if (vars.isEmpty) return;
    blocks.add(
      _Table(
        'Variables',
        const ['Name', 'Value', 'Description'],
        [
          for (final v in vars)
            [
              m(v.key),
              v.secret ? (v.value.isEmpty ? '' : docMask) : m(v.value),
              m(v.description),
            ],
        ],
      ),
    );
  }

  void _scripts(String pre, String test) {
    if (pre.trim().isNotEmpty) {
      blocks.add(_Details('Pre-request script', m(pre)));
    }
    if (test.trim().isNotEmpty) {
      blocks.add(_Details('Test script', m(test)));
    }
  }

  void _request(RequestModel r, int depth) {
    final badge = r.kind == RequestKind.http
        ? r.method.toUpperCase()
        : r.kind.badge;
    blocks.add(_Heading(_level(2 + depth), m(r.name), _anchor(), badge: badge));
    if (r.url.isNotEmpty) blocks.add(_Url(m(r.url)));
    if (r.description.trim().isNotEmpty) {
      blocks.add(_Para(m(r.description.trim())));
    }

    List<String> row(KV k) => [m(k.key), m(k.value), m(k.description)];
    _kvTable('Path variables', [
      for (final k in r.pathVariables)
        if (k.key.isNotEmpty) k,
    ], row);
    _kvTable('Query parameters', [
      for (final k in r.params)
        if (k.key.isNotEmpty) k,
    ], row);
    final headers = [
      for (final k in r.headers)
        if (k.key.isNotEmpty) k,
    ];
    _kvTable(
      'Headers',
      headers,
      (k) => [
        m(k.key),
        isSensitiveHeader(k.key) ? maskHeaderValue(m(k.value)) : m(k.value),
        m(k.description),
      ],
    );
    _body(r);

    final (auth, source) = _resolveAuth(r);
    final authBlock = _authBlock('Auth', auth, from: source);
    if (authBlock != null) blocks.add(authBlock);
    _scripts(r.preRequestScript, r.testScript);

    for (final e in r.examples) {
      _example(e);
    }
  }

  void _kvTable(String label, List<KV> rows, List<String> Function(KV) cells) {
    if (rows.isEmpty) return;
    final withDesc = rows.any((k) => k.description.isNotEmpty);
    blocks.add(
      _Table(
        label,
        withDesc
            ? const ['Name', 'Value', 'Description']
            : const ['Name', 'Value'],
        [for (final k in rows) withDesc ? cells(k) : cells(k).take(2).toList()],
        off: {
          for (var i = 0; i < rows.length; i++)
            if (!rows[i].enabled) i,
        },
      ),
    );
  }

  void _body(RequestModel r) {
    switch (r.bodyType) {
      case BodyType.none:
        return;
      case BodyType.formUrlEncoded || BodyType.formData:
        final fields = [
          for (final f in r.formFields)
            if (f.key.isNotEmpty) f,
        ];
        if (fields.isEmpty) return;
        blocks.add(
          _Table(
            'Body (${r.bodyType.label})',
            const ['Field', 'Value'],
            [
              for (final f in fields)
                [m(f.key), f.isFile ? '(file) ${m(f.value)}' : m(f.value)],
            ],
            off: {
              for (var i = 0; i < fields.length; i++)
                if (!fields[i].enabled) i,
            },
          ),
        );
      case BodyType.binary:
        blocks.add(
          const _Para(
            'a file is sent as the body',
            label: 'Body (Binary file)',
          ),
        );
      case BodyType.graphql:
        if (r.body.trim().isNotEmpty) {
          blocks.add(
            _Code(m(r.body), lang: 'graphql', label: 'Body (GraphQL)'),
          );
        }
        if (r.graphqlVariables.trim().isNotEmpty) {
          blocks.add(
            _Code(
              m(r.graphqlVariables),
              lang: 'json',
              label: 'GraphQL variables',
            ),
          );
        }
      case BodyType.json || BodyType.text || BodyType.xml:
        if (r.body.trim().isEmpty) return;
        blocks.add(
          _Code(
            _cap(m(r.body)),
            lang: switch (r.bodyType) {
              BodyType.json => 'json',
              BodyType.xml => 'xml',
              _ => '',
            },
            label: 'Body (${r.bodyType.label})',
          ),
        );
    }
  }

  /// The auth a request uses and where it comes from.
  (AuthConfig, String) _resolveAuth(RequestModel r) {
    if (r.auth.type != AuthType.inherit) return (r.auth, '');
    for (final path in CollectionModel.folderChain(r.folder).reversed) {
      final f = c.folders[path];
      if (f != null && f.auth.type != AuthType.inherit) {
        return (f.auth, 'the folder ${m(path.split('/').last)}');
      }
    }
    if (c.auth.type == AuthType.inherit) return (AuthConfig(), '');
    return (c.auth, 'the collection');
  }

  /// A short description of [a], or null for no auth and for inherit (which
  /// [_resolveAuth] has already followed). Only the type and non-secret
  /// settings are named; secrets are masked.
  _Block? _authBlock(String label, AuthConfig a, {String from = ''}) {
    if (a.type == AuthType.none || a.type == AuthType.inherit) return null;
    final lines = <String>[];
    switch (a.type) {
      case AuthType.bearer:
        lines.add('Token: ${_secretValue(a.bearerToken)}');
      case AuthType.basic:
        lines.add('Username: ${m(a.basicUser)}');
        lines.add('Password: ${_secretValue(a.basicPassword)}');
      case AuthType.apiKey:
        lines.add('Key: ${m(a.apiKeyName)}');
        lines.add('Value: ${_secretValue(a.apiKeyValue)}');
        lines.add('Sent in: ${a.apiKeyInHeader ? 'header' : 'query string'}');
      default:
        break;
    }
    final text = from.isEmpty ? a.type.label : '${a.type.label} (from $from)';
    return lines.isEmpty
        ? _Para(text, label: label)
        : _Bullets([text, ...lines], label: label);
  }

  /// A secret shown as a mask, unless it is only a `{{variable}}` name,
  /// which documents where the value comes from and is not itself secret.
  String _secretValue(String v) {
    if (v.isEmpty) return '(empty)';
    return _onlyVariables(v) ? m(v) : docMask;
  }

  void _example(ResponseExample e) {
    blocks.add(_ExampleTitle(m(e.name), e.statusCode));
    final o = e.originalRequest;
    if (o != null) {
      blocks.add(
        _Para('${o.method.toUpperCase()} ${m(o.url)}', label: 'Request'),
      );
    }
    blocks.add(
      _Para('${e.statusCode} ${m(e.statusText)}'.trim(), label: 'Status'),
    );
    final headers = [
      for (final h in e.headers)
        if (h.key.isNotEmpty) h,
    ];
    if (headers.isNotEmpty) {
      blocks.add(
        _Table(
          'Response headers',
          const ['Name', 'Value'],
          [
            for (final h in headers)
              [
                m(h.key),
                isSensitiveHeader(h.key)
                    ? maskHeaderValue(m(h.value))
                    : m(h.value),
              ],
          ],
        ),
      );
    }
    if (e.body.isNotEmpty) {
      var body = m(e.body);
      var lang = '';
      try {
        body = const JsonEncoder.withIndent('  ').convert(jsonDecode(body));
        lang = 'json';
      } catch (_) {
        final type = (e.contentType ?? '').toLowerCase();
        if (type.contains('xml')) lang = 'xml';
        if (type.contains('html')) lang = 'html';
      }
      blocks.add(_Code(_cap(body), lang: lang, label: 'Response body'));
    }
  }
}

bool _onlyVariables(String v) =>
    v.replaceAll(RegExp(r'\{\{[^{}]*\}\}'), '').trim().isEmpty;

String _cap(String s, [int max = 100 * 1024]) => s.length <= max
    ? s
    : '${s.substring(0, max)}\n… (${s.length - max} more characters not shown)';

/// True for headers that carry credentials: their values are masked.
bool isSensitiveHeader(String name) {
  final n = name.toLowerCase();
  return n == 'authorization' ||
      n == 'proxy-authorization' ||
      n == 'cookie' ||
      n == 'set-cookie' ||
      n.contains('api-key') ||
      n.contains('apikey') ||
      n.contains('token') ||
      n.contains('secret') ||
      n.contains('password');
}

/// A credential header's value as docs show it: the mask, with the scheme
/// word (`Bearer`) kept and `{{variable}}` references left readable.
String maskHeaderValue(String v) {
  if (v.trim().isEmpty) return '';
  if (_onlyVariables(v)) return v;
  final scheme = RegExp(
    r'^(Bearer|Basic|Digest|Token|Hawk|OAuth)\s+(.*)$',
    caseSensitive: false,
  ).firstMatch(v.trim());
  if (scheme != null) {
    final rest = scheme.group(2)!;
    return '${scheme.group(1)} ${_onlyVariables(rest) ? rest : docMask}';
  }
  return docMask;
}

// ---------------------------------------------------------------------------
// HTML
// ---------------------------------------------------------------------------

String _e(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

String _badgeClass(String badge) => switch (badge) {
  'GET' => 'm-get',
  'POST' => 'm-post',
  'PUT' => 'm-put',
  'PATCH' => 'm-patch',
  'DELETE' => 'm-delete',
  'QUERY' => 'm-query',
  _ => 'm-other',
};

String _statusClass(int code) {
  if (code >= 200 && code < 300) return 's-ok';
  if (code >= 300 && code < 400) return 's-redirect';
  if (code >= 400 && code < 500) return 's-client';
  if (code >= 500) return 's-server';
  return 's-other';
}

String _renderHtml(_Doc doc, DateTime? generatedAt) {
  final b = StringBuffer();
  b.writeln('<!doctype html>');
  b.writeln('<html lang="en">');
  b.writeln('<head>');
  b.writeln('<meta charset="utf-8">');
  b.writeln(
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
  );
  b.writeln('<meta name="color-scheme" content="light dark">');
  b.writeln('<title>${_e(doc.title)} - API documentation</title>');
  b.writeln('<style>$_css</style>');
  b.writeln('</head>');
  b.writeln('<body>');
  b.writeln('<div class="wrap">');

  // Table of contents.
  b.writeln('<nav class="toc"><details open><summary>Contents</summary><ul>');
  for (final blk in doc.blocks) {
    if (blk is! _Heading || blk.level == 1) continue;
    final depth = blk.level - 2;
    b.write('<li class="d$depth"><a href="#${blk.anchor}">');
    if (blk.badge != null) {
      b.write(
        '<span class="badge ${_badgeClass(blk.badge!)}">${_e(blk.badge!)}</span> ',
      );
    }
    b.writeln('${_e(blk.text)}</a></li>');
  }
  b.writeln('</ul></details></nav>');

  b.writeln('<main>');
  for (final blk in doc.blocks) {
    _htmlBlock(b, blk);
  }
  final stamp = (generatedAt ?? DateTime.now()).toString().substring(0, 16);
  b.writeln(
    '<footer>${doc.requestCount} request${doc.requestCount == 1 ? '' : 's'} '
    '&middot; generated by ApiWorkbench on ${_e(stamp)}</footer>',
  );
  b.writeln('</main>');
  b.writeln('</div>');
  b.writeln('</body>');
  b.writeln('</html>');
  return b.toString();
}

void _htmlBlock(StringBuffer b, _Block blk) {
  switch (blk) {
    case _Heading():
      b.write('<h${blk.level} id="${blk.anchor}">');
      if (blk.badge != null) {
        b.write(
          '<span class="badge ${_badgeClass(blk.badge!)}">${_e(blk.badge!)}</span> ',
        );
      }
      b.writeln('${_e(blk.text)}</h${blk.level}>');
    case _Para():
      final label = blk.label == null
          ? ''
          : '<strong>${_e(blk.label!)}:</strong> ';
      b.writeln('<p class="para">$label${_e(blk.text)}</p>');
    case _Bullets():
      if (blk.label != null) {
        b.writeln('<div class="label">${_e(blk.label!)}</div>');
      }
      b.writeln('<ul class="facts">');
      for (final i in blk.items) {
        b.writeln('<li>${_e(i)}</li>');
      }
      b.writeln('</ul>');
    case _Url():
      b.writeln('<p><code class="url">${_e(blk.text)}</code></p>');
    case _Table():
      b.writeln('<div class="label">${_e(blk.label)}</div>');
      b.writeln('<div class="tw"><table><thead><tr>');
      for (final c in blk.columns) {
        b.write('<th>${_e(c)}</th>');
      }
      b.writeln('</tr></thead><tbody>');
      for (var i = 0; i < blk.rows.length; i++) {
        b.write(blk.off.contains(i) ? '<tr class="off">' : '<tr>');
        for (final cell in blk.rows[i]) {
          b.write('<td>${_e(cell)}</td>');
        }
        b.writeln('</tr>');
      }
      b.writeln('</tbody></table></div>');
    case _Code():
      if (blk.label != null) {
        b.writeln('<div class="label">${_e(blk.label!)}</div>');
      }
      final lang = blk.lang.isEmpty ? '' : ' class="language-${_e(blk.lang)}"';
      b.writeln('<pre><code$lang>${_e(blk.text)}</code></pre>');
    case _Details():
      b.writeln(
        '<details class="script"><summary>${_e(blk.summary)}</summary>'
        '<pre><code>${_e(blk.text)}</code></pre></details>',
      );
    case _ExampleTitle():
      b.writeln(
        '<div class="example">Example: <strong>${_e(blk.name)}</strong> '
        '<span class="status ${_statusClass(blk.status)}">${blk.status}</span></div>',
      );
  }
}

const _css = '''
:root{color-scheme:light dark;--bg:#ffffff;--fg:#1c2128;--dim:#586069;--line:#d8dee4;--card:#f6f8fa;--code:#f3f4f6;--accent:#0969da}
@media (prefers-color-scheme:dark){:root{--bg:#0e1116;--fg:#e6edf3;--dim:#9aa4af;--line:#2d333b;--card:#161b22;--code:#1a2029;--accent:#58a6ff}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.55 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
.wrap{display:flex;max-width:1240px;margin:0 auto}
nav.toc{position:sticky;top:0;align-self:flex-start;flex:0 0 290px;max-height:100vh;overflow:auto;padding:20px 14px;border-right:1px solid var(--line);font-size:13px}
nav.toc summary{font-weight:700;cursor:pointer;margin-bottom:8px}
nav.toc ul{list-style:none;margin:0;padding:0}
nav.toc li{margin:3px 0;overflow-wrap:anywhere}
nav.toc li.d1{padding-left:12px}nav.toc li.d2{padding-left:24px}nav.toc li.d3{padding-left:36px}nav.toc li.d4{padding-left:48px}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
main{flex:1;min-width:0;padding:24px 32px 64px}
h1{font-size:28px;margin:0 0 8px}
h2{font-size:21px;margin:36px 0 8px;padding-bottom:6px;border-bottom:1px solid var(--line)}
h3,h4,h5,h6{font-size:17px;margin:28px 0 6px}
h2,h3,h4,h5,h6{scroll-margin-top:12px}
.para{margin:6px 0;white-space:pre-wrap;overflow-wrap:anywhere}
.label{font-size:12px;font-weight:700;text-transform:uppercase;letter-spacing:.04em;color:var(--dim);margin:14px 0 4px}
code,pre{font:13px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
code.url{background:var(--code);padding:4px 8px;border-radius:5px;overflow-wrap:anywhere}
pre{background:var(--code);border:1px solid var(--line);border-radius:6px;padding:12px;overflow:auto;margin:6px 0}
.tw{overflow-x:auto}
table{border-collapse:collapse;width:100%;font-size:13.5px}
th,td{border:1px solid var(--line);padding:6px 10px;text-align:left;vertical-align:top;overflow-wrap:anywhere}
th{background:var(--card);white-space:nowrap}
tr.off td{opacity:.5;text-decoration:line-through}
ul.facts{margin:4px 0;padding-left:20px}
.badge{display:inline-block;min-width:3.6em;padding:1px 7px;border-radius:5px;font:700 11.5px/1.6 ui-monospace,Menlo,Consolas,monospace;text-align:center;color:#fff;vertical-align:baseline}
.m-get{background:#1a7f37}.m-post{background:#b35900}.m-put{background:#0969da}.m-patch{background:#8250df}.m-delete{background:#cf222e}.m-query{background:#0a7d82}.m-other{background:#57606a}
.example{margin:20px 0 4px;padding:8px 12px;background:var(--card);border-left:3px solid var(--accent);border-radius:4px}
.status{font:700 12px ui-monospace,Menlo,Consolas,monospace;padding:1px 7px;border-radius:5px;color:#fff;margin-left:6px}
.s-ok{background:#1a7f37}.s-redirect{background:#0969da}.s-client{background:#b35900}.s-server{background:#cf222e}.s-other{background:#57606a}
details.script{margin:8px 0}details.script summary{cursor:pointer;color:var(--dim);font-size:13px}
footer{margin-top:48px;padding-top:12px;border-top:1px solid var(--line);color:var(--dim);font-size:12.5px}
@media (max-width:820px){.wrap{display:block}nav.toc{position:static;max-height:none;border-right:0;border-bottom:1px solid var(--line)}main{padding:16px}}
@media print{nav.toc{display:none}main{padding:0}pre{white-space:pre-wrap}}
''';

// ---------------------------------------------------------------------------
// Markdown
// ---------------------------------------------------------------------------

/// Text safe to put in a Markdown line: formatting characters and angle
/// brackets are escaped, newlines flattened.
String _mdText(String s) => s
    .replaceAll(RegExp(r'\r?\n'), ' ')
    .replaceAllMapped(RegExp(r'[\\`*_\[\]<>|]'), (m) => '\\${m[0]}');

/// Free text that is Markdown already (descriptions). Only `<` is escaped,
/// so raw HTML in it stays inert.
String _mdBody(String s) => s.replaceAll('<', r'\<');

String _mdCell(String s) => _mdText(s).replaceAll('\\|', r'\|');

/// A fenced block; the fence is longer than any run of backticks inside.
String _mdFence(String text, String lang) {
  var longest = 0;
  for (final m in RegExp('`+').allMatches(text)) {
    if (m.end - m.start > longest) longest = m.end - m.start;
  }
  final fence = '`' * (longest < 3 ? 3 : longest + 1);
  return '$fence$lang\n$text\n$fence';
}

/// An inline code span that survives backticks inside.
String _mdCode(String s) {
  final flat = s.replaceAll(RegExp(r'\r?\n'), ' ');
  var longest = 0;
  for (final m in RegExp('`+').allMatches(flat)) {
    if (m.end - m.start > longest) longest = m.end - m.start;
  }
  final tick = '`' * (longest + 1);
  final text = flat.trim();
  // CommonMark strips one space at each end, so pad only when a backtick
  // touches the delimiter.
  final pad = text.startsWith('`') || text.endsWith('`') ? ' ' : '';
  return '$tick$pad$text$pad$tick';
}

String _renderMarkdown(_Doc doc, DateTime? generatedAt) {
  final b = StringBuffer();
  // Table of contents first, so the document opens with it.
  final headings = [
    for (final blk in doc.blocks)
      if (blk is _Heading && blk.level > 1) blk,
  ];
  final first = doc.blocks.first as _Heading;
  b.writeln('# ${_mdText(first.text)}\n');
  var i = 1;
  // The description and collection-level blocks come before the first
  // folder or request heading; keep them above the contents list.
  while (i < doc.blocks.length && doc.blocks[i] is! _Heading) {
    _mdBlock(b, doc.blocks[i], true);
    i++;
  }
  if (headings.isNotEmpty) {
    b.writeln('## Contents\n');
    for (final h in headings) {
      final indent = '  ' * (h.level - 2);
      final badge = h.badge == null ? '' : '`${h.badge}` ';
      b.writeln('$indent- $badge[${_mdText(h.text)}](#${h.anchor})');
    }
    b.writeln();
  }
  for (; i < doc.blocks.length; i++) {
    _mdBlock(b, doc.blocks[i], false);
  }
  final stamp = (generatedAt ?? DateTime.now()).toString().substring(0, 16);
  b.writeln(
    '---\n${doc.requestCount} request${doc.requestCount == 1 ? '' : 's'} · '
    'generated by ApiWorkbench on $stamp',
  );
  return b.toString();
}

void _mdBlock(StringBuffer b, _Block blk, bool intro) {
  switch (blk) {
    case _Heading():
      final badge = blk.badge == null ? '' : '`${blk.badge}` ';
      b.writeln(
        '\n${'#' * blk.level} <a id="${blk.anchor}"></a>$badge${_mdText(blk.text)}\n',
      );
    case _Para():
      final label = blk.label == null ? '' : '**${_mdText(blk.label!)}:** ';
      b.writeln(
        '$label${blk.label == null ? _mdBody(blk.text) : _mdText(blk.text)}\n',
      );
    case _Bullets():
      if (blk.label != null) b.writeln('**${_mdText(blk.label!)}**\n');
      for (final i in blk.items) {
        b.writeln('- ${_mdText(i)}');
      }
      b.writeln();
    case _Url():
      b.writeln('${_mdCode(blk.text)}\n');
    case _Table():
      b.writeln('**${_mdText(blk.label)}**\n');
      b.writeln('| ${blk.columns.map(_mdCell).join(' | ')} |');
      b.writeln('|${' --- |' * blk.columns.length}');
      for (var i = 0; i < blk.rows.length; i++) {
        final cells = [
          for (var k = 0; k < blk.rows[i].length; k++)
            k == 0 && blk.off.contains(i)
                ? '${_mdCell(blk.rows[i][k])} _(disabled)_'
                : _mdCell(blk.rows[i][k]),
        ];
        b.writeln('| ${cells.join(' | ')} |');
      }
      b.writeln();
    case _Code():
      if (blk.label != null) b.writeln('**${_mdText(blk.label!)}**\n');
      b.writeln('${_mdFence(blk.text, blk.lang)}\n');
    case _Details():
      b.writeln('<details><summary>${_mdSummary(blk.summary)}</summary>\n');
      b.writeln('${_mdFence(blk.text, 'js')}\n');
      b.writeln('</details>\n');
    case _ExampleTitle():
      b.writeln('\n**Example: ${_mdText(blk.name)}** `${blk.status}`\n');
  }
}

String _mdSummary(String s) => _e(s);
