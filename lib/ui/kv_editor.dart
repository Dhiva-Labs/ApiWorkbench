import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme.dart';
import 'adaptive.dart';
import 'help_tip.dart';

/// Editable key/value table used for params, headers, form fields and
/// environment variables.
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

  @override
  State<KVEditor> createState() => _KVEditorState();
}

class _KVEditorState extends State<KVEditor> {
  final Map<KV, TextEditingController> _keyCtrls = {};
  final Map<KV, TextEditingController> _valCtrls = {};

  TextEditingController _ctrl(
    Map<KV, TextEditingController> map,
    KV row,
    String text,
  ) {
    return map.putIfAbsent(row, () => TextEditingController(text: text));
  }

  @override
  void dispose() {
    for (final c in _keyCtrls.values) {
      c.dispose();
    }
    for (final c in _valCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Width of a checkbox or icon button at the current density (48 on
  /// touch platforms, 40 with the compact desktop density).
  double get _control =>
      48 + Theme.of(context).visualDensity.baseSizeAdjustment.dx;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      // File rows need room for the Text/File switch and the file picker
      // button, so on narrow screens the value goes on its own line.
      final stacked = widget.allowFiles && box.maxWidth < 480;
      return _list(stacked);
    },
  );

  Widget _list(bool stacked) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
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
    );
  }

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
    if (stacked) {
      return Padding(
        padding: EdgeInsets.only(left: _control, bottom: 4),
        child: Wrap(
          spacing: 16,
          children: [
            label(widget.keyHint, widget.keyHelp, widget.keyExample),
            label(widget.valueHint, widget.valueHelp, widget.valueExample),
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
    final remove = IconButton(
      tooltip: 'Remove row',
      icon: Icon(Icons.close, size: 16, color: Palette.textDim),
      onPressed: () {
        setState(() {
          _keyCtrls.remove(row)?.dispose();
          _valCtrls.remove(row)?.dispose();
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
          remove,
        ],
      ),
    );
  }
}
