// Trailblazer Phase 8, Plan 08-01:
// Pure-Dart zoom->admin-level mapper for the focus pill (FOC-01).
// Isolate-safe — no dart:io, no Riverpod, no generated code.
// Consumed by all Phase-8 plans that need the zoom-derived admin level.

/// Maps a MapLibre camera zoom to the admin level the focus pill resolves at.
///
/// Breakpoints (RESEARCH.md §Zoom-to-Admin-Level Mapping):
///   < 6  -> 2  (Deutschland)
///   6-8  -> 4  (Bundesland)
///   9-10 -> 6  (Regierungsbezirk; rare, falls back to 4)
///   11-12-> 8  (Landkreis)
///   13-14-> 9  (Samtgemeinde; rare, falls back to 8)
///   >=15 -> 10 (Gemeinde/Ortsteil)
int zoomToAdminLevel(double zoom) {
  if (zoom < 6) return 2;
  if (zoom < 9) return 4;
  if (zoom < 11) return 6;
  if (zoom < 13) return 8;
  if (zoom < 15) return 9;
  return 10;
}

/// Parent-fallback chain for water / no-region lookups: try the zoom-derived
/// level first, then walk coarser. Level 2 (Deutschland) is the final
/// fallback so the pill is NEVER blank. (RESEARCH.md line 392, 406.)
const List<int> kFallbackLevels = [10, 9, 8, 6, 4, 2];

/// Returns the fallback levels to try, in order, starting at the level that
/// [zoomToAdminLevel] produced for [zoom]. e.g. start=8 -> [8, 6, 4, 2].
List<int> fallbackLevelsFrom(double zoom) {
  final start = zoomToAdminLevel(zoom);
  final idx = kFallbackLevels.indexOf(start);
  // start is always a member of kFallbackLevels; guard anyway.
  return idx < 0 ? kFallbackLevels : kFallbackLevels.sublist(idx);
}
