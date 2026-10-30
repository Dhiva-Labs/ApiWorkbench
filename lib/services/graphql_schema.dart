/// GraphQL schema tools for the query editor: the standard introspection
/// query and a schema model read from its result, field suggestions at the
/// cursor, click-to-insert fields with their required arguments as
/// variables, and a prettifier.
library;

import 'dart:convert';

/// The introspection query GraphiQL and Postman send.
const introspectionQuery = r'''
query IntrospectionQuery {
  __schema {
    queryType { name }
    mutationType { name }
    subscriptionType { name }
    types { ...FullType }
    directives {
      name
      description
      locations
      args { ...InputValue }
    }
  }
}

fragment FullType on __Type {
  kind
  name
  description
  fields(includeDeprecated: true) {
    name
    description
    args { ...InputValue }
    type { ...TypeRef }
    isDeprecated
    deprecationReason
  }
  inputFields { ...InputValue }
  interfaces { ...TypeRef }
  enumValues(includeDeprecated: true) {
    name
    description
    isDeprecated
    deprecationReason
  }
  possibleTypes { ...TypeRef }
}

fragment InputValue on __InputValue {
  name
  description
  type { ...TypeRef }
  defaultValue
}

fragment TypeRef on __Type {
  kind
  name
  ofType {
    kind
    name
    ofType {
      kind
      name
      ofType {
        kind
        name
        ofType {
          kind
          name
          ofType {
            kind
            name
            ofType {
              kind
              name
              ofType { kind name }
            }
          }
        }
      }
    }
  }
}
''';

/// Schemas fetched this session, by endpoint URL (variables filled in).
final Map<String, GraphqlSchema> graphqlSchemaCache = {};

// ---------------- Schema model ----------------

/// A type as used by a field or argument: `[User!]!` is NON_NULL of LIST
/// of NON_NULL of the named type User.
class GqlTypeRef {
  const GqlTypeRef(this.kind, this.name, [this.ofType]);

  factory GqlTypeRef.fromJson(Object? j) {
    final m = (j as Map?) ?? const {};
    return GqlTypeRef(
      '${m['kind'] ?? 'SCALAR'}',
      m['name'] as String?,
      m['ofType'] == null ? null : GqlTypeRef.fromJson(m['ofType']),
    );
  }

  final String kind;
  final String? name;
  final GqlTypeRef? ofType;

  bool get isNonNull => kind == 'NON_NULL';
  bool get isList => kind == 'LIST';

  /// The innermost named type.
  String get namedType => name ?? ofType?.namedType ?? '';

  @override
  String toString() => switch (kind) {
    'NON_NULL' => '$ofType!',
    'LIST' => '[$ofType]',
    _ => name ?? '?',
  };
}

/// An argument or an input object field.
class GqlInputValue {
  GqlInputValue(this.name, this.type, {this.description, this.defaultValue});

  factory GqlInputValue.fromJson(Map<String, Object?> j) => GqlInputValue(
    '${j['name']}',
    GqlTypeRef.fromJson(j['type']),
    description: j['description'] as String?,
    defaultValue: j['defaultValue'] as String?,
  );

  final String name;
  final GqlTypeRef type;
  final String? description;
  final String? defaultValue;

  /// Non-null with no default: the caller must pass it.
  bool get isRequired => type.isNonNull && defaultValue == null;
}

class GqlField {
  GqlField(
    this.name,
    this.type, {
    this.description,
    this.args = const [],
    this.isDeprecated = false,
    this.deprecationReason,
  });

  factory GqlField.fromJson(Map<String, Object?> j) => GqlField(
    '${j['name']}',
    GqlTypeRef.fromJson(j['type']),
    description: j['description'] as String?,
    args: [for (final a in _maps(j['args'])) GqlInputValue.fromJson(a)],
    isDeprecated: j['isDeprecated'] == true,
    deprecationReason: j['deprecationReason'] as String?,
  );

  final String name;
  final GqlTypeRef type;
  final String? description;
  final List<GqlInputValue> args;
  final bool isDeprecated;
  final String? deprecationReason;

  Iterable<GqlInputValue> get requiredArgs => args.where((a) => a.isRequired);
}

class GqlEnumValue {
  GqlEnumValue(this.name, {this.description, this.isDeprecated = false});

  final String name;
  final String? description;
  final bool isDeprecated;
}

class GqlType {
  GqlType({
    required this.kind,
    required this.name,
    this.description,
    this.fields = const [],
    this.inputFields = const [],
    this.interfaces = const [],
    this.enumValues = const [],
    this.possibleTypes = const [],
  });

