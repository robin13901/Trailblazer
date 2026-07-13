// Trailblazer live-nav:
// LiveTrailApplier — the MapLibre seam for the live dashed raw-GPS trail.
//
// Mirrors the TripOverlayApplier / MapLibreCoverageOverlayApplier pattern: an
// abstract seam so LiveTrailBridge can be widget-tested against a recording
// fake with a null controller, plus a production implementation backed by the
// MapLibre controller.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// MapLibre source id for the live dashed trail.
const String liveTrailSourceId = 'live_trail';

/// MapLibre layer id for the live dashed trail.
const String liveTrailLayerId = 'live_trail_layer';

/// Accent color for the live trail. A bright cyan reads as "live / provisional"
/// and is deliberately distinct from the coverage overlay's greens so the
/// dashed live path is never confused with finalized matched coverage.
const Color kLiveTrailColor = Color(0xFF00E5FF);

/// GeoJSON LineString feature from [points] ([lng, lat] order, per GeoJSON).
Map<String, dynamic> liveTrailLineFeature(List<LatLng> points) => {
      'type': 'Feature',
      'geometry': {
        'type': 'LineString',
        'coordinates': [
          for (final p in points) [p.longitude, p.latitude],
        ],
      },
      'properties': <String, dynamic>{},
    };

/// Seam for applying the live dashed trail to the map. Overridable in tests.
abstract class LiveTrailApplier {
  /// Add the dashed trail source+layer (first call) or update the source
  /// geometry in place (subsequent calls). No-op if fewer than 2 points.
  Future<void> addOrUpdate(
    MapLibreMapController? controller,
    List<LatLng> trail,
  );

  /// Remove the trail source+layer. Idempotent.
  Future<void> remove(MapLibreMapController? controller);
}

/// Production [LiveTrailApplier] backed by the MapLibre controller.
class MapLibreLiveTrailApplier implements LiveTrailApplier {
  const MapLibreLiveTrailApplier();

  @override
  Future<void> addOrUpdate(
    MapLibreMapController? controller,
    List<LatLng> trail,
  ) async {
    if (controller == null || trail.length < 2) return;
    final feature = liveTrailLineFeature(trail);
    // Try an in-place source update first (cheap, no layer churn). If the
    // source doesn't exist yet, add source + layer.
    try {
      await controller.setGeoJsonSource(liveTrailSourceId, feature);
    } on Object {
      await controller.addGeoJsonSource(liveTrailSourceId, feature);
      await controller.addLineLayer(
        liveTrailSourceId,
        liveTrailLayerId,
        LineLayerProperties(
          lineColor: _hex(kLiveTrailColor),
          lineWidth: 4,
          lineOpacity: 0.9,
          lineJoin: 'round',
          lineCap: 'round',
          // Dash pattern (in line-widths): distinguishes the provisional live
          // trail from the solid matched coverage. maplibre_gl 0.26.2 supports
          // line-dasharray on js/android/ios/macos.
          lineDasharray: const [2, 2],
        ),
      );
    }
  }

  @override
  Future<void> remove(MapLibreMapController? controller) async {
    if (controller == null) return;
    // Remove layer before source; swallow "not found" on a clean slate.
    try {
      await controller.removeLayer(liveTrailLayerId);
    } on Object {
      // layer absent — fine.
    }
    try {
      await controller.removeSource(liveTrailSourceId);
    } on Object {
      // source absent — fine.
    }
  }

  String _hex(Color color) {
    int channel(double v) => (v * 255).round() & 0xff;
    final r = channel(color.r).toRadixString(16).padLeft(2, '0');
    final g = channel(color.g).toRadixString(16).padLeft(2, '0');
    final b = channel(color.b).toRadixString(16).padLeft(2, '0');
    return '#$r$g$b';
  }
}

/// Provider for the live-trail applier. Tests override with a recording fake.
final liveTrailApplierProvider = Provider<LiveTrailApplier>(
  (_) => const MapLibreLiveTrailApplier(),
);
