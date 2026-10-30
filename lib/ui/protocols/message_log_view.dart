import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/protocols/message_log.dart';
import '../../theme.dart';
import '../adaptive.dart';
import '../help_tip.dart';

/// What the user chose in a log view: kept apart from the widget so it
/// survives the view being rebuilt (for example between the Request and
/// Response pages on a phone).
class LogViewState {
  String query = '';
  bool autoScroll = true;
  BinaryFormat binary = BinaryFormat.hex;
  Set<Direction> directions = {...Direction.values};

  /// Entries expanded to their full text, by [LogEntry.seq].
  final Set<int> expanded = {};
}

/// A message log: direction, time, size and an expandable preview that
/// pretty-prints JSON, with search, filters, clear, copy and auto-scroll.
class MessageLogView extends StatefulWidget {
  const MessageLogView({
    super.key,
    required this.log,
    required this.view,
    this.header,
    this.emptyHint = 'Nothing yet.',
  });

  final MessageLog log;
  final LogViewState view;

  /// Shown above the toolbar, such as the connection status.
  final Widget? header;

  /// Shown while the log has no entries.
  final String emptyHint;

  @override
  State<MessageLogView> createState() => _MessageLogViewState();
}

class _MessageLogViewState extends State<MessageLogView> {
  final _scroll = ScrollController();
  late final TextEditingController _search;
  int _lastSeq = 0;
  int _lastLength = 0;

  LogViewState get v => widget.view;
  MessageLog get log => widget.log;

