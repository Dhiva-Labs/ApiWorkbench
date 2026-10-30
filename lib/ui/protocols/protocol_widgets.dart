import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../services/net_config.dart';
import '../../services/protocols/live_connection.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../adaptive.dart';
import '../help_tip.dart';
import '../request/params_tab.dart';
import '../tab_memory.dart';
import 'message_log_view.dart';

/// A live connection owned by a tab: the object kept in
/// [RequestTab.session]. It tells its listeners when the connection changes,
/// at most about 16 times a second so a busy stream does not rebuild the UI
/// for every message, and closes the connection with the tab.
class LiveSession<C extends LiveConnection> extends ChangeNotifier
    implements TabSession {
  LiveSession(this.connection) {
    connection.addListener(_changed);
  }

  final C connection;

  /// Search text, filters and expanded rows of this tab's log view.
  final LogViewState logView = LogViewState();

  Timer? _timer;
  bool _pending = false;
  bool _closed = false;

  bool get isClosed => _closed;

  void _changed() {
    if (_closed) return;
    if (_timer != null) {
      _pending = true;
      return;
    }
    notifyListeners();
    _timer = Timer(const Duration(milliseconds: 60), () {
      _timer = null;
      if (_pending && !_closed) {
        _pending = false;
        _changed();
      }
    });
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _timer = null;
    connection.removeListener(_changed);
    connection.close();
  }

  @override
  void dispose() {
    close();
    super.dispose();
  }
}

/// The session of [tab], created with [create] the first time it is needed.
LiveSession<C> sessionOf<C extends LiveConnection>(
  RequestTab tab,
  C Function() create,
) {
  final existing = tab.session;
  if (existing is LiveSession<C> && !existing.isClosed) return existing;
  final session = LiveSession<C>(create());
  tab.session = session;
  return session;
}

/// A factory for HTTP clients that follow the app's proxy and TLS settings
/// for [tab]'s request.
ClientFactory clientFactoryFor(AppState state, RequestTab tab) {
  final verify = tab.request.settings.verifySsl ?? state.settings.verifySsl;
  final net = state.settings.network;
  return () => createIoClient(net, verifySsl: verify);
}

/// Whether TLS certificates are verified for [tab]'s request.
bool verifySslFor(AppState state, RequestTab tab) =>
    tab.request.settings.verifySsl ?? state.settings.verifySsl;

