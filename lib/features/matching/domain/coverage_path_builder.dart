// Trailblazer 2026-07-13 (coverage-from-trail rework):
// coveragePathFromMatch — builds the persistent on-road coverage polyline for
// a trip from the raw GPS fixes + the matcher's per-fix decisions.
//
// The user's live dashed trail is drawn straight from raw GPS and is very
// accurate on-road, so it becomes the persistent coverage line. But raw GPS
// also wanders across parking lots and off-road spots, which we do NOT want
// painted permanently. The HMM matcher already decides, per fix, whether that
// fix lay on a road (a non-null MatchedStep) or not (null — dropped below the
// confidence threshold). We use exactly that decision to TRIM the raw trail:
// keep the raw coordinates of on-road fixes, split into contiguous runs
// wherever an off-road gap interrupts them.
//
// Output: a list of polyline segments, each a list of `[lat, lon]` points.
// Segments with fewer than 2 points are dropped (a LineString needs 2+).
// Pure Dart — no Drift / Riverpod / Flutter — safe to unit-test and, if ever
// needed, to run on the matcher isolate.

import 'package:auto_explore/features/matching/domain/matched_step.dart';

/// Builds the trimmed on-road coverage polyline for a trip.
///
/// [fixesLatLon] is the raw GPS trail as `[lat, lon]` pairs, in fix order.
/// [steps] is the matcher's per-fix decision list (same length and order):
/// a non-null entry means that fix matched a road, `null` means it was
/// dropped as off-road / low-confidence.
///
/// Returns contiguous on-road runs: consecutive matched fixes form one
/// segment; a `null` step breaks the current segment. Each segment is a list
/// of `[lat, lon]` points; single-point segments are dropped.
///
/// When [steps] is empty or shorter than [fixesLatLon] (e.g. the matcher was
/// skipped), the trailing unmatched fixes are treated as off-road and dropped.
List<List<List<double>>> coveragePathFromMatch(
  List<List<double>> fixesLatLon,
  List<MatchedStep?> steps,
) {
  final segments = <List<List<double>>>[];
  var current = <List<double>>[];

  for (var i = 0; i < fixesLatLon.length; i++) {
    final onRoad = i < steps.length && steps[i] != null;
    if (onRoad) {
      final p = fixesLatLon[i];
      // Defensive: skip malformed points.
      if (p.length >= 2) current.add([p[0], p[1]]);
    } else {
      // Off-road (or no decision) → close the current run.
      if (current.length >= 2) segments.add(current);
      current = <List<double>>[];
    }
  }
  if (current.length >= 2) segments.add(current);

  return segments;
}
