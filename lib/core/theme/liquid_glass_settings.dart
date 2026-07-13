import 'dart:ui';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;

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

  /// Whether real LiquidGlass may be used for chrome layered **over the map**.
  ///
  /// 2026-07-13 (iOS on-device): `liquid_glass_renderer` blurs via a shader
  /// `ImageFilter` on a Flutter `BackdropFilterLayer`, which samples the
  /// *Flutter-rasterized* backdrop. On iOS/macOS the MapLibre map is a
  /// **PlatformView** composited by the OS outside Flutter's layer tree, so
  /// the sample returns black — chrome renders as an opaque black square with
  /// a visible rectangular sample region (the "black box over the map" bug).
  ///
  /// Android's Impeller path composites the PlatformView into the Flutter
  /// scene, so blur-over-map is device-verified working there.
  ///
  /// Chrome that sits over the map (nav pill on the Map tab, FAB, focus pill,
  /// settings/align/recenter circles, live tracking panel) passes
  /// `overMap: true` to `GlassPill`/`GlassCircle`; those widgets fall back to
  /// the tinted look on Apple platforms. Chrome over an opaque Flutter surface
  /// (Trips/Regions lists, detail sheet, matching queue pill) leaves `overMap`
  /// false and keeps the full effect on every platform.
  bool get supportsBlurOverPlatformView =>
      defaultTargetPlatform != TargetPlatform.iOS &&
      defaultTargetPlatform != TargetPlatform.macOS;

  /// Instance accessor used by downstream widgets.
  ///
  /// Reads the static [platformBlurEnabled] flag. Provided as an instance
  /// getter so widget code can use `LiquidGlassSettings.instance.platformSupportsBlurOverMap`
  /// without importing the class name twice.
  bool get platformSupportsBlurOverMap =>
      LiquidGlassSettings.platformBlurEnabled;

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
