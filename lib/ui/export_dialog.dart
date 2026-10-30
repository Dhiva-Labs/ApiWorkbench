import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/openapi_export.dart';
import '../services/postman_export.dart';
import '../services/workspace.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'adaptive.dart';
import 'app_menu.dart' show savePickedFile;
import 'help_tip.dart';

/// Export choices: the whole ApiWorkbench workspace, one collection or
/// environment as Postman files, the globals, or one collection as OpenAPI
/// 3.0 (issue #29). [collection] preselects that collection.
///
/// After saving, the dialog shows what was written and what had to be left
/// out.
Future<void> showExportDialog(
  BuildContext context, {
  CollectionModel? collection,
}) => showDialog<void>(
  context: context,
  builder: (_) => _ExportDialog(collection: collection),
);

enum _Kind {
  workspace,
  postmanCollection,
  postmanEnvironment,
  postmanGlobals,
  openApi,
}

/// A file ready to be saved, plus the words for the summary afterwards.
class _Output {
  _Output({
    required this.title,
    required this.fileName,
    required this.extension,
    required this.text,
    required this.what,
    this.skipped = const [],
    this.notes = const [],
  });

  final String title;
  final String fileName;
  final String extension;
  final String text;
  final String what;
  final List<String> skipped;
  final List<String> notes;
}

/// What a finished export tells the user.
class _Saved {
  _Saved(this.path, this.output);

  final String path;
  final _Output output;
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({this.collection});

  final CollectionModel? collection;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  late _Kind _kind;
  String? _collectionId;
  String? _environmentId;

