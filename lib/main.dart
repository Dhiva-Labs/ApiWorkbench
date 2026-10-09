import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'models/models.dart';
import 'state/app_state.dart';
import 'theme.dart';
import 'ui/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ApiWorkbenchApp());
}

class ApiWorkbenchApp extends StatelessWidget {
  const ApiWorkbenchApp({super.key, this.state});

  /// Injected in tests; the app creates its own otherwise.
  final AppState? state;

  @override
  Widget build(BuildContext context) {
    final s = state;
    return s == null
        ? ChangeNotifierProvider(
            create: (_) => AppState(),
            child: const _ThemedApp(),
          )
        : ChangeNotifierProvider.value(value: s, child: const _ThemedApp());
  }
}

/// Resolves the palette from Settings and the system brightness. Colours
/// read through [Palette] are not inherited, so [_PaletteScope] rebuilds the
/// whole tree in the same frame when the palette changes, without losing
/// any state.
class _ThemedApp extends StatefulWidget {
  const _ThemedApp();

  @override
  State<_ThemedApp> createState() => _ThemedAppState();
}

class _ThemedAppState extends State<_ThemedApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final (theme, mode) = context.select<AppState, (AppThemeId, ThemeModePref)>(
      (s) => (s.settings.theme, s.settings.themeMode),
    );
    final palette = PaletteData.resolve(
      theme,
      mode,
      WidgetsBinding.instance.platformDispatcher.platformBrightness,
    );
    Palette.use(palette);
    return MaterialApp(
      title: 'ApiWorkbench',
      debugShowCheckedModeBanner: false,
      theme: _forPlatform(buildTheme(palette)),
      // Switch in one frame. A cross-fade would blend the inherited theme
      // colours over 200 ms while every Palette colour flips at once.
      themeAnimationDuration: Duration.zero,
      builder: (context, child) =>
          _PaletteScope(paletteId: palette.id, child: child!),
      home: const HomeScreen(),
    );
  }
}

/// Touch platforms get the standard (larger) density for controls the base
/// theme makes compact, so every tap target is at least 44 px. Desktop
/// keeps the compact look.
ThemeData _forPlatform(ThemeData t) => switch (t.platform) {
  TargetPlatform.android ||
  TargetPlatform.iOS ||
  TargetPlatform.fuchsia => t.copyWith(
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: t.segmentedButtonTheme.style?.copyWith(
        visualDensity: VisualDensity.standard,
      ),
    ),
  ),
  _ => t,
};

/// Rebuilds everything below it when the palette changes, in the same
/// frame: the subtree is being built right now, so marking descendants
/// dirty is allowed and they rebuild before this frame paints. (Doing it
/// in a post-frame callback showed one frame of stale colours on widgets
/// that do not depend on anything that changed, such as const ones.)
class _PaletteScope extends StatefulWidget {
  const _PaletteScope({required this.paletteId, required this.child});

  final String paletteId;
  final Widget child;

  @override
  State<_PaletteScope> createState() => _PaletteScopeState();
}

class _PaletteScopeState extends State<_PaletteScope> {
  @override
  void didUpdateWidget(_PaletteScope old) {
    super.didUpdateWidget(old);
    if (old.paletteId == widget.paletteId) return;
    void walk(Element e) {
      e.markNeedsBuild();
      e.visitChildren(walk);
    }

    (context as Element).visitChildren(walk);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
