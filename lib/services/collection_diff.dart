import 'dart:convert';
import 'dart:typed_data';

import '../models/models.dart';

/// Shown in place of a secret value in a diff.
const diffMask = '••••••';

/// One line of a line diff.
class DiffLine {
  const DiffLine(this.added, this.text);

  /// True for a line only in the newer side, false for one only in the
  /// older side.
  final bool added;
  final String text;
}

/// One field that differs between two versions of the same thing, held as
/// the lines each side shows. A single-value field has one line (or none
/// when empty), a list field one line per row, a script or body its text.
class FieldChange {
  const FieldChange(this.field, this.before, this.after);

  final String field;
  final List<String> before;
  final List<String> after;

  /// Short values read best as `old → new` on one line.
  bool get isInline =>
      before.length <= 1 &&
      after.length <= 1 &&
      [...before, ...after].every((l) => l.length <= 80);

  /// Only the lines that differ, removed ones before the added ones they
  /// were replaced by.
  List<DiffLine> get lines => diffLines(before, after);
}

/// What changed in one request, matched by id.
class RequestDiff {
  const RequestDiff(this.before, this.after, this.changes);

  final RequestModel before;
  final RequestModel after;
  final List<FieldChange> changes;
}

/// The difference between two versions of a collection.
class CollectionDiff {
  const CollectionDiff({
    this.added = const [],
    this.removed = const [],
    this.changed = const [],
    this.collection = const [],
  });

  /// Requests only in the newer version.
  final List<RequestModel> added;

  /// Requests only in the older version.
  final List<RequestModel> removed;
  final List<RequestDiff> changed;

  /// Name, description, auth, scripts, variables, folder settings and
  /// request order.
  final List<FieldChange> collection;

  bool get isEmpty =>
      added.isEmpty && removed.isEmpty && changed.isEmpty && collection.isEmpty;

  /// One line for a snapshot list, e.g. `2 requests added, 1 request
  /// changed, auth changed`.
  String get summary {
    if (isEmpty) return 'No changes';
    String n(int count, String what) =>
        '$count request${count == 1 ? '' : 's'} $what';
    final parts = <String>[
      if (added.isNotEmpty) n(added.length, 'added'),
      if (removed.isNotEmpty) n(removed.length, 'removed'),
      if (changed.isNotEmpty) n(changed.length, 'changed'),
    ];
    if (collection.isNotEmpty) {
      final names = <String>[];
      for (final c in collection) {
        final name = c.field.toLowerCase();
        if (!names.contains(name)) names.add(name);
        if (names.length == 3) break;
      }
      final more = collection.length > names.length ? ', …' : '';
      parts.add('collection: ${names.join(', ')}$more');
    }
    return parts.join(', ');
  }
}

/// What changed from [before] to [after]. Requests are matched by id.
CollectionDiff diffCollections(CollectionModel before, CollectionModel after) {
  final oldById = {for (final r in before.requests) r.id: r};
  final newById = {for (final r in after.requests) r.id: r};
  final added = <RequestModel>[
    for (final r in after.requests)
      if (!oldById.containsKey(r.id)) r,
  ];
  final removed = <RequestModel>[
    for (final r in before.requests)
      if (!newById.containsKey(r.id)) r,
  ];
  final changed = <RequestDiff>[];
  for (final r in after.requests) {
    final old = oldById[r.id];
    if (old == null) continue;
    if (jsonEncode(old.toJson()) == jsonEncode(r.toJson())) continue;
    final changes = diffRequests(old, r);
    changed.add(
      RequestDiff(
        old,
        r,
        changes.isEmpty
            ? const [
                FieldChange('Details', [], ['modified']),
              ]
            : changes,
      ),
    );
  }

  final col = <FieldChange>[];
  void scalar(String field, String a, String b) {
    if (a != b) col.add(FieldChange(field, _text(a), _text(b)));
  }

  scalar('Name', before.name, after.name);
  scalar('Description', before.description, after.description);
  final auth = _authChange('Auth', before.auth, after.auth);
  if (auth != null) col.add(auth);
  scalar('Pre-request script', before.preRequestScript, after.preRequestScript);
  scalar('Test script', before.testScript, after.testScript);
  _listChange(
    col,
    'Variables',
    _kvLines(before.variables, variables: true),
    _variableLines(before.variables, after.variables),
  );
  _folderChanges(col, before.folders, after.folders);

  // Order matters to people who run a collection top to bottom.
  final common = [
    for (final r in before.requests)
      if (newById.containsKey(r.id)) r.id,
  ];
  final commonNew = [
    for (final r in after.requests)
      if (oldById.containsKey(r.id)) r.id,
  ];
  if (common.length == commonNew.length) {
    for (var i = 0; i < common.length; i++) {
      if (common[i] != commonNew[i]) {
        col.add(const FieldChange('Request order', [], ['reordered']));
        break;
      }
    }
  }

  return CollectionDiff(
    added: added,
    removed: removed,
    changed: changed,
    collection: col,
  );
}

