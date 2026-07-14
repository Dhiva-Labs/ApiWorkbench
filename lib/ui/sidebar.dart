import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'kv_editor.dart';
import 'runner_screen.dart';

enum SidebarSection { collections, environments, history }

class Sidebar extends StatefulWidget {
  const Sidebar({super.key, this.onRequestOpened});

  /// Called after a request is opened (used to close the drawer on mobile).
  final VoidCallback? onRequestOpened;

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  SidebarSection _section = SidebarSection.collections;
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
          child: SegmentedButton<SidebarSection>(
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            segments: const [
              ButtonSegment(
                  value: SidebarSection.collections,
                  icon: Icon(Icons.folder_outlined, size: 17),
                  tooltip: 'Collections'),
              ButtonSegment(
                  value: SidebarSection.environments,
                  icon: Icon(Icons.public, size: 17),
                  tooltip: 'Environments'),
              ButtonSegment(
                  value: SidebarSection.history,
                  icon: Icon(Icons.history, size: 17),
                  tooltip: 'History'),
            ],
            selected: {_section},
            onSelectionChanged: (s) => setState(() => _section = s.first),
          ),
        ),
        if (_section != SidebarSection.environments)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
            child: TextField(
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                hintText: 'Filter…',
                prefixIcon: Icon(Icons.search, size: 17),
                prefixIconConstraints:
                    BoxConstraints(minWidth: 36, minHeight: 36),
              ),
              onChanged: (v) => setState(() => _filter = v.toLowerCase()),
            ),
          ),
        Expanded(
          child: switch (_section) {
            SidebarSection.collections => _collections(state),
            SidebarSection.environments => _environments(state),
            SidebarSection.history => _history(state),
          },
        ),
      ],
    );
  }

  // ---------------- Collections ----------------

  Widget _collections(AppState state) {
    final cols = state.collections;
    return Column(
      children: [
        Expanded(
          child: cols.isEmpty
              ? _empty('No collections yet.\nSave a request to create one.')
              : ListView(
                  padding: const EdgeInsets.only(bottom: 8),
                  children: [
                    for (final c in cols) _collectionTile(state, c),
                  ],
                ),
        ),
        _bottomAction('New collection', Icons.create_new_folder_outlined,
            () => _newCollectionDialog(state)),
      ],
    );
  }

  Widget _collectionTile(AppState state, CollectionModel c) {
    final requests = c.requests
        .where((r) =>
            _filter.isEmpty ||
            r.name.toLowerCase().contains(_filter) ||
            r.url.toLowerCase().contains(_filter))
        .toList();
    if (_filter.isNotEmpty && requests.isEmpty) return const SizedBox.shrink();
    return ExpansionTile(
      key: PageStorageKey(c.id),
      dense: true,
      initiallyExpanded: _filter.isNotEmpty,
      leading: const Icon(Icons.folder_outlined, size: 18),
      shape: const Border(),
      title: Text(c.name,
          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
      subtitle: Text('${c.requests.length} requests',
          style: const TextStyle(fontSize: 11, color: Palette.textDim)),
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_horiz, size: 17, color: Palette.textDim),
        onSelected: (v) {
          if (v == 'run') {
            if (c.requests.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('This collection has no requests to run.')));
              return;
            }
            Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => RunnerScreen(
                  title: c.name,
                  requests: c.requests.map((r) => r.clone()).toList()),
            ));
          }
          if (v == 'rename') _renameCollectionDialog(state, c);
          if (v == 'delete') _confirmDeleteCollection(state, c);
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'run', child: Text('Run collection…')),
          PopupMenuItem(value: 'rename', child: Text('Rename')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
      children: [
        for (final r in requests)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 26, right: 8),
            leading: _methodBadge(r.method),
            title: Text(r.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13)),
            onTap: () {
              state.openRequest(r, collectionId: c.id);
              widget.onRequestOpened?.call();
            },
            trailing: PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz,
                  size: 16, color: Palette.textDim),
              onSelected: (v) {
                if (v == 'duplicate') state.duplicateRequest(c, r);
                if (v == 'delete') state.deleteRequest(c, r);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _newCollectionDialog(AppState state) async {
    final name = await _promptText(context, 'New collection', 'Name');
    if (name != null && name.isNotEmpty) state.addCollection(name);
  }

  Future<void> _renameCollectionDialog(
      AppState state, CollectionModel c) async {
    final name =
        await _promptText(context, 'Rename collection', 'Name', initial: c.name);
    if (name != null && name.isNotEmpty) state.renameCollection(c, name);
  }

  Future<void> _confirmDeleteCollection(
      AppState state, CollectionModel c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${c.name}"?'),
        content: Text(
            'This removes the collection and its ${c.requests.length} saved requests.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Palette.delete),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) state.deleteCollection(c);
  }

  // ---------------- Environments ----------------

  Widget _environments(AppState state) {
    return Column(
      children: [
        Expanded(
          child: state.environments.isEmpty
              ? _empty(
                  'No environments yet.\nDefine {{variables}} once, reuse them everywhere.')
              : RadioGroup<String?>(
                  groupValue: state.activeEnvironmentId,
                  onChanged: (v) => state.setActiveEnvironment(v),
                  child: ListView(
                    children: [
                      const RadioListTile<String?>(
                        value: null,
                        dense: true,
                        title: Text('No environment',
                            style: TextStyle(fontSize: 13)),
                      ),
                      for (final e in state.environments)
                        RadioListTile<String?>(
                          value: e.id,
                          dense: true,
                          title: Text(e.name,
                              style: const TextStyle(fontSize: 13.5)),
                          subtitle: Text('${e.variables.length} variables',
                              style: const TextStyle(
                                  fontSize: 11, color: Palette.textDim)),
                          secondary: IconButton(
                            tooltip: 'Edit variables',
                            icon: const Icon(Icons.edit_outlined,
                                size: 17, color: Palette.textDim),
                            onPressed: () => _editEnvironment(state, e),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
        _bottomAction('New environment', Icons.add_circle_outline, () async {
          final name = await _promptText(context, 'New environment', 'Name');
          if (name == null || name.isEmpty) return;
          final env = state.addEnvironment(name);
          if (mounted) _editEnvironment(state, env);
        }),
      ],
    );
  }

  void _editEnvironment(AppState state, EnvironmentModel env) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Expanded(child: Text(env.name)),
            IconButton(
              tooltip: 'Delete environment',
              icon: const Icon(Icons.delete_outline,
                  size: 19, color: Palette.delete),
              onPressed: () {
                state.deleteEnvironment(env);
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
        content: SizedBox(
          width: 520,
          height: 360,
          child: KVEditor(
            rows: env.variables,
            onChanged: state.updateEnvironment,
            keyHint: 'Variable',
            addLabel: 'Add variable',
          ),
        ),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
        ],
      ),
    );
  }

  // ---------------- History ----------------

  Widget _history(AppState state) {
    final items = state.history
        .where((h) =>
            _filter.isEmpty || h.request.url.toLowerCase().contains(_filter))
        .toList();
    return Column(
      children: [
        Expanded(
          child: items.isEmpty
              ? _empty('Requests you send will appear here.')
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (_, i) {
                    final h = items[i];
                    return ListTile(
                      dense: true,
                      leading: _methodBadge(h.request.method),
                      title: Text(
                        h.request.url,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12.5, fontFamily: 'monospace'),
                      ),
                      subtitle: Text(
                        '${h.statusCode == 0 ? 'error' : h.statusCode} • '
                        '${h.durationMs} ms • ${_ago(h.at)}',
                        style: TextStyle(
                            fontSize: 11,
                            color: h.statusCode == 0
                                ? Palette.delete
                                : statusColor(h.statusCode)),
                      ),
                      onTap: () {
                        state.newTab(h.request.clone());
                        widget.onRequestOpened?.call();
                      },
                    );
                  },
                ),
        ),
        if (state.history.isNotEmpty)
          _bottomAction(
              'Clear history', Icons.delete_sweep_outlined, state.clearHistory),
      ],
    );
  }

  // ---------------- Shared bits ----------------

  Widget _methodBadge(String method) => SizedBox(
        width: 44,
        child: Text(
          method == 'DELETE' ? 'DEL' : method,
          style: TextStyle(
            color: methodColor(method),
            fontWeight: FontWeight.w800,
            fontSize: 11,
          ),
        ),
      );

  Widget _empty(String message) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Palette.textDim, fontSize: 12.5)),
        ),
      );

  Widget _bottomAction(String label, IconData icon, VoidCallback onTap) =>
      Container(
        width: double.infinity,
        decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: Palette.border))),
        child: TextButton.icon(
          style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12)),
          onPressed: onTap,
          icon: Icon(icon, size: 17),
          label: Text(label, style: const TextStyle(fontSize: 13)),
        ),
      );
}

Future<String?> _promptText(BuildContext context, String title, String label,
    {String initial = ''}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('OK')),
      ],
    ),
  );
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}
