// Trailblazer Phase 7, Plan 07-04:
// CoverageOverlayApplier — MapLibre source+layer management for the
// app-wide coverage overlay (Gate G2 resolution: GeoJSON data-driven
// expressions; NO feature-state / setFeatureState / promoteId).
//
// Architecture:
//   - Single GeoJSON source 'coverage_overlay' carrying a FeatureCollection
//     of all resolved CoverageWays as LineString features with is_full / fraction
//     properties (produced by buildCoverageFeatureCollection in 07-04 plan T1).
//   - Single line layer 'coverage_layer' using MapLibre data-driven paint
//     expressions evaluated GPU-side per-feature (zero Dart per-feature cost).
//   - apply()       = remove-then-readd source+layer (clean slate; safe across
//                     brightness/style swaps — RESEARCH Pitfall 1/3).
//   - updateColors()= setLayerProperties with the FULL _paint property set
//                     (open-Q3/Pitfall 6: skipNulls:false would null omitted
//                     fields; passing everything prevents silent resets).
//   - remove()      = try/catch removeLayer + removeSource — idempotent.
//   - belowLayerId  = first layer id containing 'label'/'place'/'poi' found
//                     at runtime via getLayerIds() (open-Q4).
//
// The abstract CoverageOverlayApplier is the test seam — tests override
// coverageOverlayApplierProvider with a recording fake (mirrors the
// tripOverlayApplierProvider pattern in trip_overlay_layers.dart).
//
// See also: lib/features/trips/presentation/widgets/trip_overlay_layers.dart
// — the established addGeoJsonSource/addLineLayer idiom this file generalises.

import 'dart:ui';

import 'package:auto_explore/features/coverage/data/coverage_overlay_data.dart';
import 'package:auto_explore/features/coverage/domain/coverage_color_preset.dart';
import 'package:auto_explore/features/coverage/presentation/coverage_feature_collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

// ---------------------------------------------------------------------------
// Paint-expression opacity constants
//
// Named to make clear that these are golden-corpus-tunable values, not
// magic numbers.  They are extracted at this top level so
// coverageLinePaintExpressions (below) can reference them by name, giving
// reviewers a single place to adjust the visual tuning.
//
// Opacity ramp from RESEARCH §REN-03:
//   - Full way: 0.92 — solid, unmistakable
//   - Partial: max(floor, fraction * scale)
//     ~5%  fraction → opacity ≈ 0.25  ("I touched this")
//     50%  fraction → opacity ≈ 0.43
//     90%  fraction → opacity ≈ 0.77
//     Full tier: 0.92
// ---------------------------------------------------------------------------

/// Full-way line opacity (solid, unmistakable). Tunable.
const double _kFullOpacity = 0.92;

/// Scale factor applied to the `fraction` property to derive partial-way opacity. Tunable.
const double _kPartialOpacityScale = 0.85;

/// Minimum partial-way opacity floor — ensures even low-fraction ways are
/// visible as "I drove here". Tunable. Tuning recommendation: lower this
/// toward 0.15 if too many ghost traces appear on golden corpus; raise
/// toward 0.35 if barely-driven roads are too invisible. Tunable.
const double _kPartialOpacityFloor = 0.25;

// ---------------------------------------------------------------------------
// MapLibre source / layer identifier constants
// ---------------------------------------------------------------------------

/// GeoJSON source id — stable across style swaps and sessions.
const String coverageSourceId = 'coverage_overlay';

/// Line layer id — stable across style swaps and sessions.
const String coverageLayerId = 'coverage_layer';

// ---------------------------------------------------------------------------
// Pure expression builder (Task 3 test seam)
// ---------------------------------------------------------------------------

