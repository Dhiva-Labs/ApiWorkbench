import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/console_events.dart';
import '../services/doc_export.dart' show maskSecrets;
import '../state/app_state.dart';
import '../state/console_log.dart';
import '../theme.dart';
import 'help_tip.dart';

/// Below this width the console uses the two-line phone layout.
const _compactWidth = 560.0;

/// Longest body cut shown at first; "Show more" reveals up to
/// [_bodyShowLimit].
const _bodyPreviewChars = 6000;
const _bodyShowLimit = 100000;

/// Copying everything cuts each body to this many characters, so a
/// thousand entries can't produce a clipboard of hundreds of megabytes.
const _copyAllBodyChars = 8000;

TextStyle get _mono => TextStyle(
  fontFamily: 'monospace',
  fontSize: 12,
  height: 1.35,
  color: Palette.text,
);

Color _levelColor(ConsoleLevel l) => switch (l) {
  ConsoleLevel.log => Palette.text,
  ConsoleLevel.info => Palette.put,
  ConsoleLevel.warn => Palette.warning,
  ConsoleLevel.error => Palette.danger,
  ConsoleLevel.debug => Palette.textDim,
};

/// Network exchanges and script output, newest last, like the Postman
/// Console. Rows are one line each (two on phones); tapping one opens its
/// headers and bodies. Filters, search, copy and clear sit in the toolbar.
class ConsolePanel extends StatefulWidget {
  const ConsolePanel({super.key, this.onClose});

  /// Shows a close button (and the title) when the panel is docked; the
  /// phone page has an app bar for both.
  final VoidCallback? onClose;

  @override
  State<ConsolePanel> createState() => _ConsolePanelState();
}

