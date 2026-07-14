import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../services/doc_export.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'app_menu.dart';
import 'json_view.dart';

class ResponseView extends StatelessWidget {
  const ResponseView({super.key, required this.tab});

  final RequestTab tab;

  @override
  Widget build(BuildContext context) {
    if (tab.loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5)),
            SizedBox(height: 14),
            Text('Sending request…',
                style: TextStyle(color: Palette.textDim)),
          ],
        ),
      );
    }
    final res = tab.response;
    if (res == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bolt_outlined, size: 42, color: Palette.border),
            SizedBox(height: 10),
            Text('Hit Send to see the response here',
                style: TextStyle(color: Palette.textDim)),
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
            border:
                Border.all(color: Palette.delete.withValues(alpha: 0.4)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Palette.delete, size: 30),
              const SizedBox(height: 10),
              SelectableText(res.error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Palette.text, height: 1.4)),
            ],
          ),
        ),
      );
    }
    final tests = tab.assertionResults;
    final testsPassed = tests.where((t) => t.pass).length;
    return DefaultTabController(
      length: 4,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _statusBar(context, res),
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelStyle:
                const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            tabs: [
              const Tab(text: 'Pretty'),
              const Tab(text: 'Raw'),
              Tab(text: 'Headers (${res.headers.length})'),
              Tab(
                child: tests.isEmpty
                    ? const Text('Tests')
                    : Text('Tests ($testsPassed/${tests.length})',
                        style: TextStyle(
                            color: testsPassed == tests.length
                                ? Palette.get_
                                : Palette.delete)),
              ),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _scroll(JsonView(text: res.bodyText)),
                _scroll(SelectableText(
                  res.bodyText.isEmpty ? '(empty body)' : res.bodyText,
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      height: 1.5,
                      color: Palette.text),
                )),
                _headersTable(res),
                _testsList(tests),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _testsList(List<AssertionResult> tests) {
    if (tests.isEmpty) {
      return const Center(
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
              Icon(t.pass ? Icons.check_circle : Icons.cancel,
                  size: 17, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${t.assertion.kind.label}'
                      '${t.assertion.kind.hasTarget ? ' • ${t.assertion.target}' : ''}',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    Text(t.message,
                        style: TextStyle(fontSize: 12, color: color)),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 6),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '${res.statusCode}'
              '${res.statusMessage.isNotEmpty ? ' ${res.statusMessage}' : ''}',
              style: TextStyle(
                  color: color, fontWeight: FontWeight.w700, fontSize: 12.5),
            ),
          ),
          const SizedBox(width: 14),
          _metric(Icons.timer_outlined, _fmtDuration(res.durationMs)),
          const SizedBox(width: 12),
          _metric(Icons.straighten, _fmtSize(res.sizeBytes)),
          const Spacer(),
          IconButton(
            tooltip: 'Save request + response as Markdown doc',
            icon: const Icon(Icons.description_outlined,
                size: 16, color: Palette.textDim),
            onPressed: () => _saveDoc(context, res),
          ),
          IconButton(
            tooltip: 'Copy body',
            icon: const Icon(Icons.copy, size: 16, color: Palette.textDim),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: res.bodyText));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Response body copied to clipboard')));
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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Documentation saved (auth tokens are masked automatically).')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not save doc: $e')));
      }
    }
  }

  Widget _metric(IconData icon, String text) => Row(
        children: [
          Icon(icon, size: 14, color: Palette.textDim),
          const SizedBox(width: 4),
          Text(text,
              style: const TextStyle(color: Palette.textDim, fontSize: 12.5)),
        ],
      );

  Widget _headersTable(ResponseData res) {
    final entries = res.headers.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return ListView.separated(
      padding: const EdgeInsets.all(14),
      itemCount: entries.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 14, color: Palette.border),
      itemBuilder: (_, i) {
        final e = entries[i];
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 220,
              child: SelectableText(e.key,
                  style: const TextStyle(
                      color: Palette.put,
                      fontFamily: 'monospace',
                      fontSize: 12.5)),
            ),
            Expanded(
              child: SelectableText(e.value.join('\n'),
                  style: const TextStyle(
                      color: Palette.text,
                      fontFamily: 'monospace',
                      fontSize: 12.5)),
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
