import 'package:flutter/material.dart';

import '../models/models.dart';

/// Schema tools above a GraphQL query: fetch schema, explorer, field
/// suggestions (issue #28). Edits go through the controllers and then
/// [onChanged].
class GraphqlToolbar extends StatelessWidget {
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
  Widget build(BuildContext context) => const SizedBox.shrink();
}
