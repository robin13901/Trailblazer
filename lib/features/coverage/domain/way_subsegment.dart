// Trailblazer 2026-07-18 (clipped way-geometry coverage rendering):
// way_subsegment — clip an OSM way's polyline to a driven `[startMeters,
// endMeters]` sub-interval, with optional endpoint snap-to-node so adjacent
// clipped ways meet cleanly at junctions.
//
// Promoted from a private function in trip_detail_screen.dart (the trip-detail
// mini-map already rendered this way) so the app-wide coverage overlay can
// reuse the exact same clip. Pure Dart — no Flutter/Drift/Riverpod — safe on a
// compute() isolate.

import 'dart:math' as math;

import 'package:auto_explore/features/trips/domain/haversine.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

/// Endpoint snap tolerance (m). When a driven interval starts within this of a
/// way's first node it is snapped to 0; when it ends within this of the way's
/// last node it is snapped to the full length. This closes the small gaps at
/// junctions where GPS stopped matching a few metres before the shared node,
/// so two adjacent clipped ways visually meet. Render-only — never changes the
/// stored interval or the km numerator (you shouldn't claim km you didn't
/// drive; a few metres of paint at a junction is cosmetic).
const double kWaySubsegmentSnapMeters = 20;

/// Extract the sub-polyline of [geometry] between [startMeters] and
/// [endMeters] (distances measured along the way from its first node). Handles
/// reversed intervals (start > end) by normalizing the range.
///
/// When [snapMeters] > 0, an interval whose start is within [snapMeters] of the
/// way start is extended to 0, and whose end is within [snapMeters] of the way
/// end is extended to the full length — closing junction gaps (see
/// [kWaySubsegmentSnapMeters]). Pass 0 to disable snapping (exact clip).
///
/// Returns `const []` for degenerate geometry (< 2 points) or an empty overlap.
List<LatLng> reconstructWaySubsegment(
  List<LatLng> geometry,
  double startMeters,
  double endMeters, {
  double snapMeters = 0,
}) {
  if (geometry.length < 2) return const [];
  var lo = math.min(startMeters, endMeters);
  var hi = math.max(startMeters, endMeters);

  if (snapMeters > 0) {
    final total = _polylineLengthMeters(geometry);
    if (lo <= snapMeters) lo = 0;
    if (hi >= total - snapMeters) hi = total;
  }

  final result = <LatLng>[];
  var cumulative = 0.0;
  for (var i = 0; i < geometry.length - 1; i++) {
    final a = geometry[i];
    final b = geometry[i + 1];
    final segLen = haversineMeters(
      a.latitude,
      a.longitude,
      b.latitude,
      b.longitude,
    );
    final segStart = cumulative;
    final segEnd = cumulative + segLen;
    if (segLen > 0 && segEnd >= lo && segStart <= hi) {
      final tStart = ((lo - segStart) / segLen).clamp(0.0, 1.0);
      final tEnd = ((hi - segStart) / segLen).clamp(0.0, 1.0);
      final pStart = _lerpLatLng(a, b, tStart);
      final pEnd = _lerpLatLng(a, b, tEnd);
      if (result.isEmpty) {
        result.add(pStart);
      }
      result.add(pEnd);
    }
    cumulative = segEnd;
  }
  return result;
}

/// Total Haversine length (m) of a polyline.
double _polylineLengthMeters(List<LatLng> geometry) {
  var total = 0.0;
  for (var i = 0; i < geometry.length - 1; i++) {
    total += haversineMeters(
      geometry[i].latitude,
      geometry[i].longitude,
      geometry[i + 1].latitude,
      geometry[i + 1].longitude,
    );
  }
  return total;
}

LatLng _lerpLatLng(LatLng a, LatLng b, double t) => LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );
