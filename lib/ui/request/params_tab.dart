import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme.dart';
import '../kv_editor.dart';

/// Keeps [RequestModel.pathVariables] in step with the `:name` segments of
/// the URL: new names get a row, rows for names no longer in the URL go.
/// Returns true when the list changed.
bool syncPathVariables(RequestModel r) {
  final names = pathVariableNames(r.url);
  final before = r.pathVariables.map((v) => v.key).join('\n');
  final keep = {for (final v in r.pathVariables) v.key: v};
  r.pathVariables = [for (final n in names) keep[n] ?? KV(key: n)];
  return r.pathVariables.map((v) => v.key).join('\n') != before;
}

/// The Params tab: query parameters, and the path variables found in the
/// URL. (Issue #16 adds descriptions and bulk editing.)
class ParamsTab extends StatelessWidget {
  const ParamsTab({super.key, required this.request, required this.onChanged});

  final RequestModel request;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final query = KVEditor(
      rows: request.params,
      onChanged: onChanged,
      keyHint: 'Parameter',
      addLabel: 'Add parameter',
      keyHelp:
          'The name part of a query parameter. Rows are added to the URL '
          'when you send.',
      keyExample: 'page',
      valueHelp:
          'The value for that name. {{variables}} are filled in when you '
          'send.',
      valueExample: '2  or  {{pageSize}}',
    );
    if (request.pathVariables.isEmpty) return query;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: query),
        Divider(height: 1, color: Palette.border),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
          child: Text(
            'Path variables',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: Palette.textDim,
            ),
          ),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            children: [
              for (final v in request.pathVariables)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 160,
                        child: Text(
                          ':${v.key}',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                          ),
                        ),
                      ),
                      Expanded(
                        child: TextFormField(
                          key: ValueKey('pv-${v.key}'),
                          initialValue: v.value,
                          style: const TextStyle(fontSize: 13),
                          decoration: const InputDecoration(
                            isDense: true,
                            hintText: 'Value  —  {{vars}} allowed',
                          ),
                          onChanged: (s) {
                            v.value = s;
                            onChanged();
                          },
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
