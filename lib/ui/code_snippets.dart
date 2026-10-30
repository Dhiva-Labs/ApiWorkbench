import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/codegen/codegen.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'adaptive.dart';
import 'help_tip.dart';

/// The language picked last, kept for the rest of the session.
String _lastLanguageId = codeGenerators.first.id;

/// Shows the request as code in the language of the user's choice, with
/// variables, path variables and auth applied as they would be on send.
Future<void> showCodeSnippetDialog(
  BuildContext context,
  AppState state,
  RequestTab tab,
) => showDialog<void>(
  context: context,
  builder: (_) => CodeSnippetDialog(state: state, tab: tab),
);

/// The dialog behind [showCodeSnippetDialog]. Public so tests can host it.
class CodeSnippetDialog extends StatefulWidget {
  const CodeSnippetDialog({super.key, required this.state, required this.tab});

  final AppState state;
  final RequestTab tab;

  @override
  State<CodeSnippetDialog> createState() => _CodeSnippetDialogState();
}

class _CodeSnippetDialogState extends State<CodeSnippetDialog> {
  late CodeGenerator _generator = codeGeneratorById(_lastLanguageId);
  bool _unresolved = false;
  SnippetRequest? _resolved;
  String? _error;
  int _token = 0;
  bool _copied = false;
  Timer? _copiedTimer;
  final _vertical = ScrollController();
  final _horizontal = ScrollController();

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void dispose() {
    _copiedTimer?.cancel();
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  /// Builds the request as it would be sent. A copy is used so edits made
  /// while this runs cannot change it half way.
  Future<void> _resolve() async {
    final token = ++_token;
    final s = widget.state;
    final tab = widget.tab;
    try {
      final resolved = await resolveSnippetRequest(
        tab.request.clone(sameId: true),
        s.varsFor(tab.sourceCollectionId),
        collection: s.collectionById(tab.sourceCollectionId),
        app: s.settings,
        unresolved: _unresolved,
      );
      if (!mounted || token != _token) return;
      setState(() {
        _resolved = resolved;
        _error = null;
      });
    } on RequestBuildException catch (e) {
      if (!mounted || token != _token) return;
      setState(() {
        _resolved = null;
        _error = e.message;
      });
    }
  }

  String? get _code =>
      _resolved == null ? null : _generator.generate(_resolved!);

  Future<void> _copy() async {
    final code = _code;
    if (code == null) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;
    final copy = HelpHover(
      'Copy the code below to the clipboard.',
      title: 'Copy',
      child: FilledButton.icon(
        onPressed: code == null ? null : _copy,
        icon: Icon(_copied ? Icons.check : Icons.copy, size: 16),
        label: Text(_copied ? 'Copied' : 'Copy'),
      ),
    );
    return AdaptiveDialog(
      title: const Text('Code snippet'),
      width: 760,
      height: 540,
      primary: copy,
      actions: [
        copy,
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
      // With little height (a phone on its side, or the keyboard open) the
      // code box keeps a usable height and the whole dialog scrolls.
      content: LayoutBuilder(
        builder: (context, box) {
          final tight = box.maxHeight < 380;
          final column = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _controls(),
              for (final w in _resolved?.warnings ?? const <String>[])
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    w,
                    style: TextStyle(fontSize: 12.5, color: Palette.warning),
                  ),
                ),
              const SizedBox(height: 10),
              if (tight)
                SizedBox(height: 260, child: _body(code))
              else
                Expanded(child: _body(code)),
            ],
          );
          return tight ? SingleChildScrollView(child: column) : column;
        },
      ),
    );
  }

  Widget _controls() => LayoutBuilder(
    builder: (context, box) {
      final picker = DropdownMenu<CodeGenerator>(
        key: const ValueKey('snippet-language'),
        width: box.maxWidth.clamp(0, 320).toDouble(),
        label: const Text('Language'),
        initialSelection: _generator,
        enableFilter: true,
        requestFocusOnTap: true,
        menuHeight: 320,
        filterCallback: (entries, filter) {
          final q = filter.trim().toLowerCase();
          return [
            for (final e in entries)
              if (q.isEmpty ||
                  '${e.label} ${e.value.keywords}'.toLowerCase().contains(q))
                e,
          ];
        },
        dropdownMenuEntries: [
          for (final g in codeGenerators)
            DropdownMenuEntry(value: g, label: g.label),
        ],
        onSelected: (g) {
          if (g == null) return;
          _lastLanguageId = g.id;
          setState(() => _generator = g);
        },
      );
      final toggle = HelpHover(
        'Keep {{variables}} as written instead of filling in their current '
        'values, for code that reads them from somewhere else.',
        title: 'Show variables unresolved',
        example: 'Authorization: Bearer {{token}}',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              value: _unresolved,
              onChanged: (v) {
                setState(() => _unresolved = v);
                _resolve();
              },
            ),
            Flexible(
              child: Text(
                'Show {{variables}} unresolved',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      );
      return Wrap(
        spacing: 16,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          HelpHover(
            'Pick the language and library to generate. Type to search.',
            title: 'Language',
            example: 'Python – requests',
            child: picker,
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: box.maxWidth),
            child: toggle,
          ),
        ],
      );
    },
  );

  Widget _body(String? code) {
    if (_error != null) {
      return Align(
        alignment: Alignment.topLeft,
        child: Text(
          'The code cannot be generated yet: $_error',
          style: TextStyle(color: Palette.danger, fontSize: 13),
        ),
      );
    }
    if (code == null) return const Center(child: CircularProgressIndicator());
    return Container(
      decoration: BoxDecoration(
        color: Palette.surfaceAlt,
        border: Border.all(color: Palette.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Scrollbar(
        controller: _vertical,
        child: SingleChildScrollView(
          controller: _vertical,
          padding: const EdgeInsets.all(12),
          child: Scrollbar(
            controller: _horizontal,
            child: SingleChildScrollView(
              key: const ValueKey('snippet-code-scroll'),
              controller: _horizontal,
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                code,
                key: const ValueKey('snippet-code'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