/// Field-by-field changes from [a] to [b]. Secrets (tokens, passwords,
/// secret variables) are never shown; a changed one reads as `updated`.
List<FieldChange> diffRequests(RequestModel a, RequestModel b) {
  final out = <FieldChange>[];
  void scalar(String field, String x, String y) {
    if (x != y) out.add(FieldChange(field, _text(x), _text(y)));
  }

  scalar('Name', a.name, b.name);
  scalar('Type', a.kind.label, b.kind.label);
  scalar('Method', a.method, b.method);
  scalar('URL', a.url, b.url);
  scalar('Folder', a.folder, b.folder);
  scalar('Description', a.description, b.description);
  _listChange(out, 'Query params', _kvLines(a.params), _kvLines(b.params));
  _listChange(
    out,
    'Path variables',
    _kvLines(a.pathVariables),
    _kvLines(b.pathVariables),
  );
  _listChange(out, 'Headers', _kvLines(a.headers), _kvLines(b.headers));
  scalar('Body type', a.bodyType.label, b.bodyType.label);
  scalar('Body', a.body, b.body);
  scalar('GraphQL variables', a.graphqlVariables, b.graphqlVariables);
  _listChange(
    out,
    'Form fields',
    _kvLines(a.formFields),
    _kvLines(b.formFields),
  );
  final auth = _authChange('Auth', a.auth, b.auth);
  if (auth != null) out.add(auth);
  scalar('Pre-request script', a.preRequestScript, b.preRequestScript);
  scalar('Test script', a.testScript, b.testScript);
  _listChange(
    out,
    'Assertions',
    [for (final x in a.assertions) _assertionLine(x)],
    [for (final x in b.assertions) _assertionLine(x)],
  );
  _listChange(
    out,
    'Captures',
    [for (final e in a.captures.entries) '${e.key} = ${e.value}'],
    [for (final e in b.captures.entries) '${e.key} = ${e.value}'],
  );
  _listChange(
    out,
    'Settings',
    _jsonLines(a.settings.toJson()),
    _jsonLines(b.settings.toJson()),
  );
  _listChange(
    out,
    'Examples',
    _exampleLines(a.examples, b.examples, first: true),
    _exampleLines(a.examples, b.examples, first: false),
  );
  _listChange(
    out,
    'Protocol settings',
    _jsonLines(a.protocolConfig),
    _jsonLines(b.protocolConfig),
  );
  return out;
}

void _folderChanges(
  List<FieldChange> out,
  Map<String, FolderMeta> a,
  Map<String, FolderMeta> b,
) {
  final paths = <String>{...a.keys, ...b.keys}.toList()..sort();
  for (final p in paths) {
    final x = a[p] ?? FolderMeta();
    final y = b[p] ?? FolderMeta();
    if (jsonEncode(x.toJson()) == jsonEncode(y.toJson())) continue;
    final label = 'Folder $p';
    if (x.description != y.description) {
      out.add(
        FieldChange(
          '$label: description',
          _text(x.description),
          _text(y.description),
        ),
      );
    }
    final auth = _authChange('$label: auth', x.auth, y.auth);
    if (auth != null) out.add(auth);
    if (x.preRequestScript != y.preRequestScript) {
      out.add(
        FieldChange(
          '$label: pre-request script',
          _text(x.preRequestScript),
          _text(y.preRequestScript),
        ),
      );
    }
    if (x.testScript != y.testScript) {
      out.add(
        FieldChange(
          '$label: test script',
          _text(x.testScript),
          _text(y.testScript),
        ),
      );
    }
  }
}

