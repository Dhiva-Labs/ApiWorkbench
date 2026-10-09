import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme.dart';

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
  });

  final List<KV> rows;
  final VoidCallback onChanged;
  final String keyHint;
  final String valueHint;
  final String addLabel;

  /// Multipart form-data: each row can be text or a file to upload.
  final bool allowFiles;

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

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final row in widget.rows) _buildRow(row),
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

  Widget _typeToggle(KV row) => PopupMenuButton<bool>(
    tooltip: 'Text or file',
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
      PopupMenuItem(value: false, child: Text('Text')),
      PopupMenuItem(value: true, child: Text('File')),
    ],
    child: Container(
      height: 36,
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

  Widget _buildRow(KV row) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Checkbox(
            value: row.enabled,
            visualDensity: VisualDensity.compact,
            onChanged: (v) {
              setState(() => row.enabled = v ?? true);
              widget.onChanged();
            },
          ),
          Expanded(
            flex: 2,
            child: TextField(
              controller: _ctrl(_keyCtrls, row, row.key),
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(hintText: widget.keyHint),
              onChanged: (v) {
                row.key = v;
                widget.onChanged();
              },
            ),
          ),
          const SizedBox(width: 8),
          if (widget.allowFiles) ...[
            _typeToggle(row),
            const SizedBox(width: 6),
          ],
          Expanded(
            flex: 3,
            child: TextField(
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
                        tooltip: 'Choose file',
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
            ),
          ),
          IconButton(
            tooltip: 'Remove',
            icon: Icon(Icons.close, size: 16, color: Palette.textDim),
            onPressed: () {
              setState(() {
                _keyCtrls.remove(row)?.dispose();
                _valCtrls.remove(row)?.dispose();
                widget.rows.remove(row);
              });
              widget.onChanged();
            },
          ),
        ],
      ),
    );
  }
}
