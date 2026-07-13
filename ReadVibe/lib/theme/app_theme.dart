import 'package:flutter/material.dart';
import '../models/reader_settings.dart';
import 'app_spacing.dart';

/// Claude-inspired warm minimalist design system
class AppTheme {
  // ── Color palette ─────────────────────────────────────

  static const background = Color(0xFFFAF7F2); // Warm cream
  static const backgroundAlt = Color(0xFFF0EBE3); // Deeper cream
  static const surface = Color(0xFFFFFFFF); // Clean white
  static const surfaceWarm = Color(0xFFF5F0E8); // Warm beige

  static const textPrimary = Color(0xFF3D3229); // Dark warm brown
  static const textSecondary = Color(
    0xFF6F6358,
  ); // Warm medium gray (WCAG AA on background)
  static const textTertiary = Color(
    0xFF8C8172,
  ); // Light warm gray (large text/icon use only)

  static const accent = Color(
    0xFFB3543A,
  ); // Warm terracotta (WCAG AA as text and as white-on-fill)
  static const accentLight = Color(0xFFF0C4B4); // Light coral

  static const border = Color(0xFFE8E0D4); // Warm light border
  static const borderLight = Color(0xFFF0EAE0); // Subtle border

  static const success = Color(
    0xFF4F7D60,
  ); // Sage green (WCAG AA as white-on-fill)
  static const error = Color(
    0xFFB04545,
  ); // Muted red (WCAG AA on background and as white-on-fill)

  // ── Reader theme presets ──────────────────────────────

  static const readerThemes = {
    ReaderThemeMode.light: ReaderThemeColors(
      background: Color(0xFFFFFFFF),
      text: Color(0xFF3D3229),
      secondary: Color(0xFF8A7E72),
      headerBg: Color(0xFFFFFFFF),
      border: Color(0xFFE8E0D4),
      accent: Color(0xFFB3543A),
    ),
    ReaderThemeMode.warm: ReaderThemeColors(
      background: Color(0xFFFAF7F2),
      text: Color(0xFF3D3229),
      secondary: Color(0xFF8A7E72),
      headerBg: Color(0xFFFAF7F2),
      border: Color(0xFFE8E0D4),
      accent: Color(0xFFB3543A),
    ),
    ReaderThemeMode.dark: ReaderThemeColors(
      background: Color(0xFF1A1816),
      text: Color(0xFFE8DFD4),
      secondary: Color(0xFF9A9088),
      headerBg: Color(0xFF242120),
      border: Color(0xFF3A3530),
      accent: Color(0xFFE3936F),
    ),
  };

  static ReaderThemeColors getReaderTheme(
    ReaderThemeMode mode, {
    Brightness systemBrightness = Brightness.light,
  }) {
    final resolved = mode == ReaderThemeMode.system
        ? (systemBrightness == Brightness.dark
              ? ReaderThemeMode.dark
              : ReaderThemeMode.warm)
        : mode;
    return readerThemes[resolved]!;
  }

  // ── App-wide ThemeData ────────────────────────────────

  static ThemeData get theme => ThemeData(
    scaffoldBackgroundColor: background,
    colorScheme: ColorScheme.light(
      primary: accent,
      secondary: accentLight,
      surface: surface,
      onPrimary: Colors.white,
      onSurface: textPrimary,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: background,
      foregroundColor: textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    textTheme: const TextTheme(
      headlineLarge: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        color: textPrimary,
        letterSpacing: -0.3,
      ),
      headlineMedium: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: textPrimary,
      ),
      titleLarge: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: textPrimary,
      ),
      bodyLarge: TextStyle(fontSize: 16, color: textPrimary, height: 1.6),
      bodyMedium: TextStyle(fontSize: 14, color: textPrimary),
      bodySmall: TextStyle(fontSize: 12, color: textSecondary),
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: const BorderSide(color: borderLight, width: 1),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl,
          vertical: AppSpacing.md,
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        overlayColor: WidgetStateProperty.all(Colors.transparent),
      ),
    ),
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    focusColor: Colors.transparent,
    useMaterial3: true,
  );

  static ThemeData get darkTheme => ThemeData(
    scaffoldBackgroundColor: const Color(0xFF1A1816),
    colorScheme: ColorScheme.dark(
      primary: const Color(0xFFE3936F),
      secondary: const Color(0xFFF0C4B4),
      surface: const Color(0xFF242120),
      onPrimary: Colors.black,
      onSecondary: Colors.black,
      onSurface: const Color(0xFFE8DFD4),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF1A1816),
      foregroundColor: Color(0xFFE8DFD4),
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    textTheme: const TextTheme(
      headlineLarge: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        color: Color(0xFFE8DFD4),
        letterSpacing: -0.3,
      ),
      headlineMedium: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: Color(0xFFE8DFD4),
      ),
      titleLarge: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: Color(0xFFE8DFD4),
      ),
      bodyLarge: TextStyle(fontSize: 16, color: Color(0xFFE8DFD4), height: 1.6),
      bodyMedium: TextStyle(fontSize: 14, color: Color(0xFFE8DFD4)),
      bodySmall: TextStyle(fontSize: 12, color: Color(0xFF9A9088)),
    ),
    cardTheme: CardThemeData(
      color: const Color(0xFF242120),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: const BorderSide(color: Color(0xFF3A3530), width: 1),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFFE3936F),
        foregroundColor: Colors.black,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl,
          vertical: AppSpacing.md,
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        overlayColor: WidgetStateProperty.all(Colors.transparent),
      ),
    ),
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    focusColor: Colors.transparent,
    useMaterial3: true,
  );
}

/// Reader-specific color set for a given theme mode
class ReaderThemeColors {
  final Color background;
  final Color text;
  final Color secondary;
  final Color headerBg;
  final Color border;
  final Color accent;

  const ReaderThemeColors({
    required this.background,
    required this.text,
    required this.secondary,
    required this.headerBg,
    required this.border,
    required this.accent,
  });
}
