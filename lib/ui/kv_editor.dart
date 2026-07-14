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
  });

  final List<KV> rows;
  final VoidCallback onChanged;
  final String keyHint;
  final String valueHint;
  final String addLabel;

  @override
  State<KVEditor> createState() => _KVEditorState();
}

class _KVEditorState extends State<KVEditor> {
  final Map<KV, TextEditingController> _keyCtrls = {};
  final Map<KV, TextEditingController> _valCtrls = {};

  TextEditingController _ctrl(
      Map<KV, TextEditingController> map, KV row, String text) {
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
          Expanded(
            flex: 3,
            child: TextField(
              controller: _ctrl(_valCtrls, row, row.value),
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(hintText: widget.valueHint),
              onChanged: (v) {
                row.value = v;
                widget.onChanged();
              },
            ),
          ),
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.close, size: 16, color: Palette.textDim),
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
