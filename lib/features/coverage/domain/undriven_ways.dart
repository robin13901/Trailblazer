// Trailblazer undriven-ways overlay (on-demand, in-memory):
// Pure computation of the UNDRIVEN road segments inside one admin region.
//
// Given the region's Kfz ways (fetched fresh / cache-first from Overpass) and
// the driven intervals per way, this emits the complement — the parts of each
// way that lie INSIDE the region polygon and have NOT been driven — as
// CoverageWays ready for the blue undriven overlay.
//
// Pure Dart — no Flutter/Drift/Riverpod/IO — so it runs on a compute() isolate
// (mirrors clipDrivenWays / computeCoverageAttribution). The only external deps
// are the value types (WayCandidate, AdminRegion, Interval, CoverageWay) and
// the shared geometry helpers (reconstructWaySubsegment, haversine).

import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/coverage/data/coverage_overlay_data.dart';
import 'package:auto_explore/features/coverage/domain/coverage_datum.dart';
import 'package:auto_explore/features/coverage/domain/interval_union.dart';
import 'package:auto_explore/features/coverage/domain/way_subsegment.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/trips/domain/haversine.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

/// Undriven sub-segments shorter than this (meters) are dropped. Keeps the
/// overlay free of sliver artifacts from boundary-midpoint jitter and
/// float-precision gaps at junctions, without hiding genuine short stubs.
const double kUndrivenMinSegmentMeters = 5;

/// Computes the undriven road segments inside [region].
///
/// For each way in [ways]:
///   1. Find the contiguous meter-ranges whose segment midpoints fall INSIDE
///      [region] (so neighbouring roads reaching into the bbox are excluded).
///   2. Subtract the way's driven union intervals ([drivenByWayId]) from each
///      in-region range, leaving the UNDRIVEN gaps.
///   3. Reconstruct each gap's sub-polyline and emit it as a [CoverageWay]
///      (datum = undriven).
///
/// A way with no driven intervals contributes its whole in-region length; a
/// fully-driven way (inside the region) contributes nothing.
List<CoverageWay> computeUndrivenWays({
  required List<WayCandidate> ways,
  required AdminRegion region,
  required Map<int, List<Interval>> drivenByWayId,
  double minSegmentMeters = kUndrivenMinSegmentMeters,
}) {
  final out = <CoverageWay>[];

  for (final way in ways) {
    if (way.geometry.length < 2) continue;

    final inRegion = _inRegionRanges(way.geometry, region);
    if (inRegion.isEmpty) continue;

    final drivenUnion = unionIntervals(drivenByWayId[way.wayId] ?? const []);

    for (final range in inRegion) {
      for (final gap in _subtract(range, drivenUnion)) {
        if (gap.lengthMeters < minSegmentMeters) continue;
        final seg = reconstructWaySubsegment(
          way.geometry,
          gap.startMeters,
          gap.endMeters,
        );
        if (seg.length < 2) continue;
        out.add(
          CoverageWay(
            wayId: way.wayId,
            geometry: seg,
            datum: const CoverageDatum.undriven(),
          ),
        );
      }
    }
  }

  return out;
}

/// Contiguous meter-ranges of [geom] whose segment midpoints lie inside
/// [region]. Segment-midpoint containment mirrors `coverage_attribution.dart`'s
/// `_clipWayAtLevel`, which is the established approximation for clipping a
/// densified OSM polyline to an admin polygon.
List<Interval> _inRegionRanges(List<LatLng> geom, AdminRegion region) {
  final ranges = <Interval>[];
  double? runStart;
  var runEnd = 0.0;
  var cursor = 0.0;

  for (var i = 0; i < geom.length - 1; i++) {
    final a = geom[i];
    final b = geom[i + 1];
    final segLen = haversineMeters(
      a.latitude,
      a.longitude,
      b.latitude,
      b.longitude,
    );
    final segStart = cursor;
    final segEnd = cursor + segLen;
    cursor = segEnd;
    if (segLen <= 0) continue;

    final inside = region.containsPoint(
      (a.latitude + b.latitude) / 2,
      (a.longitude + b.longitude) / 2,
    );
    if (inside) {
      runStart ??= segStart;
      runEnd = segEnd;
    } else if (runStart != null) {
      ranges.add(Interval(runStart, runEnd));
      runStart = null;
    }
  }
  if (runStart != null) ranges.add(Interval(runStart, runEnd));
  return ranges;
}

/// The gaps of [range] not covered by the sorted, disjoint [drivenUnion]
/// (as produced by [unionIntervals]) — i.e. `range \ drivenUnion`.
List<Interval> _subtract(Interval range, List<Interval> drivenUnion) {
  final gaps = <Interval>[];
  var cursor = range.startMeters;

  for (final iv in drivenUnion) {
    if (iv.endMeters <= range.startMeters) continue; // entirely before range
    if (iv.startMeters >= range.endMeters) break; // entirely after (sorted)
    final gapEnd = iv.startMeters < range.endMeters
        ? iv.startMeters
        : range.endMeters;
    if (gapEnd > cursor) gaps.add(Interval(cursor, gapEnd));
    if (iv.endMeters > cursor) cursor = iv.endMeters;
  }
  if (cursor < range.endMeters) gaps.add(Interval(cursor, range.endMeters));
  return gaps;
}
