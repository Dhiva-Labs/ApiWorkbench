import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/doc_export.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'app_menu.dart';
import 'help_tip.dart';
import 'json_view.dart';
import 'tab_memory.dart';

/// Which response tab (Pretty, Raw, Headers, Tests) each request tab shows,
/// kept across new responses and across Request/Response on phones.
final _selectedTab = Expando<int>('response tab');

class ResponseView extends StatelessWidget {
  /// Captures what [tab] shows right now. When a new response arrives the
  /// outgoing view keeps showing the old one while it fades out, instead of
  /// flipping to the new state halfway through the transition.
  ResponseView({super.key, required this.tab})
    : response = tab.response,
      loading = tab.loading,
      results = tab.assertionResults;

  final RequestTab tab;
  final ResponseData? response;
  final bool loading;
  final List<AssertionResult> results;

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
    final preview = res.previewTruncated
        ? '${res.bodyPreview}\n\n[Preview limited to 64 KB. Copy or export for the full body.]'
        : res.bodyPreview;
    final tests = results;
    final testsPassed = tests.where((t) => t.pass).length;
    return DefaultTabController(
      length: 4,
      initialIndex: TabMemory.initialIndex(_selectedTab, tab, 4),
      child: TabMemory(
        owner: tab,
        memory: _selectedTab,
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
                HelpHover(
                  'Extra information the server sent with the response, such as '
                  'the body format and caching rules.',
                  title: 'Response headers',
                  example: 'Content-Type: application/json',
                  child: Tab(text: 'Headers (${res.headers.length})'),
                ),
                HelpHover(
                  'Results of the checks from the request\'s Tests tab, run on '
                  'this response. Shown as passed out of total.',
                  title: 'Test results',
                  example: 'Tests (3/4)',
                  child: Tab(
                    child: tests.isEmpty
                        ? const Text('Tests')
                        : Text(
                            'Tests ($testsPassed/${tests.length})',
                            style: TextStyle(
                              color: testsPassed == tests.length
                                  ? Palette.get_
                                  : Palette.delete,
                            ),
                          ),
                  ),
                ),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _scroll(JsonView(text: preview)),
                  _scroll(
                    SelectableText(
                      preview.isEmpty ? '(empty body)' : preview,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        height: 1.5,
                        color: Palette.text,
                      ),
                    ),
                  ),
                  _headersTable(res),
                  _testsList(tests),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _testsList(List<AssertionResult> tests) {
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

  Widget _scroll(Widget child) => SingleChildScrollView(
    padding: const EdgeInsets.all(14),
    child: Align(alignment: Alignment.topLeft, child: child),
  );

  Widget _statusBar(BuildContext context, ResponseData res) {
    final color = statusColor(res.statusCode);
    final fun = context.watch<AppState>().settings.chaosMode;
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
            child: _metric(Icons.straighten, _fmtSize(res.sizeBytes)),
          ),

          IconButton(
            tooltip:
                'Save request and response as a Markdown doc (secrets '
                'masked)',
            icon: Icon(
              Icons.description_outlined,
              size: 16,
              color: Palette.textDim,
            ),
            onPressed: () => _saveDoc(context, res),
          ),
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
        ],
      ),
    );
  }

  Future<void> _saveDoc(BuildContext context, ResponseData res) async {
    final md = buildMarkdownDoc(tab.request, res);
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

String _fmtSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
}
