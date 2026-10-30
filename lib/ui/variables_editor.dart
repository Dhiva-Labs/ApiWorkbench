import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'adaptive.dart';
import 'help_tip.dart';

/// Lists with more rows than this get a filter box.
const _filterThreshold = 8;

/// At this width and above a variable is one table row; below it the row
/// stacks (name on top, the two values underneath).
const _wideWidth = 760.0;

/// Stacked rows at this width and above keep the two values side by side
/// and show the type switch; below it (phones) the values go one under the
/// other and the type moves into the row menu.
const _mediumWidth = 420.0;

enum _RowAction { reset, persist, description, secret, delete }

/// Non-row items of the list.
enum _Entry { help, empty, noMatch, header }

/// Edits environment, collection or global variables.
///
/// Each row has an initial value (shared, exported) and a current value
/// (local, used when sending; empty means "same as initial"), a secret flag
/// that masks both, and a menu to reset, persist, describe or delete it.
/// Edits go straight into [rows]; [onChanged] runs after each.
class VariablesEditor extends StatefulWidget {
  const VariablesEditor({
    super.key,
    required this.rows,
    required this.onChanged,
    this.valueHelp,
    this.valueExample,
    this.overriddenBy,
  });

  final List<KV> rows;
  final VoidCallback onChanged;

  /// Hover help for the initial value column, about where the value is
  /// used; the editor adds what "initial" means.
  final String? valueHelp;
  final String? valueExample;

  /// Names the higher scope that shadows a variable (for instance
  /// `the active environment "Dev"`), or null when nothing does. The row
  /// then carries a note saying so.
  final String? Function(KV row)? overriddenBy;

  @override
  State<VariablesEditor> createState() => _VariablesEditorState();
}

class _VariablesEditorState extends State<VariablesEditor> {
  // Controllers outlive rebuilds (and filtering) and are keyed by row, so
  // typing never recreates them; see KVEditor.
  final Map<KV, TextEditingController> _keyCtrls = {};
  final Map<KV, TextEditingController> _initialCtrls = {};
  final Map<KV, TextEditingController> _currentCtrls = {};
  final Set<KV> _revealed = {};
  final _filterCtrl = TextEditingController();
  final _scroll = ScrollController();
  String _query = '';

  /// The row just added: it takes focus when it is first built.
  KV? _justAdded;

  /// The controller for [row]'s field. It is created once and only has its
  /// text replaced when the row changed behind the editor's back (a script
  /// or a capture), never while typing: the model already matches then.
  TextEditingController _ctrl(
    Map<KV, TextEditingController> map,
    KV row,
    String text,
  ) {
    final c = map.putIfAbsent(row, () => TextEditingController(text: text));
    if (c.text != text) c.text = text;
    return c;
  }

