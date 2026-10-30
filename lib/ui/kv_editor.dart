import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../models/models.dart';
import '../theme.dart';
import 'adaptive.dart';
import 'help_tip.dart';

/// Editable key/value table used for params, headers, form fields and
/// environment variables.
///
/// A "Bulk edit" toggle switches to a text view with one `key: value` row per
/// line (see [kvToBulkText]); switching back keeps each row's description,
/// secret flag and current value when its key is still there.
class KVEditor extends StatefulWidget {
  const KVEditor({
    super.key,
    required this.rows,
    required this.onChanged,
    this.keyHint = 'Key',
    this.valueHint = 'Value',
    this.addLabel = 'Add row',
    this.allowFiles = false,
    this.keyHelp,
    this.valueHelp,
    this.keyExample,
    this.valueExample,
    this.bulkEdit = true,
    this.showDescription = false,
    this.descriptionHint = 'Description',
    this.descriptionHelp,
    this.scrollable = true,
  });

  final List<KV> rows;
  final VoidCallback onChanged;
  final String keyHint;
  final String valueHint;
  final String addLabel;

  /// Multipart form-data: each row can be text or a file to upload.
  final bool allowFiles;

  /// Hover help for the key and value columns; when either is set, a small
  /// column header with ⓘ icons is shown above the rows.
  final String? keyHelp;
  final String? valueHelp;
  final String? keyExample;
  final String? valueExample;

  /// Offers the "Bulk edit" toggle (a text view, one row per line).
  final bool bulkEdit;

  /// Adds a description field to every row.
  final bool showDescription;
  final String descriptionHint;
  final String? descriptionHelp;

  /// False renders the rows as a plain column to place inside another
  /// scroll view; the default is a list that scrolls itself.
  final bool scrollable;

  @override
  State<KVEditor> createState() => _KVEditorState();
}

class _KVEditorState extends State<KVEditor> {
  final Map<KV, TextEditingController> _keyCtrls = {};
  final Map<KV, TextEditingController> _valCtrls = {};
  final Map<KV, TextEditingController> _descCtrls = {};

  /// The bulk text view is showing, with its text in [_bulkCtrl].
  bool _bulk = false;
  TextEditingController? _bulkCtrl;

  /// The rows as they were when bulk edit opened. Every parse matches keys
  /// against these, so a key that passes through half-typed states while
  /// editing does not lose its description.
  List<KV> _snapshot = const [];

  TextEditingController _ctrl(
    Map<KV, TextEditingController> map,
    KV row,
    String text,
  ) {
    return map.putIfAbsent(row, () => TextEditingController(text: text));
  }

  @override
  void didUpdateWidget(KVEditor old) {
    super.didUpdateWidget(old);
    if (_bulk && !identical(old.rows, widget.rows)) _enterBulk(keepMode: true);
  }

  @override
  void dispose() {
    for (final m in [_keyCtrls, _valCtrls, _descCtrls]) {
      for (final c in m.values) {
        c.dispose();
      }
    }
    _bulkCtrl?.dispose();
    super.dispose();
  }

  /// Width of a checkbox or icon button at the current density (48 on
  /// touch platforms, 40 with the compact desktop density).
  double get _control =>
      48 + Theme.of(context).visualDensity.baseSizeAdjustment.dx;

