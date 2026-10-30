import 'dart:convert';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/doc_export.dart';
import '../services/scripting/script_engine.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'app_menu.dart';
import 'examples/examples_ui.dart';
import 'help_tip.dart';
import 'json_view.dart';
import 'response/body_text.dart';
import 'response/body_tools.dart';
import 'response/cookies_tab.dart';
import 'response/find.dart';
import 'response/full_body.dart';
import 'response/preview_tab.dart';
import 'response/visualize_tab.dart';
import 'tab_memory.dart';

/// Which response tab (Pretty, Raw, Headers, Tests) each request tab shows,
/// kept across new responses and across Request/Response on phones.
final _selectedTab = Expando<int>('response tab');

class ResponseView extends StatefulWidget {
  /// Captures what [tab] shows right now. When a new response arrives the
  /// outgoing view keeps showing the old one while it fades out, instead of
  /// flipping to the new state halfway through the transition.
  ///
  /// The state this widget keeps (the find bar, the full body) belongs to
  /// one response: a new response gets a new key and starts fresh.
  ResponseView({super.key, required this.tab})
    : response = tab.response,
      loading = tab.loading,
      results = tab.assertionResults,
      scriptTests = tab.scriptTests,
      scriptError = tab.scriptError,
      visualizer = tab.visualizer;

  final RequestTab tab;
  final ResponseData? response;
  final bool loading;
  final List<AssertionResult> results;
  final List<ScriptTestResult> scriptTests;
  final String? scriptError;
  final VisualizerOutput? visualizer;

  @override
  State<ResponseView> createState() => _ResponseViewState();
}

/// Bumped by the window-wide Ctrl+F so the visible response opens its find
/// bar wherever the focus is.
final responseFindRequests = ValueNotifier<int>(0);

class _ResponseViewState extends State<ResponseView> {
  RequestTab get tab => widget.tab;
  ResponseData? get response => widget.response;
  bool get loading => widget.loading;
  List<AssertionResult> get results => widget.results;
  List<ScriptTestResult> get scriptTests => widget.scriptTests;
  String? get scriptError => widget.scriptError;
  VisualizerOutput? get visualizer => widget.visualizer;

  final _find = FindController();
  final _paneFocus = FocusNode(
    debugLabel: 'response pane',
    skipTraversal: true,
  );

  /// The response tab bar's controller, set once the tabs exist.
  TabController? _tabs;

  /// The whole body, decoded for the Pretty and Raw tabs on request.
  FullBodyData? _full;
  bool _loadingFull = false;
  bool _showFull = false;

  @override
  void initState() {
    super.initState();
    responseFindRequests.addListener(_openFind);
  }

