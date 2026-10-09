import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'import_dialog.dart';
import 'kv_editor.dart';
import 'load_test_screen.dart';
import 'runner_screen.dart';

enum SidebarSection { collections, environments, history }

extension SidebarSectionInfo on SidebarSection {
  String get label => switch (this) {
    SidebarSection.collections => 'Collections',
    SidebarSection.environments => 'Environments',
    SidebarSection.history => 'History',
  };

  IconData get icon => switch (this) {
    SidebarSection.collections => Icons.folder_copy_outlined,
    SidebarSection.environments => Icons.public,
    SidebarSection.history => Icons.history,
  };
}

/// The side panel: a collection tree with folders, environments, or
/// history. On desktop the icon rail picks [section]; on mobile (no
/// [section]) the panel shows its own switcher.
class Sidebar extends StatefulWidget {
  const Sidebar({super.key, this.section, this.onRequestOpened});

  final SidebarSection? section;

  /// Called after a request is opened (used to close the drawer on mobile).
  final VoidCallback? onRequestOpened;

  @override
  State<Sidebar> createState() => _SidebarState();
}

/// A folder in the collection tree; children are [_Folder]s and requests in
/// their original order.
class _Folder {
  _Folder(this.name, this.path);
  final String name;
  final String path;
  final children = <Object>[];

  int get count => children.fold(0, (s, c) => s + (c is _Folder ? c.count : 1));
}

class _SidebarState extends State<Sidebar> {
  SidebarSection _own = SidebarSection.collections;
  String _filter = '';
  final Set<String> _expanded = {};

