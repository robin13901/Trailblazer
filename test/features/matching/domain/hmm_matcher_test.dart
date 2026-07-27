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
    // Test 7: Confidence gap mid-trace on a single way with NO branch node
    // between the two runs → #10 (2026-07-26) bridges them into ONE interval.
    // -------------------------------------------------------------------------
    // BEHAVIOUR CHANGE (#10 highway gap fill): the same-way auto-fill upper
    // 30 m cap was removed. Way A is a single continuous OSM way and no branch
    // node (degree > 2 — there are no other ways here, so every node is
    // degree 1) lies between the two matched runs, so the 120 m hole left by
    // the dropped fix is provably drivable and is merged into a single interval
    // spanning the whole driven span. The fix is still DROPPED (unmatched);
    // only the interval-level bridging changed. Previously this produced 2
    // intervals; that premise is now contradicted by FIX B #10.
    test(
        '7. confidence gap (fix #3 is 500 m off any way) → '
        'dropped, and the same-way runs merge (no branch node between)', () {
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
      // #10: no branch node between the runs → bridged into a single interval.
      expect(result.intervals.length, equals(1),
          reason: 'same-way gap with no branch node is bridged (#10)');

      // The single interval must be on way A and span the full driven range.
      final iv = result.intervals.single;
      expect(iv.wayId, way.wayId);
      expect(iv.startMeters, lessThanOrEqualTo(20.1));
      expect(iv.endMeters, greaterThanOrEqualTo(259.9));
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

    test(
        '10. pass-through connector (A→B→C, single fix on short B) → '
        "B's interval spans its full length, not a zero-length point", () {
      // Three collinear residential ways forming a continuous drive east:
      //   A: x 0..100   B (connector): x 100..120 (20 m)   C: x 120..300
      // The vehicle drives straight through; B — being only 20 m — catches a
      // single GPS fix at its midpoint. Pre-fix this collapsed to a
      // ~zero-length interval and the coverage renderer dropped B (junction
      // gap). The pass-through fix must extend B to its full 20 m.
      final wayA = WayCandidate(
        wayId: 1,
        highwayClass: 'residential',
        geometry: [_ll(0, 0), _ll(0, 50), _ll(0, 100)],
      );
      final wayB = WayCandidate(
        wayId: 2,
        highwayClass: 'residential',
        geometry: [_ll(0, 100), _ll(0, 120)],
      );
      final wayC = WayCandidate(
        wayId: 3,
        highwayClass: 'residential',
        geometry: [_ll(0, 120), _ll(0, 200), _ll(0, 300)],
      );

      final fixes = [
        // Dense on A
        _fix(0, 20),
        _fix(0, 60, dtSecs: 2),
        _fix(0, 95, dtSecs: 4),
        // ONE fix on the short connector B (its midpoint ~x=110)
        _fix(0, 110, dtSecs: 5),
        // Dense on C
        _fix(0, 130, dtSecs: 6),
        _fix(0, 200, dtSecs: 9),
        _fix(0, 280, dtSecs: 12),
      ];

      final result = _matcher.match(fixes: fixes, ways: [wayA, wayB, wayC]);

      final bIntervals =
          result.intervals.where((iv) => iv.wayId == 2).toList();
      expect(bIntervals, isNotEmpty,
          reason: 'connector B must produce an interval');
      final bLen = bIntervals
          .map((iv) => (iv.endMeters - iv.startMeters).abs())
          .reduce((a, b) => a > b ? a : b);
      // B is ~20 m; the pass-through extension must cover essentially all of
      // it (well above the ~0 the single-fix run would otherwise yield).
      expect(bLen, greaterThan(15),
          reason: 'pass-through B should span ~full 20 m, got $bLen');
    });

    // -------------------------------------------------------------------------
    // Test 11: over-draw guard — a stray fix on a LONG parallel neighbour
    // must NOT be promoted to full-length (2026-07-10 regression).
    // -------------------------------------------------------------------------
    test(
        '11. stray fix on a long parallel neighbour is NOT extended to full '
        'length (over-draw guard)', () {
      // Main road A: 300 m east at y=0. Neighbour N: a 60 m parallel road
      // 8 m to the north (within GPS noise) — LONGER than the 30 m connector
      // threshold, so it is not a junction stub. The vehicle drives A
      // straight through; ONE noisy fix lands on N, bracketed by A on both
      // sides. Pre-guard this looked like a pass-through and N was painted as
      // fully driven. The guard must keep N's span tiny (measured, not
      // extended) so the coverage floor later discards it.
      final wayA = WayCandidate(
        wayId: 1,
        highwayClass: 'residential',
        geometry: [_ll(0, 0), _ll(0, 100), _ll(0, 200), _ll(0, 300)],
      );
      final wayN = WayCandidate(
        wayId: 2,
        highwayClass: 'residential',
        geometry: [_ll(8, 120), _ll(8, 180)], // 60 m parallel neighbour
      );

      final fixes = [
        _fix(0, 20),
        _fix(0, 60, dtSecs: 2),
        _fix(0, 110, dtSecs: 4),
        // ONE noisy fix pulled onto the neighbour N (0.5 m from N, 7.5 m from A)
        _fix(7.5, 150, dtSecs: 5),
        _fix(0, 190, dtSecs: 6),
        _fix(0, 240, dtSecs: 8),
        _fix(0, 290, dtSecs: 10),
      ];

      final result = _matcher.match(fixes: fixes, ways: [wayA, wayN]);

      final nIntervals =
          result.intervals.where((iv) => iv.wayId == 2).toList();
      // N may or may not attract the stray fix depending on the decoder, but
      // if it does, its interval must NOT have been extended to full length.
      for (final iv in nIntervals) {
        final span = (iv.endMeters - iv.startMeters).abs();
        expect(span, lessThan(30),
            reason: 'neighbour N must keep its measured (tiny) span, not be '
                'extended to its full 60 m — got $span');
      }
    });

    // -------------------------------------------------------------------------
    // Test 12: spur/ramp guard — a short stub dangling off ONE junction node
    // (A→B→A) must NOT be extended to full length (2026-07-10 "triangle at
    // every exit" / side-street-snippet artifacts).
    // -------------------------------------------------------------------------
    test(
        '12. short spur off one junction node (A→B→A) is NOT extended '
        '(exit-triangle / side-street-stub guard)', () {
      // Main road A runs east at y=0 through x=0..300. A short 18 m stub B
      // dangles NORTH off the junction node at x=150 — an exit ramp or a
      // side-street snippet. The vehicle drives A straight through; GPS noise
      // drops ONE fix onto B near the junction. Both the entry run and the
      // exit run are on A (A→B→A), and A attaches only to B's START endpoint
      // (the junction) — never its far END. The topology guard must refuse to
      // extend B, so its tiny span is later dropped by the coverage floor.
      final wayA = WayCandidate(
        wayId: 1,
        highwayClass: 'residential',
        geometry: [_ll(0, 0), _ll(0, 150), _ll(0, 300)],
      );
      // B: start node at the junction (0,150), end node 18 m NORTH (18,150).
      final wayB = WayCandidate(
        wayId: 2,
        highwayClass: 'residential',
        geometry: [_ll(0, 150), _ll(18, 150)],
      );

      final fixes = [
        _fix(0, 20),
        _fix(0, 80, dtSecs: 2),
        _fix(0, 140, dtSecs: 4),
        // ONE noisy fix pulled onto the near end of the stub B (~3 m up it)
        _fix(3, 150, dtSecs: 5),
        // Back on A, continuing east
        _fix(0, 160, dtSecs: 6),
        _fix(0, 220, dtSecs: 8),
        _fix(0, 290, dtSecs: 10),
      ];

      final result = _matcher.match(fixes: fixes, ways: [wayA, wayB]);

      final bIntervals =
          result.intervals.where((iv) => iv.wayId == 2).toList();
      // If B attracted the stray fix, its interval must NOT have been extended
      // to full length — entry and exit both attach to B's START node only.
      for (final iv in bIntervals) {
        final span = (iv.endMeters - iv.startMeters).abs();
        expect(span, lessThan(15),
            reason: 'spur B (A→B→A off one node) must keep its tiny measured '
                'span, not be extended to its full 18 m — got $span');
      }
    });

    // -------------------------------------------------------------------------
    // Test 13: spur guard — DISTINCT entry/exit roads that both attach to the
    // SAME endpoint of a short stub must NOT extend it. This is the real-world
    // residual case (2026-07-10 re-match): a T-junction where road A ends and
    // road C begins at the same node, with a short dead-end stub B dangling off
    // that node. Drive A→(brief dip onto B)→C. entryWay=A, exitWay=C differ, so
    // the "same wayId" guard doesn't catch it — only nearest-endpoint does.
    // -------------------------------------------------------------------------
    test(
        '13. distinct entry/exit both nearest the SAME connector endpoint → '
        'NOT extended (nearest-endpoint spur guard)', () {
      // Junction node at (0,150). Road A comes from the west and ENDS there;
      // road C leaves to the east and STARTS there. Stub B dangles NORTH from
      // the same node (start=junction, end=20 m north — a dead-end).
      final wayA = WayCandidate(
        wayId: 10,
        highwayClass: 'residential',
        geometry: [_ll(0, 0), _ll(0, 80), _ll(0, 150)], // ends AT junction
      );
      final wayC = WayCandidate(
        wayId: 20,
        highwayClass: 'residential',
        geometry: [_ll(0, 150), _ll(0, 220), _ll(0, 300)], // starts AT junction
      );
      final wayB = WayCandidate(
        wayId: 30,
        highwayClass: 'residential',
        geometry: [_ll(0, 150), _ll(20, 150)], // stub north off the junction
      );

      // Drive A east, one noisy fix dips onto the near end of stub B, then C.
      final fixes = [
        _fix(0, 40),
        _fix(0, 100, dtSecs: 2),
        _fix(0, 145, dtSecs: 4),
        _fix(3, 150, dtSecs: 5), // ~3 m up stub B, near the junction end
        _fix(0, 170, dtSecs: 6),
        _fix(0, 240, dtSecs: 8),
        _fix(0, 295, dtSecs: 10),
      ];

      final result = _matcher.match(fixes: fixes, ways: [wayA, wayB, wayC]);

      final bIntervals =
          result.intervals.where((iv) => iv.wayId == 30).toList();
      // A and C both attach to B's START endpoint (the junction); B's far END
      // (20 m north) was never reached. Must not extend.
      for (final iv in bIntervals) {
        final span = (iv.endMeters - iv.startMeters).abs();
        expect(span, lessThan(15),
            reason: 'stub B (A and C both attach to its junction end) must '
                'keep its tiny span, not be extended to 20 m — got $span');
      }
    });

    // -------------------------------------------------------------------------
    // Test 14: a MAJORITY-covered way whose run enters/exits via other ways but
    // NOT end-to-end (entry attaches to a MIDDLE node, not an endpoint) must
    // NOT be extended to full length (2026-07-18 "Dientzenhoferstraße" over-
    // draw: painted 100 % though its first stretch was never driven). Pre-
    // tightening, `coversMajority` alone extended it; the fix requires genuine
    // end-to-end node topology.
    // -------------------------------------------------------------------------
    test(
        '14. majority-covered way entered mid-span (not end-to-end) is NOT '
        'extended (Dientzenhoferstraße over-draw guard)', () {
      // P: 200 m east at y=0, nodes at meters 0 / 100 / 200.
      final wayP = WayCandidate(
        wayId: 200,
        highwayClass: 'residential',
        nodeIds: const [2000, 2001, 2002],
        geometry: [_ll(0, 0), _ll(0, 100), _ll(0, 200)],
      );
      // Feeder F comes from the south and joins P at its MIDDLE node 2001
      // (meter 100) — NOT an endpoint. Sharing node id 2001 makes the join
      // exact, and _attachedEndById(F) → none (2001 is neither P's start 2000
      // nor end 2002).
      final wayF = WayCandidate(
        wayId: 300,
        highwayClass: 'residential',
        nodeIds: const [3000, 2001],
        geometry: [_ll(-50, 100), _ll(0, 100)],
      );
      // Exit E leaves P at its END node 2002 (meter 200) heading south.
      final wayE = WayCandidate(
        wayId: 400,
        highwayClass: 'residential',
        nodeIds: const [2002, 4000],
        geometry: [_ll(0, 200), _ll(-50, 200)],
      );

      // Drive north up F to the junction, EAST along P from meter 100→200
      // (measured span 100 m = exactly a majority of the 200 m way), then south
      // down E. The vehicle NEVER touches P's first 100 m.
      final fixes = [
        _fix(-40, 100),
        _fix(-10, 100, dtSecs: 2),
        _fix(0, 120, dtSecs: 4),
        _fix(0, 150, dtSecs: 6),
        _fix(0, 180, dtSecs: 8),
        _fix(0, 200, dtSecs: 10),
        _fix(-20, 200, dtSecs: 12),
        _fix(-45, 200, dtSecs: 14),
      ];

      final result = _matcher.match(fixes: fixes, ways: [wayP, wayF, wayE]);

      final pIntervals =
          result.intervals.where((iv) => iv.wayId == 200).toList();
      expect(pIntervals, isNotEmpty, reason: 'P should be matched over 100→200');
      for (final iv in pIntervals) {
        final span = (iv.endMeters - iv.startMeters).abs();
        // Entry attaches to P's MIDDLE node (not an endpoint) → not a genuine
        // end-to-end pass-through → the measured ~100 m span must survive, NOT
        // be auto-completed to the full 200 m (which would over-draw meters
        // 0..100 the vehicle never drove).
        expect(span, lessThan(150),
            reason: 'P entered at its middle node must keep its measured '
                '~100 m span, not be extended to 200 m — got $span');
      }
    });
  });

  // ===========================================================================
  // #9 out-and-back reversal split (2026-07-25)
  // ===========================================================================
  group('#9 out-and-back', () {
    // A single TWO-WAY street driven out to its far end and back must cover the
    // full driven span — not collapse to a near-zero interval hiding the turn.
    test(
        'two-way out-and-back 0→~270→0 → coverage spans the full driven length',
        () {
      // 300 m two-way street east at y=0. Drive east to ~x=270, then back west
      // to ~x=20. No time gap, no way change — a pure intra-way reversal.
      final way = _eastWay();
      final fixes = [
        _fix(0, 20),
        _fix(0, 120, dtSecs: 3),
        _fix(0, 220, dtSecs: 6),
        _fix(0, 270, dtSecs: 9), // peak (far end)
        _fix(0, 200, dtSecs: 12),
        _fix(0, 100, dtSecs: 15),
        _fix(0, 20, dtSecs: 18),
      ];

      final result = _matcher.match(fixes: fixes, ways: [way]);
      final wayIntervals =
          result.intervals.where((iv) => iv.wayId == way.wayId).toList();
      expect(wayIntervals, isNotEmpty);
      // Union of all intervals must span essentially the full 20..270 excursion.
      final minStart =
          wayIntervals.map((iv) => iv.startMeters).reduce((a, b) => a < b ? a : b);
      final maxEnd =
          wayIntervals.map((iv) => iv.endMeters).reduce((a, b) => a > b ? a : b);
      expect(minStart, lessThan(30));
      expect(maxEnd, greaterThan(260),
          reason: 'out-and-back must cover the peak excursion, got $maxEnd');
    });

    test('reversal split → two intervals: forward then backward', () {
      final way = _eastWay();
      final fixes = [
        _fix(0, 20),
        _fix(0, 120, dtSecs: 3),
        _fix(0, 220, dtSecs: 6),
        _fix(0, 270, dtSecs: 9), // peak
        _fix(0, 200, dtSecs: 12),
        _fix(0, 100, dtSecs: 15),
        _fix(0, 20, dtSecs: 18),
      ];

      final result = _matcher.match(fixes: fixes, ways: [way]);
      final wayIntervals =
          result.intervals.where((iv) => iv.wayId == way.wayId).toList();
      expect(wayIntervals.length, equals(2),
          reason: 'a genuine reversal splits into two directional intervals');
      expect(wayIntervals[0].direction, equals('forward'));
      expect(wayIntervals[1].direction, equals('backward'));
    });

    test('monotonic forward run → single [0..end] forward, unchanged', () {
      // Regression guard: a straight forward run must still be ONE forward
      // interval (min==first, max==last) — the #9 change is a no-op here.
      final way = _eastWay();
      final fixes = [
        _fix(0, 20),
        _fix(0, 90, dtSecs: 3),
        _fix(0, 160, dtSecs: 6),
        _fix(0, 230, dtSecs: 9),
        _fix(0, 290, dtSecs: 12),
      ];

      final result = _matcher.match(fixes: fixes, ways: [way]);
      final wayIntervals =
          result.intervals.where((iv) => iv.wayId == way.wayId).toList();
      expect(wayIntervals.length, equals(1));
      expect(wayIntervals.first.direction, equals('forward'));
      expect(wayIntervals.first.startMeters, lessThan(wayIntervals.first.endMeters));
    });
  });

  // ===========================================================================
  // #10 matcher-side gap auto-fill (2026-07-25)
  // ===========================================================================
  group('#10 gap auto-fill', () {
    // Helper: a long straight way with explicit node ids so degree/branch
    // topology is exact. Nodes are laid at the given meter marks east at y=0.
    WayCandidate straightWayWithNodes({
      required int wayId,
      required List<int> nodeIds,
      required List<double> meterMarks,
    }) =>
        WayCandidate(
          wayId: wayId,
          highwayClass: 'residential',
          nodeIds: nodeIds,
          geometry: [for (final m in meterMarks) _ll(0, m)],
        );

    test('same-way small gap over a degree-2 mid node → merged into one', () {
      // Way W: nodes at 0/100/130/200 m. A confidence gap drops the fixes
      // between meter 100 and 130 (mid node 1001, degree 2 — no branch). The
      // two surviving runs [0..100] and [130..200] must merge into [0..200].
      final w = straightWayWithNodes(
        wayId: 1,
        nodeIds: const [1000, 1001, 1002, 1003],
        meterMarks: const [0, 100, 130, 200],
      );
      final fixes = [
        _fix(0, 20),
        _fix(0, 60, dtSecs: 2),
        _fix(0, 98, dtSecs: 4), // prev run ends ~98
        // gap: one fix 500 m off-road → dropped (null step, same-way restart)
        _fix(500, 110, dtSecs: 5),
        _fix(0, 122, dtSecs: 6), // cur run starts ~122 (gap ~24 m ≤ 30)
        _fix(0, 160, dtSecs: 8),
        _fix(0, 198, dtSecs: 10),
      ];

      final result = _matcher.match(fixes: fixes, ways: [w]);
      final wIntervals = result.intervals.where((iv) => iv.wayId == 1).toList();
      expect(wIntervals.length, equals(1),
          reason: 'small same-way gap over a degree-2 node must merge');
      expect(wIntervals.first.startMeters, lessThan(30));
      expect(wIntervals.first.endMeters, greaterThan(190));
    });

    test('same-way gap with a degree-3 branch inside → NOT merged', () {
      // Same as above, but node 1001 (at meter 100, inside the gap) is a real
      // multi-way crossroads: TWO side roads also attach there, so its distinct-
      // wayId degree is 3 (> 2). The vehicle might have turned off, so the gap
      // must NOT be bridged → two intervals survive. (A single side road →
      // degree 2 → NOT a branch under the design's >2 rule; a crossroads is.)
      final w = straightWayWithNodes(
        wayId: 1,
        nodeIds: const [1000, 1001, 1002, 1003],
        meterMarks: const [0, 100, 130, 200],
      );
      // Two side roads sharing node 1001 → distinct ways {1,2,3} → degree 3.
      final sideN = WayCandidate(
        wayId: 2,
        highwayClass: 'residential',
        nodeIds: const [1001, 5000],
        geometry: [_ll(0, 100), _ll(-50, 100)],
      );
      final sideS = WayCandidate(
        wayId: 3,
        highwayClass: 'residential',
        nodeIds: const [1001, 5001],
        geometry: [_ll(0, 100), _ll(50, 100)],
      );
      final fixes = [
        _fix(0, 20),
        _fix(0, 60, dtSecs: 2),
        _fix(0, 98, dtSecs: 4), // ends ~98
        _fix(500, 110, dtSecs: 5), // dropped
        _fix(0, 122, dtSecs: 6), // starts ~122 (gap ~24 m ≤ 30)
        _fix(0, 160, dtSecs: 8),
        _fix(0, 198, dtSecs: 10),
      ];

      final result = _matcher.match(fixes: fixes, ways: [w, sideN, sideS]);
      final wIntervals = result.intervals.where((iv) => iv.wayId == 1).toList();
      expect(wIntervals.length, greaterThanOrEqualTo(2),
          reason: 'a degree-3 crossroads inside the gap must block the merge');
    });

    test('different-way collinear across a degree-2 shared node → filled', () {
      // Two collinear ways meeting ONLY at node 2001 (degree 2, ways {1,2}).
      // A: 0..100 (nodes 2000,2001). B: 100..200 (nodes 2001,2002). A gap drops
      // the fixes right around the junction; each run reaches its shared-node
      // endpoint. The fill extends A to its END and B from its START.
      final a = WayCandidate(
        wayId: 1,
        highwayClass: 'residential',
        nodeIds: const [2000, 2001],
        geometry: [_ll(0, 0), _ll(0, 100)],
      );
      final b = WayCandidate(
        wayId: 2,
        highwayClass: 'residential',
        nodeIds: const [2001, 2002],
        geometry: [_ll(0, 100), _ll(0, 200)],
      );
      final fixes = [
        _fix(0, 20),
        _fix(0, 60, dtSecs: 2),
        _fix(0, 92, dtSecs: 4), // near A's end (meter 100)
        _fix(500, 100, dtSecs: 5), // dropped around the junction
        _fix(0, 108, dtSecs: 6), // near B's start (meter 100)
        _fix(0, 150, dtSecs: 8),
        _fix(0, 190, dtSecs: 10),
      ];

      final result = _matcher.match(fixes: fixes, ways: [a, b]);
      final aInt = result.intervals.where((iv) => iv.wayId == 1).toList();
      final bInt = result.intervals.where((iv) => iv.wayId == 2).toList();
      expect(aInt, isNotEmpty);
      expect(bInt, isNotEmpty);
      // A extended to its full 100 m end; B extended to its 0 m start.
      expect(aInt.map((iv) => iv.endMeters).reduce((x, y) => x > y ? x : y),
          greaterThan(95),
          reason: 'A must reach its shared-node endpoint (~100 m)');
      expect(bInt.map((iv) => iv.startMeters).reduce((x, y) => x < y ? x : y),
          lessThan(5),
          reason: 'B must start at its shared-node endpoint (~0 m)');
    });

    // BEHAVIOUR CHANGE (#10 through-intersection bridge, 2026-07-27): a gap
    // where the vehicle drove STRAIGHT THROUGH a degree-3 junction is now
    // bridged by Branch 3, gated by the GPS corridor. Previously the degree-2
    // continuation (Branch 2) refused it and the gap was left as a visible
    // break; that premise is now contradicted by the through-intersection
    // bridge. The bridge extends A to the junction node and B from it — it does
    // NOT paint the side road T (the vehicle never drove it: every fix sits on
    // the A→B line at y=0, none head south down T). The corridor gate confirms
    // node 3001 (x=100) sits within 45 m of the bracketing fixes (x=92 / x=108),
    // so the vehicle provably passed through it.
    test('different-way across a degree-3 shared node → bridged '
        '(through-intersection), side road NOT painted', () {
      // A and B meet at node 3001, but a third way T also attaches there
      // (degree 3). The vehicle drives straight A→through→B.
      final a = WayCandidate(
        wayId: 1,
        highwayClass: 'residential',
        nodeIds: const [3000, 3001],
        geometry: [_ll(0, 0), _ll(0, 100)],
      );
      final b = WayCandidate(
        wayId: 2,
        highwayClass: 'residential',
        nodeIds: const [3001, 3002],
        geometry: [_ll(0, 100), _ll(0, 200)],
      );
      final t = WayCandidate(
        wayId: 3,
        highwayClass: 'residential',
        nodeIds: const [3001, 6000],
        geometry: [_ll(0, 100), _ll(-50, 100)],
      );
      final fixes = [
        _fix(0, 20),
        _fix(0, 60, dtSecs: 2),
        _fix(0, 92, dtSecs: 4),
        _fix(500, 100, dtSecs: 5), // dropped
        _fix(0, 108, dtSecs: 6),
        _fix(0, 150, dtSecs: 8),
        _fix(0, 190, dtSecs: 10),
      ];

      final result = _matcher.match(fixes: fixes, ways: [a, b, t]);
      final aInt = result.intervals.where((iv) => iv.wayId == 1).toList();
      final bInt = result.intervals.where((iv) => iv.wayId == 2).toList();
      // A bridged to the junction node (~100 m); B bridged from it (~0 m).
      expect(aInt.map((iv) => iv.endMeters).reduce((x, y) => x > y ? x : y),
          greaterThan(95),
          reason: 'A bridged to the through-intersection node');
      expect(bInt.map((iv) => iv.startMeters).reduce((x, y) => x < y ? x : y),
          lessThan(5),
          reason: 'B bridged from the through-intersection node');
      // CORRECTNESS INVARIANT: the side road T must NEVER be painted — the
      // vehicle demonstrably drove straight through and never onto T.
      expect(result.intervals.where((iv) => iv.wayId == 3), isEmpty,
          reason: 'the un-driven side road T must not be painted');
    });

    // #10 highway fix (2026-07-26): the same-way upper gap cap was removed. An
    // 80 m gap (far over the old 30 m cap) on a single continuous way with NO
    // branch node between the runs must now merge into one interval.
    test('same-way 80m gap, no branch node between → merged (cap removed)', () {
      // Way W: nodes at 0/100/230/330 m. The mid nodes are degree 2 (no other
      // ways). A confidence gap drops the fixes between ~100 and ~180 (an 80 m
      // hole). Under the old 30 m cap this stayed split; now it merges.
      final w = straightWayWithNodes(
        wayId: 1,
        nodeIds: const [1000, 1001, 1002, 1003],
        meterMarks: const [0, 100, 230, 330],
      );
      final fixes = [
        _fix(0, 20),
        _fix(0, 60, dtSecs: 2),
        _fix(0, 98, dtSecs: 4), // prev run ends ~98
        _fix(500, 140, dtSecs: 5), // dropped (off-road)
        _fix(0, 180, dtSecs: 6), // cur run starts ~180 (gap ~82 m ≫ 30)
        _fix(0, 250, dtSecs: 8),
        _fix(0, 320, dtSecs: 10),
      ];

      final result = _matcher.match(fixes: fixes, ways: [w]);
      final wIntervals = result.intervals.where((iv) => iv.wayId == 1).toList();
      expect(wIntervals.length, equals(1),
          reason: 'an 80 m same-way gap with no branch node must merge '
              'now that the upper cap is removed');
      expect(wIntervals.first.startMeters, lessThan(30));
      expect(wIntervals.first.endMeters, greaterThan(310));
    });

    test('same-way 80m gap WITH a degree-3 branch inside → NOT merged', () {
      // Same 80 m gap, but a crossroads (two side roads) attaches at node 1002
      // (meter 230)... place the branch at node 1001 (meter 100), which lies
      // strictly inside the [98..180] gap. Degree 3 → the merge is refused even
      // though the cap is gone.
      final w = straightWayWithNodes(
        wayId: 1,
        nodeIds: const [1000, 1001, 1002, 1003],
        meterMarks: const [0, 100, 230, 330],
      );
      final sideN = WayCandidate(
        wayId: 2,
        highwayClass: 'residential',
        nodeIds: const [1001, 5000],
        geometry: [_ll(0, 100), _ll(-50, 100)],
      );
      final sideS = WayCandidate(
        wayId: 3,
        highwayClass: 'residential',
        nodeIds: const [1001, 5001],
        geometry: [_ll(0, 100), _ll(50, 100)],
      );
      final fixes = [
        _fix(0, 20),
        _fix(0, 60, dtSecs: 2),
        _fix(0, 98, dtSecs: 4), // ends ~98
        _fix(500, 140, dtSecs: 5), // dropped
        _fix(0, 180, dtSecs: 6), // starts ~180 (gap ~82 m; branch @100 inside)
        _fix(0, 250, dtSecs: 8),
        _fix(0, 320, dtSecs: 10),
      ];

      final result = _matcher.match(fixes: fixes, ways: [w, sideN, sideS]);
      final wIntervals = result.intervals.where((iv) => iv.wayId == 1).toList();
      expect(wIntervals.length, greaterThanOrEqualTo(2),
          reason: 'a degree-3 branch inside the 80 m gap must still block the '
              'merge even with no upper cap');
    });

    // #10 highway fix (2026-07-26): the DIFFERENT-way degree-2 continuation now
    // tolerates a highway-safe 60 m endpoint shortfall (was 30 m). A 50 m
    // per-side shortfall at the shared degree-2 node must still bridge.
    test('different-way degree-2, 50m per-side shortfall → filled (60m tol)',
        () {
      // A: 0..200 (nodes 4000,4001,4002), B: 200..400 (nodes 4002,4003,4004),
      // meeting ONLY at node 4002 (degree 2, ways {1,2}). The matched runs stop
      // ~50 m short of the junction on each side (A ends ~150, B starts ~250).
      // Under the old 30 m tolerance neither endpoint counted as touched → no
      // fill; the 60 m highway tolerance now bridges.
      final a = WayCandidate(
        wayId: 1,
        highwayClass: 'motorway',
        oneway: OnewayDirection.forward,
        nodeIds: const [4000, 4001, 4002],
        geometry: [_ll(0, 0), _ll(0, 100), _ll(0, 200)],
      );
      final b = WayCandidate(
        wayId: 2,
        highwayClass: 'motorway',
        oneway: OnewayDirection.forward,
        nodeIds: const [4002, 4003, 4004],
        geometry: [_ll(0, 200), _ll(0, 300), _ll(0, 400)],
      );
      final fixes = [
        _fix(0, 20, speed: 120),
        _fix(0, 90, dtSecs: 2, speed: 120),
        _fix(0, 150, dtSecs: 4, speed: 120), // A ends ~150 (50 m short of 200)
        _fix(500, 200, dtSecs: 5, speed: 120), // dropped around the junction
        _fix(0, 250, dtSecs: 6, speed: 120), // B starts ~250 (50 m past 200)
        _fix(0, 320, dtSecs: 8, speed: 120),
        _fix(0, 390, dtSecs: 10, speed: 120),
      ];

      final result = _matcher.match(fixes: fixes, ways: [a, b]);
      final aInt = result.intervals.where((iv) => iv.wayId == 1).toList();
      final bInt = result.intervals.where((iv) => iv.wayId == 2).toList();
      expect(aInt, isNotEmpty);
      expect(bInt, isNotEmpty);
      expect(aInt.map((iv) => iv.endMeters).reduce((x, y) => x > y ? x : y),
          greaterThan(195),
          reason: 'A must reach its shared-node endpoint (~200 m) at 60 m tol');
      expect(bInt.map((iv) => iv.startMeters).reduce((x, y) => x < y ? x : y),
          lessThan(5),
          reason: 'B must start at its shared-node endpoint (~0 m) at 60 m tol');
    });

    test('different-way degree-3 interchange, 50m shortfall → NOT filled', () {
      // Same 50 m per-side shortfall, but a third way T attaches at the shared
      // node (degree 3 = interchange). The car may have exited via a ramp →
      // no fill regardless of the raised tolerance.
      final a = WayCandidate(
        wayId: 1,
        highwayClass: 'motorway',
        oneway: OnewayDirection.forward,
        nodeIds: const [4000, 4001, 4002],
        geometry: [_ll(0, 0), _ll(0, 100), _ll(0, 200)],
      );
      final b = WayCandidate(
        wayId: 2,
        highwayClass: 'motorway',
        oneway: OnewayDirection.forward,
        nodeIds: const [4002, 4003, 4004],
        geometry: [_ll(0, 200), _ll(0, 300), _ll(0, 400)],
      );
      final ramp = WayCandidate(
        wayId: 3,
        highwayClass: 'motorway_link',
        oneway: OnewayDirection.forward,
        nodeIds: const [4002, 7000],
        geometry: [_ll(0, 200), _ll(-80, 200)],
      );
      final fixes = [
        _fix(0, 20, speed: 120),
        _fix(0, 90, dtSecs: 2, speed: 120),
        _fix(0, 150, dtSecs: 4, speed: 120), // A ends ~150
        _fix(500, 200, dtSecs: 5, speed: 120), // dropped
        _fix(0, 250, dtSecs: 6, speed: 120), // B starts ~250
        _fix(0, 320, dtSecs: 8, speed: 120),
        _fix(0, 390, dtSecs: 10, speed: 120),
      ];

      final result = _matcher.match(fixes: fixes, ways: [a, b, ramp]);
      final aInt = result.intervals.where((iv) => iv.wayId == 1).toList();
      final aMaxEnd =
          aInt.map((iv) => iv.endMeters).reduce((x, y) => x > y ? x : y);
      expect(aMaxEnd, lessThan(195),
          reason: 'a degree-3 interchange must block the continuation fill '
              'even at 60 m tolerance — A end was $aMaxEnd');
    });
  });

  // ===========================================================================
  // #10 through-intersection gap bridge (2026-07-27)
  // ===========================================================================
  //
  // Branch 3 of `_tryFill`: bridges a gap where the vehicle drove straight
  // THROUGH a branch node (degree > 2) — which the degree-2 continuation
  // (Branch 2) refuses — or across a short connector way at such a junction.
  // The bridge is triple-gated: total length ≤ kMaxBridgeMeters, route ≈
  // straight-line (kBridgeMaxLengthRatio), and every path node within
  // kBridgeCorridorMeters of a raw GPS fix. It can only close a genuine
  // data/rendering gap, never paint a wrong-road excursion.
  group('through-intersection gap bridge (#10, 2026-07-27)', () {
    // A short side road hanging off the junction node, forcing degree > 2 so
    // the degree-2 continuation (Branch 2) cannot fire — a real intersection.
    WayCandidate sideRoad({
      required int wayId,
      required int junctionNodeId,
      required double junctionEast,
    }) =>
        WayCandidate(
          wayId: wayId,
          highwayClass: 'residential',
          nodeIds: [junctionNodeId, 9000 + wayId],
          geometry: [_ll(0, junctionEast), _ll(50, junctionEast)],
        );

    // -------------------------------------------------------------------------
    // 1. BRIDGES a genuine through-intersection gap (degree > 2 shared node).
    // -------------------------------------------------------------------------
    test('1. bridges a through-intersection gap (degree>2 shared node)', () {
      // Way A (0..100) and Way B (100..200) meet at node 101 (x=100). A side
      // road also attaches at 101 → degree 3, so Branch 2 refuses it. The
      // vehicle drives straight A→X→B; the fix at the junction is dropped.
      final wayA = WayCandidate(
        wayId: 1,
        highwayClass: 'residential',
        nodeIds: const [100, 101],
        geometry: [_ll(0, 0), _ll(0, 100)],
      );
      final wayB = WayCandidate(
        wayId: 2,
        highwayClass: 'residential',
        nodeIds: const [101, 102],
        geometry: [_ll(0, 100), _ll(0, 200)],
      );
      final side =
          sideRoad(wayId: 3, junctionNodeId: 101, junctionEast: 100);

      final fixes = [
        _fix(0, 20),
        _fix(0, 80, dtSecs: 2), // A ends ~80 (touches end node 101 within tol)
        _fix(500, 100, dtSecs: 3), // dropped at the junction
        _fix(0, 120, dtSecs: 4), // B starts ~20 (touches start node 101)
        _fix(0, 180, dtSecs: 6),
      ];

      final result = _matcher.match(fixes: fixes, ways: [wayA, wayB, side]);
      final aInt = result.intervals.where((iv) => iv.wayId == 1).toList();
      final bInt = result.intervals.where((iv) => iv.wayId == 2).toList();

      expect(aInt, isNotEmpty, reason: 'A must be matched');
      expect(bInt, isNotEmpty, reason: 'B must be matched');
      // A must reach the junction node (full ~100 m); B must start from it (~0).
      expect(aInt.map((iv) => iv.endMeters).reduce((x, y) => x > y ? x : y),
          greaterThan(99),
          reason: 'A bridged to the through-intersection node (~100 m)');
      expect(bInt.map((iv) => iv.startMeters).reduce((x, y) => x < y ? x : y),
          lessThan(1),
          reason: 'B bridged from the through-intersection node (~0 m)');
      // The side road must NOT be painted.
      expect(result.intervals.where((iv) => iv.wayId == 3), isEmpty,
          reason: 'a side road the vehicle never entered must not be painted');
    });

    // -------------------------------------------------------------------------
    // 2. BRIDGES across a short intermediate connector way (on-corridor).
    // -------------------------------------------------------------------------
    test('2. bridges across a short intermediate connector way', () {
      // A (0..300, node 100→101 @ x=300). Connector C (300..340, node
      // 101→103). B (340..440, node 103→104). Vehicle drives straight through;
      // the fix on the 40 m connector is dropped. C must be painted full.
      final wayA = WayCandidate(
        wayId: 1,
        highwayClass: 'residential',
        nodeIds: const [100, 101],
        geometry: [_ll(0, 0), _ll(0, 300)],
      );
      final connector = WayCandidate(
        wayId: 2,
        highwayClass: 'residential',
        nodeIds: const [101, 103],
        geometry: [_ll(0, 300), _ll(0, 340)],
      );
      final wayB = WayCandidate(
        wayId: 3,
        highwayClass: 'residential',
        nodeIds: const [103, 104],
        geometry: [_ll(0, 340), _ll(0, 440)],
      );

      final fixes = [
        _fix(0, 100), // A start > tol so A's START endpoint is not "touched"
        _fix(0, 200, dtSecs: 3),
        _fix(0, 280, dtSecs: 5), // A ends ~280 (touches end node 101 @300)
        _fix(500, 320, dtSecs: 6), // dropped on the connector
        _fix(0, 360, dtSecs: 7), // B starts ~20 (touches start node 103 @340)
        _fix(0, 420, dtSecs: 9),
      ];

      final result =
          _matcher.match(fixes: fixes, ways: [wayA, connector, wayB]);
      final cInt = result.intervals.where((iv) => iv.wayId == 2).toList();

      expect(cInt, isNotEmpty,
          reason: 'the intermediate connector must be painted by the bridge');
      final cSpan = cInt
          .map((iv) => (iv.endMeters - iv.startMeters).abs())
          .reduce((x, y) => x > y ? x : y);
      expect(cSpan, greaterThan(35),
          reason: 'connector painted ~full 40 m, got $cSpan');
    });

    // -------------------------------------------------------------------------
    // 3. REFUSES a wrong-road detour (route ≫ straight-line / over cap).
    // -------------------------------------------------------------------------
    test('3. refuses a wrong-road detour (route over kMaxBridgeMeters)', () {
      // A (0..100) and B (140..240) do NOT share a node. Their loose ends
      // (node 101 @x=100, node 103 @x=140) are only 40 m apart straight-line
      // but the only on-road connection is a 340 m detour bowing 150 m north →
      // unreachable within the 200 m bridge cap. No bridge.
      final wayA = WayCandidate(
        wayId: 1,
        highwayClass: 'residential',
        nodeIds: const [100, 101],
        geometry: [_ll(0, 0), _ll(0, 100)],
      );
      final detour = WayCandidate(
        wayId: 2,
        highwayClass: 'residential',
        nodeIds: const [101, 501, 502, 103],
        geometry: [_ll(0, 100), _ll(150, 100), _ll(150, 140), _ll(0, 140)],
      );
      final wayB = WayCandidate(
        wayId: 3,
        highwayClass: 'residential',
        nodeIds: const [103, 104],
        geometry: [_ll(0, 140), _ll(0, 240)],
      );

      final fixes = [
        _fix(0, 20),
        _fix(0, 60, dtSecs: 2),
        _fix(0, 90, dtSecs: 4), // A ends ~90
        _fix(500, 120, dtSecs: 5), // dropped
        _fix(0, 160, dtSecs: 6), // B starts ~20
        _fix(0, 220, dtSecs: 8),
      ];

      final result = _matcher.match(fixes: fixes, ways: [wayA, detour, wayB]);
      // The detour way must NOT be painted, and A must not be extended to its
      // loose-end node.
      expect(result.intervals.where((iv) => iv.wayId == 2), isEmpty,
          reason: 'a detour longer than the bridge cap must not be painted');
      final aInt = result.intervals.where((iv) => iv.wayId == 1).toList();
      expect(aInt, isNotEmpty);
      expect(aInt.map((iv) => iv.endMeters).reduce((x, y) => x > y ? x : y),
          lessThan(95),
          reason: 'A must keep its measured span (no bridge over a long detour)');
      expect(result.intervals.where((iv) => iv.wayId == 3), isNotEmpty,
          reason: 'B stays a separate interval');
    });

    // -------------------------------------------------------------------------
    // 4. REFUSES when the GPS corridor is absent (path node far from all fixes).
    // -------------------------------------------------------------------------
    test('4. refuses when a bridge node is off the GPS corridor', () {
      // A (0..100) → connector C (100..200, mid node 500 @x=150) → B (200..300).
      // The route (200 m) and length-ratio both PASS, but node 500 @x=150 is
      // 60 m from the nearest fix (x=90 / x=210) — outside the 45 m corridor —
      // so the corridor gate refuses the bridge. Guards against inventing road.
      final wayA = WayCandidate(
        wayId: 1,
        highwayClass: 'residential',
        nodeIds: const [100, 101],
        geometry: [_ll(0, 0), _ll(0, 100)],
      );
      final connector = WayCandidate(
        wayId: 2,
        highwayClass: 'residential',
        nodeIds: const [101, 500, 103],
        geometry: [_ll(0, 100), _ll(0, 150), _ll(0, 200)],
      );
      final wayB = WayCandidate(
        wayId: 3,
        highwayClass: 'residential',
        nodeIds: const [103, 104],
        geometry: [_ll(0, 200), _ll(0, 300)],
      );

      final fixes = [
        _fix(0, 20),
        _fix(0, 60, dtSecs: 2),
        _fix(0, 90, dtSecs: 4), // A ends ~90; nearest fix to x=150 is 60 m away
        _fix(500, 150, dtSecs: 5), // dropped, off-road
        _fix(0, 210, dtSecs: 6), // B starts ~10; nearest fix to x=150 is 60 m
        _fix(0, 260, dtSecs: 8),
        _fix(0, 290, dtSecs: 10),
      ];

      final result =
          _matcher.match(fixes: fixes, ways: [wayA, connector, wayB]);
      // The connector's mid node is off-corridor → no bridge, C not painted.
      expect(result.intervals.where((iv) => iv.wayId == 2), isEmpty,
          reason: 'an off-corridor connector node must block the bridge');
      final aInt = result.intervals.where((iv) => iv.wayId == 1).toList();
      expect(aInt, isNotEmpty);
      expect(aInt.map((iv) => iv.endMeters).reduce((x, y) => x > y ? x : y),
          lessThan(95),
          reason: 'A must keep its measured span (corridor gate refused)');
    });

    // -------------------------------------------------------------------------
    // 5. FIX B BEHAVIOUR CHANGE (2026-07-27): a different-way through-
    // intersection with prev.direction != cur.direction is NOW bridged. FIX B
    // scoped the direction-equality guard to the SAME-wayId merge (Branch 1)
    // only; the different-way branches (Branch 2 / Branch 3) proceed regardless
    // of direction LABEL, because a legitimate turn (or a way digitised in the
    // reverse node order) flips the per-way direction label even on a straight
    // through-drive. The junction is on the raw-fix corridor, so the bridge
    // fires and A is extended to the shared node. Previously the top-of-_tryFill
    // guard blocked this and A kept its measured span; that premise is now
    // contradicted by FIX B.
    // -------------------------------------------------------------------------
    test('5. different-way through-intersection bridges despite direction '
        'label difference (FIX B)', () {
      // Same degree-3 through-intersection as test 1, but B is driven with a
      // DECREASING meter sense (backward label). prev='forward', cur='backward'
      // → Branch 3 still bridges (the vehicle drove straight through the node).
      final wayA = WayCandidate(
        wayId: 1,
        highwayClass: 'residential',
        nodeIds: const [100, 101],
        geometry: [_ll(0, 0), _ll(0, 100)],
      );
      final wayB = WayCandidate(
        wayId: 2,
        highwayClass: 'residential',
        nodeIds: const [101, 102],
        geometry: [_ll(0, 100), _ll(0, 200)],
      );
      final side =
          sideRoad(wayId: 3, junctionNodeId: 101, junctionEast: 100);

      final fixes = [
        _fix(0, 20), // A forward
        _fix(0, 80, dtSecs: 2),
        _fix(500, 100, dtSecs: 3), // dropped
        _fix(0, 180, dtSecs: 4), // B backward: 80 → 20 (decreasing meters)
        _fix(0, 120, dtSecs: 6),
      ];

      final result = _matcher.match(fixes: fixes, ways: [wayA, wayB, side]);
      final aInt = result.intervals.where((iv) => iv.wayId == 1).toList();
      expect(aInt, isNotEmpty);
      // A IS extended to the junction node — the direction label difference no
      // longer blocks a different-way bridge (FIX B).
      expect(aInt.map((iv) => iv.endMeters).reduce((x, y) => x > y ? x : y),
          greaterThan(95),
          reason: 'FIX B: a different-way through-intersection bridges even '
              'across a direction-label difference');
      // The un-driven side road must still never be painted.
      expect(result.intervals.where((iv) => iv.wayId == 3), isEmpty,
          reason: 'the un-driven side road must not be painted');
    });

    // -------------------------------------------------------------------------
    // 6. NO-OP regression: degree-2 continuation and same-way merge still
    // behave via Branches 2/1 exactly as before threading `fixes` through.
    // -------------------------------------------------------------------------
    test('6. no-op regression: degree-2 continuation still fills (Branch 2)',
        () {
      // Two collinear ways meeting at a pure degree-2 node 2001 (no side road).
      // Branch 2 handles this — Branch 3 must not change the outcome.
      final a = WayCandidate(
        wayId: 1,
        highwayClass: 'residential',
        nodeIds: const [2000, 2001],
        geometry: [_ll(0, 0), _ll(0, 100)],
      );
      final b = WayCandidate(
        wayId: 2,
        highwayClass: 'residential',
        nodeIds: const [2001, 2002],
        geometry: [_ll(0, 100), _ll(0, 200)],
      );
      final fixes = [
        _fix(0, 20),
        _fix(0, 60, dtSecs: 2),
        _fix(0, 92, dtSecs: 4),
        _fix(500, 100, dtSecs: 5), // dropped
        _fix(0, 108, dtSecs: 6),
        _fix(0, 150, dtSecs: 8),
        _fix(0, 190, dtSecs: 10),
      ];

      final result = _matcher.match(fixes: fixes, ways: [a, b]);
      final aInt = result.intervals.where((iv) => iv.wayId == 1).toList();
      final bInt = result.intervals.where((iv) => iv.wayId == 2).toList();
      expect(aInt.map((iv) => iv.endMeters).reduce((x, y) => x > y ? x : y),
          greaterThan(95),
          reason: 'A still reaches its shared-node endpoint (Branch 2)');
      expect(bInt.map((iv) => iv.startMeters).reduce((x, y) => x < y ? x : y),
          lessThan(5),
          reason: 'B still starts at its shared-node endpoint (Branch 2)');
    });

    test('6b. no-op regression: two isolated ways are not bridged', () {
      // Way A and a far parallel way P that share no node and are 500 m apart.
      // Branch 3 must not invent a bridge between unrelated intervals.
      final a = _eastWay();
      final p = _northOffsetWay(); // 500 m north, disjoint node ids (surrogate)
      final fixes = [
        _fix(0, 20),
        _fix(0, 140, dtSecs: 5),
        _fix(0, 260, dtSecs: 10),
        _fix(500, 20, dtSecs: 15),
        _fix(500, 140, dtSecs: 20),
        _fix(500, 260, dtSecs: 25),
      ];

      final result = _matcher.match(fixes: fixes, ways: [a, p]);
      // Exactly one interval per way — no invented intermediate, no merge.
      expect(result.intervals.where((iv) => iv.wayId == a.wayId).length, 1);
      expect(result.intervals.where((iv) => iv.wayId == p.wayId).length, 1);
    });
  });

  // ===========================================================================
  // FIX B — direction-guard scoping (in-town turn gaps, 2026-07-27)
  // ===========================================================================
  //
  // The direction-equality guard in `_tryFill` is legitimate ONLY for the
  // same-wayId merge (Branch 1), guarding a #9 reversal on ONE road. At a turn
  // between DIFFERENT ways a left/right turn flips the per-way direction LABEL
  // (each way's direction is the sign of net meters along that OSM way, and a
  // turn drives the two ways in opposite meter senses), so the guard must NOT
  // kill the different-way continuation.
  group('FIX B direction-guard scoping', () {
    test('turn between two ways with OPPOSITE direction labels still bridges',
        () {
      // A runs east, nodes [1000,1001] at east 0/100; junction at A's END node
      // 1001 (east 100). B runs south→junction: geometry [(60,100),(0,100)],
      // nodeIds [1002,1001] → junction is B's END node too. Degree-2 shared
      // {A,B}. Drive east along A (forward on A, meters increasing) then turn
      // and drive north AWAY from the junction up B: because B's node order runs
      // (north→junction), leaving the junction toward the north DECREASES B's
      // meters → 'backward' label on B. So prev='forward', cur='backward' — yet
      // a genuine continuous drive. Pre-FIX-B the top-of-_tryFill guard killed
      // this at every such turn; FIX B lets Branch 2 fire.
      final wayA = WayCandidate(
        wayId: 1,
        highwayClass: 'residential',
        nodeIds: const [1000, 1001],
        geometry: [_ll(0, 0), _ll(0, 100)],
      );
      final wayB = WayCandidate(
        wayId: 2,
        highwayClass: 'residential',
        nodeIds: const [1002, 1001],
        geometry: [_ll(60, 100), _ll(0, 100)],
      );
      final fixes = [
        _fix(0, 20),
        _fix(0, 60, dtSecs: 2),
        _fix(0, 92, dtSecs: 4), // A near its end (~92, junction @100)
        _fix(500, 100, dtSecs: 5), // dropped around the junction
        _fix(8, 100, dtSecs: 6), // on B, ~8 m north of junction (B meter ~52)
        _fix(50, 100, dtSecs: 8), // further north up B (B meter ~10)
      ];

      final result = _matcher.match(fixes: fixes, ways: [wayA, wayB]);
      final aInt = result.intervals.where((iv) => iv.wayId == 1).toList();
      final bInt = result.intervals.where((iv) => iv.wayId == 2).toList();
      expect(aInt, isNotEmpty, reason: 'A must be matched');
      expect(bInt, isNotEmpty, reason: 'B must be matched');
      // The two arms must have OPPOSITE labels (this is what pre-FIX-B blocked).
      final dirs = {...aInt.map((iv) => iv.direction), ...bInt.map((iv) => iv.direction)};
      expect(dirs, containsAll(<String>{'forward', 'backward'}),
          reason: 'the turn produces opposite per-way direction labels');
      // A extended to its junction END (~100); B extended to its junction END.
      expect(aInt.map((iv) => iv.endMeters).reduce((x, y) => x > y ? x : y),
          greaterThan(95),
          reason: 'A must reach the shared junction node despite the label diff');
      expect(bInt.map((iv) => iv.endMeters).reduce((x, y) => x > y ? x : y),
          greaterThan(55),
          reason: 'B must reach the shared junction node (its END, ~60 m)');
    });

    test('genuine reversal on the SAME way is still NOT merged (Branch 1 guard)',
        () {
      // A single two-way street driven out and back. The #9 reversal split
      // produces a 'forward' interval then a 'backward' interval on the SAME
      // way. Branch 1's direction guard (kept by FIX B) must refuse to merge
      // them back into one — the two directional legs stay distinct.
      final way = _eastWay();
      final fixes = [
        _fix(0, 20),
        _fix(0, 120, dtSecs: 3),
        _fix(0, 220, dtSecs: 6),
        _fix(0, 270, dtSecs: 9), // peak
        _fix(0, 200, dtSecs: 12),
        _fix(0, 100, dtSecs: 15),
        _fix(0, 20, dtSecs: 18),
      ];

      final result = _matcher.match(fixes: fixes, ways: [way]);
      final wayIntervals =
          result.intervals.where((iv) => iv.wayId == way.wayId).toList();
      expect(wayIntervals.length, equals(2),
          reason: 'a same-way reversal must NOT be merged (Branch 1 guard)');
      expect(wayIntervals[0].direction, equals('forward'));
      expect(wayIntervals[1].direction, equals('backward'));
    });
  });

  // ===========================================================================
  // FIX E — interior-node continuation (2026-07-27)
  // ===========================================================================
  //
  // Two ways can meet at a node that is INTERIOR to the longer way rather than
  // at its endpoint (a T/mid-way junction). Branch 2 only pairs ENDPOINT nodes,
  // so it never fires and a short gap is left. FIX E extends the interior-side
  // interval ONLY to the interior node's meters (never past the junction — the
  // far part was not driven) and the endpoint-side interval to/from its
  // endpoint.
  group('FIX E interior-node continuation', () {
    test('junction interior to prev, endpoint of cur → gap closes, far part '
        'of prev NOT painted', () {
      // Prev way P: nodes [2000,2001,2002,2003] at meters 0/100/200/300. The
      // junction is P's INTERIOR node 2002 (meter 200). Cur way C starts at that
      // node: nodes [2002,3000], geometry [(0,200),(60,200)] heading north.
      // Degree-2 shared {P,C} at node 2002. Drive east along P to ~meter 190
      // (loose end near the interior node), gap, then north up C. FIX E extends
      // P to meter 200 (NOT 300) and C from its start.
      final wayP = WayCandidate(
        wayId: 1,
        highwayClass: 'residential',
        nodeIds: const [2000, 2001, 2002, 2003],
        geometry: [_ll(0, 0), _ll(0, 100), _ll(0, 200), _ll(0, 300)],
      );
      final wayC = WayCandidate(
        wayId: 2,
        highwayClass: 'residential',
        nodeIds: const [2002, 3000],
        geometry: [_ll(0, 200), _ll(60, 200)],
      );
      final fixes = [
        _fix(0, 20),
        _fix(0, 90, dtSecs: 2),
        _fix(0, 160, dtSecs: 4),
        _fix(0, 190, dtSecs: 6), // P loose end ~190 (interior node @200)
        _fix(500, 200, dtSecs: 7), // dropped around the junction
        _fix(10, 200, dtSecs: 8), // on C, ~10 m north of junction
        _fix(50, 200, dtSecs: 10), // further north up C
      ];

      final result = _matcher.match(fixes: fixes, ways: [wayP, wayC]);
      final pInt = result.intervals.where((iv) => iv.wayId == 1).toList();
      final cInt = result.intervals.where((iv) => iv.wayId == 2).toList();
      expect(pInt, isNotEmpty, reason: 'P must be matched');
      expect(cInt, isNotEmpty, reason: 'C must be matched');
      final pMaxEnd =
          pInt.map((iv) => iv.endMeters).reduce((x, y) => x > y ? x : y);
      // P extends to the interior junction node (~200 m), closing the gap.
      expect(pMaxEnd, greaterThan(195),
          reason: 'P must extend to the interior junction node (~200 m)');
      // CRITICAL: the far part of P beyond the junction (200..300) must NOT be
      // painted — the vehicle turned off at meter 200.
      expect(pMaxEnd, lessThan(260),
          reason: 'P beyond the junction (200..300) must NOT be painted, '
              'got $pMaxEnd');
      // C extended from its shared-node start (~0 m).
      expect(cInt.map((iv) => iv.startMeters).reduce((x, y) => x < y ? x : y),
          lessThan(5),
          reason: 'C must start from the shared junction node (~0 m)');
    });
  });

  // ===========================================================================
  // FIX C — emission/collapse proximity guard (2026-07-27)
  // ===========================================================================
  //
  // The Viterbi emission can briefly snap onto a PARALLEL residential way that
  // runs tens of meters off the correctly-driven road and shares NO node with
  // it (Obrigheim B27 over-draw). Such an interval's own painted geometry sits
  // far from EVERY raw fix. FIX C drops an interval whose driven-range midpoint
  // is farther than kMaxMatchedGeometryToFixMeters (15 m) from the nearest fix,
  // while a genuine (even short/partway) drive under the fixes (<8 m) is kept.
  group('FIX C emission proximity guard', () {
    test('parallel way >15 m off all fixes is dropped; driven way kept', () {
      // Driven road A runs east at y=0 (fixes right on it, <2 m). Parallel way N
      // runs 25 m north (y=25), sharing NO node with A. If the decoder snaps any
      // fix onto N, N's painted geometry midpoint is ~25 m from the nearest raw
      // fix (>15 m) → dropped by FIX C. A stays.
      final wayA = WayCandidate(
        wayId: 1,
        highwayClass: 'residential',
        geometry: [_ll(0, 0), _ll(0, 100), _ll(0, 200), _ll(0, 300)],
      );
      final wayN = WayCandidate(
        wayId: 2,
        highwayClass: 'residential',
        geometry: [_ll(25, 100), _ll(25, 200)], // 25 m north parallel
      );
      final fixes = [
        _fix(0, 20),
        _fix(0, 70, dtSecs: 2),
        _fix(0, 120, dtSecs: 4),
        _fix(0, 170, dtSecs: 6),
        _fix(0, 220, dtSecs: 8),
        _fix(0, 280, dtSecs: 10),
      ];

      final result = _matcher.match(fixes: fixes, ways: [wayA, wayN]);
      // A must be painted (its geometry is right under the fixes).
      expect(result.intervals.where((iv) => iv.wayId == 1), isNotEmpty,
          reason: 'the genuinely-driven way A must be kept');
      // N — even if the decoder snapped a fix onto it — must be dropped, because
      // its painted midpoint is ~25 m from every raw fix.
      expect(result.intervals.where((iv) => iv.wayId == 2), isEmpty,
          reason: 'a parallel way whose geometry is >15 m from all fixes must '
              'be dropped by the proximity guard');
    });

    test('genuine partway drive (<8 m to fixes) is kept', () {
      // A single dead-end residential street driven partway. All fixes sit right
      // on the way (<2 m). The interval midpoint is under the fixes → kept.
      final way = WayCandidate(
        wayId: 1,
        highwayClass: 'residential',
        geometry: [_ll(0, 0), _ll(0, 100), _ll(0, 200)],
      );
      final fixes = [
        _fix(0, 20),
        _fix(0, 60, dtSecs: 2),
        _fix(0, 95, dtSecs: 4), // drove partway (~95 of 200 m)
      ];

      final result = _matcher.match(fixes: fixes, ways: [way]);
      final wIntervals = result.intervals.where((iv) => iv.wayId == 1).toList();
      expect(wIntervals, isNotEmpty,
          reason: 'a genuine partway drive under the fixes must be kept');
    });
  });
}
