// Trailblazer Phase 7, Plan 07-07:
// Synthetic 50k CoverageWay generator for the REN-04 stress harness.
//
// Produces deterministic, compute-isolate-safe CoverageWay lists shaped like
// real driven roads inside Germany's bounding box. Used exclusively in the
// debug-only StressCoverageScreen; tree-shaken from release via kDebugMode.
//
// Design:
//   - Top-level functions only (no class state) so `compute(fn, arg)` can
//     receive them as top-level tear-offs.
//   - Germany bbox: lat 47.27..55.06, lon 5.87..15.04 (RESEARCH §Stress Harness).
//   - 3..8 points per way; first point random in-bbox, subsequent points a
//     small random walk (0.001..0.005 deg) so geometries look road-like.
//   - fraction = random 0..1 fed through classifyCoverage so is_full / floor
//     logic is exercised identically to production.
//   - compute-friendly: record typedef arg for single-argument flutter compute call.
//   - buildSyntheticFeatureCollection runs generator + buildCoverageFeatureCollection
//     on a compute isolate (Pitfall 4 — keep 50k build off UI isolate).

import 'dart:math' as math;

import 'package:auto_explore/features/coverage/data/coverage_overlay_data.dart';
import 'package:auto_explore/features/coverage/domain/coverage_threshold.dart';
import 'package:auto_explore/features/coverage/presentation/coverage_feature_collection.dart';
import 'package:flutter/foundation.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

// ---------------------------------------------------------------------------
// Germany bounding box constants (RESEARCH §Stress Harness)
// ---------------------------------------------------------------------------

const double _kLatMin = 47.27;
const double _kLatMax = 55.06;
const double _kLonMin = 5.87;
const double _kLonMax = 15.04;

// Random-walk step range in degrees (makes geometries look road-like).
const double _kWalkStepMin = 0.001;
const double _kWalkStepMax = 0.005;

// Average step (const — used to estimate way length in metres).
const double _kAvgStepDeg = (_kWalkStepMin + _kWalkStepMax) / 2.0;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Generates [count] synthetic coverage ways with deterministic seed [seed].
///
/// All points are inside the Germany bounding box (lat 47.27..55.06,
/// lon 5.87..15.04). Each way has 3–8 points produced by a small random walk
/// so the geometries resemble road segments. Coverage fraction is random 0..1,
/// passed through [classifyCoverage] so the `isFull` / floor logic matches
/// production. wayId equals the way's index.
///
/// Deterministic: two calls with the same [seed] and [count] return identical
/// results. This function is pure (no IO, no Flutter bindings) and safe to run
/// on a Flutter compute isolate.
List<CoverageWay> syntheticCoverageWays({
  int count = 50000,
  int seed = 42,
}) {
  final rng = math.Random(seed);
  final ways = <CoverageWay>[];

  for (var i = 0; i < count; i++) {
    // 3..8 points per way
    final pointCount = 3 + rng.nextInt(6); // 0..5 → 3..8

    // First point: random within Germany bbox
    var lat = _kLatMin + rng.nextDouble() * (_kLatMax - _kLatMin);
    var lon = _kLonMin + rng.nextDouble() * (_kLonMax - _kLonMin);

    final geometry = <LatLng>[LatLng(lat, lon)];

    // Subsequent points: random walk — clamped to stay in bbox
    for (var p = 1; p < pointCount; p++) {
      final stepMag =
          _kWalkStepMin + rng.nextDouble() * (_kWalkStepMax - _kWalkStepMin);
      final sign = rng.nextBool() ? 1.0 : -1.0;
      lat = (lat + sign * stepMag * rng.nextDouble()).clamp(_kLatMin, _kLatMax);
      lon = (lon + sign * stepMag * rng.nextDouble()).clamp(_kLonMin, _kLonMax);
      geometry.add(LatLng(lat, lon));
    }

    // Estimate way length in metres from point count and average step
    // (rough approximation — just needs to be a plausible positive length
    // so classifyCoverage's floor logic can fire).
    // 1 degree ≈ 111,000 m; multiply average step by segment count.
    final wayLengthM = (geometry.length - 1) * _kAvgStepDeg * 111000.0;

    // fraction 0..1 driving classifyCoverage
    final fraction = rng.nextDouble();
    final unionLenM = fraction * wayLengthM;
    final datum = classifyCoverage(unionLenM, wayLengthM);

    ways.add(
      CoverageWay(
        wayId: i,
        geometry: geometry,
        datum: datum,
      ),
    );
  }

  return ways;
}

// ---------------------------------------------------------------------------
// Compute-friendly single-argument variant
// ---------------------------------------------------------------------------

/// Typedef for the record argument passed to [syntheticCoverageWaysArgs].
typedef SyntheticCoverageArgs = ({int count, int seed});

/// Single-argument wrapper around [syntheticCoverageWays] for use as a
/// Flutter compute isolate entry point.
///
/// ```dart
/// final ways = await compute(
///   syntheticCoverageWaysArgs,
///   (count: 50000, seed: 42),
/// );
/// ```
List<CoverageWay> syntheticCoverageWaysArgs(SyntheticCoverageArgs args) =>
    syntheticCoverageWays(count: args.count, seed: args.seed);

// ---------------------------------------------------------------------------
// buildSyntheticFeatureCollection — runs on a compute isolate (Pitfall 4)
// ---------------------------------------------------------------------------

/// Entry point for Flutter compute: generates [count] synthetic ways and converts
/// them to a GeoJSON FeatureCollection map in a single isolate hop.
///
/// Kept as a top-level function so it can be passed as a tear-off to
/// `compute(buildSyntheticFeatureCollectionIsolate, count)`.
Map<String, dynamic> buildSyntheticFeatureCollectionIsolate(int count) {
  final ways = syntheticCoverageWays(count: count);
  return buildCoverageFeatureCollection(ways);
}

/// Runs [syntheticCoverageWays] + [buildCoverageFeatureCollection] on a
/// Flutter compute isolate and returns the GeoJSON FeatureCollection map.
///
/// Offloads to a background isolate to keep the 50k JSON build off the UI
/// thread (RESEARCH Pitfall 4: large Map construction on main isolate blocks
/// frame rendering).
Future<Map<String, dynamic>> buildSyntheticFeatureCollection(int count) =>
    compute(buildSyntheticFeatureCollectionIsolate, count);
