import 'dart:convert';

import 'package:api_workbench/services/graphql_schema.dart';
import 'package:flutter_test/flutter_test.dart';

// ---- An introspection response, as a server sends it ----

Map<String, Object?> _named(String kind, String name) => {
  'kind': kind,
  'name': name,
  'ofType': null,
};
Map<String, Object?> _nn(Map<String, Object?> t) => {
  'kind': 'NON_NULL',
  'name': null,
  'ofType': t,
};
Map<String, Object?> _list(Map<String, Object?> t) => {
  'kind': 'LIST',
  'name': null,
  'ofType': t,
};
final _id = _named('SCALAR', 'ID');
final _string = _named('SCALAR', 'String');
final _int = _named('SCALAR', 'Int');
final _boolean = _named('SCALAR', 'Boolean');
Map<String, Object?> _obj(String n) => _named('OBJECT', n);

Map<String, Object?> _arg(
  String name,
  Map<String, Object?> type, [
  String? defaultValue,
]) => {
  'name': name,
  'description': null,
  'type': type,
  'defaultValue': defaultValue,
};

Map<String, Object?> _field(
  String name,
  Map<String, Object?> type, {
  List<Map<String, Object?>> args = const [],
  String? description,
  bool deprecated = false,
}) => {
  'name': name,
  'description': description,
  'args': args,
  'type': type,
  'isDeprecated': deprecated,
  'deprecationReason': deprecated ? 'Use something else' : null,
};

Map<String, Object?> _type(
  String kind,
  String name, {
  List<Map<String, Object?>>? fields,
  List<Map<String, Object?>>? inputFields,
  List<Map<String, Object?>>? interfaces,
  List<String>? enumValues,
  List<Map<String, Object?>>? possibleTypes,
  String? description,
}) => {
  'kind': kind,
  'name': name,
  'description': description,
  'fields': fields,
  'inputFields': inputFields,
  'interfaces': interfaces ?? (kind == 'OBJECT' ? [] : null),
  'enumValues': enumValues == null
      ? null
      : [
          for (final v in enumValues)
            {
              'name': v,
              'description': null,
              'isDeprecated': false,
              'deprecationReason': null,
            },
        ],
  'possibleTypes': possibleTypes,
};

/// A small blog API: users, posts, a search union and a Node interface.
final introspectionFixture = jsonEncode({
  'data': {
    '__schema': {
      'queryType': {'name': 'Query'},
      'mutationType': {'name': 'Mutation'},
      'subscriptionType': {'name': 'Subscription'},
      'types': [
        _type(
          'OBJECT',
          'Query',
          fields: [
            _field('user', _obj('User'), args: [_arg('id', _nn(_id))]),
            _field(
              'users',
              _nn(_list(_nn(_obj('User')))),
              args: [
                _arg('first', _int, '10'),
                _arg('filter', _named('INPUT_OBJECT', 'UserFilter')),
              ],
            ),
            _field(
              'search',
              _nn(_list(_nn(_named('UNION', 'SearchResult')))),
              args: [_arg('term', _nn(_string))],
            ),
            _field(
              'node',
              _named('INTERFACE', 'Node'),
              args: [_arg('id', _nn(_id))],
            ),
          ],
        ),
        _type(
          'OBJECT',
          'Mutation',
          fields: [
            _field(
              'createUser',
              _nn(_obj('User')),
              args: [
                _arg('input', _nn(_named('INPUT_OBJECT', 'CreateUserInput'))),
              ],
            ),
            _field('deleteUser', _nn(_boolean), args: [_arg('id', _nn(_id))]),
          ],
        ),
        _type(
          'OBJECT',
          'Subscription',
          fields: [_field('userCreated', _nn(_obj('User')))],
        ),
        _type(
          'OBJECT',
          'User',
          description: 'Someone with an account.',
          interfaces: [_named('INTERFACE', 'Node')],
          fields: [
            _field('id', _nn(_id)),
            _field('name', _string, description: 'Display name'),
            _field('email', _nn(_string)),
            _field('role', _nn(_named('ENUM', 'Role'))),
            _field(
              'posts',
              _nn(_list(_nn(_obj('Post')))),
              args: [_arg('first', _nn(_int))],
            ),
            _field('friends', _nn(_list(_nn(_obj('User'))))),
            _field('legacyId', _string, deprecated: true),
          ],
        ),
        _type(
          'OBJECT',
          'Post',
          interfaces: [_named('INTERFACE', 'Node')],
          fields: [
            _field('id', _nn(_id)),
            _field('title', _nn(_string)),
            _field('author', _nn(_obj('User'))),
          ],
        ),
        _type(
          'INTERFACE',
          'Node',
          fields: [_field('id', _nn(_id))],
          possibleTypes: [_obj('User'), _obj('Post')],
        ),
        _type(
          'UNION',
          'SearchResult',
          possibleTypes: [_obj('User'), _obj('Post')],
        ),
        _type('ENUM', 'Role', enumValues: ['ADMIN', 'MEMBER']),
        _type(
          'INPUT_OBJECT',
          'UserFilter',
          inputFields: [
            _arg('role', _named('ENUM', 'Role')),
            _arg('nameContains', _string),
          ],
        ),
        _type(
          'INPUT_OBJECT',
          'CreateUserInput',
          inputFields: [
            _arg('name', _nn(_string)),
            _arg('email', _nn(_string)),
            _arg('role', _named('ENUM', 'Role'), 'MEMBER'),
          ],
        ),
        _type('SCALAR', 'ID'),
        _type('SCALAR', 'String'),
        _type('SCALAR', 'Int'),
        _type('SCALAR', 'Boolean'),
        _type('OBJECT', '__Schema', fields: []),
        _type('OBJECT', '__Type', fields: []),
      ],
      'directives': [],
    },
  },
});

