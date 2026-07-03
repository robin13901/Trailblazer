import 'dart:ui';

/// Shared visual + gate settings for all Liquid Glass chrome.
///
/// The [platformBlurEnabled] flag is set by the Plan 02-01 G1 rendering
/// spike (see docs/G1_SPIKE.md). Downstream widgets (bottom nav pill, FAB,
/// focus pill, settings button) branch on this flag: use `LiquidGlass` when
/// `true`, use the fallback tinted container when `false`.
class LiquidGlassSettings {
  const LiquidGlassSettings._();

  static const LiquidGlassSettings instance = LiquidGlassSettings._();

  /// G1 gate result. Default `false` = safe fallback path.
  ///
  /// Set once at app startup after real-device validation:
  /// ```dart
  /// LiquidGlassSettings.platformBlurEnabled = true; // or false
  /// ```
  /// See docs/G1_SPIKE.md for the decision record.
  // Intentionally mutable: set once at startup, never rebuilt.
  // ignore: avoid_non_final_static_fields — flag is set once at startup.
  static bool platformBlurEnabled = false;

  /// Instance accessor used by downstream widgets.
  ///
  /// Reads the static [platformBlurEnabled] flag. Provided as an instance
  /// getter so widget code can use `LiquidGlassSettings.instance.platformSupportsBlurOverMap`
  /// without importing the class name twice.
  bool get platformSupportsBlurOverMap => LiquidGlassSettings.platformBlurEnabled;

  // Shared visual parameters (tuned per ui-ux-pro-max recommendations).
  double get glassThickness => 20;
  double get glassBlurSigma => 12;
  double get glassSaturation => 1.2;
  double get pillBorderRadius => 28;

  Color get lightGlassTint => const Color(0x38FFFFFF);
  Color get darkGlassTint => const Color(0x2A0A1728);
  Color get lightGlassBorder => const Color(0x59FFFFFF);
  Color get darkGlassBorder => const Color(0x40FFFFFF);
}
