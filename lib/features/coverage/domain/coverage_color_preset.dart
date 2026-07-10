// Trailblazer Phase 7, Plan 07-01:
// Coverage color preset enum with per-brightness hex pairs (REN-01/REN-06).
// Uses dart:ui for Brightness to stay widget-free — no Flutter/Material import.
// Isolate-safe — no dart:io, no Riverpod, no generated code.

import 'dart:ui';

import 'package:meta/meta.dart';

// ---------------------------------------------------------------------------
// CoverageColors value object
// ---------------------------------------------------------------------------

/// A pair of hex color strings for coverage rendering: one for fully-explored
/// ways and one for partially-explored ways.
///
/// Both [fullHex] and [partialHex] are 7-character RGB strings ('#RRGGBB').
@immutable
class CoverageColors {
  const CoverageColors({
    required this.fullHex,
    required this.partialHex,
  });

  /// Hex color for a fully-explored way (e.g. '#FF8C00').
  final String fullHex;

  /// Hex color for a partially-explored way (e.g. '#FFCD6B').
  final String partialHex;

  @override
  bool operator ==(Object other) =>
      other is CoverageColors &&
      other.fullHex == fullHex &&
      other.partialHex == partialHex;

  @override
  int get hashCode => Object.hash(fullHex, partialHex);

  @override
  String toString() =>
      'CoverageColors(fullHex: $fullHex, partialHex: $partialHex)';
}

// ---------------------------------------------------------------------------
// CoverageColorPreset enum
// ---------------------------------------------------------------------------

/// The 5 curated coverage color presets (REN-01 / REN-06).
///
/// The default is [amber] (orange) — chosen for maximum pop over both the
/// MapTiler dataviz light and dark base styles. Green is available as a
/// preset to honour the original REN-01 intent.
///
/// Each preset carries distinct hex pairs for light and dark brightness levels
/// via the [CoverageColorPresetColors] extension.
enum CoverageColorPreset {
  /// Amber/orange — the default explored color (REN-01 deviation from "warm green").
  amber,

  /// Green — the original REN-01 intent, offered as a preset.
  green,

  /// Blue.
  blue,

  /// Purple.
  purple,

  /// Red.
  red;

  /// Returns the preset matching [s], falling back to [amber] if no match.
  static CoverageColorPreset fromString(String s) => values.firstWhere(
        (e) => e.name == s,
        orElse: () => CoverageColorPreset.amber,
      );
}

// ---------------------------------------------------------------------------
// CoverageColorPresetColors extension
// ---------------------------------------------------------------------------

/// Provides brightness-aware [CoverageColors] for each [CoverageColorPreset].
extension CoverageColorPresetColors on CoverageColorPreset {
  /// Human-readable label for display in the Settings color picker.
  String get label {
    return switch (this) {
      CoverageColorPreset.amber => 'Amber',
      CoverageColorPreset.green => 'Green',
      CoverageColorPreset.blue => 'Blue',
      CoverageColorPreset.purple => 'Purple',
      CoverageColorPreset.red => 'Red',
    };
  }

  /// Returns the [CoverageColors] pair for this preset at the given [Brightness].
  ///
  /// Hex values are taken verbatim from RESEARCH §REN-01 (Phase 7).
  CoverageColors forBrightness(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    return switch (this) {
      CoverageColorPreset.amber => isDark
          ? const CoverageColors(fullHex: '#FFA726', partialHex: '#FFD54F')
          : const CoverageColors(fullHex: '#FF8C00', partialHex: '#FFCD6B'),
      CoverageColorPreset.green => isDark
          ? const CoverageColors(fullHex: '#4CAF50', partialHex: '#A5D6A7')
          : const CoverageColors(fullHex: '#2ECC71', partialHex: '#A8E6CF'),
      CoverageColorPreset.blue => isDark
          ? const CoverageColors(fullHex: '#42A5F5', partialHex: '#BBDEFB')
          : const CoverageColors(fullHex: '#2196F3', partialHex: '#90CAF9'),
      CoverageColorPreset.purple => isDark
          ? const CoverageColors(fullHex: '#AB47BC', partialHex: '#E1BEE7')
          : const CoverageColors(fullHex: '#9C27B0', partialHex: '#CE93D8'),
      CoverageColorPreset.red => isDark
          ? const CoverageColors(fullHex: '#EF5350', partialHex: '#FFCDD2')
          : const CoverageColors(fullHex: '#E53935', partialHex: '#FFCDD2'),
    };
  }
}
