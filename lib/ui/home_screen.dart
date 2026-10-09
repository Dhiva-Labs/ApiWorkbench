import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'adaptive.dart';
import 'app_menu.dart';
import 'chaos_effects.dart';
import 'help_tip.dart';
import 'import_dialog.dart';
import 'logo.dart';
import 'mode_toggle.dart';
import 'request_editor.dart';
import 'response_view.dart';
import 'sidebar.dart';

Widget _responseArea(AppState state, RequestTab tab) => ChaosEffects(
  enabled: state.settings.chaosMode,
  scope: tab.id,
  trigger: tab.response,
  statusCode: tab.response?.statusCode ?? 0,
  isError: tab.response?.error != null,
  // Fades only when the tab, its loading state or its response changes;
  // ResponseView keeps a snapshot, so the outgoing view shows the old state.
  child: AnimatedSwitcher(
    duration: const Duration(milliseconds: 180),
    child: ResponseView(
      key: ValueKey(
        '${tab.id}-${tab.loading}-${identityHashCode(tab.response)}',
      ),
      tab: tab,
    ),
  ),
);

/// Saves the active tab into its collection (Ctrl+S). Tabs that were never
/// saved need the editor's Save… dialog to pick a collection.
void _quickSave(BuildContext context, AppState state) {
  final tab = state.activeTab;
  final col = state.collectionById(tab?.sourceCollectionId);
  final messenger = ScaffoldMessenger.of(context);
  if (col == null) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Use Save… above the URL to choose a collection.'),
      ),
    );
    return;
  }
  state.saveActiveTo(col);
  messenger.showSnackBar(SnackBar(content: Text('Saved to "${col.name}"')));
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.loaded) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
      );
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () =>
            state.sendActive(),
        const SingleActivator(LogicalKeyboardKey.keyT, control: true): () =>
            state.newTab(),
        const SingleActivator(LogicalKeyboardKey.keyW, control: true): () =>
            state.closeTab(state.activeTabIndex),
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
            _quickSave(context, state),
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): () =>
            showImportDialog(context),
      },
      child: FocusScope(
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide =
                constraints.maxWidth >= 900 && constraints.maxHeight >= 600;
            return wide ? const _DesktopLayout() : const _MobileLayout();
          },
        ),
      ),
    );
  }
}

// ---------------- Desktop / tablet ----------------

class _DesktopLayout extends StatefulWidget {
  const _DesktopLayout();

  @override
  State<_DesktopLayout> createState() => _DesktopLayoutState();
}

class _DesktopLayoutState extends State<_DesktopLayout> {
  SidebarSection _section = SidebarSection.collections;
  bool _panelOpen = true;

  // Drag state lives in notifiers so a drag rebuilds only the sized boxes,
  // not the side panel, editor and response (a large response would make
  // every drag frame expensive).
  final _panelWidth = ValueNotifier<double>(300);
  final _split = ValueNotifier<double>(0.55); // editor's share of the height

  @override
  void dispose() {
    _panelWidth.dispose();
    _split.dispose();
    super.dispose();
  }

