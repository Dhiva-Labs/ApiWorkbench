import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme.dart';
import 'adaptive.dart';
import 'help_tip.dart';

Future<void> showChaosModeDialog(BuildContext context) async {
  final state = context.read<AppState>();
  await state.sounds.load();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => const _ChaosModeDialog(),
  );
}

class _Group {
  const _Group(this.emoji, this.title, this.prefix, this.classKey, this.color);
  final String emoji;
  final String title;
  final String prefix; // first digit of grouped codes
  final String classKey; // fallback rule key ('2xx'…) or 'error'
  final Color color;
}

// A getter, not a final: the colours follow the palette, which can change
// at runtime.
List<_Group> get _groups => [
  _Group('🎉', 'Success', '2', '2xx', Palette.get_),
  _Group('↪️', 'Redirects', '3', '3xx', Palette.put),
  _Group('🤦', 'Client errors', '4', '4xx', Palette.post),
  _Group('🔥', 'Server errors', '5', '5xx', Palette.delete),
  _Group('🚨', 'Network failures', '', 'error', Palette.query),
];

class _ChaosModeDialog extends StatefulWidget {
  const _ChaosModeDialog();

  @override
  State<_ChaosModeDialog> createState() => _ChaosModeDialogState();
}

class _ChaosModeDialogState extends State<_ChaosModeDialog> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final rules = state.settings.chaosRules;

    void surprise() {
      final all = state.sounds.all;
      state.sounds.play(all[Random().nextInt(all.length)].id);
    }

    const surpriseHelp =
        'Play a random sound from the library, to hear what is on offer.';
    final phone = isPhoneWidth(context);
    return AdaptiveDialog(
      contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      width: 620,
      height: 480,
      title: Row(
        children: [
          Container(
            width: phone ? 30 : 34,
            height: phone ? 30 : 34,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [Palette.post, Palette.delete]),
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Center(
              child: Text('🎲', style: TextStyle(fontSize: 17)),
            ),
          ),
          const SizedBox(width: 10),
          const Flexible(
            child: Text(
              'Chaos Mode',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      headerActions: [
        if (phone)
          IconButton(
            tooltip: 'Surprise me: $surpriseHelp',
            icon: const Icon(Icons.casino_outlined),
            onPressed: surprise,
          )
        else
          HelpHover(
            surpriseHelp,
            title: 'Surprise me',
            child: TextButton.icon(
              onPressed: surprise,
              icon: const Icon(Icons.casino_outlined, size: 16),
              label: const Text('Surprise me'),
            ),
          ),
      ],
      content: ListView(
        children: [
          Text(
            'Every response plays its status\'s sound. Preview with ▶, remap '
            'with the dropdowns, or import your own clips — paste any '
            'myinstants.com page URL and the mp3 is pulled out for you.',
            style: TextStyle(
              fontSize: 12.5,
              color: Palette.textDim,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          for (final g in _groups) _groupCard(state, g, rules),
          _libraryCard(state),
          const SizedBox(height: 8),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }

  // ---------------- status groups ----------------

  Widget _groupCard(AppState state, _Group g, Map<String, String> rules) {
    final codes =
        rules.keys
            .where((k) => int.tryParse(k) != null && k.startsWith(g.prefix))
            .toList()
          ..sort();
    if (g.classKey == 'error') codes.clear();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
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
              Text(g.emoji, style: const TextStyle(fontSize: 14)),
              const SizedBox(width: 7),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: LabelWithHelp(
                    g.title,
                    g.classKey == 'error'
                        ? 'Plays when a request gets no response at all, such '
                              'as a timeout, a refused connection or a bad '
                              'address.'
                        : 'Sounds for ${g.classKey} statuses. Exact codes '
                              'listed here win; everything else in the group '
                              'uses the "other" row.',
                    example: g.classKey == 'error'
                        ? 'Connection timed out'
                        : '${g.prefix}04 → its own row, else other ${g.classKey}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: g.color,
                    ),
                  ),
                ),
              ),
              if (g.prefix.isNotEmpty)
                HelpHover(
                  'Add a row for one exact status code, so it gets its own '
                  'sound.',
                  title: 'Add a status code',
                  example: '${g.prefix}18',
                  child: TextButton(
                    style: TextButton.styleFrom(),
                    onPressed: () => _addCodeRule(state, g.prefix),
                    child: const Text(
                      '+ code',
                      style: TextStyle(fontSize: 11.5),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          for (final code in codes)
            _ruleRow(
              state,
              code,
              HelpHover(
                '${httpStatusHelp(int.parse(code)).message} This row\'s sound '
                'plays for exactly this status.',
                title: httpStatusHelp(int.parse(code)).title,
                child: _chip(code, g.color),
              ),
              removable: true,
            ),
          _ruleRow(
            state,
            g.classKey,
            HelpHover(
              g.classKey == 'error'
                  ? 'Any request that fails before a status arrives.'
                  : 'Any ${g.classKey} status without its own row above.',
              title: g.classKey == 'error'
                  ? 'Any failure'
                  : 'Other ${g.classKey}',
              child: _chip(
                g.classKey == 'error' ? 'any' : 'other ${g.classKey}',
                g.color.withValues(alpha: 0.75),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, Color color) => Container(
    width: isPhoneWidth(context) ? 68 : 82,
    padding: const EdgeInsets.symmetric(vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.13),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      label,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: color,
        fontSize: 11.5,
        fontWeight: FontWeight.w800,
      ),
    ),
  );

  Widget _ruleRow(
    AppState state,
    String key,
    Widget chip, {
    bool removable = false,
  }) {
    final sounds = state.sounds;
    final current = state.settings.chaosRules[key] ?? '';
    final known = sounds.all.any((s) => s.id == current);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          chip,
          const SizedBox(width: 10),
          Expanded(
            child: HelpHover(
              'The sound this row plays. Pick (silent) to play nothing.',
              title: 'Sound',
              example: '(silent)',
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: known && current.isNotEmpty ? current : '',
                  isExpanded: true,
                  // Full height on touch screens: a 24 px row is too small
                  // to tap reliably.
                  isDense: !isTouch(context),
                  borderRadius: BorderRadius.circular(8),
                  style: TextStyle(fontSize: 12.5, color: Palette.text),
                  items: [
                    DropdownMenuItem(
                      value: '',
                      child: Text(
                        '(silent)',
                        style: TextStyle(color: Palette.textDim),
                      ),
                    ),
                    for (final s in sounds.all)
                      DropdownMenuItem(
                        value: s.id,
                        child: Text(s.name, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) {
                    state.settings.chaosRules[key] = v ?? '';
                    state.updateSettings(state.settings);
                  },
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Play this sound',
            icon: Icon(
              Icons.play_arrow,
              size: 18,
              color: current.isEmpty ? Palette.border : Palette.accent,
            ),
            onPressed: current.isEmpty ? null : () => sounds.play(current),
          ),
          if (removable)
            IconButton(
              tooltip: 'Remove this status code',
              icon: Icon(Icons.close, size: 14, color: Palette.textDim),
              onPressed: () {
                state.settings.chaosRules.remove(key);
                state.updateSettings(state.settings);
              },
            )
          else
            // Lines the dropdowns up with the rows that have a remove button.
            SizedBox(
              width: 48 + Theme.of(context).visualDensity.baseSizeAdjustment.dx,
            ),
        ],
      ),
    );
  }

  Future<void> _addCodeRule(AppState state, String prefix) async {
    final ctrl = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => ControllerScope(
        controllers: [ctrl],
        child: AlertDialog(
          scrollable: true,
          title: const Text('Add status code'),
          content: SizedBox(
            width: 240,
            child: TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Status code',
                hintText: '${prefix}18',
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    final n = int.tryParse(code ?? '');
    if (n == null || n < 100 || n > 599 || !mounted) return;
    state.settings.chaosRules.putIfAbsent('$n', () => '');
    state.updateSettings(state.settings);
  }

  // ---------------- sound library ----------------

  Widget _libraryCard(AppState state) {
    final sounds = state.sounds;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
      decoration: BoxDecoration(
        color: Palette.accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Palette.accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.library_music_outlined,
                    size: 15,
                    color: Palette.accent,
                  ),
                  const SizedBox(width: 7),
                  Flexible(
                    child: LabelWithHelp(
                      'Your sounds',
                      'Clips you imported. They show up in every sound list '
                          'above, ready to assign to a status.',
                      example: 'sad-trombone.mp3',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Palette.accent,
                      ),
                    ),
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  HelpHover(
                    'Import an mp3, wav, ogg or m4a file from this device.',
                    title: 'Import a file',
                    example: 'airhorn.mp3',
                    child: TextButton.icon(
                      onPressed: _busy ? null : () => _importFile(state),
                      icon: const Icon(Icons.audio_file_outlined, size: 15),
                      label: const Text('File', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                  HelpHover(
                    'Download a clip from a direct audio link or a '
                    'myinstants.com page; the mp3 is found for you.',
                    title: 'Import from a link',
                    example: 'https://www.myinstants.com/en/instant/…',
                    child: TextButton.icon(
                      onPressed: _busy ? null : () => _importUrl(state),
                      icon: const Icon(Icons.link, size: 15),
                      label: const Text('URL', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (sounds.custom.isEmpty && !_busy)
            Padding(
              padding: EdgeInsets.only(top: 2, bottom: 4),
              child: Text(
                'Nothing imported yet. Grab a clip from myinstants.com → URL.',
                style: TextStyle(fontSize: 12, color: Palette.textDim),
              ),
            ),
          for (final s in sounds.custom)
            Row(
              children: [
                IconButton(
                  tooltip: 'Play this sound',
                  icon: Icon(Icons.play_arrow, size: 18, color: Palette.accent),
                  onPressed: () => sounds.play(s.id),
                ),
                Expanded(
                  child: Text(
                    s.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
                IconButton(
                  tooltip: 'Delete this sound',
                  icon: Icon(
                    Icons.delete_outline,
                    size: 16,
                    color: Palette.textDim,
                  ),
                  onPressed: () async {
                    await sounds.delete(s);
                    if (!mounted) return;
                    state.settings.chaosRules.removeWhere((_, v) => v == s.id);
                    state.updateSettings(state.settings);
                  },
                ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _importFile(AppState state) async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        dialogTitle: 'Import sound',
        type: FileType.custom,
        allowedExtensions: ['mp3', 'wav', 'ogg', 'm4a'],
      );
      final path = picked?.files.single.path;
      if (path == null) return;
      setState(() => _busy = true);
      final s = await state.sounds.importFile(path);
      state.notifyRefresh();
      await state.sounds.play(s.id);
    } catch (e) {
      _toast('Import failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importUrl(AppState state) async {
    final ctrl = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => ControllerScope(
        controllers: [ctrl],
        child: AlertDialog(
          scrollable: true,
          title: const Text('Import from URL'),
          content: SizedBox(
            width: 460,
            child: TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                hintText:
                    'https://www.myinstants.com/en/instant/…  or a direct .mp3 link',
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Download'),
            ),
          ],
        ),
      ),
    );
    if (url == null || url.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      final s = await state.sounds.importUrl(url);
      state.notifyRefresh();
      await state.sounds.play(s.id);
    } catch (e) {
      _toast('Download failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
