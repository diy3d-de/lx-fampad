import 'package:flutter/material.dart';

import '../constants.dart';

/// Material-3-Theme (nur Dark Mode), ruhiger Look: gedämpftes Türkis, Flächen statt Rahmen, Inter überall (Mono nur für Codes);
/// transparenter Scaffold über dem Glow-Hintergrund (Hintergrund unverändert).
ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: kAccent, brightness: Brightness.dark).copyWith(
    primary: kAccent,
    onPrimary: kOnAccent,
    secondary: kNeural,
    surface: kSurface,
    onSurface: kText,
    onSurfaceVariant: kTextMuted,
    outline: kBorder,
    outlineVariant: kBorder,
    error: kDanger,
  );
  const radius = BorderRadius.all(Radius.circular(14));
  final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
  final textTheme = base.textTheme.apply(fontFamily: kFontSans, bodyColor: kText, displayColor: kText);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    // Tipp-Fläche aller Knöpfe mindestens 48 px, auch wenn die sichtbare Form kleiner ist (Touch-Ziele >= 44 px)
    materialTapTargetSize: MaterialTapTargetSize.padded,
    fontFamily: kFontSans,
    textTheme: textTheme,
    // transparent: den violett-cyanen Schimmer zeichnet LxBackground hinter alle Seiten
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: kBg,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: kText,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.4, color: kTextStrong),
    ),
    cardTheme: const CardThemeData(
      color: kSurface,
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(18))),
    ),
    dividerColor: kBorder,
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: kSurface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: kAccent.withValues(alpha: 0.14),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(color: s.contains(WidgetState.selected) ? kAccent : kTextMuted),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => TextStyle(
          fontFamily: kFontSans,
          fontSize: 12,
          fontWeight: s.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w500,
          color: s.contains(WidgetState.selected) ? kAccent : kTextMuted,
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: kAccent,
        foregroundColor: kOnAccent,
        minimumSize: const Size(48, 48),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
        shape: const RoundedRectangleBorder(borderRadius: radius),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: kText,
        minimumSize: const Size(48, 48),
        shape: const RoundedRectangleBorder(borderRadius: radius),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: kAccent)),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: kAccent,
      foregroundColor: kOnAccent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: kSurface2,
      border: const OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
      enabledBorder: const OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
      focusedBorder: const OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: kAccent, width: 2)),
      labelStyle: const TextStyle(color: kTextMuted),
      hintStyle: const TextStyle(color: kTextMuted),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? kOnAccent : kTextMuted),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? kAccent : kSurface2),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? kAccent : kBorder),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: kSurface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: kSurface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(18))),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: kSurface2,
      contentTextStyle: TextStyle(color: kText),
      behavior: SnackBarBehavior.floating,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: kAccent),
  );
}