class _ConsolePanelState extends State<ConsolePanel> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;

  ConsoleFilter _filter = ConsoleFilter.all;
  String _query = '';

  /// Keep the newest entry in view. Scrolling away from the bottom turns it
  /// off; reaching the bottom again, or "Latest", turns it back on.
  bool _follow = true;
  bool _jumping = false;
  int _stickFrames = 0;

  final Set<int> _expanded = {};

  // The filtered list is rebuilt only when its inputs change.
  List<ConsoleEntry> _view = const [];
  Object? _viewKey;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _queryChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _query = text);
    });
  }

  /// Entries for the current filter and search, recomputed only when the
  /// log, filter, search or secrets changed.
  List<ConsoleEntry> _visible(
    ConsoleLog log,
    Set<String> secrets,
    int secretsKey,
  ) {
    final key = Object.hash(log.version, _filter, _query, secretsKey);
    if (_viewKey != key) {
      _viewKey = key;
      _view = log.view(filter: _filter, query: _query, secrets: secrets);
      if (_follow) _stick();
    }
    return _view;
  }

  // -- Scrolling -------------------------------------------------------------

  /// Moves to the end once the new rows are laid out. Rows have varying
  /// heights, so the first jump may land short: try a few frames.
  void _stick() {
    _stickFrames = 4;
    WidgetsBinding.instance.addPostFrameCallback(_stickStep);
  }

  void _stickStep(Duration _) {
    if (!mounted || !_follow || !_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    if ((max - _scroll.offset).abs() < 1) return;
    _jumping = true;
    _scroll.jumpTo(max);
    _jumping = false;
    if (--_stickFrames > 0) {
      WidgetsBinding.instance.addPostFrameCallback(_stickStep);
    }
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0 || _jumping) return false;
    final atBottom = n.metrics.extentAfter < 32;
    if (atBottom != _follow) {
      _follow = atBottom;
      // Notifications can arrive during layout: rebuild afterwards.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
    return false;
  }

  void _jumpToLatest() {
    setState(() => _follow = true);
    _stick();
  }

  // -- Actions ---------------------------------------------------------------

  void _toast(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
  );

  Future<void> _copy(String text, String done) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) _toast(done);
  }

  void _clear(ConsoleLog log) {
    _expanded.clear();
    log.clear();
  }

  // -- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    // Rebuild when a variable becomes secret (or stops being one), so a new
    // secret is hidden from rows already on screen.
    final secretsKey = context.select<AppState, int>(
      (s) => Object.hashAllUnordered(s.secretValues),
    );
    final secrets = app.secretValues;
    final log = app.console;
    return ListenableBuilder(
      listenable: log,
      builder: (context, _) => LayoutBuilder(
        builder: (context, box) => _content(log, secrets, secretsKey, box),
      ),
    );
  }

  Widget _content(
    ConsoleLog log,
    Set<String> secrets,
    int secretsKey,
    BoxConstraints box,
  ) {
    final view = _visible(log, secrets, secretsKey);
    final compact = box.maxWidth < _compactWidth;
    final active = {
      for (final s in secrets)
        if (s.length >= 4) s,
    };
    String mask(String s) => active.isEmpty ? s : maskSecrets(s, active);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(log, view, secrets, box.maxWidth),
        _statusLine(log, view.length),
        Divider(height: 1, color: Palette.border),
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (view.isEmpty)
                _empty(log)
              else
                NotificationListener<ScrollNotification>(
                  onNotification: _onScroll,
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.only(bottom: 56),
                    itemCount: view.length,
                    itemBuilder: (context, i) {
                      final e = view[i];
                      final open = _expanded.contains(e.seq);
                      void toggle() => setState(() {
                        if (!_expanded.remove(e.seq)) _expanded.add(e.seq);
                      });
                      return switch (e) {
                        ExchangeEntry() => _ExchangeTile(
                          key: ValueKey(e.seq),
                          entry: e,
                          expanded: open,
                          compact: compact,
                          mask: mask,
                          onTap: toggle,
                          onCopy: () => _copy(
                            consoleEntryText(e, secrets: secrets),
                            'Copied the request.',
                          ),
                        ),
                        LineEntry() => _LineTile(
                          key: ValueKey(e.seq),
                          entry: e,
                          expanded: open,
                          compact: compact,
                          mask: mask,
                          onTap: toggle,
                          onCopy: () => _copy(
                            consoleEntryText(e, secrets: secrets),
                            'Copied the line.',
                          ),
                        ),
                      };
                    },
                  ),
                ),
              if (!_follow && view.isNotEmpty)
                Positioned(
                  right: 14,
                  bottom: 12,
                  child: HelpHover(
                    'Scroll to the newest entry and keep following new ones.',
                    title: 'Jump to latest',
                    child: FilledButton.icon(
                      key: const Key('console-jump'),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        elevation: 2,
                      ),
                      onPressed: _jumpToLatest,
                      icon: const Icon(Icons.arrow_downward, size: 16),
                      label: const Text('Latest'),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _empty(ConsoleLog log) {
    final none = log.entries.isEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          none
              ? 'Nothing yet. Requests, responses and console.log output '
                    'from scripts appear here.'
              : 'No entries match the filter or search.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Palette.textDim, fontSize: 12.5),
        ),
      ),
    );
  }

  Widget _statusLine(ConsoleLog log, int shown) {
    final total = log.entries.length;
    final parts = <String>[
      if (shown != total) 'Showing $shown of $total',
      if (log.dropped > 0)
        '${log.dropped} older '
            '${log.dropped == 1 ? 'entry was' : 'entries were'} dropped '
            '(the console keeps the latest ${log.capacity})',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Text(
        parts.join(' · '),
        style: TextStyle(fontSize: 11.5, color: Palette.textDim),
      ),
    );
  }

  // -- Toolbar ---------------------------------------------------------------

  Widget _toolbar(
    ConsoleLog log,
    List<ConsoleEntry> view,
    Set<String> secrets,
    double width,
  ) {
    final counts = log.counts();
    final showTitle = widget.onClose != null && width >= 420;

    Widget chip(ConsoleFilter f, int n, String help) => Padding(
      padding: const EdgeInsets.only(right: 6),
      child: HelpHover(
        help,
        title: f.label,
        child: ChoiceChip(
          key: Key('console-filter-${f.name}'),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.symmetric(horizontal: 2),
          label: Text('${f.label} $n', style: const TextStyle(fontSize: 12)),
          selected: _filter == f,
          showCheckmark: false,
          onSelected: (_) => setState(() => _filter = f),
        ),
      ),
    );

    final chips = [
      chip(ConsoleFilter.all, counts.all, 'Every entry.'),
      chip(
        ConsoleFilter.network,
        counts.network,
        'Only requests and responses, redirect hops included.',
      ),
      chip(
        ConsoleFilter.logs,
        counts.logs,
        'Only lines from console.log and other script output.',
      ),
      chip(
        ConsoleFilter.errors,
        counts.errors,
        'Failed requests (no response, or status 400 and up) and error '
        'lines.',
      ),
    ];

    final searchField = HelpHover(
      'Finds entries by method, URL, status, headers, the start of each '
      'body, or log text. Secret values stay hidden in the results.',
      title: 'Search the console',
      example: '401   or   /users',
      child: SizedBox(
        height: 36,
        child: TextField(
          key: const Key('console-search'),
          controller: _search,
          onChanged: _queryChanged,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Search',
            prefixIcon: const Icon(Icons.search, size: 18),
            prefixIconConstraints: const BoxConstraints(minWidth: 34),
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32),
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () {
                      _debounce?.cancel();
                      _search.clear();
                      setState(() => _query = '');
                    },
                  ),
          ),
        ),
      ),
    );

    Widget action(
      Key key,
      IconData icon,
      String title,
      String help,
      VoidCallback? onTap, {
      bool selected = false,
    }) => HelpHover(
      help,
      title: title,
      essential: true,
      child: IconButton(
        key: key,
        visualDensity: VisualDensity.compact,
        iconSize: 20,
        isSelected: selected,
        color: Palette.textDim,
        selectedIcon: Icon(icon, color: Palette.accent),
        icon: Icon(icon),
        onPressed: onTap,
      ),
    );

    final actions = [
      action(
        const Key('console-follow'),
        Icons.vertical_align_bottom,
        'Auto-scroll',
        'Keep the newest entry in view as new ones arrive. Scrolling up '
            'pauses it; the Latest button resumes it.',
        () {
          if (_follow) {
            setState(() => _follow = false);
          } else {
            _jumpToLatest();
          }
        },
        selected: _follow,
      ),
      action(
        const Key('console-copy-all'),
        Icons.copy_all_outlined,
        'Copy all',
        'Copy the ${view.length} entries shown as text, with each body cut '
            'to $_copyAllBodyChars characters. Secret values are masked.',
        view.isEmpty
            ? null
            : () => _copy(
                consoleText(
                  view,
                  secrets: secrets,
                  bodyLimit: _copyAllBodyChars,
                ),
                'Copied ${view.length} '
                '${view.length == 1 ? 'entry' : 'entries'}.',
              ),
      ),
      action(
        const Key('console-clear'),
        Icons.delete_sweep_outlined,
        'Clear',
        'Remove every entry from the console.',
        log.entries.isEmpty ? null : () => _clear(log),
      ),
      if (widget.onClose != null)
        action(
          const Key('console-close'),
          Icons.close,
          'Close console',
          'Hide the console. Entries are kept until you clear them.',
          widget.onClose,
        ),
    ];

    final title = LabelWithHelp(
      'Console',
      'Every request and response on the wire, redirect hops included, plus '
          'console.log output from scripts. Newest last. Click a row for '
          'its headers and bodies.',
      style: TextStyle(
        fontWeight: FontWeight.w700,
        fontSize: 12.5,
        color: Palette.textDim,
      ),
    );

    if (width >= 760) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(
          children: [
            if (showTitle) ...[title, const SizedBox(width: 12)],
            ...chips,
            const SizedBox(width: 6),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: searchField,
              ),
            ),
            const Spacer(),
            ...actions,
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (showTitle) ...[title, const SizedBox(width: 10)],
              Expanded(child: searchField),
              const SizedBox(width: 4),
              ...actions,
            ],
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: chips),
          ),
        ],
      ),
    );
  }
}

