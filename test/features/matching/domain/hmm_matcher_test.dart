// Phase 5 (Plan 05-05): HmmMatcher integration tests.
//
// Tests cover the full orchestration pipeline:
//   HmmMatcher.match(fixes, ways) → MatchResult.steps + intervals
//
// All WayCandidates are built inline; no fixture files.
// Geometry uses a simple north-south / east-west grid near lat=50, lon=9
// (roughly central Germany) so meter distances are well-defined.
//
// Test inventory (≥ 10 scenarios):
//   1. Empty fixes → empty MatchResult
//   2. Empty ways → all fixes dropped; intervals empty; steps all null
//   3. Single fix on a single 3-node way → 1 step, 1 interval, start==end
//   4. Straight 5-fix forward trace along one 4-node way → 1 interval forward
//   5. Same trace REVERSED → 1 interval backward, start < end
//   6. 10-fix trace: 5 on way A, then 5 on way B → 2 intervals
//   7. Confidence gap: fix #3 is 500 m off any way → 2 intervals on way A
//   8. Direction-flip mid-way (forward 3, backward 3) → intra-way behavior
//      per Plan 05-05 §Deviations (no crash; start ≤ end; valid direction)
//   9. Determinism: two match() calls with identical inputs produce
//      structurally identical MatchResults
//  10. matchedFixCount + droppedFixCount == fixes.length

import 'package:auto_explore/features/matching/domain/gps_fix.dart';
import 'package:auto_explore/features/matching/domain/hmm_matcher.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

// ---------------------------------------------------------------------------
// Constants and geometry helpers
// ---------------------------------------------------------------------------

/// Base latitude / longitude for all test geometry (~central Germany).
const double _baseLat = 50;
const double _baseLon = 9;

/// Approximate meters per degree at _baseLat:
///   lat: ~111 320 m/°
///   lon: ~111 320 * cos(50°) ≈ 71 575 m/°
const double _mPerDegLat = 111320;

// cos(50°) = 0.6427876097; not const because multiplication is not const.
// ignore: prefer_const_declarations
final double _mPerDegLon = _mPerDegLat * 0.6427876097;

/// Convert a local offset in meters to a LatLng relative to the base point.
LatLng _ll(double northMeters, double eastMeters) => LatLng(
      _baseLat + northMeters / _mPerDegLat,
      _baseLon + eastMeters / _mPerDegLon,
    );

/// Build a GpsFix at a local offset from the base point.
/// Uses a fixed timestamp offset of [dtSecs] seconds from epoch.
/// Accuracy defaults to 10 m (different from the 5 m parameter default so
/// avoid_redundant_argument_values is not triggered at call sites).
GpsFix _fix(
  double northMeters,
  double eastMeters, {
  int dtSecs = 0,
  double accuracy = 10,
  double speed = 30,
}) =>
    GpsFix(
      lat: _baseLat + northMeters / _mPerDegLat,
      lon: _baseLon + eastMeters / _mPerDegLon,
      accuracyMeters: accuracy,
      speedKmh: speed,
      ts: DateTime.fromMillisecondsSinceEpoch(dtSecs * 1000, isUtc: true),
    );

// ---------------------------------------------------------------------------
// Shared test ways
// ---------------------------------------------------------------------------

/// A 4-node way running east along the baseline (y=0), nodes at x=0,100,200,300 m.
WayCandidate _eastWay({int id = 1}) => WayCandidate(
      wayId: id,
      highwayClass: 'residential',
      geometry: [
        _ll(0, 0),
        _ll(0, 100),
        _ll(0, 200),
        _ll(0, 300),
      ],
    );

/// A 4-node way B running 500 m north of baseline, nodes at x=0,100,200,300 m.
WayCandidate _northOffsetWay({int id = 2}) => WayCandidate(
      wayId: id,
      highwayClass: 'residential',
      geometry: [
        _ll(500, 0),
        _ll(500, 100),
        _ll(500, 200),
        _ll(500, 300),
      ],
    );

