import 'package:flutter/material.dart';

/// Flutter chrome themes. Colors mirror the map palettes so the
/// splash + onboarding + glass overlays feel consistent when the
/// system flips theme.
///
/// Light: warm off-white background — matches `assets/map_style_light.json`
/// background (`#F2F1EF`). Trailblazer accent blue as seed.
///
/// Dark: deep navy background — matches `assets/map_style_dark.json`
/// background (`#0A1728`). Same seed for consistent action-color hue.
class AppTheme {
  AppTheme._();

  // Light — warm off-white, matches assets/map_style_light.json bg.
  static ThemeData get light => ThemeData(
    brightness: Brightness.light,
    colorScheme:
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF3B7DD8), // Trailblazer accent blue
        ).copyWith(
          surface: const Color(0xFFF2F1EF),
        ),
    scaffoldBackgroundColor: const Color(0xFFF2F1EF),
    useMaterial3: true,
  );

  // Dark — deep navy, matches assets/map_style_dark.json bg.
  static ThemeData get dark => ThemeData(
    brightness: Brightness.dark,
    colorScheme:
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF3B7DD8),
          brightness: Brightness.dark,
        ).copyWith(
          surface: const Color(0xFF0A1728),
        ),
    scaffoldBackgroundColor: const Color(0xFF0A1728),
    useMaterial3: true,
  );
}
