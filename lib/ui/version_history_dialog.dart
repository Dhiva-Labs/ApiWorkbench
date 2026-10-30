import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/collection_diff.dart';
import '../services/version_history.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'adaptive.dart';
import 'help_tip.dart';

/// Snapshots of a collection with diff and restore (issue #35).
Future<void> showVersionHistory(
  BuildContext context,
  AppState state,
  CollectionModel c,
) => showDialog<void>(
  context: context,
  builder: (ctx) {
    final available = MediaQuery.sizeOf(ctx).height - 220;
    return AdaptiveDialog(
      title: Text('${c.name} history', overflow: TextOverflow.ellipsis),
      width: 720,
      height: available.clamp(240.0, 640.0),
      contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      content: VersionHistoryView(state: state, collectionId: c.id),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Close'),
        ),
      ],
    );
  },
);

/// Puts [collectionId] back to how [snapshot] had it. The current state is
/// snapshotted first, so the restore can be undone from the same list, and
/// the collection keeps its place in the sidebar. Returns the restored
/// collection.
Future<CollectionModel> restoreSnapshot(
  AppState state,
  String collectionId,
  HistorySnapshot snapshot,
) async {
  final current = state.collectionById(collectionId);
  if (current != null) await state.collectionHistory.snapshotNow(current);
  final restored = snapshot.toCollection();
  final index = state.collections.indexWhere((c) => c.id == collectionId);
  state.mergeWorkspace([restored], const []);
  // mergeWorkspace appends; move the collection back to where it was.
  if (index >= 0 && state.collections.length > 1) {
    state.collections.remove(restored);
    state.collections.insert(
      index.clamp(0, state.collections.length),
      restored,
    );
  }
  state.updateCollections();
  return restored;
}