  factory GqlType.fromJson(Map<String, Object?> j) => GqlType(
    kind: '${j['kind']}',
    name: '${j['name']}',
    description: j['description'] as String?,
    fields: [for (final f in _maps(j['fields'])) GqlField.fromJson(f)],
    inputFields: [
      for (final f in _maps(j['inputFields'])) GqlInputValue.fromJson(f),
    ],
    interfaces: [
      for (final i in _maps(j['interfaces'])) GqlTypeRef.fromJson(i).namedType,
    ],
    enumValues: [
      for (final e in _maps(j['enumValues']))
        GqlEnumValue(
          '${e['name']}',
          description: e['description'] as String?,
          isDeprecated: e['isDeprecated'] == true,
        ),
    ],
    possibleTypes: [
      for (final p in _maps(j['possibleTypes']))
        GqlTypeRef.fromJson(p).namedType,
    ],
  );

  /// SCALAR, OBJECT, INTERFACE, UNION, ENUM or INPUT_OBJECT.
  final String kind;
  final String name;
  final String? description;
  final List<GqlField> fields;
  final List<GqlInputValue> inputFields;
  final List<String> interfaces;
  final List<GqlEnumValue> enumValues;
  final List<String> possibleTypes;

  /// Has fields to select (and needs a selection set when queried).
  bool get isComposite =>
      kind == 'OBJECT' || kind == 'INTERFACE' || kind == 'UNION';
  bool get isLeaf => kind == 'SCALAR' || kind == 'ENUM';

  GqlField? field(String name) {
    for (final f in fields) {
      if (f.name == name) return f;
    }
    return null;
  }
}

List<Map<String, Object?>> _maps(Object? v) => [
  for (final e in v as List? ?? const []) (e as Map).cast<String, Object?>(),
];

/// The three GraphQL operation types, in display order.
const graphqlOperations = ['query', 'mutation', 'subscription'];

/// A schema read from an introspection result.
class GraphqlSchema {
  GraphqlSchema({
    required this.types,
    this.queryType,
    this.mutationType,
    this.subscriptionType,
  });

  /// Reads the result of [introspectionQuery]: the whole response
  /// (`{"data": {"__schema": ...}}`), its `data`, or its text.
  ///
  /// Throws [FormatException] with a readable message, for instance when
  /// the server answered with errors because introspection is off.
  factory GraphqlSchema.fromIntrospection(Object? json) {
    if (json is String) {
      try {
        json = jsonDecode(json);
      } on FormatException {
        throw const FormatException('The response is not JSON.');
      }
    }
    if (json is! Map) {
      throw const FormatException('The response is not a JSON object.');
    }
    final data = json['data'] is Map ? json['data'] as Map : json;
    final schema = data['__schema'];
    if (schema is! Map) {
      final errors = [
        for (final e in json['errors'] as List? ?? const [])
          e is Map ? '${e['message']}' : '$e',
      ];
      throw FormatException(
        errors.isEmpty
            ? 'The response has no __schema. The server may not speak '
                  'GraphQL at this URL, or has introspection turned off.'
            : 'The server answered with errors: ${errors.join('; ')}',
      );
    }
    String? rootName(Object? v) => v is Map ? v['name'] as String? : null;
    final types = <String, GqlType>{
      for (final t in _maps(schema['types']))
        if (t['name'] != null) '${t['name']}': GqlType.fromJson(t),
    };
    return GraphqlSchema(
      types: types,
      queryType: rootName(schema['queryType']),
      mutationType: rootName(schema['mutationType']),
      subscriptionType: rootName(schema['subscriptionType']),
    );
  }

  final Map<String, GqlType> types;
  final String? queryType;
  final String? mutationType;
  final String? subscriptionType;

  GqlType? type(String? name) => name == null ? null : types[name];

  /// The root type of `query`, `mutation` or `subscription`.
  GqlType? rootType(String operation) => switch (operation) {
    'query' => type(queryType),
    'mutation' => type(mutationType),
    'subscription' => type(subscriptionType),
    _ => null,
  };

  /// Types defined by the API (introspection's own `__` types left out).
  int get typeCount => types.keys.where((n) => !n.startsWith('__')).length;

  /// The operation types this schema supports.
  List<String> get operations => [
    for (final op in graphqlOperations)
      if (rootType(op) != null) op,
  ];
}

// ---------------- Tokenizer ----------------

enum GqlTokenKind { name, punct, number, string, comment }

class GqlToken {
  const GqlToken(
    this.kind,
    this.text,
    this.start,
    this.end, {
    this.unterminated = false,
  });

