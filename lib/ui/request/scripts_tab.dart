import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../help_tip.dart';
import '../adaptive.dart';

/// Pre-request and post-response (test) scripts of a request, run with
/// Postman's `pm` API: an editor per phase and a menu of snippets.
class ScriptsTab extends StatefulWidget {
  const ScriptsTab({super.key, required this.request, required this.onChanged});

  final RequestModel request;
  final VoidCallback onChanged;

  @override
  State<ScriptsTab> createState() => _ScriptsTabState();
}

class _ScriptsTabState extends State<ScriptsTab> {
  bool _post = false;
  late final _pre = TextEditingController(
    text: widget.request.preRequestScript,
  );
  late final _test = TextEditingController(text: widget.request.testScript);

  TextEditingController get _active => _post ? _test : _pre;

  @override
  void didUpdateWidget(ScriptsTab old) {
    super.didUpdateWidget(old);
    // The same tab can be handed another request (switching tabs).
    if (!identical(old.request, widget.request)) {
      _pre.text = widget.request.preRequestScript;
      _test.text = widget.request.testScript;
    }
  }

  @override
  void dispose() {
    _pre.dispose();
    _test.dispose();
    super.dispose();
  }

  void _changed(String v) {
    if (_post) {
      widget.request.testScript = v;
    } else {
      widget.request.preRequestScript = v;
    }
    widget.onChanged();
  }

  void _insert(ScriptSnippet s) {
    final c = _active;
    final text = c.text;
    final sel = c.selection.isValid
        ? c.selection
        : TextSelection.collapsed(offset: text.length);
    // A snippet goes on lines of its own.
    final before = text.substring(0, sel.start);
    final lead = before.isEmpty || before.endsWith('\n') ? '' : '\n';
    final after = text.substring(sel.end);
    final trail = after.isEmpty || after.startsWith('\n') ? '\n' : '\n\n';
    final insert = '$lead${s.code}$trail';
    c.value = TextEditingValue(
      text: before + insert + after,
      selection: TextSelection.collapsed(offset: sel.start + insert.length),
    );
    _changed(c.text);
  }

  @override
  Widget build(BuildContext context) {
    final engine = context.select<AppState, bool>((s) => s.scripts != null);
    final enabled = context.select<AppState, bool>(
      (s) => s.settings.scriptsEnabled,
    );
    final snippets = [
      for (final s in scriptSnippets)
        if (_post ? s.post : s.pre) s,
    ];
    // Short panes (a phone with the keyboard up) scroll, with the editor at
    // a usable height, instead of squeezing it to nothing.
    return LayoutBuilder(
      builder: (context, box) => box.maxHeight >= 300
          ? _content(engine, enabled, snippets)
          : SingleChildScrollView(
              child: SizedBox(
                height: 300,
                child: _content(engine, enabled, snippets),
              ),
            ),
    );
  }