  /// Off by default: current values are where session tokens end up.
  bool _includeCurrent = false;
  bool _yaml = false;
  bool _busy = false;
  String? _error;
  _Saved? _saved;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _collectionId = widget.collection?.id ?? state.collections.firstOrNull?.id;
    _environmentId = state.environments.firstOrNull?.id;
    _kind = widget.collection != null
        ? _Kind.postmanCollection
        : _Kind.values.firstWhere(
            (k) => _available(state, k),
            orElse: () => _Kind.workspace,
          );
  }

  bool _available(AppState s, _Kind k) => switch (k) {
    _Kind.workspace =>
      s.collections.isNotEmpty ||
          s.environments.isNotEmpty ||
          s.globals.isNotEmpty,
    _Kind.postmanCollection || _Kind.openApi => s.collections.isNotEmpty,
    _Kind.postmanEnvironment => s.environments.isNotEmpty,
    _Kind.postmanGlobals => s.globals.isNotEmpty,
  };

  CollectionModel? _collection(AppState s) =>
      s.collectionById(_collectionId) ?? s.collections.firstOrNull;

  EnvironmentModel? _environment(AppState s) =>
      s.environments.where((e) => e.id == _environmentId).firstOrNull ??
      s.environments.firstOrNull;

  bool _canExport(AppState s) =>
      !_busy && _saved == null && _available(s, _kind);

  /// OpenAPI documents hold no variable values.
  bool get _hasValues => _kind != _Kind.openApi;

  // ---- export ------------------------------------------------------------

  Future<void> _export(AppState state) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final out = _build(state);
      final path = await savePickedFile(
        dialogTitle: out.title,
        fileName: out.fileName,
        extensions: [out.extension],
        bytes: utf8.encode(out.text),
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (path != null) _saved = _Saved(path, out);
      });
    } on UnimplementedError {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error =
            'OpenAPI export is not available in this build yet. Choose '
            'another format.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Export failed: $e';
      });
    }
  }

  _Output _build(AppState state) {
    switch (_kind) {
      case _Kind.workspace:
        return _Output(
          title: 'Export workspace',
          fileName: 'apiworkbench-workspace.json',
          extension: 'json',
          text: buildWorkspaceJson(
            state.collections,
            state.environments,
            globals: state.globals,
            includeCurrentValues: _includeCurrent,
          ),
          what:
              '${_count(state.collections.length, 'collection')}, '
              '${_count(state.environments.length, 'environment')} and '
              '${_count(state.globals.length, 'global variable')}',
        );
      case _Kind.postmanCollection:
        final c = _collection(state)!;
        final e = buildPostmanCollection(
          c,
          includeCurrentValues: _includeCurrent,
        );
        return _Output(
          title: 'Export Postman collection',
          fileName: '${_fileSafe(c.name)}.postman_collection.json',
          extension: 'json',
          text: e.json,
          what:
              '"${c.name}" with ${_count(e.requests, 'request')} in '
              '${_count(e.folders, 'folder')}',
          skipped: e.skipped,
          notes: e.notes,
        );
      case _Kind.postmanEnvironment:
        final env = _environment(state)!;
        final e = buildPostmanEnvironment(
          env,
          includeCurrentValues: _includeCurrent,
        );
        return _Output(
          title: 'Export Postman environment',
          fileName: '${_fileSafe(env.name)}.postman_environment.json',
          extension: 'json',
          text: e.json,
          what:
              '"${env.name}" with '
              '${_count(env.variables.length, 'variable')}',
        );
      case _Kind.postmanGlobals:
        final e = buildPostmanGlobals(
          state.globals,
          includeCurrentValues: _includeCurrent,
        );
        return _Output(
          title: 'Export Postman globals',
          fileName: 'workspace.postman_globals.json',
          extension: 'json',
          text: e.json,
          what: _count(state.globals.length, 'global variable'),
        );
      case _Kind.openApi:
        final c = _collection(state)!;
        final text = buildOpenApiDocument(c, yaml: _yaml);
        final ext = _yaml ? 'yaml' : 'json';
        return _Output(
          title: 'Export OpenAPI',
          fileName: '${_fileSafe(c.name)}.openapi.$ext',
          extension: ext,
          text: text,
          what: '"${c.name}" as OpenAPI 3.0 (${_yaml ? 'YAML' : 'JSON'})',
        );
    }
  }

  // ---- layout ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final saved = _saved;
    return AdaptiveDialog(
      width: 560,
      primary: saved != null
          ? FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            )
          : FilledButton(
              onPressed: _canExport(state) ? () => _export(state) : null,
              child: const Text('Export'),
            ),
      title: Row(
        children: [
          Icon(Icons.upload_outlined, color: Palette.accent),
          const SizedBox(width: 10),
          const Flexible(
            child: Text(
              'Export',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: saved != null ? _result(saved) : _form(state),
      ),
      actions: saved != null
          ? [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              ),
            ]
          : [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: _canExport(state) ? () => _export(state) : null,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_alt, size: 18),
                label: const Text('Export'),
              ),
            ],
    );
  }

  Widget _form(AppState state) {
    final nothing = _Kind.values.every((k) => !_available(state, k));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                'Choose a format, then where to save the file. Postman '
                'files open in Postman, OpenAPI in most API tools.',
                style: TextStyle(
                  fontSize: 13,
                  color: Palette.textDim,
                  height: 1.45,
                ),
              ),
            ),
            const HelpTip(
              'ApiWorkbench workspace files keep everything and import '
              'back without loss. Postman files keep folders, auth, '
              'scripts, examples and settings.',
              title: 'Which format?',
              example: 'Shop API.postman_collection.json',
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (nothing)
          _note(
            Icons.info_outline,
            Palette.warning,
            'Nothing to export yet. Save a request or create an environment '
            'first.',
          ),
        _tile(
          state,
          _Kind.workspace,
          Icons.inventory_2_outlined,
          'ApiWorkbench workspace',
          'Every collection, environment and global',
          'One JSON file with everything, for a backup or another computer. '
              'Ids are kept, so importing it again replaces instead of '
              'duplicating.',
          example: 'apiworkbench-workspace.json',
        ),
        _tile(
          state,
          _Kind.postmanCollection,
          Icons.folder_copy_outlined,
          'Postman collection',
          'One collection, v2.1',
          'Folders with their description, auth and scripts; requests with '
              'every body type, auth, path variables, scripts, examples and '
              'settings; and the collection variables.',
          example: 'Shop API.postman_collection.json',
        ),
        _tile(
          state,
          _Kind.postmanEnvironment,
          Icons.public,
          'Postman environment',
          'One environment',
          "Variables in Postman's environment format. Secret variables are "
              'marked as secret and disabled ones stay disabled.',
          example: 'Staging.postman_environment.json',
        ),
        _tile(
          state,
          _Kind.postmanGlobals,
          Icons.language,
          'Postman globals',
          'Global variables',
          "The Globals list in Postman's globals format.",
          example: 'workspace.postman_globals.json',
        ),
        _tile(
          state,
          _Kind.openApi,
          Icons.description_outlined,
          'OpenAPI 3.0',
          'One collection as an API description',
          'Paths, parameters, request bodies and examples as an OpenAPI '
              'document, as JSON or YAML.',
          example: 'Shop API.openapi.yaml',
        ),
        if (_kind == _Kind.postmanCollection || _kind == _Kind.openApi)
          _collectionPicker(state),
        if (_kind == _Kind.postmanEnvironment) _environmentPicker(state),
        if (_kind == _Kind.openApi) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const LabelWithHelp(
                'File type',
                'JSON is the most widely understood; YAML is easier to read '
                    'and edit by hand.',
                example: 'Shop API.openapi.yaml',
              ),
              HelpHover(
                'Choose how the OpenAPI document is written.',
                title: 'JSON or YAML',
                child: SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: false, label: Text('JSON')),
                    ButtonSegment(value: true, label: Text('YAML')),
                  ],
                  selected: {_yaml},
                  onSelectionChanged: (v) => setState(() => _yaml = v.first),
                ),
              ),
            ],
          ),
        ],
        if (_hasValues) ...[
          const SizedBox(height: 8),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: _includeCurrent,
            onChanged: (v) => setState(() => _includeCurrent = v),
            title: Row(
              children: [
                const Flexible(
                  child: Text(
                    'Include current values',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
                HelpTip(
                  _kind == _Kind.workspace
                      ? "Keeps each variable's local current value next to "
                            'its initial one.'
                      : "Writes each variable's current value where it has "
                            'one, instead of its initial value, the way '
                            'Postman does when asked to.',
                  title: 'Current values',
                  example: 'token: initial "" → current "eyJhbGci…"',
                ),
              ],
            ),
            subtitle: Text(
              'Off exports initial values only, which is what is safe to '
              'share.',
              style: TextStyle(fontSize: 12, color: Palette.textDim),
            ),
          ),
          _note(
            Icons.lock_outline,
            Palette.textDim,
            'Values, including secrets and tokens, are written to the file as '
            'plain text.',
          ),
        ],
        if (_error != null) _note(Icons.error_outline, Palette.danger, _error!),
      ],
    );
  }

  Widget _tile(
    AppState state,
    _Kind kind,
    IconData icon,
    String title,
    String subtitle,
    String help, {
    String? example,
  }) {
    final enabled = _available(state, kind);
    final selected = _kind == kind && enabled;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: HelpHover(
        enabled ? help : 'There is nothing to export in this format yet.',
        title: title,
        example: enabled ? example : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Semantics(
            button: true,
            selected: selected,
            enabled: enabled,
            label: '$title, $subtitle',
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: enabled ? () => setState(() => _kind = kind) : null,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: selected
                      ? Palette.accentSoft.withValues(alpha: 0.5)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: selected ? Palette.accent : Palette.border,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color: selected ? Palette.accent : Palette.textDim,
                    ),
                    const SizedBox(width: 10),
                    Icon(icon, size: 20, color: Palette.textDim),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: Palette.text,
                            ),
                          ),
                          Text(
                            subtitle,
                            style: TextStyle(
                              fontSize: 12,
                              color: Palette.textDim,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _collectionPicker(AppState state) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: HelpHover(
      'Only the collection you pick is exported.',
      title: 'Collection',
      example: 'Shop API',
      child: DropdownButtonFormField<String>(
        initialValue: _collection(state)?.id,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Collection'),
        items: [
          for (final c in state.collections)
            DropdownMenuItem(
              value: c.id,
              child: Text(c.name, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) => setState(() => _collectionId = v),
      ),
    ),
  );

  Widget _environmentPicker(AppState state) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: HelpHover(
      'Only the environment you pick is exported.',
      title: 'Environment',
      example: 'Staging',
      child: DropdownButtonFormField<String>(
        initialValue: _environment(state)?.id,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Environment'),
        items: [
          for (final e in state.environments)
            DropdownMenuItem(
              value: e.id,
              child: Text(e.name, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) => setState(() => _environmentId = v),
      ),
    ),
  );

  Widget _result(_Saved s) {
    final out = s.output;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Palette.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.check_circle_outline,
                size: 20,
                color: Palette.success,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Exported ${out.what}.',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: Palette.text,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            s.path,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11.5,
              color: Palette.textDim,
            ),
          ),
          if (out.skipped.isEmpty && out.notes.isEmpty)
            _note(Icons.done_all, Palette.success, 'Nothing was left out.'),
          if (out.skipped.isNotEmpty) ...[
            const SizedBox(height: 10),
            LabelWithHelp(
              'Left out (${out.skipped.length})',
              'Things the chosen format has no place for. They are still in '
                  'ApiWorkbench; export the workspace to keep them in a file.',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Palette.text,
              ),
            ),
            for (final line in out.skipped)
              _note(Icons.remove_circle_outline, Palette.warning, line),
          ],
          for (final line in out.notes)
            _note(Icons.info_outline, Palette.textDim, line),
        ],
      ),
    );
  }

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

String _count(int n, String word) => '$n $word${n == 1 ? '' : 's'}';

/// A name that is safe in a file name on every platform.
String _fileSafe(String name) {
  final s = name
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
      .trim()
      .replaceAll(RegExp(r'^\.+'), '');
  return s.isEmpty ? 'export' : s;
}