/// Builds the three MapLibre data-driven paint expressions for the coverage
/// line layer, parameterised by [preset] and [brightness].
///
/// Returned as a Dart record so the caller can destructure each expression
/// individually — useful in tests that assert expression structure without
/// constructing a [MapLibreMapController].
///
/// All expressions are plain [List<dynamic>] — the correct type for passing
/// into [LineLayerProperties]'s [dynamic]-typed fields via the method-channel
/// JSON encoder (RESEARCH Pitfall 5: passing a [List] where a string is
/// expected works because the fields are [dynamic] and pass through
/// `addIfPresent` verbatim).
///
/// **lineColor** — `case` on `is_full`:
///   - 1 (full)  → [CoverageColors.fullHex]
///   - 0 (partial) → [CoverageColors.partialHex]
///
/// **lineOpacity** — `case` on `is_full`:
///   - 1 (full)    → [_kFullOpacity] (0.92)
///   - 0 (partial) → `max(floor, fraction * scale)` — fraction-driven with
///                    a minimum floor (RESEARCH §REN-03)
///
/// **lineWidth** — `interpolate` on zoom (RESEARCH §"Zoom-Scaled Line Width"):
///   z8 → 2.5 px  (country skeleton)
///   z11 → 3.0 px
///   z13 → 4.0 px
///   z15 → 5.0 px (street-level legibility)
///   z18 → 7.0 px (matches rendered road width)
({
  List<dynamic> lineColor,
  List<dynamic> lineOpacity,
  List<dynamic> lineWidth,
}) coverageLinePaintExpressions(
  CoverageColorPreset preset,
  Brightness brightness,
) {
  final colors = preset.forBrightness(brightness);

  final lineColor = <dynamic>[
    'case',
    ['==', ['get', 'is_full'], 1],
    colors.fullHex,
    colors.partialHex,
  ];

  final lineOpacity = <dynamic>[
    'case',
    ['==', ['get', 'is_full'], 1],
    _kFullOpacity,
    <dynamic>[
      'max',
      _kPartialOpacityFloor,
      <dynamic>['*', _kPartialOpacityScale, <dynamic>['get', 'fraction']],
    ],
  ];

  // Zoom-interpolated width stops from RESEARCH §"Zoom-Scaled Line Width".
  // At z8 country scale the 2.5 px width keeps the driven-road network
  // visible as a skeleton without overwhelming the base map. At z18 the
  // 7 px width matches the rendered road width for the characteristic
  // "painted over" look.
  final lineWidth = <dynamic>[
    'interpolate',
    <dynamic>['linear'],
    <dynamic>['zoom'],
    8, 2.5,
    11, 3.0,
    13, 4.0,
    15, 5.0,
    18, 7.0,
  ];

  return (
    lineColor: lineColor,
    lineOpacity: lineOpacity,
    lineWidth: lineWidth,
  );
}

// ---------------------------------------------------------------------------
// Abstract seam
// ---------------------------------------------------------------------------

/// Seam for the coverage overlay source+layer lifecycle.
///
/// Mirrors `TripOverlayApplier` so the production implementation can be
/// replaced with a recording fake in tests that cannot construct a real
/// [MapLibreMapController].
///
/// All methods accept a nullable [MapLibreMapController] — the production
/// implementation early-returns on null, and test fakes can record calls
/// without a live platform view.
abstract class CoverageOverlayApplier {
  /// Add (or re-add after a style swap) the coverage source + line layer.
  ///
  /// Performs a remove-then-readd so repeated calls are idempotent and safe
  /// across `setStyle()` brightness swaps that wipe programmatic layers
  /// (RESEARCH Pitfall 1/3). Always adds the source even when [data] is empty
  /// so the layer is unconditionally present (RESEARCH Pitfall 7).
  Future<void> apply(
    MapLibreMapController? controller, {
    required CoverageOverlayData data,
    required CoverageColorPreset preset,
    required Brightness brightness,
  });

  /// Update the layer's paint properties live — no source reload required.
  ///
  /// Passes the FULL [LineLayerProperties] set to `setLayerProperties`
  /// (RESEARCH open-Q3 / Pitfall 6): the internal `skipNulls:false` call
  /// would silently null out any omitted fields, so we always pass the
  /// complete property object (color + opacity + width + join + cap).
  Future<void> updateColors(
    MapLibreMapController? controller, {
    required CoverageColorPreset preset,
    required Brightness brightness,
  });

  /// Remove the layer + source. Idempotent — silently swallows "not found"
  /// errors so it is safe to call before the source has ever been added and
  /// after a style swap that already wiped them.
  Future<void> remove(MapLibreMapController? controller);
}

// ---------------------------------------------------------------------------
// Production implementation
// ---------------------------------------------------------------------------

/// Production [CoverageOverlayApplier] backed by a live [MapLibreMapController].
class MapLibreCoverageOverlayApplier implements CoverageOverlayApplier {
  const MapLibreCoverageOverlayApplier();

  // -------------------------------------------------------------------------
  // CoverageOverlayApplier interface
  // -------------------------------------------------------------------------