/// Shows [message] in a snack bar and notes it in the log, so it is seen
/// whichever page of a phone layout is open.
void reportProblem(
  BuildContext context,
  LiveConnection connection,
  String message,
) {
  connection.note(message, error: true);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

// ---------------- Frame: breadcrumb, URL bar and tabs ----------------

/// One tab of a protocol editor.
class ProtocolTabSpec {
  const ProtocolTabSpec({
    required this.label,
    required this.title,
    required this.help,
    this.example,
    required this.child,
  });

  final String label;
  final String title;
  final String help;
  final String? example;
  final Widget child;
}

/// The layout every protocol editor shares: where the request is saved, the
/// [urlBar], and a row of [tabs].
class ProtocolEditorFrame extends StatelessWidget {
  const ProtocolEditorFrame({
    super.key,
    required this.tab,
    required this.urlBar,
    required this.tabs,
    required this.memory,
  });

  final RequestTab tab;
  final Widget urlBar;
  final List<ProtocolTabSpec> tabs;

  /// Remembers the selected tab while the editor is rebuilt.
  final Expando<int> memory;

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        ProtocolBreadcrumb(tab: tab),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: urlBar,
        ),
        Expanded(
          child: DefaultTabController(
            length: tabs.length,
            initialIndex: TabMemory.initialIndex(memory, tab, tabs.length),
            child: TabMemory(
              owner: tab,
              memory: memory,
              child: Column(
                children: [
                  TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    labelStyle: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    tabs: [
                      for (final t in tabs)
                        HelpHover(
                          t.help,
                          title: t.title,
                          example: t.example,
                          child: Tab(text: t.label),
                        ),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [for (final t in tabs) t.child],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxHeight >= 280) return body;
        return SingleChildScrollView(child: SizedBox(height: 360, child: body));
      },
    );
  }
}

/// Where the request lives, its name (click to rename), unsaved marker and
/// the Save button.
class ProtocolBreadcrumb extends StatelessWidget {
  const ProtocolBreadcrumb({super.key, required this.tab});

  final RequestTab tab;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final req = tab.request;
    final col = state.collectionById(tab.sourceCollectionId);
    final dim = TextStyle(fontSize: 12.5, color: Palette.textDim);
    final segs = [
      if (col != null) col.name,
      if (col != null && req.folder.isNotEmpty) ...req.folder.split('/'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 0),
      child: Row(
        children: [
          HelpHover(
            col == null
                ? 'This request is not in a collection yet. Use Save to keep '
                      'it.'
                : 'Saved in ${segs.join(' › ')}: its collection, then any '
                      'folders.',
            title: col == null ? 'Draft request' : 'Location',
            example: col == null ? null : 'Shop API › Realtime › Prices feed',
            child: Icon(
              col == null ? Icons.edit_note : Icons.folder_outlined,
              size: 16,
              color: Palette.textDim,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => Row(
                children: [
                  if (box.maxWidth >= 360)
                    for (final s in segs) ...[
                      Flexible(
                        child: Text(
                          s,
                          overflow: TextOverflow.ellipsis,
                          style: dim,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Icon(
                          Icons.chevron_right,
                          size: 15,
                          color: Palette.textDim,
                        ),
                      ),
                    ],
                  Flexible(
                    flex: 2,
                    child: HelpHover(
                      'Click the name to rename this request. The new name is '
                      'kept when you save.',
                      title: 'Request name',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: () => _rename(context, state),
                        child: ConstrainedBox(
                          constraints: isTouch(context)
                              ? const BoxConstraints(
                                  minWidth: minTouchTarget,
                                  minHeight: minTouchTarget,
                                )
                              : const BoxConstraints(),
                          child: Align(
                            widthFactor: 1,
                            heightFactor: 1,
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 2,
                                vertical: 2,
                              ),
                              child: Text(
                                req.name,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: Palette.text,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (tab.dirty)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: HelpHover(
                        'This tab has edits that are not saved to its '
                        'collection yet. Save to keep them.',
                        title: 'Unsaved changes',
                        child: Icon(
                          Icons.circle,
                          size: 7,
                          color: Palette.warning,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          HelpHover(
            col == null
                ? 'Choose a collection to keep this request in, so you can '
                      'reopen it later.'
                : 'Save your changes to this request in "${col.name}".',
            title: col == null ? 'Save to a collection' : 'Save',
            child: TextButton.icon(
              onPressed: () => saveOrAsk(context, state, tab),
              icon: const Icon(Icons.save_outlined, size: 16),
              label: Text(col == null ? 'Save…' : 'Save'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _rename(BuildContext context, AppState state) async {
    final name = await promptText(
      context,
      title: 'Rename request',
      label: 'Name',
      initial: tab.request.name,
    );
    if (name == null || name.isEmpty) return;
    tab.request.name = name;
    state.touchActive();
  }
}

/// Saves [tab] into its collection, or asks which one when it has none.
Future<void> saveOrAsk(
  BuildContext context,
  AppState state,
  RequestTab tab,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final col = state.collectionById(tab.sourceCollectionId);
  if (col != null) {
    state.saveActiveTo(col);
    messenger.showSnackBar(SnackBar(content: Text('Saved to "${col.name}"')));
    return;
  }
  final nameCtrl = TextEditingController(text: tab.request.name);
  final newColCtrl = TextEditingController();
  String? selected = state.collections.isNotEmpty
      ? state.collections.first.id
      : null;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => ControllerScope(
      controllers: [nameCtrl, newColCtrl],
      child: StatefulBuilder(
        builder: (ctx, setLocal) => AdaptiveDialog(
          title: const Text('Save request'),
          width: 420,
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Request name',
                    suffixIcon: HelpTip(
                      'How this request is listed in its collection. You can '
                      'rename it later by clicking its name.',
                      title: 'Request name',
                      example: 'Prices feed',
                    ),
                    suffixIconConstraints: BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (state.collections.isNotEmpty) ...[
                  HelpHover(
                    'The collection to keep this request in. Collections group '
                    'saved requests, for example one per API.',
                    title: 'Collection',
                    example: 'Shop API',
                    child: DropdownButtonFormField<String>(
                      initialValue: selected,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Collection',
                      ),
                      items: [
                        for (final c in state.collections)
                          DropdownMenuItem(
                            value: c.id,
                            child: Text(
                              c.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) => setLocal(() => selected = v),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: newColCtrl,
                  decoration: InputDecoration(
                    labelText: state.collections.isEmpty
                        ? 'New collection name'
                        : 'Or create a new collection',
                    suffixIcon: HelpTip(
                      state.collections.isEmpty
                          ? 'Collections group saved requests, for example '
                                'one per API or project.'
                          : 'Type a name here to save into a new collection '
                                'instead of the one picked above.',
                      title: 'New collection',
                      example: 'Shop API',
                    ),
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                  ),
                ),
              ],
            ),
          ),
          primary: FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
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
  final requestName = nameCtrl.text.trim();
  final collectionName = newColCtrl.text.trim();
  if (ok != true) return;
  CollectionModel? target;
  if (collectionName.isNotEmpty) {
    target = state.addCollection(collectionName);
  } else {
    for (final c in state.collections) {
      if (c.id == selected) target = c;
    }
  }
  if (target == null) return;
  state.saveActiveTo(target, name: requestName);
  messenger.showSnackBar(SnackBar(content: Text('Saved to "${target.name}"')));
}

/// Asks for one line of text in a dialog; null when cancelled.
Future<String?> promptText(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  String? help,
}) async {
  final ctrl = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => ControllerScope(
      controllers: [ctrl],
      child: AdaptiveDialog(
        title: Text(title),
        width: 380,
        content: SingleChildScrollView(
          child: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: InputDecoration(
              labelText: label,
              suffixIcon: help == null ? null : HelpTip(help, title: label),
              suffixIconConstraints: const BoxConstraints(
                minWidth: 32,
                minHeight: 32,
              ),
            ),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
        ),
        primary: FilledButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          child: const Text('OK'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    ),
  );
  return result;
}

// ---------------- URL bar ----------------

/// The connection state as a coloured dot and words.
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.connection, this.idleText});

  final LiveConnection connection;

  /// Replaces the word for the idle state, such as "Stopped".
  final String? idleText;

  @override
  Widget build(BuildContext context) {
    final (color, text, help) = switch (connection.state) {
      LinkState.idle => (
        Palette.textDim,
        idleText ?? 'Disconnected',
        'Not connected. Use the button next to the URL to connect.',
      ),
      LinkState.connecting => (
        Palette.warning,
        'Connecting…',
        'Waiting for the server to answer.',
      ),
      LinkState.connected => (
        Palette.success,
        'Connected',
        'The connection is open: messages flow both ways.',
      ),
      LinkState.reconnecting => (
        Palette.warning,
        'Reconnecting',
        'The connection was lost. A new attempt is made automatically.',
      ),
    };
    final detail = connection.detail;
    return HelpHover(
      help,
      title: text,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 9, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              detail.isEmpty ? text : '$text ($detail)',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The URL field with the connect / disconnect button. Narrow editors put
/// the field on its own line.
class ProtocolUrlBar extends StatefulWidget {
  const ProtocolUrlBar({
    super.key,
    required this.tab,
    required this.session,
    required this.hint,
    required this.urlTitle,
    required this.urlHelp,
    this.urlExample,
    required this.connectLabel,
    required this.connectHelp,
    required this.stopLabel,
    required this.stopHelp,
    required this.onConnect,
    required this.onStop,
    this.leading,
    this.idleText,
  });

  final RequestTab tab;
  final LiveSession<LiveConnection> session;
  final String hint;
  final String urlTitle;
  final String urlHelp;
  final String? urlExample;
  final String connectLabel;
  final String connectHelp;
  final String stopLabel;
  final String stopHelp;
  final VoidCallback onConnect;
  final VoidCallback onStop;

  /// Shown before the URL, such as a method picker.
  final Widget? leading;
  final String? idleText;

  @override
  State<ProtocolUrlBar> createState() => _ProtocolUrlBarState();
}

class _ProtocolUrlBarState extends State<ProtocolUrlBar> {
  late final TextEditingController _url;

  RequestModel get req => widget.tab.request;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: req.url);
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: _url,
      keyboardType: TextInputType.url,
      autocorrect: false,
      enableSuggestions: false,
      textInputAction: TextInputAction.go,
      style: const TextStyle(fontSize: 13.5, fontFamily: 'monospace'),
      decoration: InputDecoration(
        hintText: widget.hint,
        suffixIcon: HelpTip(
          widget.urlHelp,
          title: widget.urlTitle,
          example: widget.urlExample,
        ),
        suffixIconConstraints: const BoxConstraints(
          minWidth: 32,
          minHeight: 32,
        ),
      ),
      onChanged: (v) {
        req.url = v;
        syncPathVariables(req);
        context.read<AppState>().touchActive();
      },
      onSubmitted: (_) {
        if (!widget.session.connection.isActive) widget.onConnect();
      },
    );
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        final conn = widget.session.connection;
        final active = conn.isActive;
        final stopLabel = conn.isConnected ? widget.stopLabel : 'Cancel';
        final button = HelpHover(
          active
              ? (conn.isConnected
                    ? widget.stopHelp
                    : 'Give up on the connection attempt in progress.')
              : widget.connectHelp,
          title: active ? stopLabel : widget.connectLabel,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: active ? Palette.delete : Palette.accent,
              foregroundColor: active ? Colors.white : Palette.onAccent,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            ),
            onPressed: active ? widget.onStop : widget.onConnect,
            icon: Icon(
              active ? Icons.stop : Icons.power_settings_new,
              size: 16,
            ),
            label: Text(active ? stopLabel : widget.connectLabel),
          ),
        );
        final badge = StatusBadge(connection: conn, idleText: widget.idleText);
        return LayoutBuilder(
          builder: (context, box) {
            if (box.maxWidth >= 640) {
              return Row(
                children: [
                  if (widget.leading != null) ...[
                    widget.leading!,
                    const SizedBox(width: 8),
                  ],
                  Expanded(child: field),
                  const SizedBox(width: 10),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 190),
                    child: badge,
                  ),
                  const SizedBox(width: 10),
                  button,
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (widget.leading != null) widget.leading!,
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: (box.maxWidth - 140).clamp(80, 400),
                      ),
                      child: badge,
                    ),
                    button,
                  ],
                ),
                const SizedBox(height: 10),
                field,
              ],
            );
          },
        );
      },
    );
  }
}

// ---------------- Form pieces ----------------

/// Padding and spacing of a tab page.
const tabPadding = EdgeInsets.fromLTRB(14, 12, 14, 16);

/// A small bold heading, with optional hover help.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.help, this.example});

  final String text;
  final String? help;
  final String? example;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w700,
      color: Palette.textDim,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 6),
      child: help == null
          ? Text(text, style: style)
          : LabelWithHelp(text, help!, style: style, example: example),
    );
  }
}

/// A text field with a floating label and hover help. Pass the current
/// [value]; edits arrive through [onChanged], and a [value] that changes from
/// outside replaces the text.
class HelpField extends StatefulWidget {
  const HelpField({
    super.key,
    required this.label,
    required this.help,
    required this.value,
    required this.onChanged,
    this.hint,
    this.example,
    this.minLines = 1,
    this.maxLines = 1,
    this.mono = false,
    this.obscure = false,
    this.number = false,
    this.enabled = true,
    this.trailing,
    this.onSubmitted,
  });

  final String label;
  final String help;
  final String value;
  final ValueChanged<String> onChanged;
  final String? hint;
  final String? example;
  final int minLines;
  final int maxLines;
  final bool mono;
  final bool obscure;
  final bool number;
  final bool enabled;

  /// An extra button inside the field, before the help icon.
  final Widget? trailing;
  final ValueChanged<String>? onSubmitted;

  @override
  State<HelpField> createState() => _HelpFieldState();
}

class _HelpFieldState extends State<HelpField> {
  late final TextEditingController _c = TextEditingController(
    text: widget.value,
  );
  bool _hidden = true;

  /// An empty number field counts as 0, so clearing it to type a new number
  /// is not undone.
  static int _asNumber(String t) => int.tryParse(t.trim()) ?? 0;

  @override
  void didUpdateWidget(HelpField old) {
    super.didUpdateWidget(old);
    if (widget.value != _c.text &&
        !(widget.number && _asNumber(widget.value) == _asNumber(_c.text))) {
      _c.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final obscured = widget.obscure && _hidden;
    return TextField(
      controller: _c,
      enabled: widget.enabled,
      obscureText: obscured,
      minLines: obscured ? 1 : widget.minLines,
      maxLines: obscured ? 1 : widget.maxLines,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: widget.number
          ? TextInputType.number
          : (widget.maxLines > 1
                ? TextInputType.multiline
                : TextInputType.text),
      inputFormatters: widget.number
          ? [FilteringTextInputFormatter.digitsOnly]
          : null,
      style: TextStyle(
        fontSize: 13,
        fontFamily: widget.mono ? 'monospace' : null,
      ),
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        alignLabelWithHint: widget.maxLines > 1,
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.obscure)
              HelpHover(
                _hidden
                    ? 'Show the text instead of dots.'
                    : 'Hide the text behind dots again.',
                title: _hidden ? 'Show' : 'Hide',
                child: IconButton(
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    _hidden ? Icons.visibility_outlined : Icons.visibility_off,
                  ),
                  onPressed: () => setState(() => _hidden = !_hidden),
                ),
              ),
            ?widget.trailing,
            HelpTip(widget.help, title: widget.label, example: widget.example),
          ],
        ),
        suffixIconConstraints: const BoxConstraints(
          minWidth: 32,
          minHeight: 32,
        ),
      ),
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
    );
  }
}

/// A label, an explanation and a switch, with hover help on the whole row.
class HelpSwitch extends StatelessWidget {
  const HelpSwitch({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.example,
    this.help,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? example;

  /// Hover text; defaults to [subtitle].
  final String? help;

  @override
  Widget build(BuildContext context) => HelpHover(
    help ?? subtitle,
    title: title,
    example: example,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 13.5)),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.3,
                    color: Palette.textDim,
                  ),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    ),
  );
}

