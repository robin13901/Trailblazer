// Trailblazer region-outline overlay:
// RegionOutlineApplier — the MapLibre seam for the temporary region boundary
// (faint fill + dashed neutral border) shown after "Auf Karte anzeigen".
//
// Mirrors the LiveTrailApplier / MapLibreCoverageOverlayApplier pattern: an
// abstract seam so RegionOutlineBridge can be widget-tested against a recording
// fake with a null controller, plus a production implementation backed by the
// MapLibre controller.
//
// Two GPU layers over one GeoJSON source:
//   - fill layer  (region_outline_fill)  — faint neutral interior
//   - line layer  (region_outline_line)  — dashed neutral border, ON TOP
// Both inserted belowLayerId = first symbol/label layer so map labels stay
// legible on top (same label-discovery heuristic as the coverage overlay).
//
// Safety: production methods early-return on a null controller and swallow
// "not found" on remove so the calls are idempotent across style swaps
// (Pitfall 1 — setStyle wipes programmatic layers).

import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// MapLibre source id for the region outline.
const String regionOutlineSourceId = 'region_outline';

/// MapLibre fill layer id (faint interior).
const String regionOutlineFillLayerId = 'region_outline_fill';

/// MapLibre line layer id (dashed border, drawn on top of the fill).
const String regionOutlineLineLayerId = 'region_outline_line';

/// Faint-fill opacity for the region interior.
const double kRegionOutlineFillOpacity = 0.12;

/// Dashed-border line width (dp).
const double kRegionOutlineLineWidth = 2;

/// Dashed-border line opacity.
const double kRegionOutlineLineOpacity = 0.9;

/// Dash pattern (dash length, gap length) in line-width units.
const List<double> kRegionOutlineDashArray = [2, 2];

/// GeoJSON `(Multi)Polygon` Feature from an [AdminRegion]'s [AdminRegion.polygons].
///
/// [AdminRegion.polygons] is `polygon[ring][point]` where each point is
/// `[lat, lon]`. GeoJSON RFC 7946 §3.1.1 requires `[longitude, latitude]`, so
/// each point is swapped here (same swap as coverage_feature_collection.dart).
/// Ring 0 of each polygon is the outer ring; subsequent rings are holes — all
/// rings are emitted so donut regions (holes) render correctly.
///
/// A single polygon emits a `Polygon`; multiple polygons emit a `MultiPolygon`.
/// Rings with fewer than 4 points are skipped (a valid GeoJSON linear ring needs
/// ≥ 4 positions). If nothing survives, an empty-features FeatureCollection is
/// returned (valid GeoJSON — the layer renders nothing).
//
// TODO(region-outline): a Bundesland polygon can carry tens of thousands of
// vertices, producing a large GeoJSON string across the method channel. If a
// large-region outline stutters on-device, add a zoom-aware Douglas–Peucker
// simplification here — an outline needs no meter precision.
Map<String, dynamic> buildRegionOutlineFeature(AdminRegion region) {
  // Build the list of polygons-of-rings-of-[lon,lat] positions.
  final polygons = <List<List<List<double>>>>[];
  for (final poly in region.polygons) {
    final rings = <List<List<double>>>[];
    for (final ring in poly) {
      if (ring.length < 4) continue; // not a valid GeoJSON linear ring
      rings.add([
        for (final p in ring) [p[1], p[0]], // [lat,lon] -> [lon,lat]
      ]);
    }
    if (rings.isNotEmpty) polygons.add(rings);
  }

  if (polygons.isEmpty) {
    return {'type': 'FeatureCollection', 'features': <Map<String, dynamic>>[]};
  }

  final geometry = polygons.length == 1
      ? <String, dynamic>{'type': 'Polygon', 'coordinates': polygons.first}
      : <String, dynamic>{'type': 'MultiPolygon', 'coordinates': polygons};

  return {
    'type': 'Feature',
    'geometry': geometry,
    'properties': <String, dynamic>{'osm_id': region.osmId},
  };
}

/// Seam for applying the region outline to the map. Overridable in tests.
abstract class RegionOutlineApplier {
  /// Add the outline source + fill/line layers (first call) or update the
  /// source geometry in place (subsequent calls). No-op on a null controller.
  ///
  /// [borderHex] / [fillHex] are `#RRGGBB` strings (the neutral shade for the
  /// current brightness, chosen by the bridge).
  Future<void> addOrUpdate(
    MapLibreMapController? controller,
    AdminRegion region, {
    required String borderHex,
    required String fillHex,
  });

  /// Remove the outline layers + source. Idempotent.
  Future<void> remove(MapLibreMapController? controller);
}

/// Production [RegionOutlineApplier] backed by the MapLibre controller.
class MapLibreRegionOutlineApplier implements RegionOutlineApplier {
  const MapLibreRegionOutlineApplier();

  @override
  Future<void> addOrUpdate(
    MapLibreMapController? controller,
    AdminRegion region, {
    required String borderHex,
    required String fillHex,
  }) async {
    if (controller == null) return;
    final feature = buildRegionOutlineFeature(region);

    // Try an in-place source update first (cheap). If the source doesn't exist
    // yet, add source + both layers below the first label layer.
    try {
      await controller.setGeoJsonSource(regionOutlineSourceId, feature);
    } on Object {
      await controller.addGeoJsonSource(regionOutlineSourceId, feature);
      final belowId = await _firstSymbolLayerId(controller);
      // Fill first (so the dashed line paints on top of the faint interior).
      await controller.addFillLayer(
        regionOutlineSourceId,
        regionOutlineFillLayerId,
        FillLayerProperties(
          fillColor: fillHex,
          fillOpacity: kRegionOutlineFillOpacity,
          fillOutlineColor: borderHex,
        ),
        belowLayerId: belowId,
      );
      await controller.addLineLayer(
        regionOutlineSourceId,
        regionOutlineLineLayerId,
        LineLayerProperties(
          lineColor: borderHex,
          lineWidth: kRegionOutlineLineWidth,
          lineOpacity: kRegionOutlineLineOpacity,
          lineDasharray: kRegionOutlineDashArray,
          lineJoin: 'round',
          lineCap: 'round',
        ),
        belowLayerId: belowId,
      );
    }
  }

  @override
  Future<void> remove(MapLibreMapController? controller) async {
    if (controller == null) return;
    // Remove layers before the source; swallow "not found" so it is idempotent.
    for (final layerId in [regionOutlineLineLayerId, regionOutlineFillLayerId]) {
      try {
        await controller.removeLayer(layerId);
      } on Object {
        // Layer absent (first run or already wiped by setStyle) — ignore.
      }
    }
    try {
      await controller.removeSource(regionOutlineSourceId);
    } on Object {
      // Source absent — ignore.
    }
  }

  /// First symbol/label layer id in the current style, or null. Copied from
  /// MapLibreCoverageOverlayApplier — MapTiler dataviz label layers contain
  /// 'label'/'place'/'poi'; inserting below them keeps road/place names legible
  /// on top of the outline. Degrades to null (top of stack) on any failure.
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
      return null;
    }
  }
}

/// Provider for the region-outline applier. Tests override with a recording fake.
final regionOutlineApplierProvider = Provider<RegionOutlineApplier>(
  (_) => const MapLibreRegionOutlineApplier(),
);
