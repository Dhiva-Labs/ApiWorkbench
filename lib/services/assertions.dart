import 'dart:convert';

import '../models/models.dart';

const _missing = Object();

/// Walks a dot/bracket path like `data.items[0].name` into decoded JSON.
/// Returns [_missing] (checked via [jsonPathFound]) when the path breaks.
Object? jsonAtPath(Object? root, String path) {
  Object? cur = root;
  final re = RegExp(r'([^.\[\]]+)|\[(\d+)\]');
  for (final m in re.allMatches(path)) {
    final key = m.group(1);
    if (key != null) {
      if (cur is Map && cur.containsKey(key)) {
        cur = cur[key];
      } else {
        return _missing;
      }
    } else {
      final i = int.parse(m.group(2)!);
      if (cur is List && i >= 0 && i < cur.length) {
        cur = cur[i];
      } else {
        return _missing;
      }
    }
  }
  return cur;
}

bool jsonPathFound(Object? v) => !identical(v, _missing);

/// Evaluates every enabled assertion of [request] against [res].
List<AssertionResult> evaluateAssertions(
    RequestModel request, ResponseData res) {
  final out = <AssertionResult>[];
  for (final a in request.assertions.where((a) => a.enabled)) {
    out.add(_one(a, res));
  }
  return out;
}

AssertionResult _one(AssertionModel a, ResponseData res) {
  if (res.error != null) {
    return AssertionResult(a, false, 'request failed: ${res.error}');
  }
  switch (a.kind) {
    case AssertKind.statusEquals:
      final want = int.tryParse(a.expected.trim());
      if (want == null) {
        return AssertionResult(a, false, '"${a.expected}" is not a number');
      }
      return AssertionResult(a, res.statusCode == want,
          'expected $want, got ${res.statusCode}');
    case AssertKind.bodyContains:
      final ok = res.bodyText.contains(a.expected);
      return AssertionResult(
          a, ok, ok ? 'found "${_trunc(a.expected)}"' : 'not found in body');
    case AssertKind.jsonEquals:
      Object? decoded;
      try {
        decoded = jsonDecode(res.bodyText);
      } catch (_) {
        return AssertionResult(a, false, 'body is not valid JSON');
      }
      final v = jsonAtPath(decoded, a.target.trim());
      if (!jsonPathFound(v)) {
        return AssertionResult(a, false, 'path "${a.target}" not found');
      }
      final actual = v?.toString() ?? 'null';
      return AssertionResult(a, actual == a.expected,
          'expected "${_trunc(a.expected)}", got "${_trunc(actual)}"');
    case AssertKind.headerContains:
      final name = a.target.trim().toLowerCase();
      String? value;
      for (final e in res.headers.entries) {
        if (e.key.toLowerCase() == name) value = e.value.join(', ');
      }
      if (value == null) {
        return AssertionResult(a, false, 'header "${a.target}" is absent');
      }
      if (a.expected.isEmpty) {
        return AssertionResult(a, true, 'header present');
      }
      final ok = value.toLowerCase().contains(a.expected.toLowerCase());
      return AssertionResult(
          a, ok, ok ? 'matched "${_trunc(value)}"' : 'value is "${_trunc(value)}"');
    case AssertKind.timeBelow:
      final limit = int.tryParse(a.expected.trim());
      if (limit == null) {
        return AssertionResult(a, false, '"${a.expected}" is not a number');
      }
      return AssertionResult(a, res.durationMs < limit,
          'took ${res.durationMs} ms (limit $limit ms)');
  }
}

String _trunc(String s) => s.length <= 60 ? s : '${s.substring(0, 57)}…';
