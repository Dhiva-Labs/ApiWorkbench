import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/auth/auth.dart' show resolveAuth;
import '../services/graphql_schema.dart';
import '../services/http_service.dart' show substituteVars;
import '../state/app_state.dart';
import '../theme.dart';
import 'adaptive.dart';
import 'help_tip.dart';

/// Schema tools above a GraphQL query: fetch schema, explorer, field
/// suggestions (issue #28). Edits go through the controllers and then
/// [onChanged].
class GraphqlToolbar extends StatefulWidget {
  const GraphqlToolbar({
    super.key,
    required this.request,
    required this.queryController,
    required this.variablesController,
    required this.vars,
    required this.onChanged,
  });

  final RequestModel request;
  final TextEditingController queryController;
  final TextEditingController variablesController;

  /// Current variables, for sending the introspection query.
  final Map<String, String> Function() vars;
  final VoidCallback onChanged;

  @override
  State<GraphqlToolbar> createState() => _GraphqlToolbarState();
}

class _GraphqlToolbarState extends State<GraphqlToolbar> {
  bool _fetching = false;

  /// The last fetch error, for the URL it was fetched from.
  String? _error;
  String? _errorUrl;
  GqlCursorContext? _cursor;
  List<GqlSuggestion> _suggestions = const [];

  @override
  void initState() {
    super.initState();
    widget.queryController.addListener(_queryChanged);
  }

  @override
  void didUpdateWidget(GraphqlToolbar old) {
    super.didUpdateWidget(old);
    if (old.queryController != widget.queryController) {
      old.queryController.removeListener(_queryChanged);
      widget.queryController.addListener(_queryChanged);
    }
  }

  @override
  void dispose() {
    widget.queryController.removeListener(_queryChanged);
    super.dispose();
  }

  /// The endpoint with variables filled in: the schema cache key.
  String get _url => substituteVars(widget.request.url, widget.vars()).trim();

  GraphqlSchema? get _schema => graphqlSchemaCache[_url];

  /// Recomputes the field suggestions for the cursor position.
  void _queryChanged() {
    if (!mounted) return;
    final schema = _schema;
    final value = widget.queryController.value;
    GqlCursorContext? ctx;
    var list = const <GqlSuggestion>[];
    if (schema != null &&
        value.selection.isValid &&
        value.selection.isCollapsed) {
      ctx = graphqlCursorContext(value.text, value.selection.baseOffset);
      if (ctx != null) list = graphqlSuggestions(schema, ctx, limit: 25);
    }
    if (list.isEmpty && _suggestions.isEmpty) {
      _cursor = ctx;
      return;
    }
    setState(() {
      _cursor = ctx;
      _suggestions = list;
    });
  }