/// The console on its own page (phones).
Future<void> showConsolePage(BuildContext context) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Console')),
          body: const ConsolePanel(),
        ),
      ),
    );

// ---------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------

BoxDecoration _rowDecoration({Color? tint}) => BoxDecoration(
  color: tint,
  border: Border(
    bottom: BorderSide(color: Palette.border.withValues(alpha: 0.6)),
  ),
);

/// One request/response pair. Collapsed it costs a few text widgets; the
/// headers and bodies are decoded only once it is opened.
class _ExchangeTile extends StatelessWidget {
  const _ExchangeTile({
    super.key,
    required this.entry,
    required this.expanded,
    required this.compact,
    required this.mask,
    required this.onTap,
    required this.onCopy,
  });

  final ExchangeEntry entry;
  final bool expanded;
  final bool compact;
  final String Function(String) mask;
  final VoidCallback onTap;
  final VoidCallback onCopy;

  ExchangeRecord get r => entry.record;

  Color get _statusColor =>
      r.error != null || r.status == 0 ? Palette.danger : statusColor(r.status);

  String get _statusText {
    if (r.error != null) return 'Error';
    if (r.status == 0) return 'No response';
    return r.statusMessage.isEmpty
        ? '${r.status}'
        : '${r.status} ${r.statusMessage}';
  }

