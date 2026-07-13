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

/// Default color for the live trail when no coverage color is supplied.
///
/// 2026-07-13 (coverage-from-trail rework): the live trail now reads as
/// "coverage being drawn live" — the bridge passes the current coverage
/// preset color and the line is SOLID (no dash), so the persistent coverage
/// that finalizes post-trip looks identical to what was drawn while driving.
/// This constant is only the fallback when a color isn't provided.
const Color kLiveTrailColor = Color(0xFFFF8C00); // amber full (light)

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

/// Seam for applying the live trail to the map. Overridable in tests.
abstract class LiveTrailApplier {
  /// Add the trail source+layer (first call) or update the source geometry in
  /// place (subsequent calls). No-op if fewer than 2 points. [colorHex] is the
  /// solid line color (e.g. the current coverage preset color); defaults to
  /// [kLiveTrailColor] when null.
  Future<void> addOrUpdate(
    MapLibreMapController? controller,
    List<LatLng> trail, {
    String? colorHex,
  });

  /// Remove the trail source+layer. Idempotent.
  Future<void> remove(MapLibreMapController? controller);
}

/// Production [LiveTrailApplier] backed by the MapLibre controller.
class MapLibreLiveTrailApplier implements LiveTrailApplier {
  const MapLibreLiveTrailApplier();

  @override
  Future<void> addOrUpdate(
    MapLibreMapController? controller,
    List<LatLng> trail, {
    String? colorHex,
  }) async {
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
          // Solid, in the coverage color — the live line and the persistent
          // coverage line are the same look (2026-07-13). No dash.
          lineColor: colorHex ?? _hex(kLiveTrailColor),
          lineWidth: 5,
          lineOpacity: 0.92,
          lineJoin: 'round',
          lineCap: 'round',
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
