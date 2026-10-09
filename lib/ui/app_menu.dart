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
import 'adaptive.dart';
import 'chaos_mode.dart';
import 'help_tip.dart';
import 'import_dialog.dart';

/// Shared app menu (workspace import/export + settings), used by both the
/// desktop brand header and the mobile app bar.
class AppMenuButton extends StatelessWidget {
  const AppMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Workspace menu',
      icon: Icon(Icons.more_vert, size: 20, color: Palette.textDim),
      onSelected: (v) => switch (v) {
        'export' => exportWorkspace(context),
        'import' => showImportDialog(context),
        'settings' => showSettingsDialog(context),
        _ => null,
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'import',
          child: HelpHover(
            'Bring in Postman collections, environments and globals, or an '
            'ApiWorkbench workspace file.',
            title: 'Import',
            example: 'Shop API.postman_collection.json',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.file_download_outlined, size: 18),
              title: Text('Import (Postman, workspace)…'),
            ),
          ),
        ),
        PopupMenuItem(
          value: 'export',
          child: HelpHover(
            'Save every collection and environment to one JSON file, for a '
            'backup or another computer. Values, including tokens, are saved '
            'as plain text.',
            title: 'Export workspace',
            example: 'apiworkbench-workspace.json',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.file_upload_outlined, size: 18),
              title: Text('Export workspace…'),
            ),
          ),
        ),
        PopupMenuItem(
          value: 'settings',
          child: HelpHover(
            'Theme, hover help, HTTP version, timeouts, certificate checks '
            'and Chaos Mode.',
            title: 'Settings',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.settings_outlined, size: 18),
              title: Text('Settings…'),
            ),
          ),
        ),
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
    _toast(
      context,
      'Nothing to export yet — save a request or create an environment first.',
    );
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
      _toast(
        context,
        'Exported ${state.collections.length} collection(s) and ${state.environments.length} environment(s).',
      );
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
    final bytes =
        f.bytes ?? (f.path != null ? await File(f.path!).readAsBytes() : null);
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
  var httpVersion = s.httpVersion;
  var chaosMode = s.chaosMode;
  var theme = s.theme;
  var themeMode = s.themeMode;
  var hoverHelp = s.hoverHelp;
  final connectCtrl = TextEditingController(text: '${s.connectTimeoutS}');
  final receiveCtrl = TextEditingController(text: '${s.receiveTimeoutS}');

  AppSettings snapshot() => AppSettings(
    verifySsl: verifySsl,
    httpVersion: httpVersion,
    chaosMode: chaosMode,
    chaosRules: state.settings.chaosRules,
    theme: theme,
    themeMode: themeMode,
    hoverHelp: hoverHelp,
    connectTimeoutS: (int.tryParse(connectCtrl.text) ?? 30).clamp(1, 600),
    receiveTimeoutS: (int.tryParse(receiveCtrl.text) ?? 60).clamp(1, 600),
  );

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => ControllerScope(
      controllers: [connectCtrl, receiveCtrl],
      child: StatefulBuilder(
        builder: (ctx, setLocal) => AdaptiveDialog(
          contentPadding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
          width: 500,
          title: Row(
            children: [
              Icon(Icons.settings_outlined, size: 20, color: Palette.accent),
              const SizedBox(width: 10),
              const Flexible(
                child: Text(
                  'Settings',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          primary: FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _section(
                  Icons.palette_outlined,
                  'Appearance',
                  help:
                      'How the app looks, and whether it explains things '
                      'when you point at them.',
                  [
                    LabelWithHelp(
                      'Theme',
                      'The colour scheme for the whole app.',
                      example: 'Teal  or  Graphite and orange',
                      style: TextStyle(fontSize: 12.5, color: Palette.textDim),
                    ),
                    const SizedBox(height: 6),
                    SegmentedButton<AppThemeId>(
                      showSelectedIcon: false,
                      segments: [
                        for (final t in AppThemeId.values)
                          ButtonSegment(
                            value: t,
                            label: HelpHover(
                              t == AppThemeId.teal
                                  ? 'Teal accents, in light or dark.'
                                  : 'Dark grey with orange accents. Dark only.',
                              title: t.label,
                              child: Text(
                                t.label,
                                style: const TextStyle(fontSize: 12.5),
                              ),
                            ),
                          ),
                      ],
                      selected: {theme},
                      onSelectionChanged: (sel) =>
                          setLocal(() => theme = sel.first),
                    ),
                    const SizedBox(height: 10),
                    LabelWithHelp(
                      'Mode',
                      'Light, dark, or follow your device\'s setting. Only the '
                          'Teal theme has a light version.',
                      style: TextStyle(fontSize: 12.5, color: Palette.textDim),
                    ),
                    const SizedBox(height: 6),
                    SegmentedButton<ThemeModePref>(
                      showSelectedIcon: false,
                      segments: [
                        for (final m in ThemeModePref.values)
                          ButtonSegment(
                            value: m,
                            enabled: theme == AppThemeId.teal,
                            label: HelpHover(
                              switch (m) {
                                ThemeModePref.system =>
                                  'Match your device: light by day, dark at '
                                      'night if your system switches.',
                                ThemeModePref.light => 'Always light.',
                                ThemeModePref.dark => 'Always dark.',
                              },
                              title: m.label,
                              child: Text(
                                m.label,
                                style: const TextStyle(fontSize: 12.5),
                              ),
                            ),
                          ),
                      ],
                      selected: {themeMode},
                      onSelectionChanged: (sel) =>
                          setLocal(() => themeMode = sel.first),
                    ),
                    if (theme == AppThemeId.graphite)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'Graphite and orange is dark only.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Palette.textDim,
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    _switchRow(
                      'Hover help',
                      'Show an explanation when you point at a field, button or '
                          'badge. Turn off once you know your way around.',
                      hoverHelp,
                      (v) => setLocal(() => hoverHelp = v),
                    ),
                  ],
                ),
                _section(
                  Icons.public,
                  'Network',
                  help:
                      'How requests travel: protocol version and how long '
                      'to wait before giving up.',
                  [
                    LabelWithHelp(
                      'HTTP version',
                      'Which protocol to ask servers for. If a server does not '
                          'support the newer one, the app falls back to an '
                          'older version.',
                      example: 'HTTP/2 → falls back to HTTP/1.1',
                      style: TextStyle(fontSize: 12.5, color: Palette.textDim),
                    ),
                    const SizedBox(height: 6),
                    SegmentedButton<HttpVersionPref>(
                      segments: [
                        for (final v in HttpVersionPref.values)
                          ButtonSegment(
                            value: v,
                            label: HelpHover(
                              switch (v) {
                                HttpVersionPref.v1 =>
                                  'The classic protocol every server speaks. '
                                      'The safest choice.',
                                HttpVersionPref.v2 =>
                                  'Faster on https sites that support it; others '
                                      'fall back to HTTP/1.1 automatically.',
                                HttpVersionPref.v3 =>
                                  'The newest protocol, over QUIC. Falls back to '
                                      'HTTP/2 or 1.1 when a server lacks it.',
                              },
                              title: v.label,
                              child: Text(
                                v.label,
                                style: const TextStyle(fontSize: 12.5),
                              ),
                            ),
                          ),
                      ],
                      selected: {httpVersion},
                      onSelectionChanged: (sel) =>
                          setLocal(() => httpVersion = sel.first),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      switch (httpVersion) {
                        HttpVersionPref.v1 =>
                          'Classic HTTP/1.1 for every request.',
                        HttpVersionPref.v2 =>
                          'HTTP/2 for https (ALPN); everything else falls back '
                              'to HTTP/1.1 automatically.',
                        HttpVersionPref.v3 =>
                          Platform.isLinux || Platform.isWindows
                              ? 'QUIC via the system curl (needs a curl built '
                                    'with HTTP3); the response bar shows the '
                                    'negotiated version.'
                              : 'QUIC via the platform network stack with '
                                    'automatic fallback.',
                      },
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Palette.textDim,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: connectCtrl,
                            keyboardType: TextInputType.number,
                            style: const TextStyle(fontSize: 13),
                            decoration: const InputDecoration(
                              labelText: 'Connect timeout (s)',
                              suffixIcon: HelpTip(
                                'How long to wait for the server to accept the '
                                'connection, from 1 to 600 seconds.',
                                title: 'Connect timeout',
                                example: '30',
                              ),
                              suffixIconConstraints: BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: receiveCtrl,
                            keyboardType: TextInputType.number,
                            style: const TextStyle(fontSize: 13),
                            decoration: const InputDecoration(
                              labelText: 'Response timeout (s)',
                              suffixIcon: HelpTip(
                                'How long to wait for the server to answer once '
                                'connected, from 1 to 600 seconds. Raise it for '
                                'slow reports or uploads.',
                                title: 'Response timeout',
                                example: '60',
                              ),
                              suffixIconConstraints: BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                _section(
                  Icons.lock_outline,
                  'Security',
                  help: 'How strictly https connections are checked.',
                  [
                    _switchRow(
                      'Verify TLS certificates',
                      verifySsl
                          ? 'Recommended. Invalid certificates are rejected.'
                          : 'Off: self-signed certificates accepted — local '
                                'development only.',
                      verifySsl,
                      warn: !verifySsl,
                      help:
                          'Checks that https servers prove who they are, which '
                          'protects you from impostors. Turn off only for your '
                          'own local servers with self-signed certificates.',
                      example: 'https://localhost:8443',
                      (v) => setLocal(() => verifySsl = v),
                    ),
                  ],
                ),
                _section(
                  Icons.casino_outlined,
                  'Mode',
                  help: 'Whether responses come with sounds and effects.',
                  [
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(
                          value: false,
                          label: HelpHover(
                            'Quiet: no sounds and no effects.',
                            title: 'Focus',
                            child: Text(
                              '🧘 Focus',
                              style: TextStyle(fontSize: 12.5),
                            ),
                          ),
                        ),
                        ButtonSegment(
                          value: true,
                          label: HelpHover(
                            'Each response plays a meme sound for its status, '
                            'with confetti on success and a shake on errors.',
                            title: 'Chaos',
                            example: '404 plays its own clip',
                            child: Text(
                              '🎲 Chaos',
                              style: TextStyle(fontSize: 12.5),
                            ),
                          ),
                        ),
                      ],
                      selected: {chaosMode},
                      onSelectionChanged: (sel) =>
                          setLocal(() => chaosMode = sel.first),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      chaosMode
                          ? 'Chaos: every response plays its status\'s meme '
                                'sound, plus confetti on success and a shake on '
                                'errors.'
                          : 'Focus: pure work — no sounds, no effects. Flip to '
                                'Chaos from here or the header toggle.',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Palette.textDim,
                        height: 1.35,
                      ),
                    ),
                    if (chaosMode) ...[
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FilledButton.tonalIcon(
                          onPressed: () {
                            state.updateSettings(snapshot());
                            Navigator.pop(ctx, false);
                            showChaosModeDialog(context);
                          },
                          icon: const Icon(Icons.music_note, size: 16),
                          label: const Text('Configure sounds…'),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    ),
  );
  if (ok == true) state.updateSettings(snapshot());
}

Widget _section(
  IconData icon,
  String title,
  List<Widget> children, {
  required String help,
}) => Container(
  width: double.infinity,
  margin: const EdgeInsets.only(bottom: 12),
  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
  decoration: BoxDecoration(
    color: Palette.surfaceAlt.withValues(alpha: 0.45),
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: Palette.border),
  ),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Icon(icon, size: 15, color: Palette.accent),
          const SizedBox(width: 7),
          Flexible(
            child: LabelWithHelp(
              title,
              help,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
                color: Palette.accent,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      ...children,
    ],
  ),
);

Widget _switchRow(
  String title,
  String subtitle,
  bool value,
  ValueChanged<bool> onChanged, {
  bool warn = false,
  String? help,
  String? example,
}) {
  return Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            help == null
                ? Text(title, style: const TextStyle(fontSize: 13.5))
                : LabelWithHelp(
                    title,
                    help,
                    example: example,
                    style: const TextStyle(fontSize: 13.5),
                  ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.3,
                color: warn ? Palette.post : Palette.textDim,
              ),
            ),
          ],
        ),
      ),
      Switch(value: value, onChanged: onChanged),
    ],
  );
}