  void _select(SidebarSection s) => setState(() {
    if (s == _section) {
      _panelOpen = !_panelOpen; // re-clicking the active item collapses
    } else {
      _section = s;
      _panelOpen = true;
    }
  });

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final tab = state.activeTab!;
    final editor = ColoredBox(
      color: Palette.surface,
      child: RequestEditor(key: ValueKey(tab.id), tab: tab),
    );
    final response = ColoredBox(
      color: Palette.surface,
      child: _responseArea(state, tab),
    );
    return Scaffold(
      body: Row(
        children: [
          _NavRail(section: _section, panelOpen: _panelOpen, onSelect: _select),
          if (_panelOpen) ...[
            ValueListenableBuilder<double>(
              valueListenable: _panelWidth,
              builder: (context, width, panel) =>
                  SizedBox(width: width, child: panel),
              child: ColoredBox(
                color: Palette.surface,
                child: Sidebar(section: _section),
              ),
            ),
            // Drag to resize the side panel.
            MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (d) => _panelWidth.value =
                    (_panelWidth.value + d.delta.dx).clamp(220.0, 520.0),
                child: SizedBox(
                  width: 5,
                  child: Center(
                    child: VerticalDivider(width: 1, color: Palette.border),
                  ),
                ),
              ),
            ),
          ],
          Expanded(
            child: Column(
              children: [
                _TopBar(
                  onManageEnvironments: () =>
                      _select(SidebarSection.environments),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, box) => ValueListenableBuilder<double>(
                      valueListenable: _split,
                      builder: (context, split, _) {
                        final editorH = ((box.maxHeight - 9) * split).clamp(
                          120.0,
                          box.maxHeight - 129,
                        );
                        return Column(
                          children: [
                            SizedBox(height: editorH, child: editor),
                            // Draggable splitter between editor and response.
                            MouseRegion(
                              cursor: SystemMouseCursors.resizeRow,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onVerticalDragUpdate: (d) => _split.value =
                                    (_split.value +
                                            d.delta.dy / (box.maxHeight - 9))
                                        .clamp(0.2, 0.85),
                                child: const _SplitHandle(),
                              ),
                            ),
                            Expanded(child: response),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SplitHandle extends StatelessWidget {
  const _SplitHandle();

  @override
  Widget build(BuildContext context) => Container(
    height: 9,
    decoration: BoxDecoration(
      color: Palette.bg,
      border: Border.symmetric(horizontal: BorderSide(color: Palette.border)),
    ),
    child: Center(
      child: Container(
        width: 36,
        height: 3,
        decoration: BoxDecoration(
          color: Palette.textDim.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    ),
  );
}

/// Far-left navigation: sections on top, workspace actions at the bottom.
class _NavRail extends StatelessWidget {
  const _NavRail({
    required this.section,
    required this.panelOpen,
    required this.onSelect,
  });

  final SidebarSection section;
  final bool panelOpen;
  final ValueChanged<SidebarSection> onSelect;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Container(
      width: 76,
      decoration: BoxDecoration(
        color: Palette.rail,
        border: Border(right: BorderSide(color: Palette.border)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          const Tooltip(message: 'ApiWorkbench', child: LogoMark(size: 38)),
          const SizedBox(height: 18),
          for (final s in SidebarSection.values)
            _RailItem(
              icon: s.icon,
              label: s == SidebarSection.environments ? 'Envs' : s.label,
              tooltip: s.label,
              help:
                  switch (s) {
                    SidebarSection.collections =>
                      'Your saved requests, organised in collections and '
                          'folders. Open, run or load-test them from here.',
                    SidebarSection.environments =>
                      'Sets of {{variables}} like baseUrl or token. Pick one to '
                          'send the same requests to a different server.',
                    SidebarSection.history =>
                      'The last 100 requests you sent, with status and time. '
                          'Click one to reopen it.',
                  } +
                  (panelOpen && s == section
                      ? ' Click again to hide the side panel.'
                      : ''),
              selected: panelOpen && s == section,
              badge:
                  s == SidebarSection.environments &&
                      state.activeEnvironment != null
                  ? true
                  : null,
              onTap: () => onSelect(s),
            ),
          const Spacer(),
          _RailItem(
            icon: Icons.download_outlined,
            label: 'Import',
            tooltip: 'Import',
            help:
                'Bring in Postman collections, environments and data '
                'exports, or an ApiWorkbench workspace. Shortcut: Ctrl+O.',
            onTap: () => showImportDialog(context),
          ),
          _RailItem(
            icon: Icons.upload_outlined,
            label: 'Export',
            tooltip: 'Export',
            help:
                'Save all collections and environments to one JSON file, '
                'to back up or share with a teammate.',
            onTap: () => exportWorkspace(context),
          ),
          _RailItem(
            icon: Palette.isDark
                ? Icons.light_mode_outlined
                : Icons.dark_mode_outlined,
            label: Palette.isDark ? 'Light' : 'Dark',
            tooltip: Palette.isDark ? 'Light mode' : 'Dark mode',
            help:
                'Switch the Teal theme between light and dark. More '
                'options are in Settings.',
            onTap: () {
              final s = state.settings
                ..theme = AppThemeId.teal
                ..themeMode = Palette.isDark
                    ? ThemeModePref.light
                    : ThemeModePref.dark;
              state.updateSettings(s);
            },
          ),
          _RailItem(
            icon: Icons.settings_outlined,
            label: 'Settings',
            tooltip: 'Settings',
            help:
                'Theme, HTTP version, timeouts, certificate checks and '
                'Focus or Chaos mode.',
            onTap: () => showSettingsDialog(context),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
    this.help = '',
    this.selected = false,
    this.badge,
  });

  /// Explanation shown under [tooltip] in the hover card.
  final String help;

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;
  final bool selected;
  final bool? badge;

  @override
  Widget build(BuildContext context) {
    final color = selected ? Palette.accent : Palette.textDim;
    return HelpHover(
      help,
      title: tooltip,
      essential: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 8),
        child: Material(
          color: selected ? Palette.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: SizedBox(
              width: 60,
              height: 52,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Badge(
                    isLabelVisible: badge == true,
                    smallSize: 7,
                    backgroundColor: Palette.success,
                    child: Icon(icon, size: 21, color: color),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.fade,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: color,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Request tabs, then the environment picker and Focus/Chaos toggle.
class _TopBar extends StatelessWidget {
  const _TopBar({this.onManageEnvironments});

  final VoidCallback? onManageEnvironments;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: Palette.bg,
        border: Border(bottom: BorderSide(color: Palette.border)),
      ),
      child: Row(
        children: [
          const Expanded(child: _TabStrip()),
          const SizedBox(width: 8),
          EnvironmentPicker(onManage: onManageEnvironments),
          const SizedBox(width: 8),
          const ModeToggle(compact: true),
          const SizedBox(width: 10),
        ],
      ),
    );
  }
}

/// Compact dropdown for the active environment.
class EnvironmentPicker extends StatelessWidget {
  const EnvironmentPicker({super.key, this.onManage, this.maxWidth = 220});

  final VoidCallback? onManage;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final env = state.activeEnvironment;
    return PopupMenuButton<String>(
      tooltip:
          'Environment: the set of {{variables}} your requests use, such as '
          'baseUrl or token. Switch to send the same requests to local, '
          'staging or production.',
      onSelected: (v) {
        if (v == '__manage') {
          onManage?.call();
        } else {
          state.setActiveEnvironment(v.isEmpty ? null : v);
        }
      },
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          value: '',
          checked: env == null,
          child: const Text('No environment'),
        ),
        for (final e in state.environments)
          CheckedPopupMenuItem(
            value: e.id,
            checked: env?.id == e.id,
            child: Text(e.name),
          ),
        if (onManage != null) ...[
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: '__manage',
            child: Text('Manage environments'),
          ),
        ],
      ],
      child: Padding(
        // A 44 px tap target on touch screens around the 30 px pill.
        padding: EdgeInsets.symmetric(vertical: isTouch(context) ? 7 : 0),
        child: Container(
          height: 30,
          constraints: BoxConstraints(maxWidth: maxWidth),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: env == null ? Colors.transparent : Palette.accentSoft,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: env == null ? Palette.border : Palette.accent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.public,
                size: 15,
                color: env == null ? Palette.textDim : Palette.accent,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  env?.name ?? 'No environment',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: env == null ? Palette.textDim : Palette.text,
                    fontWeight: env == null ? FontWeight.w400 : FontWeight.w600,
                  ),
                ),
              ),
              Icon(Icons.arrow_drop_down, size: 18, color: Palette.textDim),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------- Mobile ----------------

class _MobileLayout extends StatefulWidget {
  const _MobileLayout();

  @override
  State<_MobileLayout> createState() => _MobileLayoutState();
}

class _MobileLayoutState extends State<_MobileLayout> {
  int _section = 0;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final tab = state.activeTab!;
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final compactKeyboard =
        keyboardOpen && MediaQuery.sizeOf(context).height < 500;
    return Scaffold(
      appBar: compactKeyboard
          ? null
          : AppBar(
              titleSpacing: 0,
              title: const Row(
                children: [
                  LogoMark(size: 26),
                  SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      'ApiWorkbench',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                EnvironmentPicker(
                  maxWidth: MediaQuery.sizeOf(context).width * 0.42,
                ),
                const SizedBox(width: 4),
                const AppMenuButton(),
              ],
            ),
      drawer: Drawer(
        child: SafeArea(
          child: Sidebar(
            onRequestOpened: () {
              setState(() => _section = 0);
              Navigator.of(context).maybePop();
            },
          ),
        ),
      ),
      bottomNavigationBar: keyboardOpen
          ? null
          : NavigationBar(
              selectedIndex: _section,
              onDestinationSelected: (index) {
                FocusManager.instance.primaryFocus?.unfocus();
                setState(() => _section = index);
              },
              destinations: [
                const NavigationDestination(
                  icon: Icon(Icons.edit_outlined),
                  selectedIcon: Icon(Icons.edit),
                  label: 'Request',
                ),
                NavigationDestination(
                  icon: Badge(
                    isLabelVisible: tab.loading || tab.response != null,
                    label: Text(
                      tab.loading ? '…' : '${tab.response?.statusCode ?? ''}',
                    ),
                    child: const Icon(Icons.data_object),
                  ),
                  selectedIcon: const Icon(Icons.data_object),
                  label: 'Response',
                ),
              ],
            ),
      body: SafeArea(
        top: compactKeyboard,
        bottom: false,
        child: Column(
          children: [
            if (!compactKeyboard)
              Container(
                // Tabs get the strip's height minus 6 px: 46 on touch.
                height: isTouch(context) ? 52 : 48,
                color: Palette.bg,
                child: const _TabStrip(),
              ),
            if (tab.loading)
              const LinearProgressIndicator(minHeight: 2)
            else
              Divider(height: 1, color: Palette.border),
            Expanded(
              child: ColoredBox(
                color: Palette.surface,
                child: _section == 0
                    ? RequestEditor(key: ValueKey(tab.id), tab: tab)
                    : _responseArea(state, tab),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------- Open-request tab strip ----------------

class _TabStrip extends StatelessWidget {
  const _TabStrip();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final touch = isTouch(context);
    return Row(
      children: [
        Flexible(
          child: ListView.builder(
            shrinkWrap: true,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(left: 6, top: 6),
            itemCount: state.tabs.length,
            itemBuilder: (_, i) {
              final t = state.tabs[i];
              final active = i == state.activeTabIndex;
              final title =
                  t.request.name == 'Untitled request' &&
                      t.request.url.isNotEmpty
                  ? t.request.url
                  : t.request.name;
              return Padding(
                padding: const EdgeInsets.only(right: 2),
                child: Material(
                  color: active ? Palette.surface : Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(8),
                    ),
                    side: active
                        ? BorderSide(color: Palette.border)
                        : BorderSide.none,
                  ),
                  child: InkWell(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(8),
                    ),
                    onTap: () => state.selectTab(i),
                    child: HelpHover(
                      [
                        httpMethodHelp(t.request.method).message,
                        t.request.url.isEmpty
                            ? 'No URL yet.'
                            : 'Address: ${t.request.url}',
                        if (t.dirty) 'Has unsaved changes (Ctrl+S to save).',
                      ].join('\n'),
                      title: '${t.request.method} ${t.request.name}',
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 230),
                        padding: const EdgeInsets.only(left: 12, right: 2),
                        decoration: BoxDecoration(
                          border: Border(
                            top: BorderSide(
                              width: 2,
                              color: active
                                  ? Palette.accent
                                  : Colors.transparent,
                            ),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              t.request.method == 'DELETE'
                                  ? 'DEL'
                                  : t.request.method,
                              style: TextStyle(
                                color: methodColor(t.request.method),
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(width: 7),
                            Flexible(
                              child: Text(
                                title,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: active
                                      ? Palette.text
                                      : Palette.textDim,
                                  fontWeight: active
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                            if (t.dirty)
                              Padding(
                                padding: const EdgeInsets.only(left: 5),
                                child: Icon(
                                  Icons.circle,
                                  size: 7,
                                  color: Palette.warning,
                                ),
                              ),
                            IconButton(
                              tooltip: 'Close (Ctrl+W)',
                              padding: EdgeInsets.zero,
                              constraints: BoxConstraints.tight(
                                Size.square(touch ? minTouchTarget : 32),
                              ),
                              icon: Icon(
                                Icons.close,
                                size: 14,
                                color: Palette.textDim,
                              ),
                              onPressed: () => state.closeTab(i),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        IconButton(
          tooltip: 'New request tab (Ctrl+T)',
          icon: Icon(Icons.add, size: 19, color: Palette.textDim),
          onPressed: () => state.newTab(),
        ),
      ],
    );
  }
}