void _listChange(
  List<FieldChange> out,
  String field,
  List<String> a,
  List<String> b,
) {
  if (_sameLines(a, b)) return;
  out.add(FieldChange(field, a, b));
}

bool _sameLines(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

List<String> _text(String s) =>
    s.isEmpty ? const [] : s.split(RegExp(r'\r?\n'));

String _assertionLine(AssertionModel a) {
  final target = a.kind.hasTarget && a.target.isNotEmpty ? ' ${a.target}' : '';
  return '${a.kind.label}$target: ${a.expected}${a.enabled ? '' : ' (disabled)'}';
}

List<String> _kvLines(List<KV> rows, {bool variables = false}) => [
  for (final r in rows)
    if (r.key.isNotEmpty || r.value.isNotEmpty) _kvLine(r, variables),
];

/// The newer variables as lines. A secret that changed shows the same mask
/// as before, so it is marked as updated.
List<String> _variableLines(List<KV> before, List<KV> after) {
  final old = {for (final v in before) v.key: v};
  return [
    for (final r in after)
      if (r.key.isNotEmpty || r.value.isNotEmpty)
        '${_kvLine(r, true)}${r.secret && old[r.key] != null && (old[r.key]!.value != r.value || old[r.key]!.current != r.current) ? ' (updated)' : ''}',
  ];
}

String _kvLine(KV r, bool variables) {
  final secret = variables && r.secret;
  final value = r.isFile
      ? '@file ${r.value}'
      : (secret && r.value.isNotEmpty ? diffMask : r.value);
  final b = StringBuffer('${r.key}: $value');
  if (variables && r.current != null && r.current != r.value) {
    b.write(' (current: ${secret ? diffMask : r.current})');
  }
  if (secret) b.write(' [secret]');
  if (!r.enabled) b.write(' (disabled)');
  if (r.description.isNotEmpty) {
    b.write(' // ${r.description.replaceAll('\n', ' ')}');
  }
  return b.toString();
}

List<String> _jsonLines(Map<String, dynamic> m) => [
  for (final e in m.entries) '${e.key}: ${_short(jsonEncode(e.value))}',
];

String _short(String s) => s.length <= 200 ? s : '${s.substring(0, 200)}…';

/// One line per example of the older ([first]) or newer side. An example
/// whose content changed without its name or status changing is marked, so
/// the edit still shows.
List<String> _exampleLines(
  List<ResponseExample> a,
  List<ResponseExample> b, {
  required bool first,
}) {
  String line(ResponseExample e) =>
      '${e.name} (${e.statusCode} ${e.statusText})'.trim();
  final other = {for (final e in first ? b : a) e.id: jsonEncode(e.toJson())};
  return [
    for (final e in first ? a : b)
      if (!first &&
          other[e.id] != null &&
          other[e.id] != jsonEncode(e.toJson()))
        '${line(e)} (edited)'
      else
        line(e),
  ];
}

/// Param keys that hold secrets, whatever the auth type.
const _secretParams = {
  'accessToken',
  'refreshToken',
  'clientSecret',
  'password',
  'consumerSecret',
  'tokenSecret',
  'privateKey',
  'secretKey',
  'sessionToken',
  'authKey',
  'secret',
  'code_verifier',
  'passphrase',
  'headerSecret',
};

/// True when [key] of [AuthConfig.params] holds a secret.
bool isSecretAuthParam(String key) => _secretParams.contains(key);

FieldChange? _authChange(String field, AuthConfig a, AuthConfig b) {
  final x = _authLines(a);
  final y = _authLines(b);
  // A secret that changed shows the same mask on both sides, so mark it.
  for (var i = 0; i < y.length; i++) {
    final key = y[i].split(': ').first;
    final old = x.indexWhere((l) => l.startsWith('$key: '));
    if (old < 0 || x[old] != y[i]) continue;
    if (_authSecret(a, key) != _authSecret(b, key)) y[i] = '${y[i]} (updated)';
  }
  if (_sameLines(x, y)) return null;
  return FieldChange(field, x, y);
}

String _authSecret(AuthConfig a, String label) => switch (label) {
  'Bearer token' => a.bearerToken,
  'Password' => a.basicPassword,
  'API key value' => a.apiKeyValue,
  _ => a.params[label] ?? '',
};

List<String> _authLines(AuthConfig a) {
  String show(String key, String v) =>
      v.isEmpty ? '(empty)' : (isSecretAuthParam(key) ? diffMask : v);
  final lines = <String>['Type: ${a.type.label}'];
  switch (a.type) {
    case AuthType.bearer:
      lines.add(
        'Bearer token: ${a.bearerToken.isEmpty ? '(empty)' : diffMask}',
      );
    case AuthType.basic:
      lines.add('Username: ${a.basicUser}');
      lines.add('Password: ${a.basicPassword.isEmpty ? '(empty)' : diffMask}');
    case AuthType.apiKey:
      lines.add('Key name: ${a.apiKeyName}');
      lines.add(
        'API key value: ${a.apiKeyValue.isEmpty ? '(empty)' : diffMask}',
      );
      lines.add('Sent in: ${a.apiKeyInHeader ? 'header' : 'query'}');
    case AuthType.none || AuthType.inherit:
      break;
    default:
      final keys = a.params.keys.toList()..sort();
      for (final k in keys) {
        lines.add('$k: ${show(k, a.params[k]!)}');
      }
  }
  return lines;
}

/// The lines that differ between [a] and [b]: removed lines (`added`
/// false) and added ones, in the order they occur. Common leading and
/// trailing lines are dropped first; a middle too large to compare
/// precisely is reported as wholly replaced.
List<DiffLine> diffLines(List<String> a, List<String> b) {
  var start = 0;
  while (start < a.length && start < b.length && a[start] == b[start]) {
    start++;
  }
  var endA = a.length;
  var endB = b.length;
  while (endA > start && endB > start && a[endA - 1] == b[endB - 1]) {
    endA--;
    endB--;
  }
  final x = a.sublist(start, endA);
  final y = b.sublist(start, endB);
  final out = <DiffLine>[];
  if (x.isEmpty || y.isEmpty || x.length * y.length > _maxCells) {
    return [
      for (final l in x) DiffLine(false, l),
      for (final l in y) DiffLine(true, l),
    ];
  }
  // Longest common subsequence of the differing middle.
  final w = y.length + 1;
  final t = Uint16List((x.length + 1) * w);
  for (var i = x.length - 1; i >= 0; i--) {
    for (var j = y.length - 1; j >= 0; j--) {
      t[i * w + j] = x[i] == y[j]
          ? t[(i + 1) * w + j + 1] + 1
          : (t[(i + 1) * w + j] >= t[i * w + j + 1]
                ? t[(i + 1) * w + j]
                : t[i * w + j + 1]);
    }
  }
  var i = 0;
  var j = 0;
  while (i < x.length && j < y.length) {
    if (x[i] == y[j]) {
      i++;
      j++;
    } else if (t[(i + 1) * w + j] >= t[i * w + j + 1]) {
      out.add(DiffLine(false, x[i++]));
    } else {
      out.add(DiffLine(true, y[j++]));
    }
  }
  while (i < x.length) {
    out.add(DiffLine(false, x[i++]));
  }
  while (j < y.length) {
    out.add(DiffLine(true, y[j++]));
  }
  return out;
}

// Uint16 cells hold common-run lengths up to 65535, far more than the
// middle sizes allowed here.
const _maxCells = 1000000;