  final GqlTokenKind kind;
  final String text;
  final int start;
  final int end;

  /// A string that runs to the end of the line or input.
  final bool unterminated;

  bool punct(String p) => kind == GqlTokenKind.punct && text == p;
  bool word(String w) => kind == GqlTokenKind.name && text == w;

  @override
  String toString() => text;
}

final _nameRe = RegExp(r'[_A-Za-z][_0-9A-Za-z]*');
final _numberRe = RegExp(r'-?\d+(\.\d+)?([eE][+-]?\d+)?');

/// Splits a GraphQL document into tokens. Commas and white space are
/// dropped (they are insignificant in GraphQL); comments are kept. Never
/// throws: unknown characters become single-character tokens.
List<GqlToken> tokenizeGraphql(String src) {
  final out = <GqlToken>[];
  var i = 0;
  while (i < src.length) {
    final c = src[i];
    if (c == ' ' ||
        c == '\t' ||
        c == '\n' ||
        c == '\r' ||
        c == ',' ||
        c == '﻿') {
      i++;
      continue;
    }
    if (c == '#') {
      final end = src.indexOf('\n', i);
      final stop = end < 0 ? src.length : end;
      out.add(GqlToken(GqlTokenKind.comment, src.substring(i, stop), i, stop));
      i = stop;
      continue;
    }
    if (src.startsWith('...', i)) {
      out.add(GqlToken(GqlTokenKind.punct, '...', i, i + 3));
      i += 3;
      continue;
    }
    if (src.startsWith('"""', i)) {
      var j = i + 3;
      while (j < src.length && !src.startsWith('"""', j)) {
        j += src.startsWith(r'\"""', j) ? 4 : 1;
      }
      final closed = j < src.length;
      final end = closed ? j + 3 : src.length;
      out.add(
        GqlToken(
          GqlTokenKind.string,
          src.substring(i, end),
          i,
          end,
          unterminated: !closed,
        ),
      );
      i = end;
      continue;
    }
    if (c == '"') {
      var j = i + 1;
      var closed = false;
      while (j < src.length && src[j] != '\n') {
        if (src[j] == r'\') {
          j += 2;
          continue;
        }
        if (src[j] == '"') {
          closed = true;
          j++;
          break;
        }
        j++;
      }
      final end = j.clamp(i + 1, src.length);
      out.add(
        GqlToken(
          GqlTokenKind.string,
          src.substring(i, end),
          i,
          end,
          unterminated: !closed,
        ),
      );
      i = end;
      continue;
    }
    final name = _nameRe.matchAsPrefix(src, i);
    if (name != null) {
      out.add(GqlToken(GqlTokenKind.name, name.group(0)!, i, name.end));
      i = name.end;
      continue;
    }
    final number = _numberRe.matchAsPrefix(src, i);
    if (number != null) {
      out.add(GqlToken(GqlTokenKind.number, number.group(0)!, i, number.end));
      i = number.end;
      continue;
    }
    out.add(GqlToken(GqlTokenKind.punct, c, i, i + 1));
    i++;
  }
  return out;
}

// ---------------- Selection path at the cursor ----------------

/// One step from a root type: a field, or an inline fragment's type.
class GqlPathStep {
  const GqlPathStep.field(String this.field) : typeCondition = null;
  const GqlPathStep.on(String this.typeCondition) : field = null;

  final String? field;
  final String? typeCondition;

  @override
  bool operator ==(Object other) =>
      other is GqlPathStep &&
      other.field == field &&
      other.typeCondition == typeCondition;

  @override
  int get hashCode => Object.hash(field, typeCondition);

  @override
  String toString() => field ?? '... on $typeCondition';
}

/// Where the cursor is in a query: inside which selection set, and the
/// partial name typed so far.
class GqlCursorContext {
  const GqlCursorContext({
    required this.operation,
    required this.path,
    required this.prefix,
    required this.prefixStart,
    this.rootType,
    this.argumentsOf,
  });

  /// `query`, `mutation`, `subscription` or `fragment`.
  final String operation;

  /// The type condition of a fragment definition.
  final String? rootType;

  /// Steps from the root type to the selection set holding the cursor.
  final List<GqlPathStep> path;

  /// The name being typed (may be empty), starting at [prefixStart].
  final String prefix;
  final int prefixStart;

  /// When the cursor is inside a field's `(...)`, that field's name.
  final String? argumentsOf;

  int get offset => prefixStart + prefix.length;
}