/// "Today, 14:05", "Yesterday, 09:30", "Oct 29, 17:12" (with the year when
/// it is not this year).
String describeSnapshotTime(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final clock = '${two(t.hour)}:${two(t.minute)}';
  final day = DateTime(t.year, t.month, t.day);
  final today = DateTime(n.year, n.month, n.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today, $clock';
  if (diff == 1) return 'Yesterday, $clock';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final year = t.year == n.year ? '' : ' ${t.year}';
  return '${months[t.month - 1]} ${t.day}$year, $clock';
}

/// The snapshot list, and a snapshot's changes since, for one collection.
class VersionHistoryView extends StatefulWidget {
  const VersionHistoryView({
    super.key,
    required this.state,
    required this.collectionId,
  });

  final AppState state;
  final String collectionId;

  @override
  State<VersionHistoryView> createState() => _VersionHistoryViewState();
}

class _VersionHistoryViewState extends State<VersionHistoryView> {
  late Future<List<HistorySnapshot>> _snapshots = _load();
  HistorySnapshot? _selected;
  CollectionDiff? _diff;

  CollectionHistory get _history => widget.state.collectionHistory;
  CollectionModel? get _current =>
      widget.state.collectionById(widget.collectionId);

  /// Writes any change still waiting for the throttle, so the list is
  /// complete, then reads it.
  Future<List<HistorySnapshot>> _load() async {
    await _history.flush();
    return _history.snapshots(widget.collectionId);
  }

  void _open(HistorySnapshot s) {
    final current = _current;
    setState(() {
      _selected = s;
      _diff = current == null
          ? null
          : diffCollections(s.toCollection(), current);
    });
  }

  Future<void> _restore(HistorySnapshot s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore this version?'),
        content: Text(
          'The collection goes back to how it was on '
          '${describeSnapshotTime(s.time)}. Your current version is saved as '
          'a snapshot first, so you can come back to it from this list.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    await restoreSnapshot(widget.state, widget.collectionId, s);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          'Restored the version from ${describeSnapshotTime(s.time)}.',
        ),
      ),
    );
    if (!mounted) return;
    setState(() {
      _selected = null;
      _diff = null;
      _snapshots = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    if (selected != null) {
      return _SnapshotChanges(
        snapshot: selected,
        diff: _diff,
        onBack: () => setState(() {
          _selected = null;
          _diff = null;
        }),
        onRestore: () => _restore(selected),
      );
    }
    return FutureBuilder<List<HistorySnapshot>>(
      future: _snapshots,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final list = snap.data!;
        if (list.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No snapshots yet. One is taken each time the collection '
                'changes and is saved.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Palette.textDim),
              ),
            ),
          );
        }
        final current = _current;
        final currentHash = current == null
            ? null
            : CollectionHistory.hashOf(current);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Snapshots are taken automatically as the collection changes '
                '(at most one a minute, the latest ${_history.maxSnapshots} '
                'kept). Pick one to see what changed since, or restore it.',
                style: TextStyle(fontSize: 12.5, color: Palette.textDim),
              ),
            ),
            Expanded(
              child: ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 1, color: Palette.border),
                itemBuilder: (context, i) => _SnapshotRow(
                  snapshot: list[i],
                  isCurrent: list[i].hash == currentHash,
                  onOpen: () => _open(list[i]),
                  onRestore: () => _restore(list[i]),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SnapshotRow extends StatelessWidget {
  const _SnapshotRow({
    required this.snapshot,
    required this.isCurrent,
    required this.onOpen,
    required this.onRestore,
  });

  final HistorySnapshot snapshot;
  final bool isCurrent;
  final VoidCallback onOpen;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onOpen,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      describeSnapshotTime(snapshot.time),
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                      ),
                    ),
                    if (isCurrent)
                      HelpHover(
                        'The collection is in exactly this state right now.',
                        title: 'Current',
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: Palette.accentSoft,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'current',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Palette.accent,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  snapshot.summary.isEmpty ? 'Changed' : snapshot.summary,
                  style: TextStyle(fontSize: 12.5, color: Palette.textDim),
                ),
              ],
            ),
          ),
          HelpHover(
            'Put the collection back to this version. The current one is '
            'saved as a snapshot first.',
            title: 'Restore',
            child: IconButton(
              tooltip: 'Restore',
              icon: const Icon(Icons.restore, size: 20),
              onPressed: isCurrent ? null : onRestore,
            ),
          ),
          Icon(Icons.chevron_right, color: Palette.textDim),
        ],
      ),
    ),
  );
}

/// What changed from a snapshot to the collection as it is now.
class _SnapshotChanges extends StatelessWidget {
  const _SnapshotChanges({
    required this.snapshot,
    required this.diff,
    required this.onBack,
    required this.onRestore,
  });

  final HistorySnapshot snapshot;
  final CollectionDiff? diff;
  final VoidCallback onBack;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final d = diff;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton.icon(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back, size: 17),
              label: const Text('All snapshots'),
            ),
            HelpHover(
              'Put the collection back to this version. The current one is '
              'saved as a snapshot first.',
              title: 'Restore this version',
              child: FilledButton.icon(
                onPressed: d == null || d.isEmpty ? null : onRestore,
                icon: const Icon(Icons.restore, size: 17),
                label: const Text('Restore this version'),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
            'Changes since ${describeSnapshotTime(snapshot.time)}',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          ),
        ),
        Expanded(
          child: d == null
              ? Center(
                  child: Text(
                    'This collection no longer exists.',
                    style: TextStyle(color: Palette.textDim),
                  ),
                )
              : d.isEmpty
              ? Center(
                  child: Text(
                    'The collection is the same as this snapshot.',
                    style: TextStyle(color: Palette.textDim),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 12),
                  children: [
                    if (d.collection.isNotEmpty) ...[
                      const _Heading('Collection'),
                      for (final c in d.collection) _ChangeView(c),
                    ],
                    if (d.added.isNotEmpty) ...[
                      _Heading(
                        'Added since (${d.added.length})',
                        help:
                            'Requests that are not in the snapshot. '
                            'Restoring removes them.',
                      ),
                      for (final r in d.added) _RequestLine(r),
                    ],
                    if (d.removed.isNotEmpty) ...[
                      _Heading(
                        'Removed since (${d.removed.length})',
                        help:
                            'Requests the snapshot has that are gone now. '
                            'Restoring brings them back.',
                      ),
                      for (final r in d.removed) _RequestLine(r),
                    ],
                    if (d.changed.isNotEmpty) ...[
                      _Heading('Changed since (${d.changed.length})'),
                      for (final r in d.changed) _RequestChanges(r),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text, {this.help});

  final String text;
  final String? help;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 14, 0, 6),
    child: Row(
      children: [
        Flexible(
          child: Text(
            text.toUpperCase(),
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
              color: Palette.textDim,
            ),
          ),
        ),
        if (help != null) HelpTip(help!, title: text, size: 14),
      ],
    ),
  );
}

