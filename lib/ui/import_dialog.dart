import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/postman_import.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'adaptive.dart';
import 'help_tip.dart';

/// Import Postman collections (v1, v2.0, v2.1), environments, globals and
/// data exports, or an ApiWorkbench workspace, from files or pasted JSON.
/// Shows what will be added, and what could not be carried over, before
/// anything changes.
///
/// With [collectionId] the requests are added to that existing collection
/// (under [folder], when given) instead of creating new collections; the
/// user can still change the destination in the dialog.
Future<void> showImportDialog(
  BuildContext context, {
  String? collectionId,
  String folder = '',
}) => showDialog<void>(
  context: context,
  builder: (_) => _ImportDialog(collectionId: collectionId, folder: folder),
);

class _ImportDialog extends StatefulWidget {
  const _ImportDialog({this.collectionId, this.folder = ''});

  final String? collectionId;
  final String folder;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _paste = TextEditingController();
  ImportReport? _report;
  final _sources = <String>[];
  final _errors = <String>[];
  bool _busy = false;

  /// Destination: null creates new collections; otherwise an existing id.
  late String? _target = widget.collectionId;

  /// Folder inside the destination (only while it is the preset one).
  late String _folder = widget.folder;
  bool? _group;

  @override
  void dispose() {
    _paste.dispose();
    super.dispose();
  }

  void _add(String label, String text) {
    try {
      _report = importApiFile(text, into: _report);
      _sources.add(label);
    } on FormatException catch (e) {
      _errors.add('$label: ${e.message}');
    } catch (e) {
      _errors.add('$label: could not be read ($e).');
    }
  }

  Future<void> _chooseFiles() async {
    setState(() => _busy = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
        dialogTitle: 'Import Postman or ApiWorkbench files',
        type: FileType.custom,
        allowedExtensions: ['json'],
        allowMultiple: true,
        withData: true,
      );
      for (final f in picked?.files ?? <PlatformFile>[]) {
        final bytes =
            f.bytes ??
            (f.path != null ? await File(f.path!).readAsBytes() : null);
        if (bytes == null) {
          _errors.add('${f.name}: could not be read.');
          continue;
        }
        _add(f.name, utf8.decode(bytes, allowMalformed: true));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _addPasted() {
    final text = _paste.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _add('Pasted JSON', text);
      _paste.clear();
    });
  }

