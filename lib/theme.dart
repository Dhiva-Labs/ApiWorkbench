import 'package:flutter/material.dart';

import 'models/models.dart';

/// One complete colour set. The app swaps between these at runtime, so
/// widgets read colours through [Palette] getters (never `const`).
class PaletteData {
  const PaletteData({
    required this.id,
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surfaceAlt,
    required this.rail,
    required this.border,
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.text,
    required this.textDim,
    required this.get_,
    required this.post,
    required this.put,
    required this.patch,
    required this.delete,
    required this.query,
    required this.other,
  });

  final String id;
  final Brightness brightness;

  /// Canvas behind panels.
  final Color bg;

  /// Panels: side panel, editor, response.
  final Color surface;

  /// Raised or filled controls: inputs, selected tabs, chips.
  final Color surfaceAlt;

  /// The far-left icon rail.
  final Color rail;
  final Color border;
  final Color accent;

  /// Text and icons drawn on [accent].
  final Color onAccent;

  /// Selected rows and soft accent backgrounds.
  final Color accentSoft;
  final Color text;
  final Color textDim;
  final Color get_;
  final Color post;
  final Color put;
  final Color patch;
  final Color delete;
  final Color query;
  final Color other;

  static const tealLight = PaletteData(
    id: 'teal-light',
    brightness: Brightness.light,
    bg: Color(0xFFF6F7F9),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFF1F3F6),
    rail: Color(0xFFEDEFF3),
    border: Color(0xFFE1E5EB),
    accent: Color(0xFF0E8C8C),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0xFFE2F3F3),
    text: Color(0xFF1F2430),
    textDim: Color(0xFF667085),
    get_: Color(0xFF1E9E5A),
    post: Color(0xFFB87A00),
    put: Color(0xFF2F7BD9),
    patch: Color(0xFF8A5CD6),
    delete: Color(0xFFD64545),
    query: Color(0xFF0F8FA3),
    other: Color(0xFF667085),
  );

  static const tealDark = PaletteData(
    id: 'teal-dark',
    brightness: Brightness.dark,
    bg: Color(0xFF12161C),
    surface: Color(0xFF1A2028),
    surfaceAlt: Color(0xFF222A34),
    rail: Color(0xFF0E1116),
    border: Color(0xFF2A323D),
    accent: Color(0xFF3CC3C3),
    onAccent: Color(0xFF06282A),
    accentSoft: Color(0xFF173A3D),
    text: Color(0xFFE7ECF2),
    textDim: Color(0xFF8D99A8),
    get_: Color(0xFF4CC38A),
    post: Color(0xFFE8B04B),
    put: Color(0xFF5EA2F0),
    patch: Color(0xFFB48CF2),
    delete: Color(0xFFEF6A6A),
    query: Color(0xFF55C6D8),
    other: Color(0xFF8D99A8),
  );

  static const graphite = PaletteData(
    id: 'graphite',
    brightness: Brightness.dark,
    bg: Color(0xFF1B1B1D),
    surface: Color(0xFF232326),
    surfaceAlt: Color(0xFF2C2C30),
    rail: Color(0xFF151517),
    border: Color(0xFF36363B),
    accent: Color(0xFFFF7A30),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0xFF3A2A20),
    text: Color(0xFFEDEDED),
    textDim: Color(0xFF9A9AA2),
    get_: Color(0xFF4CC38A),
    post: Color(0xFFF2B544),
    put: Color(0xFF4FA3F7),
    patch: Color(0xFFB48CF2),
    delete: Color(0xFFF2555A),
    query: Color(0xFF55C6D8),
    other: Color(0xFF9A9AA2),
  );

  /// The palette for the user's theme choice and the system brightness.
  static PaletteData resolve(
    AppThemeId theme,
    ThemeModePref mode,
    Brightness platform,
  ) {
    if (theme == AppThemeId.graphite) return graphite;
    final dark = switch (mode) {
      ThemeModePref.light => false,
      ThemeModePref.dark => true,
      ThemeModePref.system => platform == Brightness.dark,
    };
    return dark ? tealDark : tealLight;
  }
}

/// The active colours. Read these at build time; the app rebuilds every
/// widget when the palette changes.
abstract final class Palette {
  static PaletteData _p = PaletteData.tealLight;
  static PaletteData get current => _p;
  static void use(PaletteData p) => _p = p;

  static bool get isDark => _p.brightness == Brightness.dark;
  static Color get bg => _p.bg;
  static Color get surface => _p.surface;
  static Color get surfaceAlt => _p.surfaceAlt;
  static Color get rail => _p.rail;
  static Color get border => _p.border;
  static Color get accent => _p.accent;
  static Color get onAccent => _p.onAccent;
  static Color get accentSoft => _p.accentSoft;
  static Color get text => _p.text;
  static Color get textDim => _p.textDim;
  static Color get get_ => _p.get_;
  static Color get post => _p.post;
  static Color get put => _p.put;
  static Color get patch => _p.patch;
  static Color get delete => _p.delete;
  static Color get query => _p.query;
  static Color get other => _p.other;