  SidebarSection get _section => widget.section ?? _own;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Column(
      children: [
        if (widget.section == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 2),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<SidebarSection>(
                showSelectedIcon: false,
                segments: [
                  for (final s in SidebarSection.values)
                    ButtonSegment(
                      value: s,
                      icon: Icon(s.icon, size: 17),
                      tooltip: s.label,
                    ),
                ],
                selected: {_own},
                onSelectionChanged: (s) => setState(() => _own = s.first),
              ),
            ),
          ),
        _header(state),
        if (_section != SidebarSection.environments)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: SizedBox(
              height: 34,
              child: TextField(
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: _section == SidebarSection.collections
                      ? 'Search requests'
                      : 'Search history',
                  prefixIcon: Icon(
                    Icons.search,
                    size: 17,
                    color: Palette.textDim,
                  ),
                  prefixIconConstraints: const BoxConstraints(minWidth: 34),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onChanged: (v) => setState(() => _filter = v.toLowerCase()),
              ),
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

  Widget _header(AppState state) {
    Widget action(String tip, IconData icon, VoidCallback onTap) => IconButton(
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, size: 19),
      onPressed: onTap,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 6, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _section.label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Palette.text,
              ),
            ),
          ),
          ...switch (_section) {
            SidebarSection.collections => [
              action(
                'Import Postman or workspace',
                Icons.download_outlined,
                () => showImportDialog(context),
              ),
              action(
                'New collection',
                Icons.create_new_folder_outlined,
                () => _newCollectionDialog(state),
              ),
            ],
            SidebarSection.environments => [
              action(
                'New environment',
                Icons.add,
                () => _newEnvironment(state),
              ),
            ],
            SidebarSection.history => [
              if (state.history.isNotEmpty)
                action(
                  'Clear history',
                  Icons.delete_sweep_outlined,
                  state.clearHistory,
                ),
            ],
          },
        ],
      ),
    );
  }

  // ---------------- Collections ----------------

  bool _matches(RequestModel r) =>
      _filter.isEmpty ||
      r.name.toLowerCase().contains(_filter) ||
      r.url.toLowerCase().contains(_filter) ||
      r.folder.toLowerCase().contains(_filter);

  _Folder _tree(CollectionModel c) {
    final root = _Folder(c.name, '');
    final index = <String, _Folder>{'': root};
    for (final r in c.requests) {
      if (!_matches(r)) continue;
      var parent = root;
      var path = '';
      if (r.folder.isNotEmpty) {
        for (final seg in r.folder.split('/')) {
          path = path.isEmpty ? seg : '$path/$seg';
          final p = parent;
          parent = index.putIfAbsent(path, () {
            final f = _Folder(seg, path);
            p.children.add(f);
            return f;
          });
        }
      }
      parent.children.add(r);
    }
    return root;
  }

  Widget _collections(AppState state) {
    final cols = state.collections;
    if (cols.isEmpty) {
      return _emptyState(
        icon: Icons.folder_copy_outlined,
        title: 'Start a collection',
        body:
            'Save requests into collections, or bring in everything you '
            'have in Postman.',
        actions: [
          FilledButton.icon(
            onPressed: () => showImportDialog(context),
            icon: const Icon(Icons.download_outlined, size: 17),
            label: const Text('Import from Postman'),
          ),
          OutlinedButton.icon(
            onPressed: () => _newCollectionDialog(state),
            icon: const Icon(Icons.create_new_folder_outlined, size: 17),
            label: const Text('New collection'),
          ),
        ],
      );
    }
    final activeId = state.activeTab?.request.id;
    final rows = <Widget>[];
    for (final c in cols) {
      final tree = _tree(c);
      if (_filter.isNotEmpty && tree.count == 0) continue;
      final key = 'c:${c.id}';
      final open = _filter.isNotEmpty || _expanded.contains(key);
      rows.add(
        _row(
          depth: 0,
          expanded: open,
          icon: Icons.inventory_2_outlined,
          label: c.name,
          bold: true,
          meta: '${c.requests.length}',
          onTap: () => _toggle(key),
          menu: _collectionMenu(state, c),
        ),
      );
      if (open) _children(state, c, tree, 1, activeId, rows);
    }
    if (rows.isEmpty) return _empty('No requests match "$_filter".');
    return ListView(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 12),
      children: rows,
    );
  }

  void _children(
    AppState state,
    CollectionModel c,
    _Folder folder,
    int depth,
    String? activeId,
    List<Widget> out,
  ) {
    for (final child in folder.children) {
      if (child is _Folder) {
        final key = 'f:${c.id}/${child.path}';
        final open = _filter.isNotEmpty || _expanded.contains(key);
        out.add(
          _row(
            depth: depth,
            expanded: open,
            icon: open ? Icons.folder_open_outlined : Icons.folder_outlined,
            label: child.name,
            meta: '${child.count}',
            onTap: () => _toggle(key),
            menu: _folderMenu(c, child),
          ),
        );
        if (open) _children(state, c, child, depth + 1, activeId, out);
      } else if (child is RequestModel) {
        out.add(
          _row(
            depth: depth,
            method: child.method,
            label: child.name,
            selected: child.id == activeId,
            onTap: () {
              state.openRequest(child, collectionId: c.id);
              widget.onRequestOpened?.call();
            },
            menu: _requestMenu(state, c, child),
          ),
        );
      }
    }
  }

  void _toggle(String key) => setState(
    () => _expanded.contains(key) ? _expanded.remove(key) : _expanded.add(key),
  );

  /// One tree row: chevron (for groups) or method badge, label, count and a
  /// hover menu.
  Widget _row({
    required int depth,
    required String label,
    required VoidCallback onTap,
    bool? expanded,
    IconData? icon,
    String? method,
    String? meta,
    bool bold = false,
    bool selected = false,
    Widget? menu,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: selected ? Palette.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: SizedBox(
            height: 32,
            child: Row(
              children: [
                SizedBox(width: 6.0 + depth * 14),
                if (expanded != null)
                  AnimatedRotation(
                    turns: expanded ? 0.25 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: Palette.textDim,
                    ),
                  )
                else
                  const SizedBox(width: 4),
                if (icon != null) ...[
                  const SizedBox(width: 2),
                  Icon(icon, size: 16, color: Palette.textDim),
                  const SizedBox(width: 8),
                ],
                if (method != null)
                  SizedBox(
                    width: 46,
                    child: Text(
                      method == 'DELETE' ? 'DEL' : method,
                      style: TextStyle(
                        color: methodColor(method),
                        fontWeight: FontWeight.w800,
                        fontSize: 10.5,
                      ),
                    ),
                  ),
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: Palette.text,
                      fontWeight: bold
                          ? FontWeight.w600
                          : (selected ? FontWeight.w600 : FontWeight.w400),
                    ),
                  ),
                ),
                if (meta != null)
                  Text(
                    meta,
                    style: TextStyle(fontSize: 11, color: Palette.textDim),
                  ),
                ?menu,
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _menuButton(
    List<PopupMenuEntry<String>> items,
    void Function(String) on,
  ) => PopupMenuButton<String>(
    tooltip: 'More',
    padding: EdgeInsets.zero,
    iconSize: 17,
    icon: Icon(Icons.more_horiz, size: 17, color: Palette.textDim),
    onSelected: on,
    itemBuilder: (_) => items,
  );

  PopupMenuItem<String> _item(String value, IconData icon, String text) =>
      PopupMenuItem(
        value: value,
        height: 38,
        child: Row(
          children: [
            Icon(icon, size: 17, color: Palette.textDim),
            const SizedBox(width: 10),
            Text(text, style: const TextStyle(fontSize: 13)),
          ],
        ),
      );

  Widget _collectionMenu(AppState state, CollectionModel c) => _menuButton(
    [
      _item('run', Icons.play_circle_outline, 'Run collection'),
      _item('load', Icons.speed, 'Load test collection'),
      _item('import', Icons.download_outlined, 'Import into collection'),
      _item('vars', Icons.data_object, 'Variables'),
      _item('rename', Icons.edit_outlined, 'Rename'),
      _item('delete', Icons.delete_outline, 'Delete'),
    ],
    (v) => switch (v) {
      'run' => _openRunner(c, c.requests, c.name),
      'load' => _openLoadTest(c, c.requests, c.name),
      'import' => showImportDialog(context, collectionId: c.id),
      'vars' => _editCollectionVariables(state, c),
      'rename' => _renameCollectionDialog(state, c),
      'delete' => _confirmDeleteCollection(state, c),
      _ => null,
    },
  );

  Widget _folderMenu(CollectionModel c, _Folder f) {
    final inFolder = [
      for (final r in c.requests)
        if (r.folder == f.path || r.folder.startsWith('${f.path}/')) r,
    ];
    return _menuButton(
      [
        _item('run', Icons.play_circle_outline, 'Run folder'),
        _item('load', Icons.speed, 'Load test folder'),
        _item('import', Icons.download_outlined, 'Import into folder'),
      ],
      (v) => switch (v) {
        'import' => showImportDialog(
          context,
          collectionId: c.id,
          folder: f.path,
        ),
        'run' => _openRunner(c, inFolder, '${c.name} › ${f.name}'),
        'load' => _openLoadTest(c, inFolder, '${c.name} › ${f.name}'),
        _ => null,
      },
    );
  }

  Widget _requestMenu(AppState state, CollectionModel c, RequestModel r) =>
      _menuButton(
        [
          _item('duplicate', Icons.copy_outlined, 'Duplicate'),
          _item('load', Icons.speed, 'Load test'),
          _item('delete', Icons.delete_outline, 'Delete'),
        ],
        (v) => switch (v) {
          'duplicate' => state.duplicateRequest(c, r),
          'load' => _openLoadTest(c, [r], r.name),
          'delete' => state.deleteRequest(c, r),
          _ => null,
        },
      );

  void _openRunner(CollectionModel c, List<RequestModel> reqs, String title) {
    if (reqs.isEmpty) return _toast('Nothing to run here yet.');
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RunnerScreen(
          title: title,
          requests: reqs.map((r) => r.clone()).toList(),
          collectionId: c.id,
        ),
      ),
    );
  }

  void _openLoadTest(CollectionModel c, List<RequestModel> reqs, String title) {
    if (reqs.isEmpty) return _toast('Nothing to test here yet.');
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LoadTestScreen(
          title: title,
          requests: reqs.map((r) => r.clone()).toList(),
          collectionId: c.id,
        ),
      ),
    );
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  void _editCollectionVariables(AppState state, CollectionModel c) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${c.name} variables'),
        content: SizedBox(
          width: 560,
          height: 380,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Available as {{name}} to every request in this collection. '
                'The active environment wins when both define a name.',
                style: TextStyle(fontSize: 12.5, color: Palette.textDim),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: KVEditor(
                  rows: c.variables,
                  onChanged: state.updateCollections,
                  keyHint: 'Variable',
                  addLabel: 'Add variable',
                ),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _newCollectionDialog(AppState state) async {
    final name = await _promptText(context, 'New collection', 'Name');
    if (name != null && name.isNotEmpty) state.addCollection(name);
  }

  Future<void> _renameCollectionDialog(
    AppState state,
    CollectionModel c,
  ) async {
    final name = await _promptText(
      context,
      'Rename collection',
      'Name',
      initial: c.name,
    );
    if (name != null && name.isNotEmpty) state.renameCollection(c, name);
  }

  Future<void> _confirmDeleteCollection(
    AppState state,
    CollectionModel c,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${c.name}"?'),
        content: Text(
          'This removes the collection and its ${c.requests.length} saved '
          'requests.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Palette.delete,
              foregroundColor: Colors.white,
            ),
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
    if (state.environments.isEmpty) {
      return _emptyState(
        icon: Icons.public,
        title: 'Add an environment',
        body:
            'Define {{variables}} such as baseUrl or token once, then switch '
            'between local, staging and production in one click.',
        actions: [
          FilledButton.icon(
            onPressed: () => _newEnvironment(state),
            icon: const Icon(Icons.add, size: 17),
            label: const Text('New environment'),
          ),
          OutlinedButton.icon(
            onPressed: () => showImportDialog(context),
            icon: const Icon(Icons.download_outlined, size: 17),
            label: const Text('Import from Postman'),
          ),
        ],
      );
    }
    Widget envRow(EnvironmentModel? e) {
      final active = state.activeEnvironmentId == e?.id;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Material(
          color: active ? Palette.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => state.setActiveEnvironment(e?.id),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
              child: Row(
                children: [
                  Icon(
                    active
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 17,
                    color: active ? Palette.accent : Palette.textDim,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          e?.name ?? 'No environment',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: Palette.text,
                            fontWeight: active
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                        if (e != null)
                          Text(
                            '${e.variables.length} variables',
                            style: TextStyle(
                              fontSize: 11,
                              color: Palette.textDim,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (e != null)
                    IconButton(
                      tooltip: 'Edit variables',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.edit_outlined, size: 17),
                      onPressed: () => _editEnvironment(state, e),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 12),
      children: [envRow(null), for (final e in state.environments) envRow(e)],
    );
  }

  Future<void> _newEnvironment(AppState state) async {
    final name = await _promptText(context, 'New environment', 'Name');
    if (name == null || name.isEmpty) return;
    final env = state.addEnvironment(name);
    if (mounted) _editEnvironment(state, env);
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
              icon: Icon(Icons.delete_outline, size: 19, color: Palette.delete),
              onPressed: () {
                state.deleteEnvironment(env);
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
        content: SizedBox(
          width: 560,
          height: 380,
          child: KVEditor(
            rows: env.variables,
            onChanged: state.updateEnvironment,
            keyHint: 'Variable',
            addLabel: 'Add variable',
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  // ---------------- History ----------------

  Widget _history(AppState state) {
    final items = state.history
        .where(
          (h) =>
              _filter.isEmpty || h.request.url.toLowerCase().contains(_filter),
        )
        .toList();
    if (items.isEmpty) {
      return _filter.isEmpty
          ? _emptyState(
              icon: Icons.history,
              title: 'No requests yet',
              body: 'Every request you send shows up here.',
            )
          : _empty('No history matches "$_filter".');
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 12),
      itemCount: items.length,
      itemBuilder: (_, i) {
        final h = items[i];
        final code = h.statusCode;
        return InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () {
            state.newTab(h.request.clone());
            widget.onRequestOpened?.call();
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 7, 8, 7),
            child: Row(
              children: [
                SizedBox(
                  width: 46,
                  child: Text(
                    h.request.method == 'DELETE' ? 'DEL' : h.request.method,
                    style: TextStyle(
                      color: methodColor(h.request.method),
                      fontWeight: FontWeight.w800,
                      fontSize: 10.5,
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        h.request.url,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontFamily: 'monospace',
                          color: Palette.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${code == 0 ? 'Error' : code} · ${h.durationMs} ms · '
                        '${_ago(h.at)}',
                        style: TextStyle(
                          fontSize: 11,
                          color: code == 0 ? Palette.delete : statusColor(code),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------------- Shared bits ----------------

  Widget _empty(String message) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: TextStyle(color: Palette.textDim, fontSize: 12.5),
      ),
    ),
  );

  Widget _emptyState({
    required IconData icon,
    required String title,
    required String body,
    List<Widget> actions = const [],
  }) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: Palette.accentSoft,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: Palette.accent, size: 26),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
              color: Palette.text,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.5,
              color: Palette.textDim,
              height: 1.45,
            ),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 16),
            for (final a in actions)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SizedBox(width: 220, child: a),
              ),
          ],
        ],
      ),
    ),
  );
}

Future<String?> _promptText(
  BuildContext context,
  String title,
  String label, {
  String initial = '',
}) {
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
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          child: const Text('OK'),
        ),
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