  void _import() {
    final r = _report;
    if (r == null || r.isEmpty) return;
    final state = context.read<AppState>();
    final target = state.collectionById(_target);
    if (target != null && r.collections.isNotEmpty) {
      final added = state.addToCollection(
        target,
        r.collections,
        folder: _folder,
        groupByCollection: _groupFor(r),
      );
      state.mergeWorkspace(const [], r.environments);
      if (state.activeEnvironmentId == null && r.environments.length == 1) {
        state.setActiveEnvironment(r.environments.single.id);
      }
      Navigator.pop(context);
      final where = _folder.isEmpty
          ? '"${target.name}"'
          : '"${target.name} › ${_folder.replaceAll('/', ' › ')}"';
      final extras = [
        if (added.variables > 0)
          '${added.variables} new variable${added.variables == 1 ? '' : 's'}',
        if (r.environments.isNotEmpty)
          '${r.environments.length} environment'
              '${r.environments.length == 1 ? '' : 's'}',
      ];
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Added ${added.requests} request${added.requests == 1 ? '' : 's'} '
            'to $where${extras.isEmpty ? '' : ' (plus ${extras.join(' and ')})'}',
          ),
        ),
      );
      return;
    }
    final (nc, ne) = state.mergeWorkspace(r.collections, r.environments);
    if (state.activeEnvironmentId == null && r.environments.length == 1) {
      state.setActiveEnvironment(r.environments.single.id);
    }
    Navigator.pop(context);
    final parts = [
      if (nc > 0)
        '$nc collection${nc == 1 ? '' : 's'} (${r.requests} requests)',
      if (ne > 0) '$ne environment${ne == 1 ? '' : 's'}',
    ];
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Imported ${parts.join(' and ')}')));
  }

  /// Several imported collections default to one folder each, so their
  /// requests don't mix in the destination.
  bool _groupFor(ImportReport r) => _group ?? r.collections.length > 1;

  Widget _destination(ImportReport r) {
    final state = context.watch<AppState>();
    if (state.collections.isEmpty) return const SizedBox.shrink();
    final target = state.collectionById(_target);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _targetDropdown(r, state, target)),
              const HelpTip(
                'A new collection keeps the import separate. An existing one '
                'gets the requests added; its own requests and variable values '
                'are not changed.',
                title: 'Import into',
                example: 'Existing: Shop API',
              ),
            ],
          ),
          if (target != null && _folder.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: HelpHover(
                'Requests go inside this folder of the collection. Remove the '
                'chip to import at the top level instead.',
                title: 'Destination folder',
                example: 'Shop API › Orders',
                child: InputChip(
                  avatar: Icon(
                    Icons.folder_outlined,
                    size: 16,
                    color: Palette.textDim,
                  ),
                  label: Text(
                    'In folder ${_folder.replaceAll('/', ' › ')}',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                  onDeleted: () => setState(() => _folder = ''),
                  deleteButtonTooltipMessage: 'Import at the collection root',
                ),
              ),
            ),
          if (target != null)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              value: _groupFor(r),
              onChanged: (v) => setState(() => _group = v),
              title: Row(
                children: [
                  Flexible(
                    child: Text(
                      r.collections.length == 1
                          ? 'Put the requests in a folder named '
                                '"${r.collections.single.name}"'
                          : 'Put each imported collection in its own folder',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  const HelpTip(
                    'Keeps imported requests together in their own folder, '
                    'so they do not mix with requests already in the '
                    'collection.',
                    title: 'Group in a folder',
                    example: 'Shop API › Petstore › Get pet',
                  ),
                ],
              ),
              subtitle: Text(
                'Existing requests and variable values are left as they are.',
                style: TextStyle(fontSize: 12, color: Palette.textDim),
              ),
            ),
        ],
      ),
    );
  }

  Widget _targetDropdown(
    ImportReport r,
    AppState state,
    CollectionModel? target,
  ) => DropdownButtonFormField<String>(
    initialValue: target?.id ?? '',
    isExpanded: true,
    decoration: const InputDecoration(labelText: 'Import into'),
    items: [
      DropdownMenuItem(
        value: '',
        child: Text(
          r.collections.length > 1 ? 'New collections' : 'A new collection',
        ),
      ),
      for (final c in state.collections)
        DropdownMenuItem(
          value: c.id,
          child: Text('Existing: ${c.name}', overflow: TextOverflow.ellipsis),
        ),
    ],
    onChanged: (v) => setState(() {
      _target = (v == null || v.isEmpty) ? null : v;
      if (_target != widget.collectionId) _folder = '';
    }),
  );

  @override
  Widget build(BuildContext context) {
    final r = _report;
    final ready = r != null && !r.isEmpty;
    final preset = context.read<AppState>().collectionById(widget.collectionId);
    return AdaptiveDialog(
      width: 640,
      primary: FilledButton(
        onPressed: ready ? _import : null,
        child: const Text('Import'),
      ),
      title: Row(
        children: [
          Icon(Icons.download_outlined, color: Palette.accent),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              preset == null ? 'Import' : 'Import into ${preset.name}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    'Postman collections (v1, v2.0, v2.1), single requests '
                    'or folders, environments, globals and full data '
                    'exports, or an ApiWorkbench workspace. Add as many as '
                    'you like, then choose where they go.',
                    style: TextStyle(
                      fontSize: 13,
                      color: Palette.textDim,
                      height: 1.45,
                    ),
                  ),
                ),
                const HelpTip(
                  'In Postman, open the … menu on a collection or '
                  'environment and choose Export. Nothing changes here until '
                  'you press Import.',
                  title: 'Getting files from Postman',
                  example: 'Shop API.postman_collection.json',
                ),
              ],
            ),
            const SizedBox(height: 14),
            _dropZone(),
            const SizedBox(height: 12),
            TextField(
              controller: _paste,
              minLines: 3,
              maxLines: 6,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: InputDecoration(
                hintText: 'Or paste Postman JSON here',
                suffixIcon: Padding(
                  padding: const EdgeInsets.all(6),
                  child: HelpHover(
                    'Add the pasted JSON to the list to import. You can '
                    'paste several, one after another.',
                    title: 'Add pasted JSON',
                    example: '{"info": {"name": "Shop API"}, "item": [ … ]}',
                    child: TextButton(
                      onPressed: _addPasted,
                      child: const Text('Add'),
                    ),
                  ),
                ),
              ),
            ),
            if (_errors.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final e in _errors)
                _note(Icons.error_outline, Palette.danger, e),
            ],
            if (r != null && !r.isEmpty) ...[
              const SizedBox(height: 16),
              _summary(r),
              if (r.collections.isNotEmpty) _destination(r),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: ready ? _import : null,
          icon: const Icon(Icons.check, size: 18),
          label: const Text('Import'),
        ),
      ],
    );
  }

  Widget _dropZone() => HelpHover(
    'Pick one or more .json files exported from Postman or ApiWorkbench. '
    'Each one is checked and added to the summary below.',
    title: 'Choose files',
    example: 'Shop API.postman_collection.json',
    child: _dropZoneBox(),
  );

  Widget _dropZoneBox() => InkWell(
    borderRadius: BorderRadius.circular(10),
    onTap: _busy ? null : _chooseFiles,
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 22),
      decoration: BoxDecoration(
        color: Palette.accentSoft.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Palette.accent.withValues(alpha: 0.5)),
      ),
      child: Column(
        children: [
          _busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                )
              : Icon(Icons.upload_file, size: 28, color: Palette.accent),
          const SizedBox(height: 8),
          Text(
            'Choose files',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: Palette.text,
              fontSize: 13.5,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _sources.isEmpty
                ? '.json exported from Postman or ApiWorkbench'
                : 'Added: ${_sources.join(', ')}',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Palette.textDim),
          ),
        ],
      ),
    ),
  );

  Widget _summary(ImportReport r) {
    Widget stat(String n, String label, String help) => Expanded(
      child: HelpHover(
        help,
        title: '$n $label',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              n,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: Palette.text,
              ),
            ),
            Text(label, style: TextStyle(fontSize: 12, color: Palette.textDim)),
          ],
        ),
      ),
    );
    final converted = r.assertionsFromScripts + r.capturesFromScripts;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Palette.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LabelWithHelp(
            'Ready to import · ${r.formats.join(', ')}',
            'What was found in the files and pasted JSON so far. Nothing is '
                'saved until you press Import.',
            example: 'Postman collection v2.1',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: Palette.text,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              stat(
                '${r.collections.length}',
                _noun(r.collections.length, 'collection'),
                'Collections found in what you added. Each becomes a '
                    'collection, or a folder in the one you pick below.',
              ),
              stat(
                '${r.folders}',
                _noun(r.folders, 'folder'),
                'Folders inside those collections. They are kept as folders '
                    'here.',
              ),
              stat(
                '${r.requests}',
                _noun(r.requests, 'request'),
                'Requests that will be added, with their params, headers, '
                    'body and auth.',
              ),
              stat(
                '${r.environments.length}',
                _noun(r.environments.length, 'environment'),
                'Environments and globals, added to the Environments list. '
                    'A single one becomes active if none is.',
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final c in r.collections)
            _line(
              Icons.inventory_2_outlined,
              '${c.name} — ${c.requests.length} '
              '${_noun(c.requests.length, 'request')}'
              '${c.variables.isEmpty ? '' : ', ${c.variables.length} ${_noun(c.variables.length, 'variable')}'}',
            ),
          for (final e in r.environments)
            _line(
              Icons.public,
              '${e.name} — ${e.variables.length} '
              '${_noun(e.variables.length, 'variable')}',
            ),
          if (converted > 0)
            _note(
              Icons.auto_fix_high,
              Palette.success,
              'Converted from scripts: ${r.assertionsFromScripts} tests and '
              '${r.capturesFromScripts} captured values.',
            ),
          for (final w in r.warnings)
            _note(Icons.info_outline, Palette.warning, w),
        ],
      ),
    );
  }

  Widget _line(IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Row(
      children: [
        Icon(icon, size: 15, color: Palette.textDim),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, color: Palette.text),
          ),
        ),
      ],
    ),
  );

  Widget _note(IconData icon, Color color, String text) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 12.5, color: Palette.text, height: 1.4),
          ),
        ),
      ],
    ),
  );
}

String _noun(int n, String word) => n == 1 ? word : '${word}s';