/// A drop-down with a floating label and hover help.
class HelpDropdown<T> extends StatelessWidget {
  const HelpDropdown({
    super.key,
    required this.label,
    required this.help,
    required this.value,
    required this.items,
    required this.onChanged,
    this.example,
  });

  final String label;
  final String help;
  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;
  final String? example;

  @override
  Widget build(BuildContext context) => InputDecorator(
    decoration: InputDecoration(
      labelText: label,
      contentPadding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      suffixIcon: HelpTip(help, title: label, example: example),
      suffixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        value: value,
        isExpanded: true,
        isDense: true,
        borderRadius: BorderRadius.circular(8),
        style: TextStyle(fontSize: 13, color: Palette.text),
        items: [
          for (final e in items.entries)
            DropdownMenuItem(
              value: e.key,
              child: Text(e.value, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    ),
  );
}

/// Text, JSON or binary: how a message body is read.
class PayloadKindPicker extends StatelessWidget {
  const PayloadKindPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final PayloadKind value;
  final ValueChanged<PayloadKind> onChanged;

  @override
  Widget build(BuildContext context) => HelpHover(
    'Text is sent as typed. JSON is checked before it is sent and shown '
    'indented in the log. Binary reads the body as base64 and sends the '
    'bytes.',
    title: 'Message type',
    example: 'Binary: SGVsbG8=',
    child: SegmentedButton<PayloadKind>(
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(value: PayloadKind.text, label: Text('Text')),
        ButtonSegment(value: PayloadKind.json, label: Text('JSON')),
        ButtonSegment(value: PayloadKind.binary, label: Text('Binary')),
      ],
      selected: {value},
      onSelectionChanged: (s) => onChanged(s.first),
    ),
  );
}

/// The messages pane every protocol shares: status line, then the log.
class ProtocolLogPane extends StatelessWidget {
  const ProtocolLogPane({
    super.key,
    required this.session,
    required this.emptyHint,
    this.extraStatus,
    this.idleText,
  });

  final LiveSession<LiveConnection> session;
  final String emptyHint;

  /// Shown at the end of the status line.
  final Widget? extraStatus;
  final String? idleText;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final conn = session.connection;
      return MessageLogView(
        log: conn.log,
        view: session.logView,
        emptyHint: emptyHint,
        header: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 12, 0),
          child: Wrap(
            spacing: 14,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusBadge(connection: conn, idleText: idleText),
              ?extraStatus,
            ],
          ),
        ),
      );
    },
  );
}
