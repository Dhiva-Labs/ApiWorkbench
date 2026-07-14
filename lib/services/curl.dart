import 'dart:convert';

import '../models/models.dart';

/// Builds a cURL command from a request (after variable substitution is NOT
/// applied — the export keeps {{vars}} so it stays portable).
String toCurl(RequestModel r) {
  final b = StringBuffer('curl');
  final method = r.method.toUpperCase();
  if (method != 'GET') b.write(' -X $method');

  var url = r.url.trim();
  final query = r.params
      .where((p) => p.enabled && p.key.isNotEmpty)
      .map((p) =>
          '${Uri.encodeQueryComponent(p.key)}=${Uri.encodeQueryComponent(p.value)}')
      .join('&');
  if (query.isNotEmpty) {
    url = url.contains('?') ? '$url&$query' : '$url?$query';
  }
  b.write(" '${url.replaceAll("'", r"'\''")}'");

  for (final h in r.headers.where((h) => h.enabled && h.key.isNotEmpty)) {
    b.write(" \\\n  -H '${h.key}: ${h.value}'".replaceAll('\n', '\n'));
  }
  switch (r.authType) {
    case AuthType.bearer:
      b.write(" \\\n  -H 'Authorization: Bearer ${r.bearerToken}'");
    case AuthType.basic:
      b.write(" \\\n  -u '${r.basicUser}:${r.basicPassword}'");
    case AuthType.apiKey:
      if (r.apiKeyInHeader && r.apiKeyName.isNotEmpty) {
        b.write(" \\\n  -H '${r.apiKeyName}: ${r.apiKeyValue}'");
      }
    case AuthType.none:
      break;
  }

  if (r.bodyType == BodyType.formUrlEncoded) {
    for (final f in r.formFields.where((f) => f.enabled && f.key.isNotEmpty)) {
      b.write(" \\\n  --data-urlencode '${f.key}=${f.value}'");
    }
  } else if (r.bodyType == BodyType.graphql && r.body.isNotEmpty) {
    Object? gqlVars;
    try {
      if (r.graphqlVariables.trim().isNotEmpty) {
        gqlVars = jsonDecode(r.graphqlVariables);
      }
    } catch (_) {}
    final payload =
        jsonEncode({'query': r.body, 'variables': ?gqlVars});
    b.write(" \\\n  -d '${payload.replaceAll("'", r"'\''")}'");
  } else if (r.bodyType != BodyType.none && r.body.isNotEmpty) {
    b.write(" \\\n  -d '${r.body.replaceAll("'", r"'\''")}'");
  }
  return b.toString();
}

/// Parses a (reasonably standard) cURL command into a request.
/// Supports -X/--request, -H/--header, -d/--data/--data-raw, -u/--user,
/// and the bare URL. Returns null if no URL is found.
RequestModel? fromCurl(String input) {
  final tokens = _tokenize(input.trim());
  if (tokens.isEmpty || tokens.first != 'curl') return null;

  final r = RequestModel();
  String? explicitMethod;
  var hasData = false;

  for (var i = 1; i < tokens.length; i++) {
    final t = tokens[i];
    String? next() => i + 1 < tokens.length ? tokens[++i] : null;

    switch (t) {
      case '-X' || '--request':
        explicitMethod = next()?.toUpperCase();
      case '-H' || '--header':
        final h = next();
        if (h != null) {
          final idx = h.indexOf(':');
          if (idx > 0) {
            r.headers.add(KV(
                key: h.substring(0, idx).trim(),
                value: h.substring(idx + 1).trim()));
          }
        }
      case '-d' || '--data' || '--data-raw' || '--data-binary':
        final d = next();
        if (d != null) {
          hasData = true;
          r.body = d;
        }
      case '--data-urlencode':
        final d = next();
        if (d != null) {
          hasData = true;
          final idx = d.indexOf('=');
          if (idx > 0) {
            r.bodyType = BodyType.formUrlEncoded;
            r.formFields
                .add(KV(key: d.substring(0, idx), value: d.substring(idx + 1)));
          }
        }
      case '-u' || '--user':
        final u = next();
        if (u != null) {
          final idx = u.indexOf(':');
          r.authType = AuthType.basic;
          r.basicUser = idx >= 0 ? u.substring(0, idx) : u;
          r.basicPassword = idx >= 0 ? u.substring(idx + 1) : '';
        }
      case '-F' || '--form':
        next(); // multipart not supported yet; skip the value
      case '--url':
        r.url = next() ?? '';
      case '-L' || '--location' || '-s' || '--silent' || '-k' || '--insecure' || '--compressed':
        break; // flags without values we can ignore
      default:
        if (!t.startsWith('-') && r.url.isEmpty) r.url = t;
    }
  }

  if (r.url.isEmpty) return null;
  r.method = explicitMethod ?? (hasData ? 'POST' : 'GET');
  if (hasData && r.bodyType == BodyType.none) {
    final ct = r.headers.where(
        (h) => h.key.toLowerCase() == 'content-type');
    final ctv = ct.isEmpty ? '' : ct.first.value.toLowerCase();
    r.bodyType = ctv.contains('json')
        ? BodyType.json
        : ctv.contains('x-www-form-urlencoded')
            ? BodyType.formUrlEncoded
            : BodyType.text;
    if (r.bodyType == BodyType.formUrlEncoded && r.formFields.isEmpty) {
      for (final pair in r.body.split('&')) {
        final idx = pair.indexOf('=');
        if (idx > 0) {
          r.formFields.add(KV(
              key: Uri.decodeQueryComponent(pair.substring(0, idx)),
              value: Uri.decodeQueryComponent(pair.substring(idx + 1))));
        }
      }
      r.body = '';
    }
  }
  r.name = Uri.tryParse(r.url)?.path.split('/').lastWhere(
          (s) => s.isNotEmpty,
          orElse: () => r.url) ??
      r.url;
  return r;
}

/// Shell-style tokenizer handling single quotes, double quotes and
/// backslash-newline continuations.
List<String> _tokenize(String s) {
  final out = <String>[];
  final cur = StringBuffer();
  var inSingle = false, inDouble = false, hasToken = false;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (inSingle) {
      if (c == "'") {
        inSingle = false;
      } else {
        cur.write(c);
      }
    } else if (inDouble) {
      if (c == '"') {
        inDouble = false;
      } else if (c == r'\' && i + 1 < s.length && '"\\'.contains(s[i + 1])) {
        cur.write(s[++i]);
      } else {
        cur.write(c);
      }
    } else if (c == "'") {
      inSingle = true;
      hasToken = true;
    } else if (c == '"') {
      inDouble = true;
      hasToken = true;
    } else if (c == r'\' && i + 1 < s.length) {
      final n = s[i + 1];
      if (n == '\n') {
        i++; // line continuation
      } else {
        cur.write(n);
        i++;
        hasToken = true;
      }
    } else if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      if (hasToken || cur.isNotEmpty) {
        out.add(cur.toString());
        cur.clear();
        hasToken = false;
      }
    } else {
      cur.write(c);
      hasToken = true;
    }
  }
  if (hasToken || cur.isNotEmpty) out.add(cur.toString());
  return out;
}
