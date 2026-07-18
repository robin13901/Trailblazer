// Trailblazer live-nav:
// LivePuckApplier — the MapLibre seam for the live location puck drawn from
// the liveFixProvider feed.
//
// Mirrors the LiveTrailApplier pattern: abstract seam (overridable in tests)
// + production MapLibre implementation.  The bridge keeps the puck at the
// tip of the live trail in the same tick the trail extends (F5 fix — no
// lag-then-jump).
//
// Layer hierarchy (back → front):
//   live_trail_layer  (drawn by LiveTrailApplier)
//   live_puck_layer   ← sits ON TOP so the puck is never hidden by the line

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// MapLibre source id for the live puck point.
const String livePuckSourceId = 'live_puck';

/// MapLibre layer id for the live puck circle.
const String livePuckLayerId = 'live_puck_layer';

/// Puck fill color (blue, matching a conventional location indicator).
const String kLivePuckFillHex = '#1976D2';

/// Puck stroke color (white, so the dot pops against any map tile).
const String kLivePuckStrokeHex = '#FFFFFF';

/// GeoJSON Point feature from a [LatLng] ([lng, lat] order, per GeoJSON).
Map<String, dynamic> livePuckPointFeature(LatLng point) => {
      'type': 'Feature',
      'geometry': {
        'type': 'Point',
        'coordinates': [point.longitude, point.latitude],
      },
      'properties': <String, dynamic>{},
    };

/// Seam for applying the live puck to the map.  Overridable in tests.
abstract class LivePuckApplier {
  /// Add the puck source+layer (first call) or update the source position
  /// in place (subsequent calls).  [heading] is currently unused in the
  /// circle-only implementation — kept in the API so a symbol rotation can
  /// be added later without changing callers.
  Future<void> addOrUpdate(
    MapLibreMapController? controller,
    LatLng point, {
    double? heading,
  });

  /// Remove the puck source+layer. Idempotent.
  Future<void> remove(MapLibreMapController? controller);
}

/// Production [LivePuckApplier] backed by the MapLibre controller.
class MapLibreLivePuckApplier implements LivePuckApplier {
  const MapLibreLivePuckApplier();

  @override
  Future<void> addOrUpdate(
    MapLibreMapController? controller,
    LatLng point, {
    double? heading,
  }) async {
    if (controller == null) return;
    final feature = livePuckPointFeature(point);
    // Try an in-place source update first (cheap — no layer churn).  If the
    // source doesn't exist yet (style load wipes it — Pitfall 1), add source
    // + layer.
    try {
      await controller.setGeoJsonSource(livePuckSourceId, feature);
    } on Object {
      await controller.addGeoJsonSource(livePuckSourceId, feature);
      await controller.addCircleLayer(
        livePuckSourceId,
        livePuckLayerId,
        const CircleLayerProperties(
          circleRadius: 9,
          circleColor: kLivePuckFillHex,
          circleStrokeWidth: 2.5,
          circleStrokeColor: kLivePuckStrokeHex,
          circleOpacity: 1,
        ),
        // Place ABOVE the live trail so the puck sits on top of the line tip.
        // No belowLayerId needed — default (null) places the layer at the top.
      );
    }
  }

  @override
  Future<void> remove(MapLibreMapController? controller) async {
    if (controller == null) return;
    // Remove layer before source; swallow "not found" on a clean slate.
    try {
      await controller.removeLayer(livePuckLayerId);
    } on Object {
      // layer absent — fine.
    }
    try {
      await controller.removeSource(livePuckSourceId);
    } on Object {
      // source absent — fine.
    }
  }
}

/// Provider for the live-puck applier.  Tests override with a recording fake.
final livePuckApplierProvider = Provider<LivePuckApplier>(
  (_) => const MapLibreLivePuckApplier(),
);