  @override
  Widget build(BuildContext context) {
    final indent = 12.0 + 16.0 * r.hop.clamp(0, 4);
    final method = HelpHover(
      r.hop > 0
          ? '${httpMethodHelp(r.method).message} This is hop ${r.hop}: a '
                'redirect or an authentication retry of the request above.'
          : httpMethodHelp(r.method).message,
      title: httpMethodHelp(r.method).title,
      child: Text(
        r.method,
        maxLines: 1,
        style: _mono.copyWith(
          fontWeight: FontWeight.w700,
          color: methodColor(r.method),
        ),
      ),
    );
    final statusHelp = r.error != null
        ? (title: 'Request failed', message: mask(r.error!))
        : httpStatusHelp(r.status);
    final status = HelpHover(
      statusHelp.message,
      title: statusHelp.title,
      child: Text(
        _statusText,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: _statusColor,
        ),
      ),
    );
    final dim = TextStyle(fontSize: 11.5, color: Palette.textDim);
    final chevron = Icon(
      expanded ? Icons.expand_more : Icons.chevron_right,
      size: 16,
      color: Palette.textDim,
    );
    final hopIcon = r.hop > 0
        ? Padding(
            padding: const EdgeInsets.only(right: 2),
            child: Icon(
              Icons.subdirectory_arrow_right,
              size: 14,
              color: Palette.textDim,
            ),
          )
        : null;

    final Widget summary;
    if (compact) {
      summary = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ?hopIcon,
              chevron,
              const SizedBox(width: 4),
              method,
              const SizedBox(width: 10),
              Flexible(child: status),
              const Spacer(),
              Text(
                '${formatDuration(r.durationMs)} · ${formatSize(r.responseSize)}',
                style: dim,
              ),
            ],
          ),
          Padding(
            padding: EdgeInsets.only(left: hopIcon == null ? 20 : 36, top: 2),
            child: Text(
              mask(r.url.toString()),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: _mono.copyWith(fontSize: 11.5),
            ),
          ),
          Padding(
            padding: EdgeInsets.only(left: hopIcon == null ? 20 : 36, top: 1),
            child: Text(
              '${formatClock(r.at)} · ${r.source}'
              '${r.hop > 0 ? ' · hop ${r.hop}' : ''}',
              style: dim,
            ),
          ),
        ],
      );
    } else {
      summary = Row(
        children: [
          ?hopIcon,
          chevron,
          const SizedBox(width: 6),
          SizedBox(width: 62, child: Text(formatClock(r.at), style: dim)),
          SizedBox(width: 56, child: method),
          Expanded(
            child: Text(
              mask(r.url.toString()),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _mono,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(width: 92, child: status),
          SizedBox(
            width: 64,
            child: Text(
              formatDuration(r.durationMs),
              textAlign: TextAlign.right,
              style: dim,
            ),
          ),
          SizedBox(
            width: 68,
            child: Text(
              formatSize(r.responseSize),
              textAlign: TextAlign.right,
              style: dim,
            ),
          ),
          SizedBox(
            width: 70,
            child: Padding(
              padding: const EdgeInsets.only(left: 10),
              child: Text(
                r.source,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: dim,
              ),
            ),
          ),
        ],
      );
    }

    return DecoratedBox(
      decoration: _rowDecoration(
        tint: entry.isError ? Palette.danger.withValues(alpha: 0.06) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.fromLTRB(indent, 6, 10, 6),
              child: summary,
            ),
          ),
          if (expanded)
            _ExchangeDetails(
              record: r,
              mask: mask,
              indent: indent,
              onCopy: onCopy,
            ),
        ],
      ),
    );
  }
}

/// The opened part of an exchange row. Decodes and pretty-prints the bodies
/// once, not on every rebuild.
class _ExchangeDetails extends StatefulWidget {
  const _ExchangeDetails({
    required this.record,
    required this.mask,
    required this.indent,
    required this.onCopy,
  });

