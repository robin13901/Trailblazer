// Trailblazer Phase 6, Plan 06-05 Task 3:
// trip_overlay_layers — reusable MapLibre layer helpers for drawing a trip's
// raw GPS polyline (muted) and its matched intervals (accent) on a map.
//
// Extracted so Phase 7's app-wide coverage rendering can reuse the exact same
// source/layer add + clean-remove routine.
//
// **Pitfall Q1**: MapLibre's `setStyle()` (brightness swap) wipes ALL
// programmatic sources + layers. Callers MUST re-run [applyTripOverlay] inside
// `onStyleLoaded` on EVERY style load, not just the first. [applyTripOverlay]
// removes any prior overlay before re-adding, so repeated calls are safe.

import 'package:auto_explore/features/trips/domain/trip_list_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// The rendering payload for a trip's detail-map overlay.
///
/// Carries the read-model item, the raw GPS polyline (always renderable — it
/// comes from `trip_points`, no network needed), the reconstructed matched
/// segments (empty when fail-matched OR offline — the caller distinguishes),
/// and the camera bounds. Lives here (not a separate file) so both
/// [applyTripOverlay] and `TripDetailScreen` share one type without adding a
/// file outside this plan's ownership.
@immutable
class TripDetailData {
  const TripDetailData({
    required this.item,
    required this.rawPolyline,
    required this.matchedSegments,
    required this.bounds,
    required this.matchedWayCount,
    required this.matchedFraction,
    required this.offline,
  });

  final TripListItem item;
  final List<LatLng> rawPolyline;
  final List<List<LatLng>> matchedSegments;
  final LatLngBounds? bounds;

  /// Number of distinct matched ways (intervals). Zero for fail-matched.
  final int matchedWayCount;

  /// driven_length / total_length across this trip's matched ways, in [0, 1].
  /// Null when unknown (offline or no matched geometry).
  final double? matchedFraction;

  /// True when the way geometry could not be resolved (network error + cache
  /// miss, or cache-expired) even though intervals exist. The matched overlay
  /// is skipped and an offline banner is shown.
  final bool offline;
}

String _rawSourceId(int tripId) => 'trip_raw_$tripId';
String _rawLayerId(int tripId) => 'trip_raw_layer_$tripId';
String _matchedSourceId(int tripId) => 'trip_matched_$tripId';
String _matchedLayerId(int tripId) => 'trip_matched_layer_$tripId';

/// Convert a [Color] to a MapLibre `#RRGGBB` hex string.
String colorToHex(Color color) {
  int channel(double v) => (v * 255).round() & 0xff;
  final r = channel(color.r).toRadixString(16).padLeft(2, '0');
  final g = channel(color.g).toRadixString(16).padLeft(2, '0');
  final b = channel(color.b).toRadixString(16).padLeft(2, '0');
  return '#$r$g$b';
}

/// A GeoJSON LineString feature from a list of points.
Map<String, dynamic> _lineStringFeature(List<LatLng> points) => {
      'type': 'Feature',
      'geometry': {
        'type': 'LineString',
        'coordinates': [
          for (final p in points) [p.longitude, p.latitude],
        ],
      },
      'properties': <String, dynamic>{},
    };

/// A GeoJSON MultiLineString feature from a list of segments.
Map<String, dynamic> _multiLineStringFeature(List<List<LatLng>> segments) => {
      'type': 'Feature',
      'geometry': {
        'type': 'MultiLineString',
        'coordinates': [
          for (final seg in segments)
            [
              for (final p in seg) [p.longitude, p.latitude],
            ],
        ],
      },
      'properties': <String, dynamic>{},
    };

/// The overlay-application seam. Overridable in tests via
/// [tripOverlayApplierProvider] so the raw/matched adds can be recorded
/// without a live MapLibre platform view.
///
/// The `controller` is nullable so widget tests (which cannot construct a real
/// [MapLibreMapController]) can drive the whole apply routine with a `null`
/// controller against a recording fake. The production applier below early-
/// returns on a null controller.
abstract class TripOverlayApplier {
  /// Add the raw GPS polyline (muted gray) for [tripId].
  Future<void> addRawPolyline(
    MapLibreMapController? controller, {
    required int tripId,
    required List<LatLng> polyline,
    required Color color,
  });

  /// Add matched intervals (accent) for [tripId].
  Future<void> addMatchedIntervalLayers(
    MapLibreMapController? controller, {
    required int tripId,
    required List<List<LatLng>> matchedSegments,
    required Color color,
  });

  /// Remove both sources + layers for [tripId]. Idempotent.
  Future<void> removeTripOverlay(
    MapLibreMapController? controller,
    int tripId,
  );
}

/// Production [TripOverlayApplier] backed by the MapLibre controller.
class MapLibreTripOverlayApplier implements TripOverlayApplier {
  const MapLibreTripOverlayApplier();

  @override
  Future<void> addRawPolyline(
    MapLibreMapController? controller, {
    required int tripId,
    required List<LatLng> polyline,
    required Color color,
  }) async {
    if (controller == null || polyline.length < 2) return;
    await controller.addGeoJsonSource(
      _rawSourceId(tripId),
      _lineStringFeature(polyline),
    );
    await controller.addLineLayer(
      _rawSourceId(tripId),
      _rawLayerId(tripId),
      LineLayerProperties(
        lineColor: colorToHex(color),
        lineWidth: 3,
        lineOpacity: 0.9,
        lineJoin: 'round',
        lineCap: 'round',
      ),
    );
  }

  @override
  Future<void> addMatchedIntervalLayers(
    MapLibreMapController? controller, {
    required int tripId,
    required List<List<LatLng>> matchedSegments,
    required Color color,
  }) async {
    if (controller == null || matchedSegments.isEmpty) return;
    await controller.addGeoJsonSource(
      _matchedSourceId(tripId),
      _multiLineStringFeature(matchedSegments),
    );
    await controller.addLineLayer(
      _matchedSourceId(tripId),
      _matchedLayerId(tripId),
      LineLayerProperties(
        lineColor: colorToHex(color),
        lineWidth: 5,
        lineJoin: 'round',
        lineCap: 'round',
      ),
    );
  }

  @override
  Future<void> removeTripOverlay(
    MapLibreMapController? controller,
    int tripId,
  ) async {
    if (controller == null) return;
    // Remove layers before their sources; swallow "not found" errors so the
    // call is idempotent across style swaps that already wiped them.
    for (final layerId in [_rawLayerId(tripId), _matchedLayerId(tripId)]) {
      try {
        await controller.removeLayer(layerId);
      } on Object {
        // Layer absent (first run or already wiped) — ignore.
      }
    }
    for (final sourceId in [_rawSourceId(tripId), _matchedSourceId(tripId)]) {
      try {
        await controller.removeSource(sourceId);
      } on Object {
        // Source absent — ignore.
      }
    }
  }
}

/// Provider for the overlay applier. Tests override with a recording fake.
final tripOverlayApplierProvider = Provider<TripOverlayApplier>(
  (ref) => const MapLibreTripOverlayApplier(),
);

/// Apply a trip's overlay to [controller] from [data].
///
/// Always clean-removes any prior overlay first (Pitfall Q1 re-add guard),
/// then draws the raw polyline (always, when present) and the matched
/// intervals (only when [TripDetailData.matchedSegments] is non-empty — i.e.
/// NOT fail-matched, NOT offline). Frames the camera to the trip bounds.
Future<void> applyTripOverlay(
  TripOverlayApplier applier,
  MapLibreMapController? controller,
  TripDetailData data, {
  required Color rawColor,
  required Color matchedColor,
}) async {
  await applier.removeTripOverlay(controller, data.item.id);

  if (data.rawPolyline.length >= 2) {
    await applier.addRawPolyline(
      controller,
      tripId: data.item.id,
      polyline: data.rawPolyline,
      color: rawColor,
    );
  }

  if (data.matchedSegments.isNotEmpty) {
    await applier.addMatchedIntervalLayers(
      controller,
      tripId: data.item.id,
      matchedSegments: data.matchedSegments,
      color: matchedColor,
    );
  }

  final bounds = data.bounds;
  if (controller != null && bounds != null) {
    await controller.moveCamera(
      CameraUpdate.newLatLngBounds(
        bounds,
        left: 40,
        top: 40,
        right: 40,
        bottom: 40,
      ),
    );
  }
}
