import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme.dart';
import 'app_menu.dart';
import 'chaos_effects.dart';
import 'mode_toggle.dart';
import 'request_editor.dart';
import 'response_view.dart';
import 'sidebar.dart';

Widget _responseArea(AppState state, RequestTab tab) => ChaosEffects(
      enabled: state.settings.chaosMode,
      trigger: tab.response,
      statusCode: tab.response?.statusCode ?? 0,
      isError: tab.response?.error != null,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: KeyedSubtree(
          key: ValueKey(
              '${tab.id}-${tab.loading}-${identityHashCode(tab.response)}'),
          child: ResponseView(tab: tab),
        ),
      ),
    );

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.loaded) {
      return const Scaffold(
          body: Center(child: CircularProgressIndicator(strokeWidth: 2.5)));
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () =>
            state.sendActive(),
        const SingleActivator(LogicalKeyboardKey.keyT, control: true): () =>
            state.newTab(),
        const SingleActivator(LogicalKeyboardKey.keyW, control: true): () =>
            state.closeTab(state.activeTabIndex),
      },
      child: FocusScope(
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 900;
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
  double _split = 0.55; // fraction of height given to the request editor

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final tab = state.activeTab!;
    return Scaffold(
      body: Row(
        children: [
          const SizedBox(
            width: 292,
            child: ColoredBox(
              color: Palette.surface,
              child: Column(
                children: [
                  _BrandHeader(),
                  Expanded(child: Sidebar()),
                ],
              ),
            ),
          ),
          const VerticalDivider(width: 1, color: Palette.border),
          Expanded(
            child: Column(
              children: [
                const _TabStrip(),
                const Divider(height: 1, color: Palette.border),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final editorH =
                          ((box.maxHeight - 9) * _split).clamp(120.0, box.maxHeight - 129);
                      return Column(
                        children: [
                          SizedBox(
                            height: editorH,
                            child:
                                RequestEditor(key: ValueKey(tab.id), tab: tab),
                          ),
                          // Draggable splitter between editor and response.
                          MouseRegion(
                            cursor: SystemMouseCursors.resizeRow,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onVerticalDragUpdate: (d) => setState(() {
                                _split = (_split +
                                        d.delta.dy / (box.maxHeight - 9))
                                    .clamp(0.2, 0.85);
                              }),
                              child: Container(
                                height: 9,
                                color: Palette.bg,
                                child: Center(
                                  child: Container(
                                    width: 42,
                                    height: 3,
                                    decoration: BoxDecoration(
                                      color: Palette.border,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: ColoredBox(
                              color: Palette.surface,
                              child: _responseArea(state, tab),
                            ),
                          ),
                        ],
                      );
                    },
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

class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                      colors: [Palette.accent, Palette.patch]),
                  borderRadius: BorderRadius.circular(8),
                ),
                child:
                    const Icon(Icons.sync_alt, size: 18, color: Colors.white),
              ),
              const SizedBox(width: 10),
              const Text('ApiWorkbench',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const Spacer(),
              const ModeToggle(compact: true),
              const SizedBox(width: 2),
              const AppMenuButton(),
            ],
          ),
          if (state.activeEnvironment != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  const Icon(Icons.public, size: 12, color: Palette.accent),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      state.activeEnvironment!.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11, color: Palette.accent),
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

// ---------------- Mobile ----------------

class _MobileLayout extends StatelessWidget {
  const _MobileLayout();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final tab = state.activeTab!;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('ApiWorkbench',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          actions: [
            if (state.activeEnvironment != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Text(state.activeEnvironment!.name,
                      style: const TextStyle(
                          fontSize: 12, color: Palette.accent)),
                ),
              ),
            const Center(child: ModeToggle(compact: true)),
            const AppMenuButton(),
          ],
          bottom: const TabBar(
            tabs: [Tab(text: 'Request'), Tab(text: 'Response')],
          ),
        ),
        drawer: Drawer(
          backgroundColor: Palette.surface,
          child: SafeArea(
            child: Sidebar(
                onRequestOpened: () => Navigator.of(context).maybePop()),
          ),
        ),
        body: Column(
          children: [
            const _TabStrip(),
            const Divider(height: 1, color: Palette.border),
            Expanded(
              child: TabBarView(
                children: [
                  RequestEditor(key: ValueKey(tab.id), tab: tab),
                  _responseArea(state, tab),
                ],
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
    return Container(
      height: 38,
      color: Palette.bg,
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: state.tabs.length,
              itemBuilder: (_, i) {
                final t = state.tabs[i];
                final active = i == state.activeTabIndex;
                final title = t.request.name == 'Untitled request' &&
                        t.request.url.isNotEmpty
                    ? t.request.url
                    : t.request.name;
                return InkWell(
                  onTap: () => state.selectTab(i),
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 220),
                    padding: const EdgeInsets.only(left: 12, right: 4),
                    decoration: BoxDecoration(
                      color: active ? Palette.surfaceAlt : Colors.transparent,
                      border: Border(
                        bottom: BorderSide(
                          width: 2,
                          color:
                              active ? Palette.accent : Colors.transparent,
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
                              fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            title,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              color:
                                  active ? Palette.text : Palette.textDim,
                            ),
                          ),
                        ),
                        if (t.dirty)
                          const Padding(
                            padding: EdgeInsets.only(left: 4),
                            child: Icon(Icons.circle,
                                size: 7, color: Palette.post),
                          ),
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 26, minHeight: 26),
                          icon: const Icon(Icons.close,
                              size: 13, color: Palette.textDim),
                          onPressed: () => state.closeTab(i),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          IconButton(
            tooltip: 'New request tab',
            icon: const Icon(Icons.add, size: 18, color: Palette.textDim),
            onPressed: () => state.newTab(),
          ),
        ],
      ),
    );
  }
}