  final ExchangeRecord record;
  final String Function(String) mask;
  final double indent;
  final VoidCallback onCopy;

  @override
  State<_ExchangeDetails> createState() => _ExchangeDetailsState();
}

class _ExchangeDetailsState extends State<_ExchangeDetails> {
  late final BodyView _req = describeBody(
    widget.record.requestBody,
    truncated: widget.record.requestBodyTruncated,
  );
  late final BodyView _res = describeBody(
    widget.record.responseBody,
    truncated: widget.record.responseBodyTruncated,
  );

  @override
  Widget build(BuildContext context) {
    final r = widget.record;
    final mask = widget.mask;
    final reqHeaders = [for (final h in r.requestHeaders) (h.key, h.value)];
    final resHeaders = [
      for (final h in r.responseHeaders.entries)
        for (final v in h.value) (h.key, v),
    ];
    final end = r.at.add(Duration(milliseconds: r.durationMs));

    return Padding(
      padding: EdgeInsets.fromLTRB(widget.indent + 20, 0, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: HelpHover(
              'Copy this request and response as text, with every header and '
              'body. Secret values are masked.',
              title: 'Copy request',
              child: TextButton.icon(
                key: const Key('console-copy-entry'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: widget.onCopy,
                icon: const Icon(Icons.copy_outlined, size: 16),
                label: const Text('Copy'),
              ),
            ),
          ),
          if (r.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: SelectableText(
                mask(r.error!),
                style: TextStyle(fontSize: 12.5, color: Palette.danger),
              ),
            ),
          _Section(
            'Network',
            child: Column(
              children: [
                _KV('URL', mask(r.url.toString()), mono: true),
                _KV(
                  'Status',
                  r.error != null
                      ? 'Failed'
                      : r.status == 0
                      ? 'No response'
                      : '${r.status} ${r.statusMessage}'.trim(),
                  color: r.error != null || r.status == 0
                      ? Palette.danger
                      : statusColor(r.status),
                ),
                _KV('Protocol', protocolLabel(r.protocol)),
                _KV(
                  'Hop',
                  r.hop == 0
                      ? '0 (the request as sent)'
                      : '${r.hop} (a redirect or retry that followed hop '
                            '${r.hop - 1})',
                ),
                _KV('Source', r.source),
                _KV('Started', formatClock(r.at, millis: true)),
                _KV(
                  'Time',
                  '${formatDuration(r.durationMs)}, finished '
                      '${formatClock(end, millis: true)}',
                ),
                _KV('Response size', formatSize(r.responseSize)),
              ],
            ),
          ),
          _Section(
            'Request headers (${reqHeaders.length})',
            child: _Headers(reqHeaders, mask: mask),
          ),
          _Section(
            'Request body',
            child: _Body(
              view: _req,
              mask: mask,
              note: r.requestBodyTruncated
                  ? truncationNote('Request body', 0)
                  : null,
              emptyText: 'No request body.',
            ),
          ),
          _Section(
            'Response headers (${resHeaders.length})',
            child: _Headers(resHeaders, mask: mask),
          ),
          _Section(
            'Response body',
            child: _Body(
              view: _res,
              mask: mask,
              note: r.responseBodyTruncated
                  ? truncationNote('Response body', r.responseSize)
                  : null,
              emptyText: r.error != null
                  ? 'No response.'
                  : 'The response had no body.',
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, {required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Palette.textDim,
            ),
          ),
        ),
        child,
      ],
    ),
  );
}

class _KV extends StatelessWidget {
  const _KV(this.label, this.value, {this.mono = false, this.color});

  final String label;
  final String value;
  final bool mono;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1.5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: Palette.textDim),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: (mono ? _mono : const TextStyle(fontSize: 12.5)).copyWith(
              color: color ?? Palette.text,
            ),
          ),
        ),
      ],
    ),
  );
}

class _CodeBox extends StatelessWidget {
  const _CodeBox({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: Palette.surfaceAlt,
      border: Border.all(color: Palette.border),
      borderRadius: BorderRadius.circular(6),
    ),
    child: child,
  );
}

class _Headers extends StatelessWidget {
  const _Headers(this.headers, {required this.mask});

  final List<(String, String)> headers;
  final String Function(String) mask;