/// The selection path at [offset] in [text], or null when the cursor is
/// not inside a selection set (or is inside a string or comment). Works on
/// incomplete queries, since only the text before the cursor matters.
GqlCursorContext? graphqlCursorContext(String text, int offset) {
  if (offset < 0 || offset > text.length) return null;
  final tokens = tokenizeGraphql(text.substring(0, offset));
  var prefix = '';
  var prefixStart = offset;
  if (tokens.isNotEmpty) {
    final last = tokens.last;
    if (last.kind == GqlTokenKind.comment) return null;
    if (last.kind == GqlTokenKind.string && last.unterminated) return null;
    if (last.kind == GqlTokenKind.name && last.end == offset) {
      prefix = last.text;
      prefixStart = last.start;
      tokens.removeLast();
    }
  }
  var operation = 'query';
  String? rootType;
  final frames = <GqlPathStep?>[]; // null = the root selection set
  String? pendingField;
  String? pendingCondition;
  var spread = false;
  var expectCondition = false;
  var expectFragmentType = false;
  var directive = false;
  var parens = 0;
  String? argsField;
  GqlToken? prev;
  for (final t in tokens) {
    if (t.kind == GqlTokenKind.comment) continue;
    if (parens > 0) {
      if (t.punct('(')) parens++;
      if (t.punct(')')) parens--;
      if (parens == 0) argsField = null;
      prev = t;
      continue;
    }
    if (t.punct('(')) {
      parens = 1;
      final afterDirective = directive && prev?.kind == GqlTokenKind.name;
      argsField = frames.isEmpty || afterDirective ? null : pendingField;
      directive = false;
    } else if (t.punct('{')) {
      if (frames.isEmpty) {
        frames.add(null);
      } else if (pendingCondition != null) {
        frames.add(GqlPathStep.on(pendingCondition));
      } else if (spread) {
        frames.add(const GqlPathStep.on('')); // `... @include(...) {`
      } else if (pendingField != null) {
        frames.add(GqlPathStep.field(pendingField));
      } else {
        frames.add(const GqlPathStep.on('')); // `... {` keeps the type
      }
      pendingField = null;
      pendingCondition = null;
      spread = false;
      directive = false;
    } else if (t.punct('}')) {
      if (frames.isNotEmpty) frames.removeLast();
      if (frames.isEmpty) {
        operation = 'query';
        rootType = null;
      }
      pendingField = null;
      pendingCondition = null;
    } else if (t.punct('...')) {
      spread = true;
    } else if (t.punct('@')) {
      directive = true;
    } else if (t.kind == GqlTokenKind.name) {
      if (frames.isEmpty) {
        if (graphqlOperations.contains(t.text) && prev?.punct(':') != true) {
          operation = t.text;
          rootType = null;
        } else if (t.text == 'fragment') {
          operation = 'fragment';
        } else if (t.text == 'on' && operation == 'fragment') {
          expectFragmentType = true;
        } else if (expectFragmentType) {
          rootType = t.text;
          expectFragmentType = false;
        }
      } else if (directive && prev?.punct('@') == true) {
        // A directive name; its arguments are skipped.
      } else if (spread) {
        spread = false;
        if (t.text == 'on') {
          expectCondition = true;
        } else {
          pendingField = null; // a named fragment spread
        }
      } else if (expectCondition) {
        pendingCondition = t.text;
        expectCondition = false;
      } else {
        pendingField = t.text; // an alias is overwritten by its field
        pendingCondition = null;
      }
    }
    prev = t;
  }
  if (frames.isEmpty) return null;
  if (parens > 0 && argsField == null) return null;
  // After `...` or `... on` a fragment or type name is typed, not a field.
  if (spread || expectCondition) return null;
  return GqlCursorContext(
    operation: operation,
    rootType: rootType,
    path: [
      for (final f in frames.skip(1))
        if (f != null && f.typeCondition != '') f,
    ],
    prefix: prefix,
    prefixStart: prefixStart,
    argumentsOf: parens > 0 ? argsField : null,
  );
}

/// The type whose fields can be selected at [ctx], or null when the path
/// does not match the schema.
GqlType? graphqlTypeAt(GraphqlSchema schema, GqlCursorContext ctx) {
  var t = ctx.rootType != null
      ? schema.type(ctx.rootType)
      : schema.rootType(ctx.operation);
  for (final step in ctx.path) {
    if (t == null) return null;
    if (step.typeCondition != null) {
      t = schema.type(step.typeCondition);
    } else {
      final f = t.field(step.field!);
      if (f == null) return null;
      t = schema.type(f.type.namedType);
    }
  }
  return t;
}

