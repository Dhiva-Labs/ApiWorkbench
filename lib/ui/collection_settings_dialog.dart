import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'adaptive.dart';
import 'help_tip.dart';
import 'request/auth_editor.dart';
import 'variables_editor.dart';

/// A collection's auth, scripts, description and variables.
///
/// Edits are made in place on the collection and saved a moment after the
/// last keystroke, and again when the dialog closes.
Future<void> showCollectionSettings(
  BuildContext context,
  AppState state,
  CollectionModel c,
) => _show(
  context,
  state,
  _Scope(
    title: '${c.name} settings',
    kind: 'collection',
    auth: c.auth,
    allowInherit: false,
    variables: c.variables,
    getPre: () => c.preRequestScript,
    setPre: (v) => c.preRequestScript = v,
    getTest: () => c.testScript,
    setTest: (v) => c.testScript = v,
    getDescription: () => c.description,
    setDescription: (v) => c.description = v,
  ),
);

/// Settings shared by a folder's requests: auth they can inherit, scripts
/// that run around each of them, and the folder's description.
Future<void> showFolderSettings(
  BuildContext context,
  AppState state,
  CollectionModel c,
  String folderPath,
) {
  final meta = c.folders.putIfAbsent(folderPath, FolderMeta.new);
  return _show(
    context,
    state,
    _Scope(
      title: '${folderPath.split('/').last} settings',
      kind: 'folder',
      auth: meta.auth,
      allowInherit: true,
      inheritedFrom: _parentAuth(c, folderPath),
      getPre: () => meta.preRequestScript,
      setPre: (v) => meta.preRequestScript = v,
      getTest: () => meta.testScript,
      setTest: (v) => meta.testScript = v,
      getDescription: () => meta.description,
      setDescription: (v) => meta.description = v,
    ),
  );
}

/// What a folder set to "inherit" gets: the nearest parent folder's auth,
/// else the collection's.
String _parentAuth(CollectionModel c, String folderPath) {
  final chain = CollectionModel.folderChain(folderPath).toList()
    ..removeLast(); // the folder itself
  for (final path in chain.reversed) {
    final f = c.folders[path];
    if (f != null && f.auth.type != AuthType.inherit) {
      return '${f.auth.type.label} from the folder ${path.split('/').last}';
    }
  }
  return c.auth.type == AuthType.none || c.auth.type == AuthType.inherit
      ? 'no auth (the collection ${c.name} has none)'
      : '${c.auth.type.label} from the collection ${c.name}';
}

/// What the dialog edits: a collection or one of its folders.
class _Scope {
  _Scope({
    required this.title,
    required this.kind,
    required this.auth,
    required this.allowInherit,
    required this.getPre,
    required this.setPre,
    required this.getTest,
    required this.setTest,
    required this.getDescription,
    required this.setDescription,
    this.variables,
    this.inheritedFrom,
  });

  final String title;

  /// 'collection' or 'folder', for help texts.
  final String kind;
  final AuthConfig auth;
  final bool allowInherit;
  final String? inheritedFrom;

  /// Only collections have variables.
  final List<KV>? variables;
  final String Function() getPre;
  final void Function(String) setPre;
  final String Function() getTest;
  final void Function(String) setTest;
  final String Function() getDescription;
  final void Function(String) setDescription;
}

/// Saves after a pause in typing, and on demand. Saving writes the whole
/// workspace and re-renders the sidebar, which is too much per keystroke.
class _Saver {
  _Saver(this.state);

  final AppState state;
  Timer? _timer;
  bool _dirty = false;

  void touch() {
    _dirty = true;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 400), flush);
  }

  void flush() {
    _timer?.cancel();
    _timer = null;
    if (!_dirty) return;
    _dirty = false;
    state.updateCollections();
  }
}

Future<void> _show(BuildContext context, AppState state, _Scope scope) {
  final saver = _Saver(state);
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final available = MediaQuery.sizeOf(ctx).height - 220;
      return AdaptiveDialog(
        title: Text(scope.title, overflow: TextOverflow.ellipsis),
        width: 640,
        height: available.clamp(220.0, 560.0),
        contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        content: _SettingsBody(state: state, scope: scope, saver: saver),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Done'),
          ),
        ],
      );
    },
  ).whenComplete(saver.flush);
}

class _SettingsBody extends StatefulWidget {
  const _SettingsBody({
    required this.state,
    required this.scope,
    required this.saver,
  });

  final AppState state;
  final _Scope scope;
  final _Saver saver;

  @override
  State<_SettingsBody> createState() => _SettingsBodyState();
}