  /// Disposes [ctrls] once this frame has rebuilt: the removed rows' text
  /// fields keep listening until then.
  void _disposeLater(Iterable<TextEditingController?> ctrls) {
    final dead = ctrls.nonNulls.toList();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final c in dead) {
        c.dispose();
      }
    });
  }

  @override
  void didUpdateWidget(VariablesEditor old) {
    super.didUpdateWidget(old);
    // Rows may be removed or replaced by the caller (an import, a script).
    final live = widget.rows.toSet();
    _revealed.retainAll(live);
    for (final map in [_keyCtrls, _initialCtrls, _currentCtrls]) {
      final gone = map.keys.where((r) => !live.contains(r)).toList();
      _disposeLater(gone.map(map.remove));
    }
  }

  @override
  void dispose() {
    for (final map in [_keyCtrls, _initialCtrls, _currentCtrls]) {
      for (final c in map.values) {
        c.dispose();
      }
    }
    _filterCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Width of a checkbox or icon button at the current density.
  double get _control =>
      48 + Theme.of(context).visualDensity.baseSizeAdjustment.dx;

  bool get _showFilter => widget.rows.length > _filterThreshold;

  bool _matches(KV r) {
    final q = _query.toLowerCase();
    if (q.isEmpty) return true;
    bool has(String s) => s.toLowerCase().contains(q);
    // Secret values never take part in a search.
    return has(r.key) ||
        has(r.description) ||
        (!r.secret && (has(r.value) || has(r.current ?? '')));
  }

  /// Indexes into [VariablesEditor.rows] of the rows to show.
  List<int> _visible() => [
    for (var i = 0; i < widget.rows.length; i++)
      if (!_showFilter || _matches(widget.rows[i])) i,
  ];

  /// Rows that have a current value, among those shown (with a filter on,
  /// the bulk buttons only touch the matches).
  List<KV> _withCurrent() => [
    for (final i in _visible())
      if (widget.rows[i].current != null) widget.rows[i],
  ];

  bool get _filtering => _showFilter && _query.isNotEmpty;

  void _changed() {
    setState(() {});
    widget.onChanged();
  }

  // ---- Actions -----------------------------------------------------------

  void _add() {
    final row = KV();
    setState(() {
      _filterCtrl.clear();
      _query = '';
      widget.rows.add(row);
      _justAdded = row;
    });
    widget.onChanged();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
      // Cleared a frame later so the autofocus has fired.
      WidgetsBinding.instance.addPostFrameCallback((_) => _justAdded = null);
    });
  }

  void _setEnabled(KV row, bool on) {
    row.enabled = on;
    _changed();
  }

  void _setSecret(KV row, bool secret) {
    row.secret = secret;
    if (!secret) _revealed.remove(row);
    _changed();
  }

  void _toggleReveal(KV row) => setState(() {
    if (!_revealed.remove(row)) _revealed.add(row);
  });

  void _resetRow(KV row) {
    row.current = null;
    _currentCtrls[row]?.text = '';
  }

  void _persistRow(KV row) {
    final cur = row.current;
    if (cur == null) return;
    row.value = cur;
    row.current = null;
    _initialCtrls[row]?.text = cur;
    _currentCtrls[row]?.text = '';
  }

  void _delete(KV row) {
    _revealed.remove(row);
    _disposeLater([
      _keyCtrls.remove(row),
      _initialCtrls.remove(row),
      _currentCtrls.remove(row),
    ]);
    widget.rows.remove(row);
    _changed();
  }

  Future<void> _editDescription(KV row) async {
    final ctrl = TextEditingController(text: row.description);
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => ControllerScope(
        controllers: [ctrl],
        child: AlertDialog(
          scrollable: true,
          title: Text(row.key.isEmpty ? 'Description' : '${row.key} note'),
          content: SizedBox(
            width: 360,
            child: HelpHover(
              'A note about what this variable is for. It is saved with the '
              'variable.',
              title: 'Description',
              example: 'Base URL of the staging API',
              child: TextField(
                controller: ctrl,
                autofocus: true,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  hintText: 'What is this variable for?',
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (text == null || !mounted) return;
    row.description = text;
    _changed();
  }

  Future<bool> _confirm(String title, String body, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true && mounted;
  }

  Future<void> _resetAll() async {
    final targets = _withCurrent();
    if (targets.isEmpty) return;
    final n = targets.length;
    final ok = await _confirm(
      'Reset current values?',
      'Clear the current value of $n ${_filtering ? 'matching ' : ''}'
          '${n == 1 ? 'variable' : 'variables'}, so requests use the initial '
          'values again. The initial values do not change.',
      'Reset all',
    );
    if (!ok) return;
    for (final r in targets) {
      _resetRow(r);
    }
    _changed();
  }

  Future<void> _persistAll() async {
    final targets = _withCurrent();
    if (targets.isEmpty) return;
    final n = targets.length;
    final ok = await _confirm(
      'Persist current values?',
      'Copy the current value of $n ${_filtering ? 'matching ' : ''}'
          '${n == 1 ? 'variable' : 'variables'} over the initial value, which '
          'is the shared one that gets exported, then clear the current '
          'values.',
      'Persist all',
    );
    if (!ok) return;
    for (final r in targets) {
      _persistRow(r);
    }
    _changed();
  }

  // ---- Layout ------------------------------------------------------------

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final wide = box.maxWidth >= _wideWidth;
      final medium = box.maxWidth >= _mediumWidth;
      final visible = _visible();
      final entries = <Object>[
        _Entry.help,
        if (widget.rows.isEmpty)
          _Entry.empty
        else if (visible.isEmpty)
          _Entry.noMatch
        else if (wide)
          _Entry.header,
        ...visible,
      ];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _toolbar(compact: !medium),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              itemCount: entries.length,
              itemBuilder: (_, i) => switch (entries[i]) {
                _Entry.help => _helpLine(),
                _Entry.empty => _note(
                  'No variables yet. Press "Add variable" to create one.',
                ),
                _Entry.noMatch => _note('No variable matches "$_query".'),
                _Entry.header => _header(),
                final int index => KeyedSubtree(
                  key: ObjectKey(widget.rows[index]),
                  child: _row(index, wide: wide, medium: medium),
                ),
                _ => const SizedBox.shrink(),
              },
            ),
          ),
        ],
      );
    },
  );

  Widget _toolbar({required bool compact}) {
    final hasCurrent = _withCurrent().isNotEmpty;
    final scope = _filtering ? ' of the matching variables' : '';
    final resetText =
        'Clears the current value$scope, so requests use the initial values '
        'again. Asks first.';
    final persistText =
        'Copies the current value$scope into the initial value, so it is '
        'shared and exported, then clears the current value. Asks first.';
    const resetExample = 'Current "dev-token" goes back to the initial value';
    const persistExample = 'Initial "" becomes "dev-token"';

    final add = HelpHover(
      'Adds an empty row at the end. Name it, then give it a value.',
      title: 'Add variable',
      example: 'baseUrl = https://api.example.com',
      child: TextButton.icon(
        onPressed: _add,
        icon: const Icon(Icons.add, size: 18),
        label: const Text('Add variable'),
      ),
    );
    final filter = _showFilter
        ? HelpHover(
            'Shows only the variables whose name, description or value '
            'contains the text. Secret values are never searched.',
            title: 'Filter variables',
            example: 'token',
            child: TextField(
              key: const Key('var.filter'),
              controller: _filterCtrl,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Filter variables',
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear the filter',
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () => setState(() {
                          _filterCtrl.clear();
                          _query = '';
                        }),
                      ),
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
          )
        : null;

    if (compact) {
      // Phones: the two bulk actions move into a menu to save a line.
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Column(
          children: [
            Row(
              children: [
                // Loose, so a large text size wraps the label, not overflows.
                Expanded(
                  child: Align(alignment: Alignment.centerLeft, child: add),
                ),
                HelpHover(
                  'Reset or persist every current value at once. Asks '
                  'first.',
                  title: 'All variables',
                  example: 'Persist all: initial "" becomes "dev-token"',
                  essential: true,
                  child: PopupMenuButton<bool>(
                    key: const Key('var.bulk'),
                    tooltip: '', // the hover help above replaces it
                    icon: Icon(Icons.more_horiz, color: Palette.textDim),
                    onSelected: (persist) =>
                        persist ? _persistAll() : _resetAll(),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: false,
                        enabled: hasCurrent,
                        child: HelpHover(
                          resetText,
                          title: 'Reset all',
                          example: resetExample,
                          child: const Text('Reset all'),
                        ),
                      ),
                      PopupMenuItem(
                        value: true,
                        enabled: hasCurrent,
                        child: HelpHover(
                          persistText,
                          title: 'Persist all',
                          example: persistExample,
                          child: const Text('Persist all'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            ?filter,
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          add,
          HelpHover(
            resetText,
            title: 'Reset all',
            example: resetExample,
            child: TextButton.icon(
              onPressed: hasCurrent ? _resetAll : null,
              icon: const Icon(Icons.restart_alt, size: 18),
              label: const Text('Reset all'),
            ),
          ),
          HelpHover(
            persistText,
            title: 'Persist all',
            example: persistExample,
            child: TextButton.icon(
              onPressed: hasCurrent ? _persistAll : null,
              icon: const Icon(Icons.save_alt, size: 18),
              label: const Text('Persist all'),
            ),
          ),
          if (filter != null) SizedBox(width: 200, child: filter),
        ],
      ),
    );
  }

  Widget _helpLine() => Padding(
    padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
    child: Text(
      'Initial is the shared value that gets exported. Current stays on this '
      'device and is what requests use; leave it empty to use the initial.',
      style: TextStyle(fontSize: 12, color: Palette.textDim, height: 1.35),
    ),
  );

  Widget _note(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: 12.5, color: Palette.textDim),
    ),
  );

  /// Column labels lined up with the wide row.
  Widget _header() {
    final style = TextStyle(
      fontSize: 11.5,
      fontWeight: FontWeight.w600,
      color: Palette.textDim,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(width: _control),
          Expanded(
            flex: 2,
            child: LabelWithHelp(
              'Variable',
              _nameHelp,
              style: style,
              example: 'baseUrl',
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: LabelWithHelp(
              'Initial value',
              _initialHelp,
              style: style,
              example: _initialExample,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: LabelWithHelp(
              'Current value',
              _currentHelp,
              style: style,
              example: _currentExample,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 92 + _control,
            child: LabelWithHelp(
              'Type',
              _typeHelp,
              style: style,
              example: _typeExample,
            ),
          ),
          SizedBox(width: _control),
        ],
      ),
    );
  }

  static const _nameHelp =
      'The variable name. Use it anywhere in a request as {{name}}.';
  static const _currentHelp =
      'Your local value, used when you send. Scripts and captures write '
      'here. Leave it empty to use the initial value (shown greyed out).';
  static const _currentExample = 'http://localhost:8080';
  static const _typeHelp =
      'Default values show as typed. Secret values are hidden in the '
      'editor, the console, docs and exports until you press the eye.';
  static const _typeExample = 'apiKey = secret';

  String get _initialHelp =>
      'The shared starting value, saved with exports. '
      '${widget.valueHelp ?? 'It replaces {{name}} when you send, unless a '
              'current value is set.'}';

  String get _initialExample =>
      widget.valueExample ?? 'https://api.example.com';

  // ---- One row -----------------------------------------------------------

  Widget _row(int index, {required bool wide, required bool medium}) {
    final row = widget.rows[index];
    final revealed = _revealed.contains(row);
    final hide = row.secret && !revealed;
    final autofocus = identical(row, _justAdded);

    final checkbox = HelpHover(
      'Ticked variables are used. Untick to switch one off without '
      'deleting it.',
      title: row.enabled ? 'On' : 'Off',
      example: 'baseUrl = https://api.example.com',
      child: Checkbox(
        key: Key('var.$index.enabled'),
        value: row.enabled,
        onChanged: (v) => _setEnabled(row, v ?? true),
      ),
    );

    final name = HelpHover(
      _nameHelp,
      title: 'Variable',
      example: 'baseUrl',
      child: TextField(
        key: Key('var.$index.name'),
        controller: _ctrl(_keyCtrls, row, row.key),
        autofocus: autofocus,
        style: const TextStyle(fontSize: 13),
        decoration: const InputDecoration(hintText: 'Variable'),
        onChanged: (v) {
          row.key = v;
          widget.onChanged();
        },
      ),
    );

    // Stacked rows have no column header, so their fields carry a label.
    Widget initial(bool labelled) => HelpHover(
      _initialHelp,
      title: 'Initial value',
      example: _initialExample,
      child: TextField(
        key: Key('var.$index.initial'),
        controller: _ctrl(_initialCtrls, row, row.value),
        obscureText: hide,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          hintText: 'Value',
          labelText: labelled ? 'Initial value' : null,
          floatingLabelBehavior: labelled ? FloatingLabelBehavior.always : null,
        ),
        onChanged: (v) {
          row.value = v;
          widget.onChanged();
          // The Current placeholder follows the initial value.
          if (row.current == null) setState(() {});
        },
      ),
    );

    Widget current(bool labelled) => HelpHover(
      _currentHelp,
      title: 'Current value',
      example: _currentExample,
      child: TextField(
        key: Key('var.$index.current'),
        controller: _ctrl(_currentCtrls, row, row.current ?? ''),
        obscureText: hide,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          hintText: _currentHint(row, hide),
          labelText: labelled ? 'Current value' : null,
          floatingLabelBehavior: labelled ? FloatingLabelBehavior.always : null,
          // A tint marks a variable whose current value differs.
          fillColor: row.current != null ? Palette.accentSoft : null,
        ),
        onChanged: (v) {
          // Clearing the field gives the variable back its initial value.
          row.current = v.isEmpty ? null : v;
          _changed();
        },
      ),
    );

    final eye = row.secret
        ? HelpHover(
            revealed
                ? 'Hides the initial and current values of this variable '
                      'again.'
                : 'Shows the initial and current values of this variable '
                      'while you edit.',
            title: revealed ? 'Hide values' : 'Show values',
            example: 'sk-live-••••  and  sk-live-4f9a',
            essential: true,
            child: IconButton(
              key: Key('var.$index.eye'),
              icon: Icon(
                revealed
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 18,
              ),
              onPressed: () => _toggleReveal(row),
            ),
          )
        : null;

    final menu = _menu(index, row, showSecretItem: !(wide || medium));

    final Widget body;
    if (wide) {
      body = Row(
        children: [
          checkbox,
          Expanded(flex: 2, child: name),
          const SizedBox(width: 8),
          Expanded(flex: 3, child: initial(false)),
          const SizedBox(width: 8),
          Expanded(flex: 3, child: current(false)),
          const SizedBox(width: 8),
          SizedBox(width: 92, child: _typeChip(index, row)),
          SizedBox(width: _control, child: eye),
          SizedBox(width: _control, child: menu),
        ],
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              checkbox,
              Expanded(child: name),
              if (medium) ...[const SizedBox(width: 8), _typeChip(index, row)],
              ?eye,
              menu,
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: EdgeInsets.only(left: _control),
            child: medium
                ? Row(
                    children: [
                      Expanded(child: initial(true)),
                      const SizedBox(width: 8),
                      Expanded(child: current(true)),
                    ],
                  )
                : Column(
                    children: [
                      initial(true),
                      const SizedBox(height: 10),
                      current(true),
                    ],
                  ),
          ),
        ],
      );
    }

    return Padding(
      padding: EdgeInsets.only(bottom: wide ? 8 : 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A switched-off variable stays editable but looks inactive.
          Opacity(opacity: row.enabled ? 1 : 0.55, child: body),
          ?_caption(row),
        ],
      ),
    );
  }

  /// What the Current field shows while it is empty: the initial value, as
  /// a greyed-out placeholder (masked for secrets).
  String _currentHint(KV row, bool hide) {
    if (row.current == '') return '(empty)';
    if (row.value.isEmpty) return 'Same as initial';
    return hide ? '••••••••' : row.value;
  }

  /// The row's description and, when a higher scope shadows it, a note.
  Widget? _caption(KV row) {
    final shadow = row.enabled && row.key.isNotEmpty
        ? widget.overriddenBy?.call(row)
        : null;
    if (row.description.isEmpty && shadow == null) return null;
    final style = TextStyle(fontSize: 11.5, color: Palette.textDim);
    return Padding(
      padding: EdgeInsets.only(left: _control, top: 2, right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (row.description.isNotEmpty)
            Text(
              row.description,
              style: style,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          if (shadow != null)
            HelpHover(
              'A variable with this name in a scope that ranks higher wins '
              'when you send, so this value is not the one used there.',
              title: 'Overridden',
              example: 'Globals < collection < environment < data < local',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.layers_outlined, size: 13, color: Palette.textDim),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      'Overridden by $shadow',
                      style: style.copyWith(fontStyle: FontStyle.italic),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Default or secret.
  Widget _typeChip(int index, KV row) => HelpHover(
    _typeHelp,
    title: 'Type',
    example: _typeExample,
    child: PopupMenuButton<bool>(
      key: Key('var.$index.type'),
      tooltip: '', // the hover help above replaces the plain tooltip
      initialValue: row.secret,
      onSelected: (secret) {
        if (secret != row.secret) _setSecret(row, secret);
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: false,
          child: HelpHover(
            'Shown as typed. Right for URLs, ids and other values that are '
            'safe to see.',
            title: 'Default',
            example: 'baseUrl = https://api.example.com',
            child: Text('Default'),
          ),
        ),
        PopupMenuItem(
          value: true,
          child: HelpHover(
            'Hidden in the editor, the console, docs and exports. Right for '
            'tokens, passwords and keys.',
            title: 'Secret',
            example: 'apiKey = ••••••••',
            child: Text('Secret'),
          ),
        ),
      ],
      child: Container(
        height: isTouch(context) ? minTouchTarget : 36,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: row.secret ? Palette.accentSoft : null,
          border: Border.all(color: Palette.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (row.secret) ...[
              Icon(Icons.lock_outline, size: 13, color: Palette.accent),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                row.secret ? 'Secret' : 'Default',
                style: TextStyle(fontSize: 12, color: Palette.textDim),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 16, color: Palette.textDim),
          ],
        ),
      ),
    ),
  );

  Widget _menu(int index, KV row, {required bool showSecretItem}) {
    final hasCurrent = row.current != null;
    return HelpHover(
      'Reset or persist the current value, add a note, or delete this '
      'variable.',
      title: 'Variable actions',
      example: 'Persist: initial "" becomes the current "dev-token"',
      essential: true,
      child: PopupMenuButton<_RowAction>(
        key: Key('var.$index.menu'),
        tooltip: '', // the hover help above replaces the plain tooltip
        icon: Icon(Icons.more_vert, size: 18, color: Palette.textDim),
        onSelected: (a) {
          switch (a) {
            case _RowAction.reset:
              _resetRow(row);
              _changed();
            case _RowAction.persist:
              _persistRow(row);
              _changed();
            case _RowAction.description:
              _editDescription(row);
            case _RowAction.secret:
              _setSecret(row, !row.secret);
            case _RowAction.delete:
              _delete(row);
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: _RowAction.reset,
            enabled: hasCurrent,
            child: const HelpHover(
              'Clears the current value, so requests use the initial value '
              'again.',
              title: 'Reset',
              example: 'Current "dev-token" goes back to the initial value',
              child: Text('Reset'),
            ),
          ),
          PopupMenuItem(
            value: _RowAction.persist,
            enabled: hasCurrent,
            child: const HelpHover(
              'Copies the current value into the initial value (the shared, '
              'exported one) and clears the current value.',
              title: 'Persist',
              example: 'Initial "" becomes "dev-token"',
              child: Text('Persist'),
            ),
          ),
          if (showSecretItem)
            CheckedPopupMenuItem(
              value: _RowAction.secret,
              checked: row.secret,
              child: const HelpHover(
                'Hides the values in the editor, the console, docs and '
                'exports.',
                title: 'Secret',
                example: 'apiKey = ••••••••',
                child: Text('Secret'),
              ),
            ),
          const PopupMenuItem(
            value: _RowAction.description,
            child: HelpHover(
              'Adds a note about what this variable is for.',
              title: 'Description',
              example: 'Base URL of the staging API',
              child: Text('Description…'),
            ),
          ),
          const PopupMenuItem(
            value: _RowAction.delete,
            child: HelpHover(
              'Removes this variable.',
              title: 'Delete',
              example: 'baseUrl',
              child: Text('Delete'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens the Globals scope for editing.
Future<void> editGlobals(BuildContext context, AppState state) =>
    showDialog<void>(
      context: context,
      builder: (ctx) => AdaptiveDialog(
        title: ListenableBuilder(
          listenable: state,
          builder: (context, _) => Text('Globals (${state.globals.length})'),
        ),
        width: 820,
        height: 480,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _ScopeOrder(),
            const SizedBox(height: 6),
            Text(
              'Applies to every request in every collection. A variable of '
              'the same name in a higher scope wins.',
              style: TextStyle(fontSize: 12.5, color: Palette.textDim),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: VariablesEditor(
                rows: state.globals,
                onChanged: state.updateGlobals,
                valueHelp:
                    'Used by every request, unless a collection, environment, '
                    'data or script value of the same name wins.',
                overriddenBy: (row) => _globalOverride(state, row),
              ),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Done'),
          ),
        ],
      ),
    );

/// The higher scope (the active environment, else a collection) that also
/// defines [row]'s name, for the "Overridden by" note.
String? _globalOverride(AppState state, KV row) {
  bool defines(List<KV> vars) => vars.any((v) => v.enabled && v.key == row.key);
  final env = state.activeEnvironment;
  if (env != null && defines(env.variables)) {
    return 'the active environment "${env.name}"';
  }
  for (final c in state.collections) {
    if (defines(c.variables)) return 'the variables of collection "${c.name}"';
  }
  return null;
}

/// The scope order, lowest precedence first, with Globals highlighted.
class _ScopeOrder extends StatelessWidget {
  const _ScopeOrder();

  static const _scopes = [
    ('Globals', 'Variables for every request in every collection.'),
    ('Collection', 'Variables of the collection the request is saved in.'),
    ('Environment', 'Variables of the environment you selected.'),
    ('Data', 'The current row of the data file in the Runner.'),
    ('Local', 'Values a script sets for the current run only.'),
  ];

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: 12, color: Palette.textDim);
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('Lowest to highest precedence:', style: style),
        for (var i = 0; i < _scopes.length; i++) ...[
          if (i > 0) Text('<', style: style),
          HelpHover(
            _scopes[i].$2,
            title: _scopes[i].$1,
            example: 'Globals < collection < environment < data < local',
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: i == 0 ? Palette.accentSoft : null,
                border: Border.all(
                  color: i == 0 ? Palette.accent : Palette.border,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _scopes[i].$1,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: i == 0 ? FontWeight.w700 : FontWeight.w500,
                  color: i == 0 ? Palette.text : Palette.textDim,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