  void _setQuery(String text, {int? cursor}) {
    widget.queryController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: cursor ?? text.length),
    );
    widget.request.body = text;
  }

  void _applySuggestion(GqlSuggestion s) {
    final ctx = _cursor;
    if (ctx == null) return;
    final (text, cursor) = applyGraphqlSuggestion(
      widget.queryController.text,
      ctx,
      s,
    );
    _setQuery(text, cursor: cursor);
    widget.onChanged();
  }

  Future<void> _fetch() async {
    final state = context.read<AppState>();
    final vars = widget.vars();
    final url = _url;
    if (url.isEmpty) {
      setState(() {
        _error = 'Enter the GraphQL endpoint URL first.';
        _errorUrl = url;
      });
      return;
    }
    setState(() {
      _fetching = true;
      _error = null;
    });
    // The request as the user set it up (URL, headers, auth), with the
    // introspection query as its body.
    final probe = widget.request.clone()
      ..method = 'POST'
      ..bodyType = BodyType.graphql
      ..body = introspectionQuery
      ..graphqlVariables = '';
    CollectionModel? collection;
    for (final c in state.collections) {
      if (c.requests.any((r) => r.id == widget.request.id)) collection = c;
    }
    final res = await state.http.send(
      probe,
      vars,
      tabId: 'graphql-schema-${widget.request.id}',
      auth: resolveAuth(widget.request, collection),
      source: 'graphql',
    );
    if (!mounted) return;
    String? error;
    if (res.error != null) {
      error = res.error;
    } else {
      try {
        graphqlSchemaCache[url] = GraphqlSchema.fromIntrospection(res.bodyText);
      } on FormatException catch (e) {
        error = res.statusCode >= 400
            ? 'HTTP ${res.statusCode}: ${e.message}'
            : e.message;
      }
    }
    setState(() {
      _fetching = false;
      _error = error;
      _errorUrl = url;
    });
    _queryChanged();
  }

  void _prettify() {
    final text = widget.queryController.text;
    if (text.trim().isEmpty) return;
    _setQuery(prettifyGraphql(text));
    widget.onChanged();
  }

  /// Inserts a field from the explorer; returns a status line for it.
  String _insert(String operation, List<String> path) {
    final schema = _schema;
    if (schema == null) return 'Fetch the schema first.';
    try {
      final r = insertGraphqlField(
        query: widget.queryController.text,
        variables: widget.variablesController.text,
        schema: schema,
        operation: operation,
        path: path,
      );
      _setQuery(r.query);
      widget.variablesController.text = r.variables;
      widget.request.graphqlVariables = r.variables;
      widget.onChanged();
      final vars = r.addedVariables.map((v) => '\$$v').join(', ');
      return 'Added ${path.join('.')}'
          '${vars.isEmpty ? '' : ' with variables $vars'}.';
    } on FormatException catch (e) {
      return e.message;
    }
  }

  void _openExplorer() {
    final schema = _schema;
    if (schema == null) return;
    showDialog<void>(
      context: context,
      builder: (_) => GraphqlExplorerDialog(schema: schema, onInsert: _insert),
    );
  }

  @override
  Widget build(BuildContext context) {
    final schema = _schema;
    final error = _errorUrl == _url ? _error : null;
    final compact = OutlinedButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      textStyle: const TextStyle(fontSize: 12.5),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              HelpHover(
                'Ask the endpoint for its schema with the standard '
                'introspection query, using this request\'s URL, headers and '
                'auth. The schema is kept for this URL until the app closes.',
                title: 'Fetch schema',
                example: 'query IntrospectionQuery { __schema { … } }',
                child: OutlinedButton.icon(
                  style: compact,
                  onPressed: _fetching ? null : _fetch,
                  icon: _fetching
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_download_outlined, size: 16),
                  label: Text(schema == null ? 'Fetch schema' : 'Refetch'),
                ),
              ),
              HelpHover(
                'Browse queries, mutations, subscriptions and every type. '
                'Click + on a field to add it to the query, with its required '
                'arguments as variables.',
                title: 'Schema explorer',
                example: 'Query › user › posts',
                child: OutlinedButton.icon(
                  style: compact,
                  onPressed: schema == null ? null : _openExplorer,
                  icon: const Icon(Icons.account_tree_outlined, size: 16),
                  label: const Text('Explorer'),
                ),
              ),
              HelpHover(
                'Re-indent the query: one field per line, two spaces per '
                'level. Comments are kept.',
                title: 'Prettify query',
                example: '{ user(id: 1) { name } }',
                child: OutlinedButton.icon(
                  style: compact,
                  onPressed: _prettify,
                  icon: const Icon(Icons.auto_fix_high, size: 16),
                  label: const Text('Prettify'),
                ),
              ),
              _statusChip(schema, error),
            ],
          ),
          if (_suggestions.isNotEmpty) _suggestionRow(),
        ],
      ),
    );
  }

  Widget _statusChip(GraphqlSchema? schema, String? error) {
    if (_fetching) {
      return Text(
        'Fetching schema…',
        style: TextStyle(fontSize: 12, color: Palette.textDim),
      );
    }
    if (error != null) {
      return HelpHover(
        error,
        title: 'Could not fetch the schema',
        example: 'Check the URL, auth, and that introspection is enabled.',
        child: Chip(
          visualDensity: VisualDensity.compact,
          avatar: Icon(Icons.error_outline, size: 16, color: Palette.danger),
          side: BorderSide(color: Palette.danger.withValues(alpha: 0.5)),
          label: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(
              error,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: Palette.danger),
            ),
          ),
        ),
      );
    }
    if (schema == null) {
      return HelpHover(
        'No schema loaded for this URL yet. Fetch it to browse types and get '
        'field suggestions while typing.',
        title: 'Schema',
        child: Text(
          'No schema',
          style: TextStyle(fontSize: 12, color: Palette.textDim),
        ),
      );
    }
    final roots = [
      if (schema.queryType != null) 'query: ${schema.queryType}',
      if (schema.mutationType != null) 'mutation: ${schema.mutationType}',
      if (schema.subscriptionType != null)
        'subscription: ${schema.subscriptionType}',
    ];
    return HelpHover(
      'Schema loaded for this URL (kept until the app closes). Field '
      'suggestions appear below the buttons while you type.',
      title: '${schema.typeCount} types',
      example: roots.join(', '),
      child: Chip(
        visualDensity: VisualDensity.compact,
        avatar: Icon(Icons.check_circle, size: 16, color: Palette.success),
        side: BorderSide(color: Palette.success.withValues(alpha: 0.5)),
        label: Text(
          '${schema.typeCount} types',
          style: const TextStyle(fontSize: 12),
        ),
      ),
    );
  }

  Widget _suggestionRow() {
    final ctx = _cursor;
    final where = ctx == null
        ? ''
        : ctx.argumentsOf != null
        ? 'arguments of ${ctx.argumentsOf}'
        : [
            ctx.rootType ?? ctx.operation,
            ...ctx.path.map((s) => '$s'),
          ].join(' › ');
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: SizedBox(
        height: 34,
        child: Row(
          children: [
            HelpTip(
              'Fields (or arguments) that fit where the cursor is: $where. '
              'Tap one to insert it.',
              title: 'Suggestions',
              example: 'posts {  }',
            ),
            Expanded(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _suggestions.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (_, i) {
                  final s = _suggestions[i];
                  return ActionChip(
                    visualDensity: VisualDensity.compact,
                    tooltip: s.detail,
                    label: Text(
                      s.isArgument ? '${s.name}:' : s.name,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                    onPressed: () => _applySuggestion(s),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One level of the explorer: a type, reached from an operation's root
/// through [path] (so its fields can be inserted), or browsed directly.
class _Crumb {
  const _Crumb(this.type, {this.operation, this.path = const []});

  final String type;
  final String? operation;
  final List<String> path;
}

/// Browses a schema by operation and by type, with search, and inserts
/// fields into the query through [onInsert] (which returns a status line).
class GraphqlExplorerDialog extends StatefulWidget {
  const GraphqlExplorerDialog({
    super.key,
    required this.schema,
    required this.onInsert,
  });

  final GraphqlSchema schema;
  final String Function(String operation, List<String> path) onInsert;

  @override
  State<GraphqlExplorerDialog> createState() => _GraphqlExplorerDialogState();
}

class _GraphqlExplorerDialogState extends State<GraphqlExplorerDialog> {
  final _search = TextEditingController();
  final List<_Crumb> _stack = [];
  String? _status;

  GraphqlSchema get _schema => widget.schema;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _push(_Crumb c) => setState(() {
    _stack.add(c);
    _search.clear();
  });

  void _pop() => setState(() {
    if (_stack.isNotEmpty) _stack.removeLast();
    _search.clear();
  });

  void _insert(String operation, List<String> path) =>
      setState(() => _status = widget.onInsert(operation, path));

  @override
  Widget build(BuildContext context) {
    final crumb = _stack.isEmpty ? null : _stack.last;
    return AdaptiveDialog(
      width: 620,
      height: 520,
      title: const Text('Schema explorer'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (crumb != null)
                IconButton(
                  tooltip: 'Back',
                  icon: const Icon(Icons.arrow_back, size: 18),
                  onPressed: _pop,
                ),
              Expanded(
                child: Text(
                  crumb == null
                      ? 'All operations and types'
                      : _breadcrumb(crumb),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 18),
              hintText: 'Search fields and types',
              suffixIcon: HelpTip(
                'Filter by name. On the first page it searches every type '
                'and the fields of the root operations.',
                title: 'Search',
                example: 'user',
              ),
              suffixIconConstraints: BoxConstraints(
                minWidth: 32,
                minHeight: 32,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Expanded(child: crumb == null ? _home() : _typeView(crumb)),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _status!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Palette.textDim),
              ),
            ),
        ],
      ),
    );
  }

  String _breadcrumb(_Crumb c) {
    if (c.operation == null) return c.type;
    final root = _schema.rootType(c.operation!)?.name ?? c.operation!;
    return [root, ...c.path].join(' › ');
  }

  bool _matches(String name) {
    final q = _search.text.trim().toLowerCase();
    return q.isEmpty || name.toLowerCase().contains(q);
  }

  Widget _home() {
    final searching = _search.text.trim().isNotEmpty;
    final types =
        _schema.types.values
            .where((t) => !t.name.startsWith('__') && _matches(t.name))
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));
    return ListView(
      children: [
        _heading('Operations'),
        for (final op in _schema.operations)
          if (!searching)
            _operationTile(op)
          else
            for (final f in _schema.rootType(op)!.fields)
              if (_matches(f.name))
                _FieldTile(
                  schema: _schema,
                  field: f,
                  prefix: '${_label(op)}.',
                  onOpen: () => _openField(op, const [], f),
                  onInsert: () => _insert(op, [f.name]),
                ),
        _heading('Types'),
        for (final t in types)
          ListTile(
            dense: true,
            title: Text(t.name, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              _kindLabel(t.kind),
              style: TextStyle(fontSize: 11.5, color: Palette.textDim),
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => _push(_Crumb(t.name)),
          ),
      ],
    );
  }

  static String _label(String op) => op[0].toUpperCase() + op.substring(1);

  static String _kindLabel(String kind) => switch (kind) {
    'OBJECT' => 'Object type',
    'INTERFACE' => 'Interface',
    'UNION' => 'Union',
    'ENUM' => 'Enum',
    'INPUT_OBJECT' => 'Input type',
    'SCALAR' => 'Scalar',
    _ => kind,
  };

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        letterSpacing: 0.6,
        fontWeight: FontWeight.w700,
        color: Palette.textDim,
      ),
    ),
  );

  Widget _operationTile(String op) {
    final root = _schema.rootType(op)!;
    return HelpHover(
      switch (op) {
        'query' => 'Read data. Open it to see every query field.',
        'mutation' => 'Change data. Open it to see every mutation.',
        _ => 'Get updates pushed as they happen.',
      },
      title: _label(op),
      example: root.fields.take(3).map((f) => f.name).join(', '),
      child: ListTile(
        dense: true,
        leading: Icon(switch (op) {
          'query' => Icons.search,
          'mutation' => Icons.edit_outlined,
          _ => Icons.notifications_active_outlined,
        }, size: 18),
        title: Text('${_label(op)}  ·  ${root.name}'),
        subtitle: Text(
          '${root.fields.length} fields',
          style: TextStyle(fontSize: 11.5, color: Palette.textDim),
        ),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: () => _push(_Crumb(root.name, operation: op)),
      ),
    );
  }

  void _openField(String? op, List<String> path, GqlField f) {
    final target = _schema.type(f.type.namedType);
    if (target == null) return;
    _push(
      target.isComposite && op != null
          ? _Crumb(target.name, operation: op, path: [...path, f.name])
          : _Crumb(target.name),
    );
  }

  Widget _typeView(_Crumb crumb) {
    final type = _schema.type(crumb.type);
    if (type == null) return const SizedBox.shrink();
    final op = crumb.operation;
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Chip(
                visualDensity: VisualDensity.compact,
                label: Text(
                  _kindLabel(type.kind),
                  style: const TextStyle(fontSize: 11.5),
                ),
              ),
              for (final i in type.interfaces)
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(
                    'implements $i',
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  onPressed: () => _push(_Crumb(i)),
                ),
            ],
          ),
        ),
        if ((type.description ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(
              type.description!,
              style: TextStyle(fontSize: 12.5, color: Palette.textDim),
            ),
          ),
        for (final f in type.fields)
          if (_matches(f.name))
            _FieldTile(
              schema: _schema,
              field: f,
              onOpen: () => _openField(op, crumb.path, f),
              onInsert: op == null
                  ? null
                  : () => _insert(op, [...crumb.path, f.name]),
            ),
        for (final f in type.inputFields)
          if (_matches(f.name))
            ListTile(
              dense: true,
              title: Text(
                '${f.name}: ${f.type}'
                '${f.defaultValue == null ? '' : ' = ${f.defaultValue}'}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
              ),
              subtitle: f.description == null ? null : Text(f.description!),
              onTap: () => _push(_Crumb(f.type.namedType)),
            ),
        for (final v in type.enumValues)
          if (_matches(v.name))
            ListTile(
              dense: true,
              title: Text(
                v.name,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                  decoration: v.isDeprecated
                      ? TextDecoration.lineThrough
                      : null,
                ),
              ),
              subtitle: v.description == null ? null : Text(v.description!),
            ),
        for (final p in type.possibleTypes)
          if (_matches(p))
            ListTile(
              dense: true,
              title: Text(p),
              subtitle: const Text('Possible type'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => _push(_Crumb(p)),
            ),
      ],
    );
  }
}