/// A 3-node way running east, nodes at x=0,100,200 m.
WayCandidate _threeNodeWay({int id = 3}) => WayCandidate(
      wayId: id,
      highwayClass: 'residential',
      geometry: [
        _ll(0, 0),
        _ll(0, 100),
        _ll(0, 200),
      ],
    );

// ---------------------------------------------------------------------------
// HmmMatcher under test
// ---------------------------------------------------------------------------

/// Matcher with a generous betaMeters so transition penalties do not
/// dominate for closely-spaced test fixes on straight roads.
const HmmMatcher _matcher = HmmMatcher(betaMeters: 100);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('HmmMatcher', () {
    // -------------------------------------------------------------------------
    // Test 1: Empty fixes → empty MatchResult
    // -------------------------------------------------------------------------
    test(
        '1. empty fixes → empty MatchResult '
        '(0 intervals, 0 matched, 0 dropped)', () {
      final result = _matcher.match(fixes: [], ways: [_eastWay()]);

      expect(result.isEmpty, isTrue);
      expect(result.steps, isEmpty);
      expect(result.intervals, isEmpty);
      expect(result.matchedFixCount, 0);
      expect(result.droppedFixCount, 0);
    });

    // -------------------------------------------------------------------------
    // Test 2: Empty ways → all fixes dropped
    // -------------------------------------------------------------------------
    test('2. empty ways → all fixes dropped; intervals empty; steps all null',
        () {
      final fixes = [
        _fix(0, 50),
        _fix(0, 150, dtSecs: 2),
      ];

      final result = _matcher.match(fixes: fixes, ways: []);

      expect(result.steps.length, 2);
      expect(result.steps.every((s) => s == null), isTrue,
          reason: 'all steps should be null when no ways provided');
      expect(result.intervals, isEmpty);
      expect(result.matchedFixCount, 0);
      expect(result.droppedFixCount, 2);
    });

    // -------------------------------------------------------------------------
    // Test 3: Single fix on a single 3-node way → 1 step, 1 interval point
    // -------------------------------------------------------------------------
    test(
        '3. single fix on a 3-node way → 1 step, 1 interval with '
        'start==end, direction==forward', () {
      // Fix at the midpoint of segment 0 (x=50 m from start).
      final fix = _fix(0, 50);
      final way = _threeNodeWay();

      final result = _matcher.match(fixes: [fix], ways: [way]);

      expect(result.steps.length, 1);
      expect(result.matchedFixCount + result.droppedFixCount, 1);

      // We expect at least one interval if the fix matched.
      if (result.matchedFixCount == 1) {
        expect(result.intervals.length, 1);
        final iv = result.intervals.first;
        expect(iv.wayId, way.wayId);
        // Single fix: start and end meters should be the same.
        expect(iv.startMeters, closeTo(iv.endMeters, 0.01));
        expect(iv.direction, 'forward');
      }
    });

    // -------------------------------------------------------------------------
    // Test 4: 5-fix forward trace → 1 interval, direction='forward'
    // -------------------------------------------------------------------------
    test(
        '4. straight 5-fix forward trace along one 4-node way → '
        '1 interval, direction=forward, start < end', () {
      final way = _eastWay();
      // Place fixes at x=20,80,140,200,260 m (all on or very near the road).
      final fixes = [
        _fix(0, 20),
        _fix(0, 80, dtSecs: 5),
        _fix(0, 140, dtSecs: 10),
        _fix(0, 200, dtSecs: 15),
        _fix(0, 260, dtSecs: 20),
      ];

      final result = _matcher.match(fixes: fixes, ways: [way]);

      expect(result.matchedFixCount + result.droppedFixCount, fixes.length);

      // We expect exactly 1 interval if the trace matched well.
      expect(result.intervals.length, 1,
          reason: 'all fixes on same way → 1 interval');
      final iv = result.intervals.first;
      expect(iv.wayId, way.wayId);
      expect(iv.direction, 'forward');
      expect(iv.startMeters, lessThan(iv.endMeters),
          reason: 'forward trace: start < end');
    });

    // -------------------------------------------------------------------------
    // Test 5: Same trace REVERSED → direction='backward', start < end
    // -------------------------------------------------------------------------
    test(
        '5. reversed trace on same 4-node way → '
        'direction=backward, start < end (min/max swap)', () {
      final way = _eastWay();
      // Fixes travel from x=260 back to x=20 m.
      final fixes = [
        _fix(0, 260),
        _fix(0, 200, dtSecs: 5),
        _fix(0, 140, dtSecs: 10),
        _fix(0, 80, dtSecs: 15),
        _fix(0, 20, dtSecs: 20),
      ];

      final result = _matcher.match(fixes: fixes, ways: [way]);

      expect(result.matchedFixCount + result.droppedFixCount, fixes.length);
      expect(result.intervals.length, 1);
      final iv = result.intervals.first;
      expect(iv.wayId, way.wayId);
      expect(iv.direction, 'backward');
      // After min/max swap, startMeters <= endMeters.
      expect(iv.startMeters, lessThanOrEqualTo(iv.endMeters));
      expect(iv.startMeters, greaterThanOrEqualTo(0));
    });

    // -------------------------------------------------------------------------
    // Test 6: 10-fix trace: 5 on way A, then 5 on way B → 2 intervals
    // -------------------------------------------------------------------------
    test(
        '6. 10-fix trace: 5 fixes on way A then 5 on way B → '
        '2 intervals, one per way', () {
      final wayA = _eastWay();
      final wayB = _northOffsetWay();

      final fixes = [
        // 5 fixes along way A (y=0, x=20..260)
        _fix(0, 20),
        _fix(0, 80, dtSecs: 5),
        _fix(0, 140, dtSecs: 10),
        _fix(0, 200, dtSecs: 15),
        _fix(0, 260, dtSecs: 20),
        // 5 fixes along way B (y=500, x=20..260)
        _fix(500, 20, dtSecs: 25),
        _fix(500, 80, dtSecs: 30),
        _fix(500, 140, dtSecs: 35),
        _fix(500, 200, dtSecs: 40),
        _fix(500, 260, dtSecs: 45),
      ];

      final result = _matcher.match(fixes: fixes, ways: [wayA, wayB]);

      expect(result.matchedFixCount + result.droppedFixCount, fixes.length);
      // Expect at least 2 intervals (one per way). Some fixes may drop
      // but the way-change boundary must produce at least 2 intervals.
      expect(result.intervals.length, greaterThanOrEqualTo(2),
          reason: 'way change must produce at least 2 intervals');

      final wayIds = result.intervals.map((iv) => iv.wayId).toSet();
      expect(wayIds, contains(wayA.wayId));
      expect(wayIds, contains(wayB.wayId));
    });

    // -------------------------------------------------------------------------
    // Test 7: Confidence gap mid-trace → 2 intervals on way A
    // -------------------------------------------------------------------------
    test(
        '7. confidence gap (fix #3 is 500 m off any way) → '
        '≥ 2 intervals on way A separated by the drop', () {
      final way = _eastWay();

      // Fix 3 is placed 500 m north of the road — well beyond the 150 m
      // adaptive radius; the decoder drops it as unmatched (null step).
      final fixes = [
        _fix(0, 20),
        _fix(0, 80, dtSecs: 5),
        _fix(500, 140, dtSecs: 10), // ← 500 m north, should be dropped
        _fix(0, 200, dtSecs: 15),
        _fix(0, 260, dtSecs: 20),
      ];

      final result = _matcher.match(fixes: fixes, ways: [way]);

      // Verify fix #3 was dropped.
      expect(result.droppedFixCount, greaterThanOrEqualTo(1));
      // After the gap, a new interval must start → at least 2 intervals.
      expect(result.intervals.length, greaterThanOrEqualTo(2),
          reason: 'null gap must split the interval');

      // All intervals must be on way A.
      for (final iv in result.intervals) {
        expect(iv.wayId, way.wayId);
      }
    });

    // -------------------------------------------------------------------------
    // Test 8: Direction flip mid-way (forward then backward)
    // -------------------------------------------------------------------------
    // Per Plan 05-05 §Deviations: the merger does NOT split intra-way
    // direction changes. A single interval is produced whose direction is
    // the sign of the net delta (rawFirstMeters → rawLastMeters).
    test(
        '8. direction flip mid-way (forward 3, backward 3) → '
        'no crash; all intervals have start ≤ end; '
        'direction is forward or backward (not both)', () {
      final way = _eastWay();
      final fixes = [
        // Forward 3 fixes
        _fix(0, 20),
        _fix(0, 140, dtSecs: 5),
        _fix(0, 260, dtSecs: 10),
        // Backward 3 fixes — same road, going back
        _fix(0, 200, dtSecs: 15),
        _fix(0, 100, dtSecs: 20),
        _fix(0, 20, dtSecs: 25),
      ];

      final result = _matcher.match(fixes: fixes, ways: [way]);

      expect(result.matchedFixCount + result.droppedFixCount, fixes.length);
      // All intervals must respect start ≤ end.
      for (final iv in result.intervals) {
        expect(iv.startMeters, lessThanOrEqualTo(iv.endMeters));
        expect(iv.wayId, way.wayId);
      }
      // Direction must be 'forward' or 'backward', never 'both'.
      for (final iv in result.intervals) {
        expect(iv.direction, anyOf('forward', 'backward'));
      }
    });

    // -------------------------------------------------------------------------
    // Test 9: Determinism — two calls with identical inputs → identical outputs
    // -------------------------------------------------------------------------
    test(
        '9. determinism: two match() calls with identical inputs → '
        'structurally identical MatchResults', () {
      final way = _eastWay();
      final fixes = [
        _fix(0, 20),
        _fix(0, 80, dtSecs: 5),
        _fix(0, 140, dtSecs: 10),
        _fix(0, 200, dtSecs: 15),
        _fix(0, 260, dtSecs: 20),
      ];

      final r1 = _matcher.match(fixes: fixes, ways: [way]);
      final r2 = _matcher.match(fixes: fixes, ways: [way]);

      expect(r1.matchedFixCount, r2.matchedFixCount);
      expect(r1.droppedFixCount, r2.droppedFixCount);
      expect(r1.intervals.length, r2.intervals.length);

      // Compare intervals by toString — sufficient for structural equality.
      final iv1 = r1.intervals.map((iv) => iv.toString()).toList();
      final iv2 = r2.intervals.map((iv) => iv.toString()).toList();
      expect(iv1, iv2,
          reason: 'identical inputs must produce identical intervals');
    });

    // -------------------------------------------------------------------------
    // Test 10: matchedFixCount + droppedFixCount == fixes.length
    // -------------------------------------------------------------------------
    test(
        '10. matchedFixCount + droppedFixCount == fixes.length for any input',
        () {
      // Case A: all fixes expected to match.
      final wayA = _eastWay();
      final fixesA = [
        _fix(0, 20),
        _fix(0, 140, dtSecs: 5),
        _fix(0, 260, dtSecs: 10),
      ];
      final rA = _matcher.match(fixes: fixesA, ways: [wayA]);
      expect(rA.matchedFixCount + rA.droppedFixCount, fixesA.length);

      // Case B: all fixes dropped (no ways).
      final fixesB = [
        _fix(0, 20),
        _fix(0, 140, dtSecs: 5),
      ];
      final rB = _matcher.match(fixes: fixesB, ways: []);
      expect(rB.matchedFixCount + rB.droppedFixCount, fixesB.length);

      // Case C: mix (one off-road fix).
      final fixesC = [
        _fix(0, 20),
        _fix(500, 140, dtSecs: 5), // off-road
        _fix(0, 260, dtSecs: 10),
      ];
      final rC = _matcher.match(fixes: fixesC, ways: [wayA]);
      expect(rC.matchedFixCount + rC.droppedFixCount, fixesC.length);
    });
  });
}