  Widget _content(bool engine, bool enabled, List<ScriptSnippet> snippets) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              HelpHover(
                'Pre-request runs before the request is sent and can change '
                'it. Post-response runs on the response: tests, saving '
                'values, visualizing. Collection and folder scripts run '
                'first, in that order. A dot marks a phase with a script.',
                title: 'Script phase',
                example: 'pm.environment.set("ts", Date.now());',
                child: SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: false,
                      label: Text(
                        _marked('Pre-request', widget.request.preRequestScript),
                      ),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text(
                        _marked('Post-response', widget.request.testScript),
                      ),
                    ),
                  ],
                  selected: {_post},
                  onSelectionChanged: (s) => setState(() => _post = s.first),
                ),
              ),
              HelpHover(
                'Inserts a ready-made piece of script at the cursor.',
                title: 'Snippets',
                example: 'Status code is 200',
                child: PopupMenuButton<ScriptSnippet>(
                  key: const ValueKey('script-snippets'),
                  tooltip: '',
                  onSelected: _insert,
                  itemBuilder: (_) => [
                    for (final s in snippets)
                      PopupMenuItem(
                        value: s,
                        child: Text(
                          s.title,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                  ],
                  child: Container(
                    constraints: BoxConstraints(
                      minHeight: isTouch(context) ? minTouchTarget : 0,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.bolt, size: 16, color: Palette.accent),
                        const SizedBox(width: 4),
                        Text(
                          'Snippets',
                          style: TextStyle(fontSize: 13, color: Palette.accent),
                        ),
                        Icon(Icons.arrow_drop_down, color: Palette.accent),
                      ],
                    ),
                  ),
                ),
              ),
              const HelpTip(
                'JavaScript with Postman\'s pm API: variables, pm.request, '
                'pm.response, pm.test with pm.expect (Chai), pm.sendRequest, '
                'console.log, and require() for lodash, crypto-js, moment, '
                'uuid, chai, tv4 and ajv. Scripts can\'t touch files, and '
                'reach the network only through pm.sendRequest. They stop '
                'after the script timeout set in Settings.',
                title: 'Scripts',
                example:
                    'pm.test("ok", () => pm.response.to.have.status(200));',
              ),
            ],
          ),
          if (!engine || !enabled)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, size: 15, color: Palette.warning),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      !engine
                          ? 'Scripts are saved with the request but not run: '
                                'this build has no script engine.'
                          : 'Scripts are turned off in Settings: they are '
                                'saved but not run.',
                      style: TextStyle(fontSize: 12, color: Palette.textDim),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 10),
          Expanded(
            child: ScriptCodeEditor(
              key: ValueKey(_post),
              controller: _active,
              onChanged: _changed,
              hint: _post
                  ? 'pm.test("Status is 200", () => {\n'
                        '  pm.response.to.have.status(200);\n'
                        '});'
                  : 'pm.environment.set("now", Date.now());',
            ),
          ),
        ],
      ),
    );
  }

  static String _marked(String label, String script) =>
      script.trim().isEmpty ? label : '$label •';
}

/// A monospace code field with line numbers. Tab and Shift+Tab indent and
/// outdent by two spaces (every selected line when the selection spans
/// lines), and Enter keeps the indentation of the line above. Long lines
/// wrap; the gutter numbers the logical lines.
class ScriptCodeEditor extends StatefulWidget {
  const ScriptCodeEditor({
    super.key,
    required this.controller,
    required this.onChanged,
    this.hint,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String? hint;

  @override
  State<ScriptCodeEditor> createState() => _ScriptCodeEditorState();
}

const _indent = '  ';

class _IndentIntent extends Intent {
  const _IndentIntent({required this.outdent});
  final bool outdent;
}

class _ScriptCodeEditorState extends State<ScriptCodeEditor> {
  final _focus = FocusNode();
  final _scroll = ScrollController();

  static const _fontSize = 13.0;
  static const _height = 1.45;
  static const _style = TextStyle(
    fontFamily: 'monospace',
    fontSize: _fontSize,
    height: _height,
  );
  static const _strut = StrutStyle(
    fontFamily: 'monospace',
    fontSize: _fontSize,
    height: _height,
    forceStrutHeight: true,
  );

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_rebuild);
  }

  @override
  void didUpdateWidget(ScriptCodeEditor old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.removeListener(_rebuild);
      widget.controller.addListener(_rebuild);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_rebuild);
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _set(TextEditingValue v) {
    widget.controller.value = v;
    widget.onChanged(v.text);
  }