class _RequestLine extends StatelessWidget {
  const _RequestLine(this.request);

  final RequestModel request;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        _Badge(request),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            request.folder.isEmpty
                ? request.name
                : '${request.folder} / ${request.name}',
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );
}

class _Badge extends StatelessWidget {
  const _Badge(this.request);

  final RequestModel request;

  @override
  Widget build(BuildContext context) {
    final color = requestBadgeColor(request);
    return Container(
      constraints: const BoxConstraints(minWidth: 44),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        requestBadge(request),
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}

class _RequestChanges extends StatelessWidget {
  const _RequestChanges(this.diff);

  final RequestDiff diff;

  @override
  Widget build(BuildContext context) => Theme(
    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
    child: ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(left: 8, bottom: 8),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      title: Row(
        children: [
          _Badge(diff.after),
          const SizedBox(width: 8),
          Expanded(
            child: Text(diff.after.name, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
      subtitle: Text(
        diff.changes.map((c) => c.field.toLowerCase()).join(', '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: Palette.textDim),
      ),
      children: [for (final c in diff.changes) _ChangeView(c)],
    ),
  );
}

/// One changed field: `old → new` when short, else the changed lines.
class _ChangeView extends StatelessWidget {
  const _ChangeView(this.change);

  final FieldChange change;

  static const _maxLines = 60;

  @override
  Widget build(BuildContext context) {
    final mono = TextStyle(
      fontFamily: 'monospace',
      fontSize: 12,
      height: 1.4,
      color: Palette.text,
    );
    final Widget body;
    if (change.isInline) {
      body = Text.rich(
        TextSpan(
          style: mono,
          children: [
            if (change.before.isNotEmpty)
              TextSpan(
                text: change.before.first,
                style: TextStyle(
                  color: Palette.danger,
                  decoration: TextDecoration.lineThrough,
                ),
              )
            else
              TextSpan(
                text: '(empty)',
                style: TextStyle(color: Palette.textDim),
              ),
            TextSpan(
              text: '  →  ',
              style: TextStyle(color: Palette.textDim),
            ),
            if (change.after.isNotEmpty)
              TextSpan(
                text: change.after.first,
                style: TextStyle(color: Palette.success),
              )
            else
              TextSpan(
                text: '(empty)',
                style: TextStyle(color: Palette.textDim),
              ),
          ],
        ),
      );
    } else {
      final lines = change.lines;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final l in lines.take(_maxLines))
            Container(
              color: (l.added ? Palette.success : Palette.danger).withValues(
                alpha: 0.13,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              child: Text('${l.added ? '+' : '-'} ${l.text}', style: mono),
            ),
          if (lines.length > _maxLines)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '… ${lines.length - _maxLines} more lines',
                style: TextStyle(fontSize: 12, color: Palette.textDim),
              ),
            ),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            change.field,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          body,
        ],
      ),
    );
  }
}