  @override
  void initState() {
    super.initState();
    _search = TextEditingController(text: v.query);
    _lastSeq = log.isEmpty ? 0 : log[log.length - 1].seq;
    _lastLength = log.length;
    WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom());
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(MessageLogView old) {
    super.didUpdateWidget(old);
    final seq = log.isEmpty ? 0 : log[log.length - 1].seq;
    if ((seq != _lastSeq || log.length != _lastLength) && v.autoScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom());
    }
    _lastSeq = seq;
    _lastLength = log.length;
  }

  /// Jumps to the newest message. Rows differ in height, so the scroll extent
  /// is only an estimate until they are laid out; a few passes settle it.
  void _toBottom([int pass = 0]) {
    if (!mounted || !_scroll.hasClients) return;
    final before = _scroll.position.maxScrollExtent;
    _scroll.jumpTo(before);
    if (pass < 3) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients || !v.autoScroll) return;
        if (_scroll.position.maxScrollExtent != before) _toBottom(pass + 1);
      });
    }
  }

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$what copied to clipboard')));
  }

  @override
  Widget build(BuildContext context) {
    final shown = log.filtered(query: v.query, directions: v.directions);
    final filtering = v.query.trim().isNotEmpty || v.directions.length < 3;
    return Column(
      children: [
        ?widget.header,
        _toolbar(),
        Divider(height: 1, color: Palette.border),
        Expanded(
          child: shown.isEmpty
              ? _empty(filtering)
              : NotificationListener<ScrollUpdateNotification>(
                  onNotification: (n) {
                    // Scrolling up to read pauses auto-scroll.
                    if ((n.scrollDelta ?? 0) < 0 &&
                        v.autoScroll &&
                        n.metrics.maxScrollExtent - n.metrics.pixels > 40) {
                      setState(() => v.autoScroll = false);
                    }
                    return false;
                  },
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: shown.length,
                    itemBuilder: (context, i) => _EntryTile(
                      key: ValueKey(shown[i].seq),
                      entry: shown[i],
                      format: v.binary,
                      expanded: v.expanded.contains(shown[i].seq),
                      onToggle: () => setState(() {
                        final s = shown[i].seq;
                        if (!v.expanded.remove(s)) v.expanded.add(s);
                      }),
                      onCopy: () => _copy(shown[i].body(v.binary), 'Message'),
                    ),
                  ),
                ),
        ),
        _footer(shown.length, filtering),
      ],
    );
  }

  Widget _empty(bool filtering) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        filtering
            ? 'No messages match the search or filter.'
            : widget.emptyHint,
        textAlign: TextAlign.center,
        style: TextStyle(color: Palette.textDim, fontSize: 13),
      ),
    ),
  );

  Widget _footer(int shown, bool filtering) {
    final total = log.length;
    final parts = [
      filtering ? '$shown of $total messages' : '$total messages',
      if (log.dropped > 0)
        '${log.dropped} older dropped (limit ${log.capacity})',
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Palette.border)),
      ),
      child: Text(
        parts.join(' · '),
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11.5, color: Palette.textDim),
      ),
    );
  }

  Widget _toolbar() {
    final search = TextField(
      controller: _search,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        hintText: 'Search messages',
        prefixIcon: Icon(Icons.search, size: 18, color: Palette.textDim),
        prefixIconConstraints: const BoxConstraints(minWidth: 34),
        suffixIcon: const HelpTip(
          'Show only messages containing this text, in the payload, topic, '
          'event name or details. Case does not matter.',
          title: 'Search the log',
          example: 'error',
        ),
        suffixIconConstraints: const BoxConstraints(
          minWidth: 32,
          minHeight: 32,
        ),
      ),
      onChanged: (t) => setState(() => v.query = t),
    );
    final iconSize = isTouch(context) ? 22.0 : 19.0;
    final actions = Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        HelpHover(
          'Choose which kinds of entries to list: messages you sent, messages '
          'you received, and system notes such as connect, disconnect and '
          'errors.',
          title: 'Filter by direction',
          child: PopupMenuButton<Direction>(
            tooltip: '',
            icon: Icon(
              v.directions.length < 3
                  ? Icons.filter_alt
                  : Icons.filter_alt_outlined,
              size: iconSize,
              color: v.directions.length < 3 ? Palette.accent : Palette.textDim,
            ),
            onSelected: (d) => setState(() {
              final next = {...v.directions};
              if (!next.remove(d)) next.add(d);
              v.directions = next.isEmpty ? {...Direction.values} : next;
            }),
            itemBuilder: (_) => [
              for (final d in Direction.values)
                CheckedPopupMenuItem(
                  value: d,
                  checked: v.directions.contains(d),
                  child: Text(switch (d) {
                    Direction.sent => 'Sent',
                    Direction.received => 'Received',
                    Direction.system => 'System notes',
                  }),
                ),
            ],
          ),
        ),
        HelpHover(
          'Binary payloads are shown as hex bytes or as base64. Click to '
          'switch; copied binary messages use the same format.',
          title: v.binary == BinaryFormat.hex
              ? 'Binary as hex'
              : 'Binary as base64',
          example: v.binary == BinaryFormat.hex ? '48 65 6c 6c 6f' : 'SGVsbG8=',
          child: TextButton(
            onPressed: () => setState(
              () => v.binary = v.binary == BinaryFormat.hex
                  ? BinaryFormat.base64
                  : BinaryFormat.hex,
            ),
            style: TextButton.styleFrom(
              minimumSize: const Size(44, 36),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: Text(
              v.binary == BinaryFormat.hex ? 'HEX' : 'B64',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
        ),
        HelpHover(
          v.autoScroll
              ? 'The list follows new messages. It pauses when you scroll up '
                    'to read; click to follow again.'
              : 'The list stays where it is. Click to jump to the newest '
                    'message and follow new ones.',
          title: v.autoScroll ? 'Auto-scroll on' : 'Auto-scroll off',
          child: IconButton(
            iconSize: iconSize,
            icon: Icon(
              Icons.vertical_align_bottom,
              color: v.autoScroll ? Palette.accent : Palette.textDim,
            ),
            onPressed: () {
              setState(() => v.autoScroll = !v.autoScroll);
              if (v.autoScroll) {
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _toBottom(),
                );
              }
            },
          ),
        ),
        HelpHover(
          'Copy every message listed here (after the search and filter) as '
          'plain text, with time, direction and size.',
          title: 'Copy all',
          child: IconButton(
            iconSize: iconSize,
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: log.isEmpty
                ? null
                : () => _copy(
                    log.export(
                      v.binary,
                      only: log.filtered(
                        query: v.query,
                        directions: v.directions,
                      ),
                    ),
                    'Log',
                  ),
          ),
        ),
        HelpHover(
          'Remove every message from the log. The connection stays as it is.',
          title: 'Clear the log',
          child: IconButton(
            iconSize: iconSize,
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: log.isEmpty
                ? null
                : () => setState(() {
                    v.expanded.clear();
                    log.clear();
                  }),
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 4),
      child: LayoutBuilder(
        builder: (context, box) => box.maxWidth >= 520
            ? Row(
                children: [
                  Expanded(child: search),
                  const SizedBox(width: 4),
                  actions,
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [search, actions],
              ),
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    super.key,
    required this.entry,
    required this.format,
    required this.expanded,
    required this.onToggle,
    required this.onCopy,
  });

  final LogEntry entry;
  final BinaryFormat format;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onCopy;

  /// Longest text drawn when an entry is expanded; more is cut with a note.
  static const _maxChars = 20000;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final color = switch (e.direction) {
      Direction.sent => Palette.put,
      Direction.received => Palette.get_,
      Direction.system => e.isError ? Palette.delete : Palette.textDim,
    };
    final icon = switch (e.direction) {
      Direction.sent => Icons.arrow_upward,
      Direction.received => Icons.arrow_downward,
      Direction.system => e.isError ? Icons.error_outline : Icons.info_outline,
    };
    final help = switch (e.direction) {
      Direction.sent => 'A message this client sent to the server.',
      Direction.received => 'A message the server sent to this client.',
      Direction.system =>
        e.isError
            ? 'A problem with the connection.'
            : 'A note about the connection, not a message.',
    };
    final mono = TextStyle(
      fontFamily: 'monospace',
      fontSize: 12.5,
      height: 1.35,
      color: e.direction == Direction.system && !e.isError
          ? Palette.textDim
          : Palette.text,
    );
    final body = expanded ? e.body(format) : '';
    final cut = body.length > _maxChars;
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 5, 4, 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            HelpHover(
              help,
              title: switch (e.direction) {
                Direction.sent => 'Sent',
                Direction.received => 'Received',
                Direction.system => e.isError ? 'Error' : 'System',
              },
              child: Padding(
                padding: const EdgeInsets.only(top: 2, right: 8),
                child: Icon(icon, size: 16, color: color),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        formatClock(e.time),
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11.5,
                          color: Palette.textDim,
                        ),
                      ),
                      if (e.label.isNotEmpty && e.direction != Direction.system)
                        _Chip(e.label, color),
                      if (e.title != null && e.title!.isNotEmpty)
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.sizeOf(context).width - 120,
                          ),
                          child: Text(
                            e.title!,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      for (final m in e.meta.entries)
                        _Chip('${m.key} ${m.value}', Palette.textDim),
                      if (e.direction != Direction.system)
                        Text(
                          formatSize(e.size),
                          style: TextStyle(
                            fontSize: 11.5,
                            color: Palette.textDim,
                          ),
                        ),
                    ],
                  ),
                  if (expanded)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, right: 8),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Palette.surfaceAlt,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: SelectableText(
                          cut
                              ? '${body.substring(0, _maxChars)}\n'
                                    '… ${body.length - _maxChars} more '
                                    'characters. Copy the message for all of it.'
                              : body,
                          style: mono,
                        ),
                      ),
                    )
                  else if (e.text.isNotEmpty || e.isBinary)
                    Padding(
                      padding: const EdgeInsets.only(top: 1, right: 8),
                      child: Text(
                        e.preview(format),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: mono,
                      ),
                    ),
                ],
              ),
            ),
            HelpHover(
              'Copy this message\'s payload to the clipboard.',
              title: 'Copy message',
              child: IconButton(
                iconSize: 17,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy_outlined),
                onPressed: onCopy,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.text, this.color);

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
    ),
  );
}
