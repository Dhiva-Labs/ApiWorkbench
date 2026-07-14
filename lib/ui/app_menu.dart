import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/workspace.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// Shared app menu (workspace import/export + settings), used by both the
/// desktop brand header and the mobile app bar.
class AppMenuButton extends StatelessWidget {
  const AppMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Workspace menu',
      icon: const Icon(Icons.menu, size: 19, color: Palette.textDim),
      onSelected: (v) => switch (v) {
        'export' => exportWorkspace(context),
        'import' => importWorkspace(context),
        'settings' => showSettingsDialog(context),
        _ => null,
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
            value: 'import',
            child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.file_download_outlined, size: 18),
                title: Text('Import workspace…'))),
        PopupMenuItem(
            value: 'export',
            child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.file_upload_outlined, size: 18),
                title: Text('Export workspace…'))),
        PopupMenuItem(
            value: 'settings',
            child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.settings_outlined, size: 18),
                title: Text('Settings…'))),
      ],
    );
  }
}

void _toast(BuildContext context, String msg) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

/// Writes [bytes] to a user-picked location. Returns the path (or a marker
/// on mobile where the platform handles the write), null when cancelled.
Future<String?> savePickedFile({
  required String dialogTitle,
  required String fileName,
  required List<String> extensions,
  required Uint8List bytes,
}) async {
  final path = await FilePicker.platform.saveFile(
    dialogTitle: dialogTitle,
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: extensions,
    bytes: bytes,
  );
  if (path == null) return null;
  // On desktop the picker only returns the path; write the file ourselves.
  if (!Platform.isAndroid && !Platform.isIOS) {
    await File(path).writeAsBytes(bytes, flush: true);
  }
  return path;
}

Future<void> exportWorkspace(BuildContext context) async {
  final state = context.read<AppState>();
  if (state.collections.isEmpty && state.environments.isEmpty) {
    _toast(context, 'Nothing to export yet — save a request or create an environment first.');
    return;
  }
  final json = buildWorkspaceJson(state.collections, state.environments);
  try {
    final path = await savePickedFile(
      dialogTitle: 'Export workspace',
      fileName: 'apiworkbench-workspace.json',
      extensions: ['json'],
      bytes: utf8.encode(json),
    );
    if (path == null) return;
    if (context.mounted) {
      _toast(context,
          'Exported ${state.collections.length} collection(s) and ${state.environments.length} environment(s).');
    }
  } catch (e) {
    if (context.mounted) _toast(context, 'Export failed: $e');
  }
}

Future<void> importWorkspace(BuildContext context) async {
  final state = context.read<AppState>();
  try {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Import workspace',
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final f = picked.files.single;
    final bytes = f.bytes ?? (f.path != null ? await File(f.path!).readAsBytes() : null);
    if (bytes == null) {
      if (context.mounted) _toast(context, 'Could not read the selected file.');
      return;
    }
    final ws = parseWorkspaceJson(utf8.decode(bytes));
    final (nc, ne) = state.mergeWorkspace(ws.collections, ws.environments);
    if (context.mounted) {
      _toast(context, 'Imported $nc collection(s) and $ne environment(s).');
    }
  } on FormatException catch (e) {
    if (context.mounted) _toast(context, e.message);
  } catch (e) {
    if (context.mounted) _toast(context, 'Import failed: $e');
  }
}

Future<void> showSettingsDialog(BuildContext context) async {
  final state = context.read<AppState>();
  final s = state.settings;
  var verifySsl = s.verifySsl;
  final connectCtrl = TextEditingController(text: '${s.connectTimeoutS}');
  final receiveCtrl = TextEditingController(text: '${s.receiveTimeoutS}');

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: const Text('Settings'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Verify TLS certificates',
                    style: TextStyle(fontSize: 14)),
                subtitle: Text(
                  verifySsl
                      ? 'Recommended. Invalid certificates are rejected.'
                      : 'Off: self-signed certificates are accepted. Use only '
                          'for local development servers.',
                  style: TextStyle(
                      fontSize: 12,
                      color: verifySsl ? Palette.textDim : Palette.post),
                ),
                value: verifySsl,
                onChanged: (v) => setLocal(() => verifySsl = v),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: connectCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: 'Connect timeout (s)'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: receiveCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: 'Response timeout (s)'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    ),
  );
  if (ok != true) return;
  state.updateSettings(AppSettings(
    verifySsl: verifySsl,
    connectTimeoutS: (int.tryParse(connectCtrl.text) ?? 30).clamp(1, 600),
    receiveTimeoutS: (int.tryParse(receiveCtrl.text) ?? 60).clamp(1, 600),
  ));
}