/// A field or argument name offered while typing.
class GqlSuggestion {
  const GqlSuggestion(
    this.name,
    this.detail, {
    this.isArgument = false,
    this.composite = false,
  });

  final String name;

  /// Its type, such as `[Post!]!`.
  final String detail;
  final bool isArgument;

  /// A field whose type needs a selection set.
  final bool composite;
}

/// Field names (or argument names, inside parentheses) that fit at [ctx],
/// matching the typed prefix: names starting with it first, then names
/// containing it.
List<GqlSuggestion> graphqlSuggestions(
  GraphqlSchema schema,
  GqlCursorContext ctx, {
  int limit = 30,
}) {
  final type = graphqlTypeAt(schema, ctx);
  if (type == null) return const [];
  final candidates = <GqlSuggestion>[];
  if (ctx.argumentsOf != null) {
    final field = type.field(ctx.argumentsOf!);
    for (final a in field?.args ?? const <GqlInputValue>[]) {
      candidates.add(GqlSuggestion(a.name, '${a.type}', isArgument: true));
    }
  } else {
    for (final f in type.fields) {
      final target = schema.type(f.type.namedType);
      candidates.add(
        GqlSuggestion(
          f.name,
          '${f.type}',
          composite: target?.isComposite ?? false,
        ),
      );
    }
    if (type.isComposite) {
      candidates.add(const GqlSuggestion('__typename', 'String!'));
    }
  }
  final p = ctx.prefix.toLowerCase();
  if (p.isEmpty) return candidates.take(limit).toList();
  final starts = candidates.where((c) => c.name.toLowerCase().startsWith(p));
  final contains = candidates.where(
    (c) =>
        !c.name.toLowerCase().startsWith(p) && c.name.toLowerCase().contains(p),
  );
  return [
    ...starts,
    ...contains,
  ].where((c) => c.name != ctx.prefix).take(limit).toList();
}

/// [text] with the typed prefix at [ctx] replaced by [s], and the new
/// cursor offset. Composite fields get `{ }` with the cursor inside;
/// arguments get `name: `.
(String, int) applyGraphqlSuggestion(
  String text,
  GqlCursorContext ctx,
  GqlSuggestion s,
) {
  final insert = s.isArgument
      ? '${s.name}: '
      : s.composite
      ? '${s.name} {  }'
      : s.name;
  final cursor = s.composite && !s.isArgument
      ? ctx.prefixStart + s.name.length + 3
      : ctx.prefixStart + insert.length;
  return (text.replaceRange(ctx.prefixStart, ctx.offset, insert), cursor);
}

// ---------------- Inserting fields ----------------

class _Sel {
  _Sel(this.open);

  final int open;
  int close = -1;
  final List<_FieldNode> fields = [];
}

class _FieldNode {
  _FieldNode(this.name, this.alias, this.end);

  final String name;
  final String? alias;

  /// Offset after the name, arguments and directives.
  int end;
  _Sel? selection;
}

class _Operation {
  _Operation(this.type, this.start, this.keywordEnd, {this.shorthand = false});

  final String type;
  final int start;
  final int keywordEnd;
  final bool shorthand;
  int? nameEnd;
  int? varsClose;

  /// Variable name → its type as written.
  final Map<String, String> variables = {};
  _Sel? selection;
}

/// Operations of a document with the offsets needed to edit them.
class _Outline {
  _Outline(String text)
    : _t = tokenizeGraphql(
        text,
      ).where((t) => t.kind != GqlTokenKind.comment).toList();

  final List<GqlToken> _t;
  int _i = 0;
  bool broken = false;
  final List<_Operation> operations = [];

  bool _is(String p) => _i < _t.length && _t[_i].punct(p);
  bool get _name => _i < _t.length && _t[_i].kind == GqlTokenKind.name;

  _Outline parse() {
    while (_i < _t.length) {
      final t = _t[_i];
      if (t.kind == GqlTokenKind.name && graphqlOperations.contains(t.text)) {
        _i++;
        final op = _Operation(t.text, t.start, t.end);
        if (_name) op.nameEnd = _t[_i++].end;
        if (_is('(')) _variables(op);
        _directives();
        if (_is('{')) op.selection = _selection();
        operations.add(op);
      } else if (t.punct('{')) {
        final op = _Operation('query', t.start, t.start, shorthand: true)
          ..selection = _selection();
        operations.add(op);
      } else if (t.word('fragment')) {
        _i++;
        while (_i < _t.length && !_is('{')) {
          _i++;
        }
        if (_is('{')) _selection();
      } else {
        _i++;
      }
    }
    return this;
  }