  /// Disposes the row controllers once the frame that drops their fields is
  /// done; the rows are about to be replaced by new objects.
  void _retireRowControllers() {
    final old = [
      ..._keyCtrls.values,
      ..._valCtrls.values,
      ..._descCtrls.values,
    ];
    _keyCtrls.clear();
    _valCtrls.clear();
    _descCtrls.clear();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      for (final c in old) {
        c.dispose();
      }
    });
  }

  void _enterBulk({bool keepMode = false}) {
    _retireRowControllers();
    _snapshot = List.of(widget.rows);
    final text = kvToBulkText(widget.rows, allowFiles: widget.allowFiles);
    if (_bulkCtrl == null) {
      _bulkCtrl = TextEditingController(text: text);
    } else {
      _bulkCtrl!.text = text;
    }
    if (!keepMode) setState(() => _bulk = true);
  }

  void _leaveBulk() {
    // The rows were updated as the text changed; apply once more in case
    // the last edit has not been parsed yet.
    _applyBulk(_bulkCtrl?.text ?? '');
    _retireRowControllers();
    setState(() => _bulk = false);
  }

  /// Parses the bulk text into the rows and reports a change, but only when
  /// the rows really differ, so opening bulk edit and closing it again leaves
  /// the request as it was.
  void _applyBulk(String text) {
    final parsed = kvFromBulkText(
      text,
      previous: _snapshot,
      allowFiles: widget.allowFiles,
    );
    if (_sameRows(widget.rows, parsed)) return;
    widget.rows
      ..clear()
      ..addAll(parsed);
    widget.onChanged();
  }

  static bool _sameRows(List<KV> a, List<KV> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (jsonEncode(a[i].toJson()) != jsonEncode(b[i].toJson())) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      // File rows need room for the Text/File switch and the file picker
      // button, and a description needs its own column, so on narrow
      // screens the value (and description) go on their own lines.
      final stacked =
          (widget.allowFiles && box.maxWidth < 480) ||
          (widget.showDescription && box.maxWidth < 640);
      final children = <Widget>[
        if (widget.bulkEdit) _toolbar(),
        if (_bulk)
          ..._bulkView()
        else ...[
          if (widget.rows.isNotEmpty &&
              (widget.keyHelp != null || widget.valueHelp != null))
            _header(stacked),
          for (final row in widget.rows) _buildRow(row, stacked),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () {
                setState(() => widget.rows.add(KV()));
                widget.onChanged();
              },
              icon: const Icon(Icons.add, size: 18),
              label: Text(widget.addLabel),
            ),
          ),
        ],
      ];
      if (!widget.scrollable) {
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        );
      }
      return ListView(padding: const EdgeInsets.all(12), children: children);
    },
  );

  /// The Bulk edit / Key-value edit switch, right-aligned above the rows.
  Widget _toolbar() => Align(
    alignment: Alignment.centerRight,
    child: HelpHover(
      _bulk
          ? 'Go back to the table. Your lines are turned into rows again, '
                'and rows keep their descriptions when the key is unchanged.'
          : 'Edit every row as text, one per line, which is quick for pasting '
                'many rows. Start a line with // to turn that row off.',
      title: _bulk ? 'Key-value edit' : 'Bulk edit',
      example: _bulk ? null : 'Accept: application/json\n// X-Debug: 1',
      child: TextButton.icon(
        onPressed: _bulk ? _leaveBulk : _enterBulk,
        icon: Icon(
          _bulk ? Icons.table_rows_outlined : Icons.edit_note,
          size: 18,
        ),
        label: Text(_bulk ? 'Key-value edit' : 'Bulk edit'),
      ),
    ),
  );

  List<Widget> _bulkView() => [
    TextField(
      key: const ValueKey('kv-bulk-text'),
      controller: _bulkCtrl,
      minLines: 8,
      maxLines: null,
      keyboardType: TextInputType.multiline,
      autocorrect: false,
      enableSuggestions: false,
      style: const TextStyle(
        fontSize: 13,
        fontFamily: 'monospace',
        height: 1.4,
      ),
      decoration: InputDecoration(
        hintText: widget.allowFiles
            ? 'name: Ada\n// disabled: yes\navatar: @/path/to/file'
            : '${widget.keyHint}: ${widget.valueHint}',
        alignLabelWithHint: true,
      ),
      onChanged: _applyBulk,
    ),
    const SizedBox(height: 8),
    Text(
      widget.allowFiles
          ? 'One row per line as key: value. Start a line with // to turn it '
                'off. Write a file as key: @/path/to/file.'
          : 'One row per line as key: value. Start a line with // to turn it '
                'off.',
      style: TextStyle(fontSize: 12, color: Palette.textDim),
    ),
  ];

  /// Column labels lined up with the row fields: checkbox, key, value, remove.
  Widget _header(bool stacked) {
    final style = TextStyle(
      fontSize: 11.5,
      fontWeight: FontWeight.w600,
      color: Palette.textDim,
    );
    Widget label(String text, String? help, String? example) => help == null
        ? Text(text, style: style, overflow: TextOverflow.ellipsis)
        : LabelWithHelp(text, help, style: style, example: example);
    final desc = widget.showDescription
        ? label(widget.descriptionHint, widget.descriptionHelp, null)
        : null;
    if (stacked) {
      return Padding(
        padding: EdgeInsets.only(left: _control, bottom: 4),
        child: Wrap(
          spacing: 16,
          children: [
            label(widget.keyHint, widget.keyHelp, widget.keyExample),
            label(widget.valueHint, widget.valueHelp, widget.valueExample),
            ?desc,
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(width: _control),
          Expanded(
            flex: 2,
            child: label(widget.keyHint, widget.keyHelp, widget.keyExample),
          ),
          const SizedBox(width: 8),
          if (widget.allowFiles) const SizedBox(width: 64),
          Expanded(
            flex: 3,
            child: label(
              widget.valueHint,
              widget.valueHelp,
              widget.valueExample,
            ),
          ),
          if (desc != null) ...[
            const SizedBox(width: 8),
            Expanded(flex: 2, child: desc),
          ],
          SizedBox(width: _control),
        ],
      ),
    );
  }

  Widget _typeToggle(KV row) => PopupMenuButton<bool>(
    tooltip: 'Switch between a text value and a file upload',
    initialValue: row.isFile,
    onSelected: (file) {
      if (file == row.isFile) return;
      setState(() {
        row.isFile = file;
        row.value = '';
        _valCtrls[row]?.text = '';
      });
      widget.onChanged();
    },
    itemBuilder: (_) => const [
      PopupMenuItem(
        value: false,
        child: HelpHover(
          'Send this field as a plain text value.',
          title: 'Text field',
          example: 'name = Ada',
          child: Text('Text'),
        ),
      ),
      PopupMenuItem(
        value: true,
        child: HelpHover(
          'Upload a file from this device in this field, as an upload form '
          'does.',
          title: 'File field',
          example: 'avatar = /home/me/photo.png',
          child: Text('File'),
        ),
      ),
    ],
    child: Container(
      height: isTouch(context) ? minTouchTarget : 36,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border.all(color: Palette.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            row.isFile ? 'File' : 'Text',
            style: TextStyle(fontSize: 12, color: Palette.textDim),
          ),
          Icon(Icons.arrow_drop_down, size: 16, color: Palette.textDim),
        ],
      ),
    ),
  );

  Future<void> _pickFile(KV row) async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Choose a file to upload',
    );
    final path = picked?.files.singleOrNull?.path;
    if (path == null || !mounted) return;
    setState(() {
      row.value = path;
      _valCtrls[row]?.text = path;
    });
    widget.onChanged();
  }

  Widget _buildRow(KV row, bool stacked) {
    final checkbox = HelpHover(
      'Ticked rows are used. Untick to switch a row off without '
      'deleting it.',
      title: row.enabled ? 'On' : 'Off',
      child: Checkbox(
        value: row.enabled,
        onChanged: (v) {
          setState(() => row.enabled = v ?? true);
          widget.onChanged();
        },
      ),
    );
    final key = TextField(
      controller: _ctrl(_keyCtrls, row, row.key),
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(hintText: widget.keyHint),
      onChanged: (v) {
        row.key = v;
        widget.onChanged();
      },
    );
    final value = TextField(
      controller: _ctrl(_valCtrls, row, row.value),
      style: TextStyle(
        fontSize: 13,
        fontFamily: row.isFile ? 'monospace' : null,
      ),
      decoration: InputDecoration(
        hintText: row.isFile ? 'File to upload' : widget.valueHint,
        prefixIcon: row.isFile
            ? Icon(Icons.attach_file, size: 16, color: Palette.textDim)
            : null,
        prefixIconConstraints: const BoxConstraints(minWidth: 30),
        suffixIcon: row.isFile
            ? IconButton(
                tooltip: 'Choose a file to upload',
                icon: Icon(
                  Icons.folder_open_outlined,
                  size: 17,
                  color: Palette.accent,
                ),
                onPressed: () => _pickFile(row),
              )
            : null,
      ),
      onChanged: (v) {
        row.value = v;
        widget.onChanged();
      },
    );
    final description = widget.showDescription
        ? TextField(
            controller: _ctrl(_descCtrls, row, row.description),
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(hintText: widget.descriptionHint),
            onChanged: (v) {
              row.description = v;
              widget.onChanged();
            },
          )
        : null;
    final remove = IconButton(
      tooltip: 'Remove row',
      icon: Icon(Icons.close, size: 16, color: Palette.textDim),
      onPressed: () {
        setState(() {
          _keyCtrls.remove(row)?.dispose();
          _valCtrls.remove(row)?.dispose();
          _descCtrls.remove(row)?.dispose();
          widget.rows.remove(row);
        });
        widget.onChanged();
      },
    );
    if (stacked) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          children: [
            Row(
              children: [
                checkbox,
                Expanded(child: key),
                const SizedBox(width: 8),
                _typeToggle(row),
                remove,
              ],
            ),
            const SizedBox(height: 6),
            Padding(
              padding: EdgeInsets.only(left: _control, right: _control),
              child: value,
            ),
            if (description != null) ...[
              const SizedBox(height: 6),
              Padding(
                padding: EdgeInsets.only(left: _control, right: _control),
                child: description,
              ),
            ],
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          checkbox,
          Expanded(flex: 2, child: key),
          const SizedBox(width: 8),
          if (widget.allowFiles) ...[
            _typeToggle(row),
            const SizedBox(width: 6),
          ],
          Expanded(flex: 3, child: value),
          if (description != null) ...[
            const SizedBox(width: 8),
            Expanded(flex: 2, child: description),
          ],
          remove,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bulk edit text format
//
//   Accept: application/json        an enabled row
//   // X-Debug: 1                   a disabled row
//   avatar: @/path/to/file          a file row (multipart form-data)
//
// A backslash escapes what the line format would otherwise misread: `\:` in a
// key, `\n` and `\r` for line breaks, `\\` for a backslash that precedes
// another escape, `\//` for a key that starts with //, `\@` for a text value
// that starts with @, and `\ ` for a key's leading or trailing space.
// ---------------------------------------------------------------------------

/// What may follow a backslash to form an escape, and what it stands for.
const _bulkEscapes = {
  r'\': r'\',
  'n': '\n',
  'r': '\r',
  ':': ':',
  '/': '/',
  ' ': ' ',
  '\t': '\t',
  '@': '@',
};

bool _isBlank(String c) => c == ' ' || c == '\t';

String _encodeBulk(String s, {required bool isKey, bool escapeAt = false}) {
  var lead = 0;
  while (lead < s.length && _isBlank(s[lead])) {
    lead++;
  }
  var trail = 0;
  while (trail < s.length - lead && _isBlank(s[s.length - 1 - trail])) {
    trail++;
  }
  final tokens = <String>[];
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == r'\') {
      tokens.add(c);
    } else if (c == '\n') {
      tokens.add(r'\n');
    } else if (c == '\r') {
      tokens.add(r'\r');
    } else if (isKey && c == ':') {
      tokens.add(r'\:');
    } else if (isKey && _isBlank(c) && (i < lead || i >= s.length - trail)) {
      tokens.add('\\$c');
    } else if (isKey && i == 0 && s.startsWith('//')) {
      tokens.add(r'\/');
    } else if (escapeAt && i == 0 && c == '@') {
      tokens.add(r'\@');
    } else {
      tokens.add(c);
    }
  }
  // A literal backslash that would join the next character into an escape
  // is doubled. A key is followed by the `:` separator.
  for (var t = 0; t < tokens.length; t++) {
    if (tokens[t] != r'\') continue;
    final next = t + 1 < tokens.length ? tokens[t + 1] : (isKey ? ':' : null);
    if (next != null && _bulkEscapes.containsKey(next[0])) tokens[t] = r'\\';
  }
  return tokens.join();
}

String _decodeBulk(String s) {
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    final mapped = c == r'\' && i + 1 < s.length
        ? _bulkEscapes[s[i + 1]]
        : null;
    if (mapped != null) {
      b.write(mapped);
      i++;
    } else {
      b.write(c);
    }
  }
  return b.toString();
}