  @override
  Widget build(BuildContext context) {
    if (headers.isEmpty) {
      return Text(
        'None.',
        style: TextStyle(fontSize: 12, color: Palette.textDim),
      );
    }
    return _CodeBox(
      child: SelectableText.rich(
        TextSpan(
          style: _mono,
          children: [
            for (final (name, value) in headers) ...[
              TextSpan(
                text: name,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Palette.accent,
                ),
              ),
              TextSpan(text: ': ${mask(value)}\n'),
            ],
          ],
        ),
      ),
    );
  }
}

/// A body, cut to [_bodyPreviewChars] until "Show more" is pressed, because
/// laying out hundreds of KB of text in a list row would stall scrolling.
class _Body extends StatefulWidget {
  const _Body({
    required this.view,
    required this.mask,
    required this.emptyText,
    this.note,
  });

  final BodyView view;
  final String Function(String) mask;
  final String emptyText;
  final String? note;

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final v = widget.view;
    if (v.text.isEmpty) {
      return Text(
        widget.emptyText,
        style: TextStyle(fontSize: 12, color: Palette.textDim),
      );
    }
    final limit = _all ? _bodyShowLimit : _bodyPreviewChars;
    final cut = v.text.length > limit;
    final shown = cut ? v.text.substring(0, limit) : v.text;
    final dim = TextStyle(fontSize: 11.5, color: Palette.textDim);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CodeBox(
          child: SelectableText(
            widget.mask(shown),
            style: v.binary ? _mono.copyWith(color: Palette.textDim) : _mono,
          ),
        ),
        if (cut)
          Align(
            alignment: Alignment.centerLeft,
            child: _all
                ? Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Showing the first $_bodyShowLimit characters. Copy the '
                      'entry to get all of it.',
                      style: dim,
                    ),
                  )
                : HelpHover(
                    'Shows up to $_bodyShowLimit characters. Long text is '
                    'cut at first because it would slow down scrolling.',
                    title: 'Show more',
                    child: TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () => setState(() => _all = true),
                      child: Text(
                        'Show more (${v.text.length - limit} more characters)',
                      ),
                    ),
                  ),
          ),
        if (widget.note != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              widget.note!,
              style: dim.copyWith(color: Palette.warning),
            ),
          ),
      ],
    );
  }
}

/// A line of script output or a notice, coloured by level.
class _LineTile extends StatelessWidget {
  const _LineTile({
    super.key,
    required this.entry,
    required this.expanded,
    required this.compact,
    required this.mask,
    required this.onTap,
    required this.onCopy,
  });

  final LineEntry entry;
  final bool expanded;
  final bool compact;
  final String Function(String) mask;
  final VoidCallback onTap;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final l = entry.line;
    final color = _levelColor(l.level);
    final tint = switch (l.level) {
      ConsoleLevel.error => Palette.danger.withValues(alpha: 0.07),
      ConsoleLevel.warn => Palette.warning.withValues(alpha: 0.07),
      _ => null,
    };
    final dim = TextStyle(fontSize: 11.5, color: Palette.textDim);
    final text = mask(l.message);
    return DecoratedBox(
      decoration: _rowDecoration(tint: tint),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 10, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                expanded ? Icons.expand_more : Icons.chevron_right,
                size: 16,
                color: Palette.textDim,
              ),
              const SizedBox(width: 6),
              if (!compact)
                SizedBox(width: 62, child: Text(formatClock(l.at), style: dim)),
              SizedBox(
                width: 44,
                child: Text(
                  l.level.name.toUpperCase(),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    expanded
                        ? SelectableText(
                            text,
                            style: _mono.copyWith(color: color),
                          )
                        : Text(
                            text,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: _mono.copyWith(color: color),
                          ),
                    if (compact || l.source.isNotEmpty)
                      Text(
                        [
                          if (compact) formatClock(l.at),
                          if (l.source.isNotEmpty) mask(l.source),
                        ].join(' · '),
                        style: dim,
                      ),
                    if (expanded)
                      HelpHover(
                        'Copy this line as text, with its time and source.',
                        title: 'Copy line',
                        child: TextButton.icon(
                          key: const Key('console-copy-entry'),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: onCopy,
                          icon: const Icon(Icons.copy_outlined, size: 16),
                          label: const Text('Copy'),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
