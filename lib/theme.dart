import 'package:flutter/material.dart';

// A calm, high-contrast dark palette in the spirit of modern API clients.
abstract final class Palette {
  static const bg = Color(0xFF15171C);
  static const surface = Color(0xFF1C1F26);
  static const surfaceAlt = Color(0xFF232730);
  static const border = Color(0xFF2E3340);
  static const accent = Color(0xFF7C8CF8);
  static const text = Color(0xFFE6E9F0);
  static const textDim = Color(0xFF9AA3B5);

  static const get_ = Color(0xFF4EC9A0);
  static const post = Color(0xFFE8B84B);
  static const put = Color(0xFF5CA8F5);
  static const patch = Color(0xFFB78AF7);
  static const delete = Color(0xFFEF6A6A);
  static const query = Color(0xFF55C6D8);
  static const other = Color(0xFF9AA3B5);
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

ThemeData buildTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  const scheme = ColorScheme.dark(
    primary: Palette.accent,
    secondary: Palette.accent,
    surface: Palette.surface,
    onSurface: Palette.text,
    outline: Palette.border,
  );
  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: Palette.bg,
    canvasColor: Palette.surface,
    dividerColor: Palette.border,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: Palette.surface,
      foregroundColor: Palette.text,
      elevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: Palette.surfaceAlt,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      hintStyle: const TextStyle(color: Palette.textDim),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Palette.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Palette.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Palette.accent),
      ),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: Palette.text,
      unselectedLabelColor: Palette.textDim,
      indicatorColor: Palette.accent,
      dividerColor: Palette.border,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Palette.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: Palette.surfaceAlt,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Palette.surfaceAlt,
      contentTextStyle: TextStyle(color: Palette.text),
      behavior: SnackBarBehavior.floating,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: Palette.surfaceAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Palette.border),
      ),
      textStyle: const TextStyle(color: Palette.text, fontSize: 12),
    ),
  );
}