  @override
  Future<void> apply(
    MapLibreMapController? controller, {
    required CoverageOverlayData data,
    required CoverageColorPreset preset,
    required Brightness brightness,
  }) async {
    if (controller == null) return;

    // 1. Clean slate — safe across style swaps (RESEARCH Pitfall 1/3).
    await remove(controller);

    // 2. Always add the source — even when data.ways is empty.
    //    An empty FeatureCollection is valid GeoJSON; the layer renders
    //    nothing but is present so belowLayerId insertion is unconditional
    //    (RESEARCH Pitfall 7).
    final fc = buildCoverageFeatureCollection(data.ways);
    await controller.addGeoJsonSource(coverageSourceId, fc);

    // 3. Discover the best below-label insertion point at runtime.
    //    MapTiler style layer IDs are not hardcoded — discover via getLayerIds.
    final belowId = await _firstSymbolLayerId(controller);

    // 4. Add the line layer with data-driven paint expressions.
    await controller.addLineLayer(
      coverageSourceId,
      coverageLayerId,
      _paint(preset, brightness),
      belowLayerId: belowId,
    );
  }

  @override
  Future<void> updateColors(
    MapLibreMapController? controller, {
    required CoverageColorPreset preset,
    required Brightness brightness,
  }) async {
    if (controller == null) return;
    // Pass the FULL LineLayerProperties (color + opacity + width + join + cap)
    // because setLayerProperties internally calls toJson(skipNulls: false),
    // which would emit null for every omitted field, silently clearing those
    // layer properties on the native side (RESEARCH open-Q3 / Pitfall 6).
    // By passing all intended values every time, we guarantee the layer
    // always has a complete, well-defined paint state after a recolor call.
    await controller.setLayerProperties(
      coverageLayerId,
      _paint(preset, brightness),
    );
  }

  @override
  Future<void> remove(MapLibreMapController? controller) async {
    if (controller == null) return;
    // Remove layer before its source; swallow "not found" errors so the call
    // is idempotent — same pattern as MapLibreTripOverlayApplier.removeTripOverlay.
    try {
      await controller.removeLayer(coverageLayerId);
    } on Object {
      // Layer absent (first run, or already wiped by setStyle()) — ignore.
    }
    try {
      await controller.removeSource(coverageSourceId);
    } on Object {
      // Source absent — ignore.
    }
  }

  // -------------------------------------------------------------------------
  // Private helpers
  // -------------------------------------------------------------------------

  /// Builds a fully-specified [LineLayerProperties] from the paint-expression
  /// builder. Fully-specified = all intended fields set — required because
  /// `setLayerProperties` uses skipNulls:false (see [updateColors] docstring).
  LineLayerProperties _paint(
    CoverageColorPreset preset,
    Brightness brightness,
  ) {
    final exprs = coverageLinePaintExpressions(preset, brightness);
    return LineLayerProperties(
      lineColor: exprs.lineColor,
      lineOpacity: exprs.lineOpacity,
      lineWidth: exprs.lineWidth,
      lineJoin: 'round',
      lineCap: 'round',
    );
  }

  /// Discovers the first symbol/label layer ID in the current style by
  /// calling `controller.getLayerIds()` and searching for known
  /// naming patterns from the MapTiler dataviz style (RESEARCH open-Q4).
  ///
  /// MapTiler dataviz label layers are named like 'Place labels',
  /// 'Road labels', 'POI labels' — all contain 'label', 'place', or 'poi'
  /// (case-insensitive). Returning this ID as `belowLayerId` inserts the
  /// coverage lines above base road geometry but below text labels, so
  /// road names remain legible on top of the orange coverage overlay.
  ///
  /// Falls back to null (top of stack) if:
  ///   - No matching layer is found (custom style with different naming)
  ///   - getLayerIds() throws (pre-style-loaded race, unsupported API)
  ///
  /// The heuristic is documented here rather than hardcoded because hosted
  /// style layer IDs are discovered at runtime — they can change across
  /// MapTiler style versions without a client-side update.
  Future<String?> _firstSymbolLayerId(MapLibreMapController controller) async {
    try {
      final ids = await controller.getLayerIds();
      for (final id in ids) {
        final lower = id.toString().toLowerCase();
        if (lower.contains('label') ||
            lower.contains('place') ||
            lower.contains('poi')) {
          return id.toString();
        }
      }
      return null;
    } on Object {
      // getLayerIds() failed — degrade gracefully; never block the overlay.
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

/// Provider for the coverage overlay applier.
///
/// Tests override this with a recording fake so `apply`/`updateColors`/`remove`
/// calls can be asserted without a live [MapLibreMapController].
/// Mirrors `tripOverlayApplierProvider` in trip_overlay_layers.dart.
final coverageOverlayApplierProvider = Provider<CoverageOverlayApplier>(
  (ref) => const MapLibreCoverageOverlayApplier(),
);