/// The bulk-edit text for [rows]: one `key: value` line per row, `// ` in
/// front of disabled rows, and `key: @path` for file rows when [allowFiles].
String kvToBulkText(List<KV> rows, {bool allowFiles = false}) {
  final lines = <String>[];
  for (final r in rows) {
    final key = _encodeBulk(r.key, isKey: true);
    final value = allowFiles && r.isFile
        ? '@${_encodeBulk(r.value, isKey: false)}'
        : _encodeBulk(r.value, isKey: false, escapeAt: allowFiles);
    lines.add(
      '${r.enabled ? '' : '// '}$key:${value.isEmpty ? '' : ' $value'}',
    );
  }
  return lines.join('\n');
}

/// Parses bulk-edit [text] back into rows. Blank lines are skipped, `//`
/// disables a row and, with [allowFiles], a value starting with `@` is a file
/// row. Each row whose key matches a row of [previous] (in order, so repeated
/// keys pair up) keeps that row's description, secret flag and current value.
List<KV> kvFromBulkText(
  String text, {
  List<KV> previous = const [],
  bool allowFiles = false,
}) {
  final pool = List<KV>.of(previous);
  final out = <KV>[];
  for (final raw in text.split(RegExp(r'\r\n|\r|\n'))) {
    var line = raw.trimLeft();
    if (line.trim().isEmpty) continue;
    var enabled = true;
    if (line.startsWith('//')) {
      enabled = false;
      line = line.substring(2);
      if (line.startsWith(' ')) line = line.substring(1);
    }
    // The key runs to the first colon that is not escaped.
    final chars = <String>[];
    final escaped = <bool>[];
    var i = 0;
    var colon = -1;
    while (i < line.length) {
      final c = line[i];
      if (c == r'\' && i + 1 < line.length) {
        final mapped = _bulkEscapes[line[i + 1]];
        if (mapped != null) {
          chars.add(mapped);
          escaped.add(true);
          i += 2;
          continue;
        }
      }
      if (c == ':') {
        colon = i;
        break;
      }
      chars.add(c);
      escaped.add(false);
      i++;
    }
    var start = 0;
    while (start < chars.length && !escaped[start] && _isBlank(chars[start])) {
      start++;
    }
    var end = chars.length;
    while (end > start && !escaped[end - 1] && _isBlank(chars[end - 1])) {
      end--;
    }
    final key = chars.sublist(start, end).join();

    var rest = colon < 0 ? '' : line.substring(colon + 1);
    if (rest.startsWith(' ')) rest = rest.substring(1);
    final isFile = allowFiles && rest.startsWith('@');
    final value = _decodeBulk(isFile ? rest.substring(1) : rest);

    final at = pool.indexWhere((k) => k.key == key);
    final prev = at < 0 ? null : pool.removeAt(at);
    out.add(
      KV(
        key: key,
        value: value,
        enabled: enabled,
        isFile: allowFiles ? isFile : (prev?.isFile ?? false),
        secret: prev?.secret ?? false,
        current: prev?.current,
        description: prev?.description ?? '',
      ),
    );
  }
  return out;
}
