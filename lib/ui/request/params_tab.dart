import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme.dart';
import '../help_tip.dart';
import '../kv_editor.dart';

/// Keeps [RequestModel.pathVariables] in step with the `:name` segments of
/// the URL: new names get a row, rows for names no longer in the URL go.
/// Rows keep their value, description and flags for as long as the name
/// stays. When as many names appear as disappear at once (a name being
/// retyped), the new names take over the old rows instead of starting empty.
/// Returns true when the list changed.
bool syncPathVariables(RequestModel r) {
  final names = pathVariableNames(r.url);
  final before = r.pathVariables.map((v) => v.key).join('\n');

  final byKey = <String, KV>{};
  for (final v in r.pathVariables) {
    byKey.putIfAbsent(v.key, () => v);
  }
  final wanted = names.toSet();
  final orphans = [
    for (final v in byKey.values)
      if (!wanted.contains(v.key)) v,
  ];
  final fresh = [
    for (final n in names)
      if (!byKey.containsKey(n)) n,
  ];
  final renamed = <String, KV>{};
  if (orphans.isNotEmpty && orphans.length == fresh.length) {
    for (var i = 0; i < fresh.length; i++) {
      renamed[fresh[i]] = orphans[i]..key = fresh[i];
    }
  }

  r.pathVariables = [
    for (final n in names) byKey[n] ?? renamed[n] ?? KV(key: n),
  ];
  return r.pathVariables.map((v) => v.key).join('\n') != before;
}

/// The Params tab: the query parameters table, and the path variables for
/// the `:name` segments of the URL. Both scroll together, so the path
/// variables stay reachable on a phone.
class ParamsTab extends StatefulWidget {
  const ParamsTab({super.key, required this.request, required this.onChanged});

  final RequestModel request;
  final VoidCallback onChanged;

  @override
  State<ParamsTab> createState() => _ParamsTabState();
}

class _ParamsTabState extends State<ParamsTab> {
  @override
  void initState() {
    super.initState();
    // A request opened from a collection or an import may have `:name`
    // segments without rows yet. This is derived data, so it is not a change.
    syncPathVariables(widget.request);
  }

  @override
  void didUpdateWidget(ParamsTab old) {
    super.didUpdateWidget(old);
    syncPathVariables(widget.request);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const _SectionTitle(
            'Query params',
            'Name and value pairs added to the end of the URL after a ?. '
                'Untick a row to leave it out without deleting it.',
            example: '?page=2&limit=20',
          ),
          KVEditor(
            rows: r.params,
            onChanged: widget.onChanged,
            scrollable: false,
            showDescription: true,
            keyHint: 'Parameter',
            addLabel: 'Add parameter',
            keyHelp:
                'The name part of a query parameter. Rows are added to the '
                'URL when you send.',
            keyExample: 'page',
            valueHelp:
                'The value for that name. {{variables}} are filled in when '
                'you send.',
            valueExample: '2  or  {{pageSize}}',
            descriptionHelp:
                'A note about this parameter for you and your team. It is '
                'never sent.',
          ),
          Divider(height: 1, color: Palette.border),
          const _SectionTitle(
            'Path variables',
            'Values for the :name segments in the URL. Write :id in the URL '
                'and a row appears here; the value replaces :id when you '
                'send.',
            example: '/users/:id  with  id = 42',
          ),
          PathVariablesTable(
            key: const ValueKey('path-variables'),
            variables: r.pathVariables,
            onChanged: widget.onChanged,
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, this.help, {this.example});

  final String title;
  final String help;
  final String? example;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
    child: Align(
      alignment: Alignment.centerLeft,
      child: LabelWithHelp(
        title,
        help,
        example: example,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          color: Palette.textDim,
        ),
      ),
    ),
  );
}

/// The path variables of a request: the key is read-only (it comes from the
/// URL), the value takes {{variables}}, and each row can have a description.
/// On narrow screens the fields stack under the key.
class PathVariablesTable extends StatelessWidget {
  const PathVariablesTable({
    super.key,
    required this.variables,
    required this.onChanged,
  });

  final List<KV> variables;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    if (variables.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
        child: Text(
          'No path variables. Put a :name segment in the URL, like '
          '/users/:id, to add one.',
          style: TextStyle(fontSize: 12.5, color: Palette.textDim),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        final stacked = box.maxWidth < 560;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(stacked),
              for (final v in variables)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _row(v, stacked),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _header(bool stacked) {
    final style = TextStyle(
      fontSize: 11.5,
      fontWeight: FontWeight.w600,
      color: Palette.textDim,
    );
    final labels = [
      LabelWithHelp(
        'Key',
        'The :name segment from the URL. It cannot be edited here; change '
            'it in the URL.',
        style: style,
        example: ':id',
      ),
      LabelWithHelp(
        'Value',
        'What replaces the segment when you send. {{variables}} are filled '
            'in first. An empty value leaves :name as typed.',
        style: style,
        example: '42  or  {{userId}}',
      ),
      LabelWithHelp(
        'Description',
        'A note about this variable for you and your team. It is never sent.',
        style: style,
      ),
    ];
    if (stacked) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Wrap(spacing: 16, runSpacing: 2, children: labels),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(width: _keyWidth, child: labels[0]),
          const SizedBox(width: 8),
          Expanded(flex: 3, child: labels[1]),
          const SizedBox(width: 8),
          Expanded(flex: 2, child: labels[2]),
        ],
      ),
    );
  }

  static const _keyWidth = 150.0;

  Widget _row(KV v, bool stacked) {
    final key = HelpHover(
      'Comes from the URL, so it is read-only. Rename it by editing the '
      ':name segment in the URL; the value stays while the name does.',
      title: ':${v.key}',
      child: Container(
        height: 40,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Palette.surfaceAlt,
          border: Border.all(color: Palette.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          ':${v.key}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ),
      ),
    );
    final value = TextFormField(
      key: ValueKey(v),
      initialValue: v.value,
      style: const TextStyle(fontSize: 13),
      decoration: const InputDecoration(hintText: 'Value  —  {{vars}} allowed'),
      onChanged: (s) {
        v.value = s;
        onChanged();
      },
    );
    final description = TextFormField(
      key: ValueKey((v, 'description')),
      initialValue: v.description,
      style: const TextStyle(fontSize: 13),
      decoration: const InputDecoration(hintText: 'Description'),
      onChanged: (s) {
        v.description = s;
        onChanged();
      },
    );
    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(alignment: Alignment.centerLeft, child: key),
          const SizedBox(height: 6),
          value,
          const SizedBox(height: 6),
          description,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: _keyWidth, child: key),
        const SizedBox(width: 8),
        Expanded(flex: 3, child: value),
        const SizedBox(width: 8),
        Expanded(flex: 2, child: description),
      ],
    );
  }
}