void main() {
  final schema = GraphqlSchema.fromIntrospection(introspectionFixture);

  group('introspection', () {
    test('reads root types, fields, arguments and type references', () {
      expect(schema.queryType, 'Query');
      expect(schema.mutationType, 'Mutation');
      expect(schema.subscriptionType, 'Subscription');
      expect(schema.operations, ['query', 'mutation', 'subscription']);
      // Introspection's own __ types are not counted.
      expect(schema.typeCount, 14);

      final users = schema.rootType('query')!.field('users')!;
      expect('${users.type}', '[User!]!');
      expect(users.type.namedType, 'User');
      expect(users.args.map((a) => '${a.name}: ${a.type}'), [
        'first: Int',
        'filter: UserFilter',
      ]);
      expect(users.args.first.defaultValue, '10');
      expect(users.requiredArgs, isEmpty);
      expect(
        schema.rootType('query')!.field('user')!.requiredArgs.single.name,
        'id',
      );

      final user = schema.type('User')!;
      expect(user.kind, 'OBJECT');
      expect(user.isComposite, isTrue);
      expect(user.description, 'Someone with an account.');
      expect(user.interfaces, ['Node']);
      expect(user.field('legacyId')!.isDeprecated, isTrue);
      expect(schema.type('Role')!.enumValues.map((v) => v.name), [
        'ADMIN',
        'MEMBER',
      ]);
      expect(schema.type('Role')!.isLeaf, isTrue);
      expect(schema.type('SearchResult')!.possibleTypes, ['User', 'Post']);
      final input = schema.type('CreateUserInput')!;
      expect(input.inputFields.where((f) => f.isRequired).map((f) => f.name), [
        'name',
        'email',
      ]);
    });

    test('accepts the data object or a decoded map too', () {
      final decoded = jsonDecode(introspectionFixture) as Map;
      expect(
        GraphqlSchema.fromIntrospection(decoded['data']).typeCount,
        schema.typeCount,
      );
      expect(GraphqlSchema.fromIntrospection(decoded).typeCount, 14);
    });

    test('readable errors', () {
      expect(
        () => GraphqlSchema.fromIntrospection(
          '{"errors": [{"message": "Introspection is disabled"}]}',
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'The server answered with errors: Introspection is disabled',
          ),
        ),
      );
      expect(
        () => GraphqlSchema.fromIntrospection('<html>'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'The response is not JSON.',
          ),
        ),
      );
      expect(
        () => GraphqlSchema.fromIntrospection('{"data": {}}'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('has no __schema'),
          ),
        ),
      );
    });
  });

  group('path at the cursor', () {
    /// Context at the `|` in [query].
    GqlCursorContext? at(String query) {
      final offset = query.indexOf('|');
      return graphqlCursorContext(query.replaceFirst('|', ''), offset);
    }

    List<String> names(String query) => [
      for (final s in graphqlSuggestions(schema, at(query)!)) s.name,
    ];

    test('nested selections and the typed prefix', () {
      final ctx = at('query { user(id: 1) { posts(first: 2) { ti| } } }')!;
      expect(ctx.operation, 'query');
      expect(ctx.path.map((s) => '$s'), ['user', 'posts']);
      expect(ctx.prefix, 'ti');
      expect(graphqlTypeAt(schema, ctx)!.name, 'Post');
      expect(names('query { user(id: 1) { posts(first: 2) { ti| } } }'), [
        'title',
      ]);
    });

    test('works while the query is still unfinished', () {
      final ctx = at('{ us|')!;
      expect(ctx.path, isEmpty);
      expect(names('{ us|'), ['user', 'users']);
      // Names containing the prefix follow those starting with it.
      expect(names('{ user(id: 1) { e| '), [
        'email',
        'name',
        'role',
        'friends',
        'legacyId',
        '__typename',
      ]);
      expect(names('{ user(id: 1) { |'), contains('posts'));
    });

    test('mutations, subscriptions and fragments', () {
      expect(
        graphqlTypeAt(
          schema,
          at('mutation M { createUser(input: {}) { | } }')!,
        )!.name,
        'User',
      );
      expect(
        at('subscription { userCreated { na| } }')!.operation,
        'subscription',
      );
      final frag = at('fragment F on Post { au| }')!;
      expect(frag.operation, 'fragment');
      expect(frag.rootType, 'Post');
      expect(names('fragment F on Post { au| }'), ['author']);
    });

    test('aliases, inline fragments, object values and directives', () {
      expect(at('{ me: user(id: 1) { f| } }')!.path.map((s) => '$s'), ['user']);
      final inline = at('{ search(term: "x") { ... on Post { a| } } }')!;
      expect(inline.path.map((s) => '$s'), ['search', '... on Post']);
      expect(names('{ search(term: "x") { ... on Post { a| } } }'), [
        'author',
        '__typename',
      ]);
      expect(
        at('{ users(filter: {role: ADMIN}) { na| } }')!.path.map((s) => '$s'),
        ['users'],
      );
      expect(
        at('{ user(id: 1) @include(if: true) { na| } }')!.path.map((s) => '$s'),
        ['user'],
      );
      expect(
        at(
          '{ user(id: 1) { ... @include(if: true) { na| } } }',
        )!.path.map((s) => '$s'),
        ['user'],
      );
    });

    test('argument names inside parentheses', () {
      final ctx = at('{ users(fi| ')!;
      expect(ctx.argumentsOf, 'users');
      expect(names('{ users(fi| '), ['first', 'filter']);
      expect(names('{ users(first: 2, |'), ['first', 'filter']);
    });

    test('no context outside selections, in strings or comments', () {
      expect(at('|'), isNull);
      expect(at('query Q(\$id: |'), isNull);
      expect(at('{ user(id: "ab|'), isNull);
      expect(at('{ user # a comment |'), isNull);
      expect(at('query { user(id: 1) { id } }\n|'), isNull);
      expect(at('{ ...|'), isNull);
    });

    test('applying a suggestion', () {
      const q = '{ user(id: 1) { po } }';
      final ctx = graphqlCursorContext(q, q.indexOf('po') + 2)!;
      final posts = graphqlSuggestions(
        schema,
        ctx,
      ).firstWhere((s) => s.name == 'posts');
      expect(posts.composite, isTrue);
      final (text, cursor) = applyGraphqlSuggestion(q, ctx, posts);
      expect(text, '{ user(id: 1) { posts {  } } }');
      expect(text.substring(0, cursor), '{ user(id: 1) { posts { ');
    });
  });

  group('inserting fields', () {
    GqlInsertResult insert(
      String query,
      List<String> path, {
      String operation = 'query',
      String variables = '',
    }) => insertGraphqlField(
      query: query,
      variables: variables,
      schema: schema,
      operation: operation,
      path: path,
    );

    test('into an empty query, with required args as variables', () {
      final r = insert('', ['user']);
      expect(
        r.query,
        'query(\$id: ID!) {\n'
        '  user(id: \$id) {\n'
        '    id\n'
        '    name\n'
        '    email\n'
        '    role\n'
        '  }\n'
        '}',
      );
      expect(r.addedVariables, ['id']);
      expect(jsonDecode(r.variables), {'id': ''});
    });

    test('reuses selected fields and adds variable definitions', () {
      final r = insert('query Q {\n  user(id: "1") {\n    id\n  }\n}', [
        'user',
        'posts',
      ], variables: '{"x": 1}');
      expect(
        r.query,
        'query Q(\$first: Int!) {\n'
        '  user(id: "1") {\n'
        '    id\n'
        '    posts(first: \$first) {\n'
        '      id\n'
        '      title\n'
        '    }\n'
        '  }\n'
        '}',
      );
      expect(r.variables, '{\n  "x": 1,\n  "first": 0\n}');
    });

    test('renames clashing variables and reuses matching ones', () {
      final clash = insert('query Q(\$id: String) { user(id: "1") { id } }', [
        'node',
      ]);
      expect(
        clash.query,
        'query Q(\$id: String, \$id2: ID!) {\n'
        '  user(id: "1") {\n'
        '    id\n'
        '  }\n'
        '  node(id: \$id2) {\n'
        '    id\n'
        '  }\n'
        '}',
      );
      expect(clash.addedVariables, ['id2']);

      final reuse = insert('query Q(\$id: ID!) { user(id: \$id) { id } }', [
        'node',
      ], variables: '{"id": "7"}');
      expect(reuse.query, contains('node(id: \$id) {'));
      expect(reuse.addedVariables, isEmpty);
      expect(reuse.variables, '{"id": "7"}');
    });

    test('a field already selected leaves the query alone', () {
      const q = '{ user(id: 1) { id } }';
      final r = insert(q, ['user']);
      expect(r.query, q);
      expect(r.addedVariables, isEmpty);
    });

    test('gives a selection set to a field that had none', () {
      final r = insert('query { user(id: "1") }', ['user', 'friends']);
      expect(
        r.query,
        'query {\n'
        '  user(id: "1") {\n'
        '    friends {\n'
        '      id\n'
        '      name\n'
        '      email\n'
        '      role\n'
        '    }\n'
        '  }\n'
        '}',
      );
    });

    test('adds a new operation, with input objects in the variables', () {
      final r = insert('{ users { id } }', [
        'createUser',
      ], operation: 'mutation');
      expect(
        r.query,
        '{\n'
        '  users {\n'
        '    id\n'
        '  }\n'
        '}\n'
        '\n'
        'mutation(\$input: CreateUserInput!) {\n'
        '  createUser(input: \$input) {\n'
        '    id\n'
        '    name\n'
        '    email\n'
        '    role\n'
        '  }\n'
        '}',
      );
      expect(jsonDecode(r.variables), {
        'input': {'name': '', 'email': ''},
      });
    });

    test('turns a shorthand query into one with variables', () {
      final r = insert('{ users { id } }', ['user']);
      expect(r.query, startsWith('query(\$id: ID!) {\n  users {'));
      expect(r.query, contains('  user(id: \$id) {\n    id\n'));
    });

    test('unions get __typename; errors are readable', () {
      final r = insert('', ['search']);
      expect(r.query, contains('search(term: \$term) {\n    __typename\n'));
      expect(
        () => insert('{ user(id: 1) {', ['users']),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Close every "{"'),
          ),
        ),
      );
      expect(
        () => insert('', ['nope']),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            '"nope" is not a field of Query.',
          ),
        ),
      );
    });
  });

  group('prettifier', () {
    test('indents selections and spaces arguments', () {
      expect(
        prettifyGraphql(
          r'query Q($id: ID!, $n: Int = 5){user(id:$id){id name '
          r'posts(first:$n){title}} ...F @include(if: true) ... on User'
          r'{email}} fragment F on User{role}',
        ),
        'query Q(\$id: ID!, \$n: Int = 5) {\n'
        '  user(id: \$id) {\n'
        '    id\n'
        '    name\n'
        '    posts(first: \$n) {\n'
        '      title\n'
        '    }\n'
        '  }\n'
        '  ...F @include(if: true)\n'
        '  ... on User {\n'
        '    email\n'
        '  }\n'
        '}\n'
        '\n'
        'fragment F on User {\n'
        '  role\n'
        '}',
      );
    });

    test('keeps comments, strings, aliases, lists and objects', () {
      expect(
        prettifyGraphql(
          '{ a: users(filter: {role: ADMIN nameContains: "x, y"} '
          'ids: [1 2]) { id # the id\n } }',
        ),
        '{\n'
        '  a: users(filter: {role: ADMIN, nameContains: "x, y"}, ids: [1, 2]) {\n'
        '    id # the id\n'
        '  }\n'
        '}',
      );
    });

    test('is idempotent', () {
      const messy =
          'query Q(\$a: [Int!]! = [1]) @dir { x { y(z: "q") @skip(if: \$b) '
          '{ ...on T { w } } } }';
      final once = prettifyGraphql(messy);
      expect(prettifyGraphql(once), once);
      expect(once, startsWith('query Q(\$a: [Int!]! = [1]) @dir {'));
    });
  });
}