/// A field with its arguments and type: tap to open its type, + to insert.
class _FieldTile extends StatelessWidget {
  const _FieldTile({
    required this.schema,
    required this.field,
    required this.onOpen,
    this.onInsert,
    this.prefix = '',
  });

  final GraphqlSchema schema;
  final GqlField field;
  final String prefix;
  final VoidCallback onOpen;

  /// Null when the field is not reachable from an operation here.
  final VoidCallback? onInsert;

  @override
  Widget build(BuildContext context) {
    final args = field.args.isEmpty
        ? ''
        : '(${field.args.map((a) => '${a.name}: ${a.type}').join(', ')})';
    final required = field.requiredArgs
        .map((a) => '${a.name}: \$${a.name}')
        .join(', ');
    final notes = [
      ?field.description,
      if (field.deprecationReason != null)
        'Deprecated: ${field.deprecationReason}',
    ];
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      title: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$prefix${field.name}',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                decoration: field.isDeprecated
                    ? TextDecoration.lineThrough
                    : null,
              ),
            ),
            TextSpan(
              text: args,
              style: TextStyle(color: Palette.textDim),
            ),
            TextSpan(
              text: ': ${field.type}',
              style: TextStyle(color: Palette.accent),
            ),
          ],
        ),
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: notes.isEmpty
          ? null
          : Text(
              notes.join('\n'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5),
            ),
      onTap: schema.type(field.type.namedType) == null ? null : onOpen,
      trailing: onInsert == null
          ? null
          : HelpHover(
              required.isEmpty
                  ? 'Add this field to the query.'
                  : 'Add this field to the query; its required arguments '
                        'become variables.',
              title: 'Insert ${field.name}',
              example: required.isEmpty
                  ? field.name
                  : '${field.name}($required)',
              child: IconButton(
                icon: Icon(Icons.add_circle_outline, color: Palette.accent),
                onPressed: onInsert,
              ),
            ),
    );
  }
}