  /// Skips a balanced `(...)`; returns the offset of the `)`.
  int _parens() {
    var depth = 0;
    while (_i < _t.length) {
      final t = _t[_i++];
      if (t.punct('(')) depth++;
      if (t.punct(')') && --depth == 0) return t.start;
    }
    broken = true;
    return -1;
  }

  void _variables(_Operation op) {
    final open = _i;
    op.varsClose = _parens();
    if (broken) return;
    // `$name: Type = default @dir` repeated.
    for (var k = open + 1; k < _i - 1; k++) {
      if (_t[k].punct(r'$') &&
          k + 2 < _i &&
          _t[k + 1].kind == GqlTokenKind.name &&
          _t[k + 2].punct(':')) {
        final type = StringBuffer();
        var j = k + 3;
        while (j < _i - 1 &&
            !_t[j].punct('=') &&
            !_t[j].punct(r'$') &&
            !_t[j].punct('@')) {
          type.write(_t[j].text);
          j++;
        }
        op.variables[_t[k + 1].text] = type.toString();
      }
    }
  }

  void _directives() {
    while (_is('@')) {
      _i++;
      if (_name) _i++;
      if (_is('(')) _parens();
    }
  }

  _Sel _selection() {
    final sel = _Sel(_t[_i++].start);
    while (_i < _t.length) {
      final t = _t[_i];
      if (t.punct('}')) {
        sel.close = t.start;
        _i++;
        return sel;
      }
      if (t.punct('...')) {
        _i++;
        if (_i < _t.length && _t[_i].word('on')) _i += 2;
        if (_name) _i++;
        _directives();
        if (_is('{')) _selection();
        continue;
      }
      if (t.kind == GqlTokenKind.name) {
        _i++;
        var name = t.text;
        String? alias;
        var end = t.end;
        if (_is(':')) {
          _i++;
          if (_name) {
            alias = name;
            name = _t[_i].text;
            end = _t[_i].end;
            _i++;
          }
        }
        if (_is('(')) {
          _parens();
          if (broken) return sel;
          end = _t[_i - 1].end;
        }
        if (_is('@')) {
          _directives();
          end = _t[_i - 1].end;
        }
        final field = _FieldNode(name, alias, end);
        if (_is('{')) field.selection = _selection();
        sel.fields.add(field);
        continue;
      }
      _i++;
    }
    broken = true;
    return sel;
  }
}

/// The result of [insertGraphqlField].
class GqlInsertResult {
  const GqlInsertResult(this.query, this.variables, this.addedVariables);

  final String query;
  final String variables;

  /// Variables declared for the new field's required arguments.
  final List<String> addedVariables;
}