  @override
  void dispose() {
    responseFindRequests.removeListener(_openFind);
    _find.dispose();
    _paneFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(height: 14),
            Text('Sending request…', style: TextStyle(color: Palette.textDim)),
          ],
        ),
      );
    }
    final res = response;
    if (res == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bolt_outlined, size: 42, color: Palette.border),
            SizedBox(height: 10),
            Text(
              'Hit Send to see the response here',
              style: TextStyle(color: Palette.textDim),
            ),
          ],
        ),
      );
    }
    if (res.error != null) {
      return Center(
        child: Container(
          margin: const EdgeInsets.all(24),
          padding: const EdgeInsets.all(20),
          constraints: const BoxConstraints(maxWidth: 560),
          decoration: BoxDecoration(
            color: Palette.delete.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Palette.delete.withValues(alpha: 0.4)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: Palette.delete, size: 30),
              const SizedBox(height: 10),
              SelectableText(
                res.error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Palette.text, height: 1.4),
              ),
            ],
          ),
        ),
      );
    }
    final tests = results;
    final testCount = tests.length + scriptTests.length;
    final testsPassed =
        tests.where((t) => t.pass).length +
        scriptTests.where((t) => t.pass).length;
    final testsOk = testsPassed == testCount && scriptError == null;
    final tabCount = visualizer == null ? 6 : 7;
    return DefaultTabController(
      length: tabCount,
      initialIndex: TabMemory.initialIndex(_selectedTab, tab, tabCount),
      child: TabMemory(
        owner: tab,
        memory: _selectedTab,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyF, control: true):
                _openFind,
            const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
                _openFind,
          },
          child: Focus(
            focusNode: _paneFocus,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _statusBar(context, res),
                TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  labelStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  tabs: [
                    const HelpHover(
                      'The body laid out for reading, with JSON indented and '
                      'colour-coded.',
                      title: 'Pretty view',
                      child: Tab(text: 'Pretty'),
                    ),
                    const HelpHover(
                      'The body exactly as the server sent it, as plain text. Use '
                      'it for HTML, XML or anything that is not JSON.',
                      title: 'Raw view',
                      child: Tab(text: 'Raw'),
                    ),
                    const HelpHover(
                      'The body rendered: HTML pages, images, SVG and PDF files. '
                      'Other binary data shows as bytes.',
                      title: 'Preview',
                      child: Tab(text: 'Preview'),
                    ),
                    HelpHover(
                      'Extra information the server sent with the response, such as '
                      'the body format and caching rules.',
                      title: 'Response headers',
                      example: 'Content-Type: application/json',
                      child: Tab(text: 'Headers (${res.headers.length})'),
                    ),
                    const HelpHover(
                      'Cookies this response set, and what the cookie jar holds '
                      'for its address.',
                      title: 'Cookies',
                      example: 'session=abc123; HttpOnly',
                      child: Tab(text: 'Cookies'),
                    ),
                    HelpHover(
                      'Results of the request\'s Tests tab and of pm.test calls in '
                      'its scripts, run on this response. Shown as passed out of '
                      'total.',
                      title: 'Test results',
                      example: 'Tests (3/4)',
                      child: Tab(
                        child: testCount == 0 && scriptError == null
                            ? const Text('Tests')
                            : Text(
                                'Tests ($testsPassed/$testCount)',
                                style: TextStyle(
                                  color: testsOk
                                      ? Palette.get_
                                      : Palette.delete,
                                ),
                              ),
                      ),
                    ),
                    if (visualizer != null)
                      const HelpHover(
                        'The view the test script built with pm.visualizer.set.',
                        title: 'Visualize',
                        child: Tab(text: 'Visualize'),
                      ),
                  ],
                ),
                _FindBarHost(
                  find: _find,
                  onController: (c) => _tabs = c,
                  onIndex: (_) {
                    if (_find.isOpen) _syncFindText();
                  },
                  onClose: _closeFind,
                ),
                Expanded(
                  // A mouse click anywhere in the body gives the pane keyboard
                  // focus, so Ctrl+F works after clicking on a header or a tab.
                  child: Listener(
                    onPointerDown: (e) {
                      if (e.kind == PointerDeviceKind.mouse &&
                          !_paneFocus.hasFocus) {
                        _paneFocus.requestFocus();
                      }
                    },
                    child: TabBarView(
                      children: [
                        _bodyPage(res, pretty: true),
                        _bodyPage(res, pretty: false),
                        ResponsePreview(response: res, request: tab.request),
                        _headersTable(res),
                        ResponseCookies(response: res),
                        _testsList(tests),
                        if (visualizer != null)
                          VisualizeView(output: visualizer!),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _testsList(List<AssertionResult> tests) {
    if (scriptTests.isNotEmpty || scriptError != null) {
      return ListView(
        padding: const EdgeInsets.all(14),
        children: [
          if (scriptError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SelectableText(
                'Test script failed: $scriptError',
                style: TextStyle(color: Palette.delete, fontSize: 12.5),
              ),
            ),
          for (final t in scriptTests)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    t.pass ? Icons.check_circle : Icons.cancel,
                    size: 17,
                    color: t.pass ? Palette.get_ : Palette.delete,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.name,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (t.error != null)
                          Text(
                            t.error!,
                            style: TextStyle(
                              fontSize: 12,
                              color: Palette.delete,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          if (tests.isNotEmpty)
            SizedBox(height: 360, child: _assertionList(tests)),
        ],
      );
    }
    return _assertionList(tests);
  }

  Widget _assertionList(List<AssertionResult> tests) {
    if (tests.isEmpty) {
      return Center(
        child: Text(
          'No tests defined.\nAdd them in the request\'s Tests tab.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Palette.textDim, fontSize: 12.5),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(14),
      itemCount: tests.length,
      itemBuilder: (_, i) {
        final t = tests[i];
        final color = t.pass ? Palette.get_ : Palette.delete;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              HelpHover(
                t.pass
                    ? 'This check passed on this response.'
                    : 'This check failed. The line below says what came back '
                          'instead.',
                title: t.pass ? 'Passed' : 'Failed',
                child: Icon(
                  t.pass ? Icons.check_circle : Icons.cancel,
                  size: 17,
                  color: color,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${t.assertion.kind.label}'
                      '${t.assertion.kind.hasTarget ? ' • ${t.assertion.target}' : ''}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      t.message,
                      style: TextStyle(fontSize: 12, color: color),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // --- Pretty and Raw ------------------------------------------------------

  /// The Pretty or Raw tab: the 64 KB preview (or, once asked for, the full
  /// body), under a note when the preview is cut short.
  Widget _bodyPage(ResponseData res, {required bool pretty}) {
    final full = _showFull ? _full : null;
    final Widget body;
    if (full != null) {
      final rows = pretty ? (full.pretty ?? full.raw) : full.raw;
      body = LargeTextView(
        key: ValueKey(pretty ? 'full-pretty' : 'full-raw'),
        index: rows,
        find: _find,
        colourJson: pretty && full.pretty != null,
      );
    } else {
      final preview = res.bodyPreview;
      if (pretty) {
        body = FindScroll(
          find: _find,
          text: JsonView.displayText(preview),
          child: JsonView(text: preview, find: _find),
        );
      } else {
        body = FindScroll(
          find: _find,
          text: preview,
          child: preview.isEmpty
              ? SelectableText('(empty body)', style: bodyMono)
              : FindableText(text: preview, find: _find),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (res.previewTruncated) _truncationNote(res),
        Expanded(child: body),
      ],
    );
  }

  /// "Preview limited to 64 KB of 2 MB" with the button that shows it all.
  Widget _truncationNote(ResponseData res) {
    final size = formatByteSize(res.sizeBytes);
    final big = res.sizeBytes > fullBodyWarnBytes;
    final full = _showFull ? _full : null;
    final String message;
    if (_loadingFull) {
      message = 'Preparing the full body…';
    } else if (full == null) {
      message =
          'Preview limited to ${formatByteSize(ResponseData.previewByteLimit)} '
          'of $size.${big ? ' Showing all of it can be slow.' : ''}';
    } else if (full.cut) {
      message =
          'Showing the first ${formatByteSize(full.shownBytes)} of $size. '
          'Save the response to a file for the rest.';
    } else {
      message = 'Showing the full body ($size).';
    }
    final Widget action;
    if (_loadingFull) {
      action = const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (full == null) {
      action = HelpHover(
        'Shows the whole response in Pretty and Raw, for this response '
        'only. Bodies over 5 MB are slow to show and ask first; Save writes '
        'the whole body to a file instead.',
        title: 'Show full body',
        child: TextButton.icon(
          style: _noteButtonStyle,
          onPressed: () => _showFullBody(res),
          icon: const Icon(Icons.unfold_more, size: 16),
          label: const Text('Show full body'),
        ),
      );
    } else {
      action = HelpHover(
        'Go back to the first 64 KB, which is quick to draw and select.',
        title: 'Back to preview',
        child: TextButton.icon(
          style: _noteButtonStyle,
          onPressed: _hideFullBody,
          icon: const Icon(Icons.unfold_less, size: 16),
          label: const Text('Back to preview'),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 4, 8, 4),
      decoration: BoxDecoration(
        color: Palette.surfaceAlt,
        border: Border(bottom: BorderSide(color: Palette.border)),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 0,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Icon(
            big && full == null
                ? Icons.warning_amber_rounded
                : Icons.info_outline,
            size: 16,
            color: big && full == null ? Palette.warning : Palette.textDim,
          ),
          Text(
            message,
            style: TextStyle(
              fontSize: 12.5,
              color: big && full == null ? Palette.warning : Palette.textDim,
            ),
          ),
          action,
        ],
      ),
    );
  }

  ButtonStyle get _noteButtonStyle => TextButton.styleFrom(
    visualDensity: VisualDensity.compact,
    textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
  );

  Future<void> _showFullBody(ResponseData res) async {
    if (res.sizeBytes > fullBodyWarnBytes) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Show the full body?'),
          content: Text(
            'This response is ${formatByteSize(res.sizeBytes)}. Showing all '
            'of it can take a while and use a lot of memory'
            '${res.sizeBytes > fullBodyLimitBytes ? ', and only the first ${formatByteSize(fullBodyLimitBytes)} can be shown' : ''}. '
            'Saving it to a file is quicker for a body this size.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Show anyway'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    if (_full == null) {
      setState(() => _loadingFull = true);
      try {
        final data = await prepareFullBody(res.bodyBytes);
        if (!mounted) return;
        _full = data;
      } catch (e) {
        if (!mounted) return;
        setState(() => _loadingFull = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not prepare the full body: $e')),
        );
        return;
      }
    }
    setState(() {
      _loadingFull = false;
      _showFull = true;
    });
    if (_find.isOpen) _syncFindText();
  }

  void _hideFullBody() {
    setState(() => _showFull = false);
    if (_find.isOpen) _syncFindText();
  }

  // --- find in body --------------------------------------------------------

  /// The text the find bar searches while tab [index] is showing: what the
  /// Pretty or Raw view draws, or null on the other tabs.
  String? _findTextFor(int index) {
    final res = response;
    if (res == null || index > 1) return null;
    final full = _showFull ? _full : null;
    if (full != null) {
      return index == 0 ? (full.pretty ?? full.raw).text : full.raw.text;
    }
    final preview = res.bodyPreview;
    return index == 0 ? JsonView.displayText(preview) : preview;
  }

  void _syncFindText() {
    final tabs = _tabs;
    if (tabs == null) return;
    final text = _findTextFor(tabs.index);
    if (text != null) _find.setText(text);
  }

  /// Ctrl+F or the search button: show the bar over Pretty or Raw. From
  /// another tab it switches to Pretty first.
  void _openFind() {
    final tabs = _tabs;
    if (tabs == null) return;
    if (tabs.index > 1) tabs.animateTo(0);
    _syncFindText();
    _find.open();
  }

  void _closeFind() {
    _find.close();
    _paneFocus.requestFocus();
  }

  Widget _statusBar(BuildContext context, ResponseData res) {
    final color = statusColor(res.statusCode);
    final fun = context.watch<AppState>().settings.chaosMode;
    // On narrow panes the rarely used actions move into a menu so the row
    // stays a line or two tall.
    return LayoutBuilder(
      builder: (context, constraints) => _statusRow(
        context,
        res,
        color: color,
        fun: fun,
        compact: constraints.maxWidth < 560,
      ),
    );
  }

  Widget _statusRow(
    BuildContext context,
    ResponseData res, {
    required Color color,
    required bool fun,
    required bool compact,
  }) {
    final saveExample = IconButton(
      tooltip: 'Save as example',
      icon: Icon(Icons.bookmark_add_outlined, size: 16, color: Palette.textDim),
      onPressed: () =>
          saveResponseAsExample(context, context.read<AppState>(), tab, res),
    );
    final saveDocButton = IconButton(
      tooltip:
          'Save request and response as a Markdown doc (secrets '
          'masked)',
      icon: Icon(Icons.description_outlined, size: 16, color: Palette.textDim),
      onPressed: () => _saveDoc(context, res),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (fun) ...[
            HelpHover(
              'Chaos Mode is on, so each response gets an emoji and a sound '
              'for its status. Switch to Focus in the header to turn it off.',
              title: 'Chaos Mode',
              child: Text(switch (res.statusCode) {
                >= 200 && < 300 => '🎉',
                >= 300 && < 400 => '↪️',
                >= 400 && < 500 => '🤦',
                >= 500 => '🔥',
                _ => '🚨',
              }, style: const TextStyle(fontSize: 15)),
            ),
            const SizedBox(width: 8),
          ],
          HelpHover(
            httpStatusHelp(res.statusCode).message,
            title: httpStatusHelp(res.statusCode).title,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '${res.statusCode}'
                '${res.statusMessage.isNotEmpty ? ' ${res.statusMessage}' : ''}',
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                ),
              ),
            ),
          ),
          if (res.protocol != null) ...[
            const SizedBox(width: 8),
            HelpHover(
              'The HTTP version the server agreed to use for this response. '
              'Set your preference in Settings.',
              title: 'Protocol',
              example: 'HTTP/3',
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: Palette.query.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'HTTP/${res.protocol}',
                  style: TextStyle(
                    color: Palette.query,
                    fontWeight: FontWeight.w700,
                    fontSize: 11.5,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(width: 14),
          HelpHover(
            'Time from sending the request to receiving the whole response, '
            'including connecting to the server.',
            title: 'Response time',
            example: '230 ms',
            child: _metric(Icons.timer_outlined, _fmtDuration(res.durationMs)),
          ),
          const SizedBox(width: 12),
          HelpHover(
            'Size of the response body, not counting headers.',
            title: 'Body size',
            example: '1.4 KB',
            child: _metric(Icons.straighten, formatByteSize(res.sizeBytes)),
          ),

          HelpHover(
            'Search the body for text. The Pretty or Raw view highlights every '
            'match. Ctrl+F (Cmd+F on a Mac) does the same.',
            title: 'Find in body',
            example: 'Ctrl+F',
            child: IconButton(
              icon: Icon(Icons.search, size: 16, color: Palette.textDim),
              onPressed: _openFind,
            ),
          ),
          IconButton(
            tooltip: 'Save response body to a file',
            icon: Icon(Icons.save_alt, size: 16, color: Palette.textDim),
            onPressed: () => saveResponseBody(context, res, tab.request),
          ),
          if (!compact) ...[saveExample, saveDocButton],
          IconButton(
            tooltip: 'Copy body',
            icon: Icon(Icons.copy, size: 16, color: Palette.textDim),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: res.bodyText));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Response body copied to clipboard'),
                ),
              );
            },
          ),
          if (compact)
            PopupMenuButton<String>(
              tooltip: 'More response actions',
              icon: Icon(Icons.more_vert, size: 18, color: Palette.textDim),
              onSelected: (v) {
                if (v == 'example') {
                  saveResponseAsExample(
                    context,
                    context.read<AppState>(),
                    tab,
                    res,
                  );
                } else {
                  _saveDoc(context, res);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'example',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.bookmark_add_outlined),
                    title: Text('Save as example'),
                  ),
                ),
                PopupMenuItem(
                  value: 'doc',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.description_outlined),
                    title: Text('Save as Markdown doc'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _saveDoc(BuildContext context, ResponseData res) async {
    final md = buildMarkdownDoc(
      tab.request,
      res,
      secrets: context.read<AppState>().secretValues,
    );
    final name = tab.request.name == 'Untitled request'
        ? 'request-doc'
        : tab.request.name.replaceAll(RegExp(r'[^\w\- ]'), '').trim();
    try {
      final path = await savePickedFile(
        dialogTitle: 'Save documentation',
        fileName: '$name.md',
        extensions: ['md'],
        bytes: utf8.encode(md),
      );
      if (path != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Documentation saved (auth tokens are masked automatically).',
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not save doc: $e')));
      }
    }
  }

  Widget _metric(IconData icon, String text) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 14, color: Palette.textDim),
      const SizedBox(width: 4),
      Text(text, style: TextStyle(color: Palette.textDim, fontSize: 12.5)),
    ],
  );

  Widget _headersTable(ResponseData res) {
    final entries = res.headers.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return ListView.separated(
      padding: const EdgeInsets.all(14),
      itemCount: entries.length,
      separatorBuilder: (_, _) => Divider(height: 14, color: Palette.border),
      itemBuilder: (_, i) {
        final e = entries[i];
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: SelectableText(
                e.key,
                style: TextStyle(
                  color: Palette.put,
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                ),
              ),
            ),
            Expanded(
              child: SelectableText(
                e.value.join('\n'),
                style: TextStyle(
                  color: Palette.text,
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

String _fmtDuration(int ms) =>
    ms < 1000 ? '$ms ms' : '${(ms / 1000).toStringAsFixed(2)} s';

/// Hosts the find bar between the tab bar and the tab pages. It shows only
/// while the Pretty or Raw tab is selected, and tells the response view which
/// tab that is so the bar searches the text that tab shows.
class _FindBarHost extends StatefulWidget {
  const _FindBarHost({
    required this.find,
    required this.onController,
    required this.onIndex,
    required this.onClose,
  });

  final FindController find;

  /// Called with the tab controller once the tabs exist (and if it changes).
  final void Function(TabController controller) onController;

  /// Called when the selected tab changes.
  final void Function(int index) onIndex;

  final VoidCallback onClose;

  @override
  State<_FindBarHost> createState() => _FindBarHostState();
}

class _FindBarHostState extends State<_FindBarHost> {
  TabController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = DefaultTabController.of(context);
    if (c == _controller) return;
    _controller?.removeListener(_changed);
    _controller = c..addListener(_changed);
    widget.onController(c);
  }

  @override
  void dispose() {
    _controller?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    widget.onIndex(_controller!.index);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.find,
    builder: (context, _) => widget.find.isOpen && _controller!.index <= 1
        ? FindBar(find: widget.find, onClose: widget.onClose)
        : const SizedBox.shrink(),
  );
}
