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

/// Resolves the palette from Settings and the system brightness, and
/// rebuilds every widget when it changes so colours read through [Palette]
/// update in place without losing any state.
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

  void _rebuildAll() {
    void walk(Element e) {
      e.markNeedsBuild();
      e.visitChildren(walk);
    }

    if (mounted) (context as Element).visitChildren(walk);
  }

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
    if (palette.id != Palette.current.id) {
      Palette.use(palette);
      WidgetsBinding.instance.addPostFrameCallback((_) => _rebuildAll());
    }
    return MaterialApp(
      title: 'ApiWorkbench',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(palette),
      home: const HomeScreen(),
    );
  }
}