/// Adds the field at [path] (field names from the [operation]'s root type)
/// to [query]: into the first operation of that type, reusing the fields
/// already selected along the way, or as a new operation. Required
/// arguments become `$variables`, declared on the operation and given an
/// example value in [variables] (JSON). A field of an object type gets its
/// scalar fields as a starting selection.
///
/// Throws [FormatException] when the path is not in the schema or the
/// query has unclosed brackets.
GqlInsertResult insertGraphqlField({
  required String query,
  required String variables,
  required GraphqlSchema schema,
  required String operation,
  required List<String> path,
}) {
  if (path.isEmpty) throw const FormatException('No field to insert.');
  var type = schema.rootType(operation);
  if (type == null) {
    throw FormatException('This schema has no $operation type.');
  }
  final chain = <GqlField>[];
  for (final name in path) {
    final f = type?.field(name);
    if (f == null) {
      throw FormatException('"$name" is not a field of ${type?.name}.');
    }
    chain.add(f);
    type = schema.type(f.type.namedType);
  }

  final outline = _Outline(query).parse();
  if (outline.broken) {
    throw const FormatException(
      'Close every "{" and "(" in the query before inserting fields.',
    );
  }
  _Operation? op;
  for (final o in outline.operations) {
    if (o.type == operation) {
      op = o;
      break;
    }
  }
  final declared = Map.of(op?.variables ?? const <String, String>{});
  final added = <String, GqlTypeRef>{};

  String variableFor(GqlInputValue arg) {
    final type = '${arg.type}';
    var name = arg.name;
    for (var n = 2; ; n++) {
      final existing = declared[name];
      if (existing == null) break;
      if (existing.replaceAll(' ', '') == type) return name;
      name = '${arg.name}$n';
    }
    declared[name] = type;
    added[name] = arg.type;
    return name;
  }

  String head(GqlField f) {
    final args = [
      for (final a in f.requiredArgs) '${a.name}: \$${variableFor(a)}',
    ];
    return args.isEmpty ? f.name : '${f.name}(${args.join(', ')})';
  }

  String build(int k) {
    final f = chain[k];
    final h = head(f);
    if (k < chain.length - 1) return '$h { ${build(k + 1)} }';
    final leaf = _starterSelection(schema, schema.type(f.type.namedType));
    return leaf == null ? h : '$h { $leaf }';
  }

  final edits = <(int, String)>[];
  String? newOperation;
  if (op == null || op.selection == null) {
    newOperation = build(0);
  } else {
    var sel = op.selection!;
    for (var k = 0; k < chain.length; k++) {
      _FieldNode? match;
      for (final f in sel.fields) {
        if (f.name == chain[k].name) {
          match = f;
          if (f.alias == null) break;
        }
      }
      if (match == null) {
        edits.add((sel.close, ' ${build(k)}\n'));
        break;
      }
      if (k == chain.length - 1) break; // already selected
      final next = match.selection;
      if (next == null) {
        edits.add((match.end, ' { ${build(k + 1)} }'));
        break;
      }
      sel = next;
    }
  }

  final defs = [for (final e in added.entries) '\$${e.key}: ${e.value}'];
  if (newOperation != null) {
    final vars = defs.isEmpty ? '' : '(${defs.join(', ')}) ';
    final text = '$operation $vars{ $newOperation }';
    final base = query.trimRight();
    query = base.isEmpty ? text : '$base\n\n$text';
  } else if (defs.isNotEmpty) {
    final o = op!;
    if (o.varsClose != null) {
      edits.add((
        o.varsClose!,
        o.variables.isEmpty ? defs.join(', ') : ', ${defs.join(', ')}',
      ));
    } else if (o.shorthand) {
      edits.add((o.start, 'query (${defs.join(', ')}) '));
    } else {
      edits.add((o.nameEnd ?? o.keywordEnd, '(${defs.join(', ')})'));
    }
  }
  if (edits.isEmpty && newOperation == null) {
    return GqlInsertResult(query, variables, const []);
  }
  edits.sort((a, b) => b.$1.compareTo(a.$1));
  for (final (at, text) in edits) {
    query = query.replaceRange(at, at, text);
  }
  return GqlInsertResult(
    prettifyGraphql(query),
    mergeGraphqlVariables(variables, schema, added),
    added.keys.toList(),
  );
}

/// The scalar and enum fields (without required arguments) of an object
/// or interface, or `__typename` for unions and types without any.
String? _starterSelection(GraphqlSchema schema, GqlType? type) {
  if (type == null || !type.isComposite) return null;
  final leaves = [
    for (final f in type.fields)
      if (!f.isDeprecated &&
          f.requiredArgs.isEmpty &&
          (schema.type(f.type.namedType)?.isLeaf ?? true))
        f.name,
  ];
  return leaves.isEmpty ? '__typename' : leaves.take(12).join(' ');
}

/// [variablesJson] with an example value added for each of [added] that it
/// does not already set. Text that is not a JSON object is returned
/// unchanged.
String mergeGraphqlVariables(
  String variablesJson,
  GraphqlSchema schema,
  Map<String, GqlTypeRef> added,
) {
  if (added.isEmpty) return variablesJson;
  Map<String, Object?> vars;
  if (variablesJson.trim().isEmpty) {
    vars = {};
  } else {
    try {
      final decoded = jsonDecode(variablesJson);
      if (decoded is! Map) return variablesJson;
      vars = decoded.cast<String, Object?>();
    } on FormatException {
      return variablesJson;
    }
  }
  for (final e in added.entries) {
    vars.putIfAbsent(e.key, () => graphqlExampleValue(schema, e.value));
  }
  return const JsonEncoder.withIndent('  ').convert(vars);
}

/// A placeholder value of [type] for the variables editor.
Object? graphqlExampleValue(
  GraphqlSchema schema,
  GqlTypeRef type, [
  int depth = 0,
]) {
  if (type.isNonNull) return graphqlExampleValue(schema, type.ofType!, depth);
  if (type.isList) return <Object?>[];
  switch (type.name) {
    case 'Int':
      return 0;
    case 'Float':
      return 0.0;
    case 'Boolean':
      return false;
    case 'String' || 'ID':
      return '';
  }
  final named = schema.type(type.name);
  if (named == null) return '';
  if (named.kind == 'ENUM') {
    return named.enumValues.isEmpty ? '' : named.enumValues.first.name;
  }
  if (named.kind == 'INPUT_OBJECT') {
    if (depth > 3) return <String, Object?>{};
    return {
      for (final f in named.inputFields)
        if (f.isRequired)
          f.name: graphqlExampleValue(schema, f.type, depth + 1),
    };
  }
  return '';
}