  /// Success / warning / error aliases for non-HTTP status UI.
  static Color get success => _p.get_;
  static Color get warning => _p.post;
  static Color get danger => _p.delete;
}

extension AppThemeIdLabel on AppThemeId {
  String get label => switch (this) {
    AppThemeId.teal => 'Teal',
    AppThemeId.graphite => 'Graphite and orange',
  };
}

extension ThemeModePrefLabel on ThemeModePref {
  String get label => switch (this) {
    ThemeModePref.system => 'System',
    ThemeModePref.light => 'Light',
    ThemeModePref.dark => 'Dark',
  };
}

Color methodColor(String method) => switch (method.toUpperCase()) {
  'GET' => Palette.get_,
  'POST' => Palette.post,
  'PUT' => Palette.put,
  'PATCH' => Palette.patch,
  'DELETE' => Palette.delete,
  'QUERY' => Palette.query,
  _ => Palette.other,
};

Color statusColor(int code) {
  if (code >= 200 && code < 300) return Palette.get_;
  if (code >= 300 && code < 400) return Palette.put;
  if (code >= 400 && code < 500) return Palette.post;
  if (code >= 500) return Palette.delete;
  return Palette.other;
}

ThemeData buildTheme([PaletteData? palette]) {
  final p = palette ?? Palette.current;
  final scheme = ColorScheme(
    brightness: p.brightness,
    primary: p.accent,
    onPrimary: p.onAccent,
    primaryContainer: p.accentSoft,
    onPrimaryContainer: p.text,
    secondary: p.accent,
    onSecondary: p.onAccent,
    secondaryContainer: p.accentSoft,
    onSecondaryContainer: p.text,
    error: p.delete,
    onError: Colors.white,
    surface: p.surface,
    onSurface: p.text,
    onSurfaceVariant: p.textDim,
    surfaceContainerLowest: p.bg,
    surfaceContainerLow: p.surface,
    surfaceContainer: p.surface,
    surfaceContainerHigh: p.surfaceAlt,
    surfaceContainerHighest: p.surfaceAlt,
    outline: p.border,
    outlineVariant: p.border,
  );
  final radius = BorderRadius.circular(8);
  OutlineInputBorder border(Color c) => OutlineInputBorder(
    borderRadius: radius,
    borderSide: BorderSide(color: c),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: p.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.surface,
    dividerColor: p.border,
    dividerTheme: DividerThemeData(color: p.border, space: 1, thickness: 1),
    splashFactory: InkSparkle.splashFactory,
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.accent,
      selectionColor: p.accent.withValues(alpha: 0.28),
      selectionHandleColor: p.accent,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: p.surface,
      foregroundColor: p.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      shape: Border(bottom: BorderSide(color: p.border)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: p.surfaceAlt,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      hintStyle: TextStyle(color: p.textDim),
      labelStyle: TextStyle(color: p.textDim),
      border: border(p.border),
      enabledBorder: border(p.border),
      focusedBorder: border(p.accent),
      disabledBorder: border(p.border.withValues(alpha: 0.5)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        shape: RoundedRectangleBorder(borderRadius: radius),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.text,
        side: BorderSide(color: p.border),
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.accent,
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: p.textDim),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: p.accentSoft,
        selectedForegroundColor: p.text,
        foregroundColor: p.textDim,
        side: BorderSide(color: p.border),
        visualDensity: VisualDensity.compact,
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.onAccent : p.textDim,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.accent : p.surfaceAlt,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.accent : p.border,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.accent : Colors.transparent,
      ),
      checkColor: WidgetStatePropertyAll(p.onAccent),
      side: BorderSide(color: p.textDim, width: 1.4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.accent,
      linearTrackColor: p.border,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: p.text,
      unselectedLabelColor: p.textDim,
      indicatorColor: p.accent,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: p.border,
      labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      unselectedLabelStyle: const TextStyle(fontSize: 13),
      tabAlignment: TabAlignment.start,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: p.textDim,
      textColor: p.text,
      selectedColor: p.text,
      selectedTileColor: p.accentSoft,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.surface,
      indicatorColor: p.accentSoft,
      surfaceTintColor: Colors.transparent,
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: p.border),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(p.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.text,
      contentTextStyle: TextStyle(color: p.surface),
      actionTextColor: p.accent,
      behavior: SnackBarBehavior.floating,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.text,
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: TextStyle(color: p.surface, fontSize: 12),
      waitDuration: const Duration(milliseconds: 400),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(p.textDim.withValues(alpha: 0.35)),
      radius: const Radius.circular(4),
      thickness: const WidgetStatePropertyAll(6),
    ),
    badgeTheme: BadgeThemeData(
      backgroundColor: p.accent,
      textColor: p.onAccent,
    ),
  );
}
