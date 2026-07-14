// Trailblazer 2026-07-14 (road-snapped coverage rework):
// coveragePathFromMatch — builds the persistent coverage polyline for a trip
// from the raw GPS fixes + the matcher's per-fix decisions.
//
// The coverage line is ROAD-SNAPPED: for every fix the matcher accepted as
// on-road (a non-null MatchedStep), we draw the fix's SNAPPED position on the
// matched road segment (`MatchedStep.snappedLat/Lon`) rather than the noisy raw
// GPS point. The snapped line hugs the road and closes the small junction gaps
// that plagued the old whole-way resolver — consecutive on-road fixes across a
// short connector chain snap onto adjoining segments, so the line stays
// continuous through the junction.
//
// Where the matcher found NO road match (a `null` step — off-road / low
// confidence, e.g. a parking lot or a field track), we bridge the gap with the
// RAW GPS point so the trail still shows where the vehicle actually went. This
// is the "fill the gaps with the GPS line" behaviour: road geometry where we
// have it, raw GPS only where we don't.
//
// Output: a list of polyline segments, each a list of `[lat, lon]` points. The
// whole trip is ONE segment unless a large GPS outage (> splitGapMeters between
// consecutive points) forces a split, so a dropout doesn't draw a straight line
// across town. Segments with fewer than 2 points are dropped (a LineString
// needs 2+). Pure Dart — no Drift / Riverpod / Flutter — safe to unit-test and
// to run on the matcher isolate.

import 'package:auto_explore/features/matching/domain/matched_step.dart';
import 'package:auto_explore/features/trips/domain/haversine.dart';

/// Distance (m) between two consecutive coverage points beyond which the line
/// is split into separate segments. At ~1 fix/s, in-town spacing is a few tens
/// of meters even at speed; a jump past this implies a multi-second GPS outage
/// worth breaking the line rather than chording straight across.
const double kCoverageSplitGapMeters = 200;

/// Builds the road-snapped coverage polyline for a trip.
///
/// [fixesLatLon] is the raw GPS trail as `[lat, lon]` pairs, in fix order.
/// [steps] is the matcher's per-fix decision list (same length and order): a
/// non-null entry means that fix matched a road (and carries the snapped
/// on-road point); `null` means it was dropped as off-road / low-confidence.
///
/// For each fix: an on-road fix contributes its snapped road point; an off-road
/// fix (or one beyond [steps]) contributes its raw GPS point as a bridge.
/// Consecutive points are joined into one polyline; a jump greater than
/// [splitGapMeters] closes the current run and starts a new one. Points
/// identical to the previous one are dropped (collapses zero-length connector
/// fixes). Runs shorter than 2 points are discarded.
List<List<List<double>>> coveragePathFromMatch(
  List<List<double>> fixesLatLon,
  List<MatchedStep?> steps, {
  double splitGapMeters = kCoverageSplitGapMeters,
}) {
  final segments = <List<List<double>>>[];
  var current = <List<double>>[];
  List<double>? prev;

  for (var i = 0; i < fixesLatLon.length; i++) {
    final step = i < steps.length ? steps[i] : null;

    final List<double> point;
    if (step != null) {
      // On-road: draw the snapped position on the matched road.
      point = [step.snappedLat, step.snappedLon];
    } else {
      // Off-road (or no decision): bridge the gap with the raw GPS point.
      final p = fixesLatLon[i];
      if (p.length < 2) continue; // defensive: skip malformed fix
      point = [p[0], p[1]];
    }

    // Large jump → split so a GPS outage isn't drawn as a straight line.
    if (prev != null &&
        haversineMeters(prev[0], prev[1], point[0], point[1]) >
            splitGapMeters) {
      if (current.length >= 2) segments.add(current);
      current = <List<double>>[];
      prev = null;
    }

    // Skip a point identical to the last (zero-length connector fixes).
    if (current.isEmpty ||
        current.last[0] != point[0] ||
        current.last[1] != point[1]) {
      current.add(point);
      prev = point;
    }
  }
  if (current.length >= 2) segments.add(current);

  return segments;
}
