import 'dart:math' as math;

import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/matching/domain/way_segment.dart';
import 'package:auto_explore/features/trips/domain/haversine.dart';

/// Pure, network-free helpers that turn a snapped road [WaySegment] into a
/// stabilized camera bearing for heading-up navigation.
///
/// Design: the road segment gives the precise *axis* of travel (its tangent),
/// but a line has two directions (θ and θ+180). The raw GPS heading — even when
/// jittery — reliably tells us which of the two we're driving. So we snap to
/// the road axis and disambiguate the sign with the raw heading. This handles
/// two-way, oneway, and reverse-oneway ways uniformly.
///
/// When no raw heading is available (stationary / no course over ground), we
/// fall back to the way's stored orientation via its [OnewayDirection].

/// Smallest absolute angular difference between two bearings, in `0..180`.
double headingDelta(double a, double b) {
  final diff = (a - b).abs() % 360.0;
  return diff > 180.0 ? 360.0 - diff : diff;
}

/// Travel-direction bearing (0..360) along [seg], disambiguated by [rawHeading].
///
/// - Computes the segment tangent `a → b` via [bearingDegrees].
/// - If [rawHeading] is provided, returns whichever of {tangent, tangent+180}
///   is angularly closest to it — the road fixes the axis, GPS fixes the sign.
/// - If [rawHeading] is null, uses the stored orientation: [OnewayDirection.no]
///   and [OnewayDirection.forward] → tangent; [OnewayDirection.backward] →
///   reverse (Overpass verbatim `oneway=-1`, where node order was not flipped).
double segmentTravelBearing(WaySegment seg, double? rawHeading) {
  final tangent = bearingDegrees(seg.aLat, seg.aLon, seg.bLat, seg.bLon);
  final reverse = (tangent + 180.0) % 360.0;

  if (rawHeading != null) {
    return headingDelta(tangent, rawHeading) <= headingDelta(reverse, rawHeading)
        ? tangent
        : reverse;
  }

  return switch (seg.oneway) {
    OnewayDirection.backward => reverse,
    OnewayDirection.forward => tangent,
    OnewayDirection.no => tangent,
  };
}

/// Circularly blends the [roadBearing] with the [rawHeading] so a good road
/// snap dominates while still tracking the GPS when the two disagree, and so a
/// missing/poor snap degrades gracefully.
///
/// [roadWeight] in `0..1` is the weight given to the road bearing (default
/// 0.8 — road-dominant). Blending is done in vector space (sin/cos) so it
/// respects the circular wrap at 0/360 and always takes the shortest arc.
///
/// Returns [roadBearing] unchanged when [rawHeading] is null.
double blendHeading(
  double roadBearing,
  double? rawHeading, {
  double roadWeight = 0.8,
}) {
  if (rawHeading == null) return roadBearing;
  final w = roadWeight.clamp(0.0, 1.0);
  final roadRad = roadBearing * (math.pi / 180.0);
  final rawRad = rawHeading * (math.pi / 180.0);
  final x = w * math.cos(roadRad) + (1 - w) * math.cos(rawRad);
  final y = w * math.sin(roadRad) + (1 - w) * math.sin(rawRad);
  return (math.atan2(y, x) * (180.0 / math.pi) + 360.0) % 360.0;
}
