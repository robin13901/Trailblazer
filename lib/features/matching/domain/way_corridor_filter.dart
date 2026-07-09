// Trailblazer Phase 6, Plan 06-07 (re-drive #2 OOM fix):
// Corridor pre-filter for the matcher.
//
// PROBLEM (measured on-device 2026-07-09): a ~96 km commute trip has a bbox
// of ~52 x 42 km. `WayCandidateSource.fetchWaysInBbox` returns EVERY Kfz way
// in that box — 29,497 ways / 13.7 MB — which is then copied across the
// isolate boundary (2x resident) and R-Tree-indexed, on top of the ~529 MB
// resident MapLibre GL surface. That tips the device past its RAM ceiling and
// Android's low-memory-killer terminates the app.
//
// FIX: the trip only travels a thin corridor through that bbox. Keep only ways
// whose geometry passes within ~250 m of the trip polyline before matching.
// This cuts a 96 km-commute way-set by ~20x with no loss of matchable roads
// (the matcher's own candidate radius is 25 m base, so a 250 m corridor is a
// generous superset of everything it could snap to).

import 'dart:math' as math;

import 'package:auto_explore/features/matching/domain/gps_fix.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';

/// Grid cell size in degrees (~278 m of latitude at DE latitudes). Lon cells
/// are finer (~180 m near 49.5°N) which only makes the corridor tighter in the
/// E-W direction — still well above the matcher's 25 m candidate radius.
const double _cellDeg = 0.0025;

/// Along-segment sample spacing in meters. A way segment longer than this is
/// sampled at intervals so a long straight (e.g. an autobahn run with vertices
/// 1 km apart) is not missed just because its endpoints fall outside the
/// corridor while its middle runs right along the trip.
const double _sampleSpacingMeters = 150;

/// Approximate meters per degree of latitude (WGS84 mean).
const double _metersPerDegLat = 111320;

/// Keep only [ways] whose geometry passes within ~one grid cell of the trip
/// path described by [fixes]. Pure function — safe to call on the main isolate
/// (it runs before the expensive isolate copy, shrinking that copy) and unit
/// testable without Drift or platform channels.
///
/// Returns the input list unchanged when [fixes] is empty (nothing to filter
/// against) so a degenerate trip still reaches the matcher's own guards.
List<WayCandidate> filterWaysToTripCorridor({
  required List<GpsFix> fixes,
  required List<WayCandidate> ways,
}) {
  if (fixes.isEmpty || ways.isEmpty) return ways;

  // 1. Build an occupancy set from the trip fixes: each fix marks its own cell
  //    plus the 8 neighbors, giving a corridor half-width of ~one cell.
  final occupied = <int>{};
  for (final f in fixes) {
    final latIdx = (f.lat / _cellDeg).floor();
    final lonIdx = (f.lon / _cellDeg).floor();
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        occupied.add(_cellKey(latIdx + dy, lonIdx + dx));
      }
    }
  }

  // 2. Keep any way with a vertex — or an along-segment sample — in an
  //    occupied cell.
  final kept = <WayCandidate>[];
  for (final w in ways) {
    if (_wayTouchesCorridor(w, occupied)) kept.add(w);
  }
  return kept;
}

bool _wayTouchesCorridor(WayCandidate way, Set<int> occupied) {
  final geom = way.geometry;
  for (var i = 0; i < geom.length; i++) {
    final p = geom[i];
    if (occupied.contains(
      _cellKey((p.latitude / _cellDeg).floor(), (p.longitude / _cellDeg).floor()),
    )) {
      return true;
    }
    // Sample along the segment to the next vertex so long straights are not
    // skipped when both endpoints sit just outside the corridor.
    if (i + 1 < geom.length) {
      final q = geom[i + 1];
      final segMeters = _approxMeters(p.latitude, p.longitude, q.latitude, q.longitude);
      if (segMeters > _sampleSpacingMeters) {
        final steps = (segMeters / _sampleSpacingMeters).ceil();
        for (var s = 1; s < steps; s++) {
          final t = s / steps;
          final lat = p.latitude + (q.latitude - p.latitude) * t;
          final lon = p.longitude + (q.longitude - p.longitude) * t;
          if (occupied.contains(
            _cellKey((lat / _cellDeg).floor(), (lon / _cellDeg).floor()),
          )) {
            return true;
          }
        }
      }
    }
  }
  return false;
}

/// Cheap planar distance approximation — adequate for the short segments and
/// coarse corridor test here (full haversine is unnecessary at this scale).
double _approxMeters(double lat1, double lon1, double lat2, double lon2) {
  final midLatRad = ((lat1 + lat2) / 2) * (math.pi / 180.0);
  final dLatM = (lat2 - lat1) * _metersPerDegLat;
  final dLonM = (lon2 - lon1) * _metersPerDegLat * math.cos(midLatRad);
  return math.sqrt(dLatM * dLatM + dLonM * dLonM);
}

int _cellKey(int latIdx, int lonIdx) {
  // Germany sits in positive lat/lon; at _cellDeg the indices stay well under
  // 20 bits, so a flat multiply-pack is collision-free and fast.
  return latIdx * 10000000 + lonIdx;
}