  /// Tab / Shift+Tab.
  void _shift(bool outdent) {
    final v = widget.controller.value;
    final text = v.text;
    var sel = v.selection;
    if (!sel.isValid) sel = TextSelection.collapsed(offset: text.length);
    final multiLine = text.substring(sel.start, sel.end).contains('\n');
    if (!outdent && !multiLine) {
      _set(
        TextEditingValue(
          text: text.replaceRange(sel.start, sel.end, _indent),
          selection: TextSelection.collapsed(
            offset: sel.start + _indent.length,
          ),
        ),
      );
      return;
    }
    // Indent or outdent every line the selection touches.
    final from = sel.start == 0 ? 0 : text.lastIndexOf('\n', sel.start - 1) + 1;
    var end = sel.end;
    if (multiLine && end > from && text[end - 1] == '\n') end--;
    final lineEnd = text.indexOf('\n', end);
    final to = lineEnd < 0 ? text.length : lineEnd;
    final lines = text.substring(from, to).split('\n');
    var firstDelta = 0;
    var total = 0;
    final out = <String>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (outdent) {
        final n = line.startsWith(_indent)
            ? 2
            : (line.startsWith(' ') || line.startsWith('\t') ? 1 : 0);
        out.add(line.substring(n));
        if (i == 0) firstDelta = -math.min(n, sel.start - from);
        total -= n;
      } else {
        out.add('$_indent$line');
        if (i == 0) firstDelta = _indent.length;
        total += _indent.length;
      }
    }
    final start = math.max(from, sel.start + firstDelta);
    _set(
      TextEditingValue(
        text: text.replaceRange(from, to, out.join('\n')),
        selection: sel.isCollapsed
            ? TextSelection.collapsed(offset: start)
            : TextSelection(
                baseOffset: start,
                extentOffset: math.max(start, sel.end + total),
              ),
      ),
    );
  }

  // Rows per line text at [_rowsWidth]: a keystroke re-measures one line.
  final Map<String, int> _rowCache = {};
  double _rowsWidth = -1;
  TextScaler? _rowsScaler;
  double _charWidth = 0;
  static final _plainAscii = RegExp(r'^[ -~]*$');

  /// Visual rows of each logical line at [width], for the gutter.
  List<int> _rows(String text, double width, TextScaler scaler) {
    final lines = text.split('\n');
    final rows = List<int>.filled(lines.length, 1);
    if (width <= 0) return rows;
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      strutStyle: _strut,
    );
    if (width != _rowsWidth || scaler != _rowsScaler) {
      _rowCache.clear();
      _rowsWidth = width;
      _rowsScaler = scaler;
      painter
        ..text = const TextSpan(text: 'MMMMMMMMMMMMMMMMMMMM', style: _style)
        ..layout();
      _charWidth = painter.width / 20;
    }
    if (_rowCache.length > 4000) _rowCache.clear();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      // Plain ASCII in a monospace font: the width is known without layout.
      if (line.length * _charWidth <= width && _plainAscii.hasMatch(line)) {
        continue;
      }
      rows[i] = _rowCache[line] ??= () {
        painter
          ..text = TextSpan(text: line, style: _style)
          ..layout(maxWidth: width);
        return math.max(1, painter.computeLineMetrics().length);
      }();
    }
    painter.dispose();
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final lineHeight = scaler.scale(_fontSize) * _height;
    final text = widget.controller.text;
    final digits = math.max(2, '${'\n'.allMatches(text).length + 1}'.length);
    final gutter = 12.0 + digits * scaler.scale(_fontSize) * 0.62;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Palette.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Palette.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: LayoutBuilder(
          builder: (context, box) {
            // The field's width, less the room RenderEditable keeps for the
            // caret at the end of a line.
            final fieldWidth = math.max(0.0, box.maxWidth - gutter - 20);
            final rows = _rows(text, fieldWidth - 3, scaler);
            final total = rows.fold<int>(0, (a, b) => a + b);
            return GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _focus.requestFocus,
              child: Scrollbar(
                controller: _scroll,
                child: SingleChildScrollView(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: math.max(0.0, box.maxHeight - 20),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ExcludeSemantics(
                          child: CustomPaint(
                            size: Size(gutter, total * lineHeight),
                            painter: _GutterPainter(
                              rows: rows,
                              lineHeight: lineHeight,
                              style: _style.copyWith(color: Palette.textDim),
                              scaler: scaler,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: _field()),
                        const SizedBox(width: 12),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _field() => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.tab): _IndentIntent(outdent: false),
      SingleActivator(LogicalKeyboardKey.tab, shift: true): _IndentIntent(
        outdent: true,
      ),
    },
    child: Actions(
      actions: {
        _IndentIntent: CallbackAction<_IndentIntent>(
          onInvoke: (i) {
            _shift(i.outdent);
            return null;
          },
        ),
      },
      child: TextField(
        controller: widget.controller,
        focusNode: _focus,
        maxLines: null,
        keyboardType: TextInputType.multiline,
        autocorrect: false,
        enableSuggestions: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        style: _style.copyWith(color: Palette.text),
        strutStyle: _strut,
        inputFormatters: [_AutoIndent()],
        // No theme borders or fill: the editor's frame is the box.
        decoration: InputDecoration(
          isCollapsed: true,
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          contentPadding: EdgeInsets.zero,
          hintText: widget.hint,
          hintStyle: _style.copyWith(color: Palette.textDim),
          hintMaxLines: 6,
        ),
        onChanged: widget.onChanged,
      ),
    ),
  );
}

class _GutterPainter extends CustomPainter {
  _GutterPainter({
    required this.rows,
    required this.lineHeight,
    required this.style,
    required this.scaler,
  });

  final List<int> rows;
  final double lineHeight;
  final TextStyle style;
  final TextScaler scaler;

  @override
  void paint(Canvas canvas, Size size) {
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.right,
      textScaler: scaler,
    );
    final width = math.max(0.0, size.width - 4);
    var y = 0.0;
    for (var i = 0; i < rows.length; i++) {
      painter
        ..text = TextSpan(text: '${i + 1}', style: style)
        ..layout(minWidth: width, maxWidth: width);
      painter.paint(canvas, Offset(0, y + (lineHeight - painter.height) / 2));
      y += rows[i] * lineHeight;
    }
    painter.dispose();
  }

  @override
  bool shouldRepaint(_GutterPainter old) =>
      old.lineHeight != lineHeight ||
      old.style != style ||
      !listEquals(old.rows, rows);
}

/// Enter keeps the indentation of the line above, one level deeper after
/// an opening bracket.
class _AutoIndent extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final sel = newValue.selection;
    if (!sel.isCollapsed ||
        newValue.composing.isValid ||
        newValue.text.length != oldValue.text.length + 1 ||
        sel.start < 1 ||
        newValue.text[sel.start - 1] != '\n') {
      return newValue;
    }
    final before = newValue.text.substring(0, sel.start - 1);
    final line = before.substring(before.lastIndexOf('\n') + 1);
    var pad = RegExp(r'^[ \t]*').stringMatch(line) ?? '';
    final trimmed = line.trimRight();
    if (trimmed.endsWith('{') ||
        trimmed.endsWith('(') ||
        trimmed.endsWith('[')) {
      pad += _indent;
    }
    if (pad.isEmpty) return newValue;
    return TextEditingValue(
      text: newValue.text.replaceRange(sel.start, sel.start, pad),
      selection: TextSelection.collapsed(offset: sel.start + pad.length),
    );
  }
}

/// A ready-made piece of script for the Snippets menu.
class ScriptSnippet {
  const ScriptSnippet(
    this.title,
    this.code, {
    this.pre = true,
    this.post = true,
  });

  final String title;
  final String code;

  /// Offered in the pre-request / post-response editor.
  final bool pre;
  final bool post;
}

/// Postman's common snippets.
const scriptSnippets = <ScriptSnippet>[
  ScriptSnippet(
    'Status code is 200',
    'pm.test("Status code is 200", function () {\n'
        '  pm.response.to.have.status(200);\n'
        '});',
    pre: false,
  ),
  ScriptSnippet(
    'Status code is 201 or 202',
    'pm.test("Successful POST request", function () {\n'
        '  pm.expect(pm.response.code).to.be.oneOf([201, 202]);\n'
        '});',
    pre: false,
  ),
  ScriptSnippet(
    'Response time is below 200 ms',
    'pm.test("Response time is less than 200ms", function () {\n'
        '  pm.expect(pm.response.responseTime).to.be.below(200);\n'
        '});',
    pre: false,
  ),
  ScriptSnippet(
    'Check a JSON value',
    'pm.test("Check a JSON value", function () {\n'
        '  const json = pm.response.json();\n'
        '  pm.expect(json.value).to.eql(100);\n'
        '});',
    pre: false,
  ),
  ScriptSnippet(
    'Body contains a string',
    'pm.test("Body contains a string", function () {\n'
        '  pm.expect(pm.response.text()).to.include("text_to_find");\n'
        '});',
    pre: false,
  ),
  ScriptSnippet(
    'Body equals a string',
    'pm.test("Body is correct", function () {\n'
        '  pm.response.to.have.body("expected_body");\n'
        '});',
    pre: false,
  ),
  ScriptSnippet(
    'Content-Type header is present',
    'pm.test("Content-Type is present", function () {\n'
        '  pm.response.to.have.header("Content-Type");\n'
        '});',
    pre: false,
  ),
  ScriptSnippet(
    'Validate the JSON schema',
    'const schema = {\n'
        '  type: "object",\n'
        '  required: ["id"],\n'
        '  properties: { id: { type: "number" } },\n'
        '};\n'
        'pm.test("Schema is valid", function () {\n'
        '  pm.response.to.have.jsonSchema(schema);\n'
        '});',
    pre: false,
  ),
  ScriptSnippet(
    'Save a value from the response',
    'const json = pm.response.json();\n'
        'pm.environment.set("token", json.token);',
    pre: false,
  ),
  ScriptSnippet(
    'Visualize the response',
    'const template = `\n'
        '<table>\n'
        '  <tr><th>Name</th></tr>\n'
        '  {{#each items}}<tr><td>{{name}}</td></tr>{{/each}}\n'
        '</table>`;\n'
        'pm.visualizer.set(template, { items: pm.response.json() });',
    pre: false,
  ),
  ScriptSnippet(
    'Set an environment variable',
    'pm.environment.set("variable_key", "variable_value");',
  ),
  ScriptSnippet(
    'Get an environment variable',
    'pm.environment.get("variable_key");',
  ),
  ScriptSnippet(
    'Set a collection variable',
    'pm.collectionVariables.set("variable_key", "variable_value");',
  ),
  ScriptSnippet(
    'Set a global variable',
    'pm.globals.set("variable_key", "variable_value");',
  ),
  ScriptSnippet('Get a variable', 'pm.variables.get("variable_key");'),
  ScriptSnippet(
    'Clear an environment variable',
    'pm.environment.unset("variable_key");',
  ),
  ScriptSnippet(
    'Add a request header',
    'pm.request.headers.upsert({\n'
        '  key: "X-Request-Id",\n'
        '  value: pm.variables.replaceIn("{{\$guid}}"),\n'
        '});',
    post: false,
  ),
  ScriptSnippet(
    'Send a request',
    'pm.sendRequest("https://postman-echo.com/get", function (err, response) {\n'
        '  if (err) {\n'
        '    console.error(err);\n'
        '    return;\n'
        '  }\n'
        '  console.log(response.json());\n'
        '});',
  ),
  ScriptSnippet(
    'Send a request and wait for it',
    'const response = await pm.sendRequest({\n'
        '  url: "https://postman-echo.com/post",\n'
        '  method: "POST",\n'
        '  header: { "Content-Type": "application/json" },\n'
        '  body: { mode: "raw", raw: JSON.stringify({ hello: "world" }) },\n'
        '});\n'
        'console.log(response.code, response.json());',
  ),
  ScriptSnippet(
    'Skip this request',
    'pm.execution.skipRequest();',
    post: false,
  ),
  ScriptSnippet(
    'Set the next request (runner)',
    'pm.execution.setNextRequest("request_name");',
  ),
  ScriptSnippet('Log to the console', 'console.log(pm.info.requestName);'),
];