// ---------------- Prettifier ----------------

/// Re-indents a GraphQL document: one field per line, two spaces per
/// level, arguments and values inline with `, ` between them. Comments are
/// kept. Never throws; unbalanced brackets are printed as they come.
String prettifyGraphql(String src, {String indent = '  '}) {
  final tokens = tokenizeGraphql(src);
  final out = StringBuffer();
  final stack = <String>[]; // sel, paren, list, obj
  var depth = 0;
  var lineStart = true;
  var blankBeforeNext = false;
  GqlToken? prev;

  void newline() {
    out.write('\n');
    lineStart = true;
  }

  void write(String s) {
    if (lineStart) {
      if (blankBeforeNext) {
        out.write('\n');
        blankBeforeNext = false;
      }
      out.write(indent * depth);
      lineStart = false;
    }
    out.write(s);
  }

  bool valueEnd(GqlToken? t) =>
      t != null &&
      (t.kind == GqlTokenKind.name ||
          t.kind == GqlTokenKind.number ||
          t.kind == GqlTokenKind.string ||
          t.punct(']') ||
          t.punct('}') ||
          t.punct('!') ||
          t.punct(')'));

  bool valueStart(GqlToken t) =>
      t.kind == GqlTokenKind.name ||
      t.kind == GqlTokenKind.number ||
      t.kind == GqlTokenKind.string ||
      t.punct(r'$') ||
      t.punct('[') ||
      t.punct('{');

  /// Spacing inside arguments, variable definitions, lists and objects.
  String gap(GqlToken t) {
    final p = prev;
    if (p == null || p.punct('(') || p.punct('[') || p.punct('{')) return '';
    if (t.punct(')') || t.punct(']') || t.punct('}')) return '';
    if (t.punct(':') || t.punct('!')) return '';
    if (p.punct(r'$') || p.punct('@')) return '';
    if (p.punct(':') || t.punct('=') || p.punct('=') || t.punct('@')) {
      return ' ';
    }
    if (valueEnd(p) && valueStart(t)) return ', ';
    return ' ';
  }

  for (final t in tokens) {
    final inValue = stack.isNotEmpty && stack.last != 'sel';
    if (t.kind == GqlTokenKind.comment) {
      if (!lineStart) out.write(' ');
      write(t.text);
      newline();
      prev = null;
      continue;
    }
    if (inValue) {
      if (t.punct(')') || t.punct(']') || t.punct('}')) {
        write(t.text);
        if (stack.isNotEmpty) stack.removeLast();
      } else {
        write(gap(t) + t.text);
        if (t.punct('(')) stack.add('paren');
        if (t.punct('[')) stack.add('list');
        if (t.punct('{')) stack.add('obj');
      }
      prev = t;
      continue;
    }
    final p = prev;
    switch (t.text) {
      case '{' when t.kind == GqlTokenKind.punct:
        write(lineStart ? '{' : ' {');
        stack.add('sel');
        depth++;
        newline();
      case '}' when t.kind == GqlTokenKind.punct:
        if (!lineStart) newline();
        if (stack.isNotEmpty) stack.removeLast();
        depth = depth > 0 ? depth - 1 : 0;
        write('}');
        newline();
        if (stack.isEmpty) blankBeforeNext = true;
      case '(' when t.kind == GqlTokenKind.punct:
        write('(');
        stack.add('paren');
      case '...' when t.kind == GqlTokenKind.punct:
        if (!lineStart && stack.isNotEmpty) newline();
        write(lineStart ? '...' : ' ...');
      case '@' when t.kind == GqlTokenKind.punct:
        write(' @');
      case ':' when t.kind == GqlTokenKind.punct:
        write(':');
      default:
        if (t.kind == GqlTokenKind.name) {
          final inSelection = stack.isNotEmpty;
          if (lineStart) {
            write(t.text);
          } else if (p != null && (p.punct('@') || p.punct('...'))) {
            write(t.text == 'on' ? ' on' : t.text);
          } else if (p != null && (p.punct(':') || p.word('on'))) {
            write(' ${t.text}');
          } else if (inSelection) {
            newline();
            write(t.text);
          } else {
            write(' ${t.text}');
          }
        } else {
          write(lineStart ? t.text : ' ${t.text}');
        }
    }
    prev = t;
  }
  return out.toString().trimRight();
}