class _SettingsBodyState extends State<_SettingsBody> {
  late final _pre = TextEditingController(text: widget.scope.getPre());
  late final _test = TextEditingController(text: widget.scope.getTest());
  late final _desc = TextEditingController(text: widget.scope.getDescription());

  _Scope get scope => widget.scope;

  @override
  void dispose() {
    _pre.dispose();
    _test.dispose();
    _desc.dispose();
    super.dispose();
  }

  Tab _tab(String label, String help, String example) => Tab(
    child: HelpHover(help, title: label, example: example, child: Text(label)),
  );

  @override
  Widget build(BuildContext context) {
    final hasVars = scope.variables != null;
    return DefaultTabController(
      length: hasVars ? 4 : 3,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              _tab(
                'Auth',
                'The login every request in this ${scope.kind} can inherit, '
                    'so a token is set in one place.',
                'Bearer {{token}}',
              ),
              _tab(
                'Scripts',
                'Code that runs before and after every request in this '
                    '${scope.kind}.',
                'pm.environment.set("startedAt", Date.now())',
              ),
              _tab(
                'Docs',
                'A description shown in the exported documentation.',
                'Orders, payments and refunds.',
              ),
              if (hasVars)
                _tab(
                  'Variables',
                  'Values every request in this collection can use as '
                      '{{name}}.',
                  'baseUrl = https://api.example.com',
                ),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                AuthEditor(
                  auth: scope.auth,
                  onChanged: widget.saver.touch,
                  allowInherit: scope.allowInherit,
                  inheritedFrom: scope.inheritedFrom,
                ),
                _scripts(),
                _docs(),
                if (hasVars) _variables(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _scripts() {
    final noEngine = widget.state.scripts == null;
    return ListView(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 14),
      children: [
        if (noEngine)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'This build has no script engine yet, so scripts are saved and '
              'exported but not run.',
              style: TextStyle(fontSize: 12.5, color: Palette.textDim),
            ),
          ),
        _ScriptField(
          label: 'Pre-request script',
          help:
              'Runs before each request in this ${scope.kind} is sent, ahead '
              'of the request\'s own script.',
          example: 'pm.environment.set("ts", Date.now())',
          controller: _pre,
          onChanged: (v) {
            scope.setPre(v);
            widget.saver.touch();
          },
        ),
        const SizedBox(height: 18),
        _ScriptField(
          label: 'Post-response script',
          help:
              'Runs after each response in this ${scope.kind}, once the '
              'request\'s own tests have run.',
          example: 'pm.test("ok", () => pm.response.to.have.status(200))',
          controller: _test,
          onChanged: (v) {
            scope.setTest(v);
            widget.saver.touch();
          },
        ),
      ],
    );
  }

  Widget _docs() => ListView(
    padding: const EdgeInsets.fromLTRB(4, 14, 4, 14),
    children: [
      TextField(
        controller: _desc,
        minLines: 6,
        maxLines: null,
        keyboardType: TextInputType.multiline,
        style: const TextStyle(fontSize: 13.5, height: 1.45),
        decoration: InputDecoration(
          labelText: 'Description',
          alignLabelWithHint: true,
          hintText: 'What this ${scope.kind} is for, how to use it…',
          suffixIcon: HelpTip(
            'Notes for you and your team. Shown at the top of this '
            '${scope.kind} in the exported docs, and kept in workspace '
            'exports.',
            title: 'Description',
            example: 'Orders, payments and refunds.',
          ),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 32,
            minHeight: 32,
          ),
        ),
        onChanged: (v) {
          scope.setDescription(v);
          widget.saver.touch();
        },
      ),
    ],
  );

  Widget _variables() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
        child: Text(
          'Available to every request in this collection. The active '
          'environment wins on a name clash.',
          style: TextStyle(fontSize: 12.5, color: Palette.textDim),
        ),
      ),
      Expanded(
        child: VariablesEditor(
          rows: scope.variables!,
          onChanged: widget.saver.touch,
        ),
      ),
    ],
  );
}

/// A labelled, monospace, growing text box for script code.
class _ScriptField extends StatelessWidget {
  const _ScriptField({
    required this.label,
    required this.help,
    required this.example,
    required this.controller,
    required this.onChanged,
  });

  final String label;
  final String help;
  final String example;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      LabelWithHelp(
        label,
        help,
        example: example,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 6),
      TextField(
        controller: controller,
        minLines: 6,
        maxLines: null,
        keyboardType: TextInputType.multiline,
        autocorrect: false,
        enableSuggestions: false,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 12.5,
          height: 1.45,
        ),
        decoration: const InputDecoration(
          hintText: '// JavaScript',
          alignLabelWithHint: true,
        ),
        onChanged: onChanged,
      ),
    ],
  );
}
