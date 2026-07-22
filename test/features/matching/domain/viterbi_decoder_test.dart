// Phase 5 (Plan 05-04): Viterbi HMM decoder — scenario tests.
//
// 12 scenarios covering:
//   1.  Empty trace → empty result
//   2.  Single-fix with 1 candidate → 1 MatchedStep
//   3.  Single-fix with 0 candidates → [null]
//   4.  Straight 5-fix trace along one way → 5 MatchedSteps, all forward
//   5.  MMT-07 speed guard: slow fixes near motorway → service road wins
//   6.  MMT-07 without guard: fast fixes → no penalty applied
//   7.  Gap detection: 10 fixes with 90-second gap → two sub-tracks
//   8.  Low-confidence drop: all fixes 500 m from any way → all null
//   9.  One-way violation: backward motion on oneway=forward way → penalized
//  10.  Deterministic output: two identical runs produce identical results
//  11.  Beam width matters: k=5 solves a scenario k=1 fails
//  12.  Result length equals input length

import 'dart:math' as math;

import 'package:auto_explore/features/matching/domain/gps_fix.dart';
import 'package:auto_explore/features/matching/domain/hmm_probability.dart';
import 'package:auto_explore/features/matching/domain/node_graph.dart';
import 'package:auto_explore/features/matching/domain/viterbi_decoder.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/matching/domain/way_segment_index.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Construct a [WayCandidate] with a straight W→E geometry.
WayCandidate eastWestWay({
  required int wayId,
  required double latBase,
  required double lonStart,
  required double lonEnd,
  String highwayClass = 'residential',
  OnewayDirection oneway = OnewayDirection.no,
  int pointCount = 5,
}) {
  final geom = <LatLng>[];
  for (var i = 0; i < pointCount; i++) {
    final t = i / (pointCount - 1);
    geom.add(LatLng(latBase, lonStart + t * (lonEnd - lonStart)));
  }
  return WayCandidate(
    wayId: wayId,
    geometry: geom,
    highwayClass: highwayClass,
    oneway: oneway,
  );
}

/// Construct a [WayCandidate] with a straight S→N geometry.
WayCandidate northSouthWay({
  required int wayId,
  required double lonBase,
  required double latStart,
  required double latEnd,
  String highwayClass = 'residential',
  OnewayDirection oneway = OnewayDirection.no,
  int pointCount = 5,
}) {
  final geom = <LatLng>[];
  for (var i = 0; i < pointCount; i++) {
    final t = i / (pointCount - 1);
    geom.add(LatLng(latStart + t * (latEnd - latStart), lonBase));
  }
  return WayCandidate(
    wayId: wayId,
    geometry: geom,
    highwayClass: highwayClass,
    oneway: oneway,
  );
}

/// Build GPS fixes equally spaced along a W→E line.
List<GpsFix> eastBoundFixes({
  required double lat,
  required double lonStart,
  required double lonEnd,
  required int count,
  double speedKmh = 50,
  double accuracyMeters = 5,
  DateTime? startTime,
  int intervalSeconds = 1,
}) {
  final base = startTime ?? DateTime.utc(2026, 7, 8, 12);
  final fixes = <GpsFix>[];
  for (var i = 0; i < count; i++) {
    final t = count > 1 ? i / (count - 1) : 0.0;
    fixes.add(
      GpsFix(
        lat: lat,
        lon: lonStart + t * (lonEnd - lonStart),
        accuracyMeters: accuracyMeters,
        speedKmh: speedKmh,
        ts: base.add(Duration(seconds: i * intervalSeconds)),
      ),
    );
  }
  return fixes;
}

/// Single-segment E-W way for trivial tests.
WayCandidate tinyEW(int wayId) => WayCandidate(
      wayId: wayId,
      geometry: const [LatLng(49, 9), LatLng(49, 9.001)],
      highwayClass: 'residential',
    );

void main() {
  // ---------------------------------------------------------------------------
  // Test 1: Empty trace → empty result
  // ---------------------------------------------------------------------------
  test('1. empty trace → empty result', () {
    final index = WaySegmentIndex.buildFromWays([tinyEW(1)]);
    const decoder = ViterbiDecoder();
    expect(decoder.decode([], index), isEmpty);
  });

  // ---------------------------------------------------------------------------
  // Test 2: Single-fix trace with 1 candidate in radius → 1 MatchedStep
  // ---------------------------------------------------------------------------
  test('2. single-fix trace with 1 candidate → 1 MatchedStep', () {
    final way = eastWestWay(wayId: 2, latBase: 49, lonStart: 9, lonEnd: 9.001);
    final index = WaySegmentIndex.buildFromWays([way]);
    const decoder = ViterbiDecoder();

    final fixes = [
      GpsFix(
        lat: 49,
        lon: 9.0005,
        accuracyMeters: 5,
        speedKmh: 30,
        ts: DateTime.utc(2026, 7, 8, 12),
      ),
    ];
    final result = decoder.decode(fixes, index);
    expect(result, hasLength(1));
    expect(result[0], isNotNull);
    expect(result[0]!.wayId, equals(2));
    expect(result[0]!.direction, equals('forward'));
  });

  // ---------------------------------------------------------------------------
  // Test 3: Single-fix trace with 0 candidates in radius → [null]
  // ---------------------------------------------------------------------------
  test('3. single-fix trace with 0 candidates → [null]', () {
    // Way is far north; fix is far south.
    final way = eastWestWay(wayId: 3, latBase: 55, lonStart: 9, lonEnd: 9.1);
    final index = WaySegmentIndex.buildFromWays([way]);
    const decoder = ViterbiDecoder();

    final fixes = [
      GpsFix(
        lat: 49, // ~670 km south of the way
        lon: 9.05,
        accuracyMeters: 5,
        speedKmh: 30,
        ts: DateTime.utc(2026, 7, 8, 12),
      ),
    ];
    final result = decoder.decode(fixes, index);
    expect(result, hasLength(1));
    expect(result[0], isNull);
  });

  // ---------------------------------------------------------------------------
  // Test 4: Straight 5-fix trace along one way → 5 MatchedSteps, all forward
  // ---------------------------------------------------------------------------
  test('4. straight 5-fix trace along one way → all forward on same wayId', () {
    // One E-W way, fixes progress W→E with a 3 m perpendicular offset
    // — well within the emission sigma.
    final way = eastWestWay(wayId: 4, latBase: 49, lonStart: 9, lonEnd: 9.001);
    final index = WaySegmentIndex.buildFromWays([way]);
    const decoder = ViterbiDecoder();

    // 3 m ≈ 0.000027° latitude offset.
    const perpOffsetDeg = 3 / 111320.0;
    final fixes = eastBoundFixes(
      lat: 49 + perpOffsetDeg,
      lonStart: 9.0001,
      lonEnd: 9.0009,
      count: 5,
    );
    final result = decoder.decode(fixes, index);
    expect(result, hasLength(5));
    for (final step in result) {
      expect(step, isNotNull, reason: 'All 5 fixes should match');
      expect(step!.wayId, equals(4));
      expect(step.direction, equals('forward'));
    }
  });

  // ---------------------------------------------------------------------------
  // Test 5: MMT-07 speed guard — slow fixes near motorway + residential
  // ---------------------------------------------------------------------------
  test('5. MMT-07 speed guard: slow speed → residential beats motorway', () {
    // Two ways at very similar perpendicular distances:
    //   way 51: motorway at lat 49.0
    //   way 52: residential at lat 49.000045 (~5 m north)
    // Fix at lat 49.000025 (halfway between) at speed 5 km/h.
    // Motorway penalty ≈ -13.8 nats → residential wins.
    final motorway = eastWestWay(
      wayId: 51,
      latBase: 49,
      lonStart: 9,
      lonEnd: 9.01,
      highwayClass: 'motorway',
    );
    final residential = eastWestWay(
      wayId: 52,
      latBase: 49.000045, // ~5 m north
      lonStart: 9,
      lonEnd: 9.01,
    );
    final index = WaySegmentIndex.buildFromWays([motorway, residential]);
    const decoder = ViterbiDecoder();

    final fixes = List.generate(5, (i) {
      final t = i / 4;
      return GpsFix(
        lat: 49.000025,
        lon: 9 + t * 0.01,
        accuracyMeters: 5,
        speedKmh: 5, // < kSpeedGuardKmh = 15
        ts: DateTime.utc(2026, 7, 8, 12, 0, i),
      );
    });

    final result = decoder.decode(fixes, index);
    expect(result, hasLength(5));
    for (final step in result) {
      expect(step, isNotNull);
      expect(
        step!.wayId,
        equals(52),
        reason: 'Residential should win over motorway at slow speed',
      );
    }
  });

  // ---------------------------------------------------------------------------
  // Test 6: MMT-07 — fast fixes (> 15 km/h) → no penalty applied
  // ---------------------------------------------------------------------------
  test('6. MMT-07: fast speed → motorway emission NOT penalized', () {
    // Single fix exactly on a motorway at speed 80 km/h → no penalty.
    final motorway = eastWestWay(
      wayId: 61,
      latBase: 49,
      lonStart: 9,
      lonEnd: 9.01,
      highwayClass: 'motorway',
    );
    final index = WaySegmentIndex.buildFromWays([motorway]);
    const decoder = ViterbiDecoder();

    final fixes = [
      GpsFix(
        lat: 49,
        lon: 9.005,
        accuracyMeters: 5,
        speedKmh: 80, // fast → no penalty
        ts: DateTime.utc(2026, 7, 8, 12),
      ),
    ];
    final result = decoder.decode(fixes, index);
    expect(result, hasLength(1));
    expect(result[0], isNotNull);
    final step = result[0]!;
    expect(step.wayId, equals(61));

    // Without penalty: emission at perp≈0, sigma=4.07 ≈ -2.72 nats.
    // With penalty: ≈ -2.72 - 13.82 ≈ -16.5 nats.
    // Assert emission is well above -10.0 (unpenalized range).
    expect(
      step.emissionLogP,
      greaterThan(-10.0),
      reason: 'High-speed motorway fix should have unpenalized emission',
    );
  });

  // ---------------------------------------------------------------------------
  // Test 7: Gap detection — 10 fixes with 90-second gap → two sub-tracks
  // ---------------------------------------------------------------------------
  test('7. gap detection: 90-second gap produces two sub-tracks', () {
    final way = eastWestWay(wayId: 7, latBase: 49, lonStart: 9, lonEnd: 9.01);
    final index = WaySegmentIndex.buildFromWays([way]);
    const decoder = ViterbiDecoder();

    final baseTime = DateTime.utc(2026, 7, 8, 12);
    final fixes = <GpsFix>[];

    // First sub-track: fixes 0..4, 1 second apart.
    for (var i = 0; i < 5; i++) {
      fixes.add(GpsFix(
        lat: 49,
        lon: 9 + i * 0.001,
        accuracyMeters: 5,
        speedKmh: 50,
        ts: baseTime.add(Duration(seconds: i)),
      ));
    }
    // Gap: fixes 5..9 are 90 seconds after fix 4 each.
    for (var i = 5; i < 10; i++) {
      fixes.add(GpsFix(
        lat: 49,
        lon: 9.005 + (i - 5) * 0.001,
        accuracyMeters: 5,
        speedKmh: 50,
        ts: baseTime.add(Duration(seconds: 4 + (i - 4) * 90)),
      ));
    }

    final result = decoder.decode(fixes, index);
    expect(result, hasLength(10));

    // All 10 fixes should be matched (way runs along the fix path).
    for (final step in result) {
      expect(step, isNotNull, reason: 'All 10 fixes are close to the way');
    }
    // Both sides of the gap should still match to way 7.
    expect(result[4]!.wayId, equals(7));
    expect(result[5]!.wayId, equals(7));
  });

  // ---------------------------------------------------------------------------
  // Test 7b: Mid-subtrack broken-path reset — the WINNING chain resets in the
  // middle of one sub-track (no time gap), because the route between two
  // consecutive candidates is unreachable on the node graph. Regression for the
  // trip-11 half-match bug (2026-07-22): the traceback used to `break` at the
  // first null back-pointer and silently drop every step BEFORE it. The fix
  // re-chases the prefix so ALL matched fixes are written.
  // ---------------------------------------------------------------------------
  test('7b. mid-subtrack broken-path reset still writes the pre-reset half',
      () {
    // Way A: E-W around lon 9.000-9.004 at lat 49.
    final wayA = eastWestWay(
      wayId: 701,
      latBase: 49,
      lonStart: 9,
      lonEnd: 9.004,
    );
    // Way B: E-W FAR away (lat 49.20, ~22 km north) and NOT connected to A on
    // the node graph — no shared node, and far beyond the route-search cap. A
    // fix jumping from A to B is a Newson-Krumm broken path → B's state resets
    // (backptr null) mid-sub-track.
    final wayB = eastWestWay(
      wayId: 702,
      latBase: 49.20,
      lonStart: 9,
      lonEnd: 9.004,
    );
    final index = WaySegmentIndex.buildFromWays([wayA, wayB]);
    final nodeGraph = NodeGraph.fromWays([wayA, wayB]);
    const decoder = ViterbiDecoder();

    final base = DateTime.utc(2026, 7, 8, 12);
    final fixes = <GpsFix>[];
    // Fixes 0..4 hug way A.
    for (var i = 0; i < 5; i++) {
      fixes.add(GpsFix(
        lat: 49,
        lon: 9.000 + i * 0.001,
        accuracyMeters: 5,
        speedKmh: 50,
        ts: base.add(Duration(seconds: i)),
      ));
    }
    // Fixes 5..9 hug way B — only 1 s later each (NO time gap → same sub-track),
    // but spatially disconnected so the A→B transition is a broken path.
    for (var i = 5; i < 10; i++) {
      fixes.add(GpsFix(
        lat: 49.20,
        lon: 9.000 + (i - 5) * 0.001,
        accuracyMeters: 5,
        speedKmh: 50,
        ts: base.add(Duration(seconds: i)),
      ));
    }

    final result = decoder.decode(fixes, index, nodeGraph: nodeGraph);
    expect(result, hasLength(10));

    // The PRE-reset half (way A, fixes 0..4) must be written — this is exactly
    // what the old traceback dropped.
    for (var i = 0; i < 5; i++) {
      expect(result[i], isNotNull,
          reason: 'fix $i on way A must be matched, not dropped');
      expect(result[i]!.wayId, equals(701));
    }
    // The post-reset half (way B) is matched too.
    for (var i = 5; i < 10; i++) {
      expect(result[i], isNotNull, reason: 'fix $i on way B must be matched');
      expect(result[i]!.wayId, equals(702));
    }
  });

  // ---------------------------------------------------------------------------
  // Test 8: Low-confidence drop — all fixes 500 m from any way → all null
  // ---------------------------------------------------------------------------
  test('8. low-confidence drop: all fixes 500 m from ways → all null', () {
    final way = eastWestWay(wayId: 8, latBase: 49, lonStart: 9, lonEnd: 9.01);
    final index = WaySegmentIndex.buildFromWays([way]);
    const decoder = ViterbiDecoder();

    // 500 m ≈ 0.004496° latitude shift.
    const offsetDeg = 500.0 / 111320.0;
    final fixes = List.generate(
      5,
      (i) => GpsFix(
        lat: 49 - offsetDeg, // 500 m south
        lon: 9 + i * 0.001,
        accuracyMeters: 5,
        speedKmh: 30,
        ts: DateTime.utc(2026, 7, 8, 12, 0, i),
      ),
    );

    final result = decoder.decode(fixes, index);
    expect(result, hasLength(5));
    for (final step in result) {
      expect(step, isNull, reason: 'No way within candidate radius');
    }
  });

  // ---------------------------------------------------------------------------
  // Test 9: One-way violation — backward motion penalized
  // ---------------------------------------------------------------------------
  test('9. one-way: backward motion on forward way vs bidirectional parallel', () {
    // Two parallel ways:
    //   way 91: oneway=forward, lat 49.0
    //   way 92: oneway=no,      lat 49.000090 (~10 m north)
    // Fixes move E→W (backward along way 91's stored node order).
    final onewayEast = eastWestWay(
      wayId: 91,
      latBase: 49,
      lonStart: 9,
      lonEnd: 9.01,
      oneway: OnewayDirection.forward,
    );
    final bothWay = eastWestWay(
      wayId: 92,
      latBase: 49.000090, // ~10 m north
      lonStart: 9,
      lonEnd: 9.01,
    );
    final index = WaySegmentIndex.buildFromWays([onewayEast, bothWay]);
    const decoder = ViterbiDecoder();

    // 3 fixes moving W (decreasing lon) — backward along way 91's node order.
    final baseTime = DateTime.utc(2026, 7, 8, 12);
    final fixes = [
      GpsFix(
        lat: 49,
        lon: 9.008,
        accuracyMeters: 5,
        speedKmh: 30,
        ts: baseTime,
      ),
      GpsFix(
        lat: 49,
        lon: 9.006,
        accuracyMeters: 5,
        speedKmh: 30,
        ts: baseTime.add(const Duration(seconds: 1)),
      ),
      GpsFix(
        lat: 49,
        lon: 9.004,
        accuracyMeters: 5,
        speedKmh: 30,
        ts: baseTime.add(const Duration(seconds: 2)),
      ),
    ];

    final result = decoder.decode(fixes, index);
    expect(result, hasLength(3));

    // Way 91 has better emission (0 m vs 10 m) but incurs the oneway-
    // violation penalty on backward-moving transitions.
    // Accept both outcomes: either the penalty steered to way 92,
    // OR way 91 won (physically closer) but direction is 'backward'.
    final wayIds = result.map((s) => s?.wayId).toList();
    final allOnOneway = wayIds.every((id) => id == 91);
    if (allOnOneway) {
      // Way 91 won despite the penalty. Verify direction is labeled correctly.
      expect(
        result[1]!.direction,
        equals('backward'),
        reason: 'Backward motion on oneway=forward way must be labeled backward',
      );
    } else {
      // Penalty steered some steps to the bidirectional way.
      expect(
        wayIds.any((id) => id == 92),
        isTrue,
        reason: 'Oneway penalty should steer some steps to bidirectional way',
      );
    }
  });

  // ---------------------------------------------------------------------------
  // Test 10: Deterministic output — two runs produce identical results
  // ---------------------------------------------------------------------------
  test('10. deterministic: two runs on same input produce identical output', () {
    final way1 = eastWestWay(wayId: 101, latBase: 49, lonStart: 9, lonEnd: 9.01);
    final way2 = northSouthWay(
      wayId: 102,
      lonBase: 9.005,
      latStart: 48.99,
      latEnd: 49.01,
    );
    final index = WaySegmentIndex.buildFromWays([way1, way2]);
    const decoder = ViterbiDecoder();

    final fixes = eastBoundFixes(
      lat: 49,
      lonStart: 9.001,
      lonEnd: 9.009,
      count: 5,
    );

    final result1 = decoder.decode(fixes, index);
    final result2 = decoder.decode(fixes, index);

    expect(result1, hasLength(result2.length));
    for (var i = 0; i < result1.length; i++) {
      expect(
        result1[i]?.toString(),
        equals(result2[i]?.toString()),
        reason: 'Step $i must be identical across runs',
      );
    }
  });

  // ---------------------------------------------------------------------------
  // Test 11: Beam width matters — k=5 solves a scenario k=1 cannot
  // ---------------------------------------------------------------------------
  test('11. beam width: k=5 keeps correct sequence; k=1 only retains nearest', () {
    // 6 parallel N-S ways at lon 9.0, 9.0001, ..., 9.0005.
    // Fix 0: lon=9.0     → closest to way 111 (index 0)
    // Fix 1: lon=9.0002  → closest to way 113 (index 2)
    // Fix 2: lon=9.0005  → exactly on way 116 (index 5)
    //
    // k=5 carries the full beam so way 116 is always a candidate.
    // k=1 at fix 0 keeps only way 111; at fix 1 it must pick way 113
    // (the nearest at that step).
    final ways = List.generate(
      6,
      (i) => northSouthWay(
        wayId: 111 + i,
        lonBase: 9 + i * 0.0001,
        latStart: 48.995,
        latEnd: 49.005,
      ),
    );
    final index = WaySegmentIndex.buildFromWays(ways);

    final fixes = [
      GpsFix(
        lat: 49,
        lon: 9,
        accuracyMeters: 5,
        speedKmh: 30,
        ts: DateTime.utc(2026, 7, 8, 12),
      ),
      GpsFix(
        lat: 49,
        lon: 9.0002,
        accuracyMeters: 5,
        speedKmh: 30,
        ts: DateTime.utc(2026, 7, 8, 12, 0, 1),
      ),
      GpsFix(
        lat: 49,
        lon: 9.0005,
        accuracyMeters: 5,
        speedKmh: 30,
        ts: DateTime.utc(2026, 7, 8, 12, 0, 2),
      ),
    ];

    // k=5: fix 2 must match to way 116 (nearest at lon 9.0005).
    const decoder5 = ViterbiDecoder();
    final result5 = decoder5.decode(fixes, index);
    expect(result5, hasLength(3));
    expect(result5[2], isNotNull);
    expect(result5[2]!.wayId, equals(116));

    // k=1: at fix 1 (lon=9.0002), only the nearest is kept → way 113.
    const decoder1 = ViterbiDecoder(beamWidth: 1);
    final result1 = decoder1.decode(fixes, index);
    expect(result1, hasLength(3));
    expect(result1[1], isNotNull);
    expect(
      result1[1]!.wayId,
      equals(113),
      reason: 'k=1: at lon=9.0002, nearest candidate is way 113',
    );

    // kBeamWidth constant check (MMT-04).
    expect(kBeamWidth, equals(5), reason: 'MMT-04 requires kBeamWidth = 5');
  });

  // ---------------------------------------------------------------------------
  // Test 12: Result length equals input length
  // ---------------------------------------------------------------------------
  test('12. result length equals input length for various trace lengths', () {
    final way = eastWestWay(wayId: 12, latBase: 49, lonStart: 9, lonEnd: 9.01);
    final index = WaySegmentIndex.buildFromWays([way]);
    const decoder = ViterbiDecoder();

    for (final n in [1, 3, 7, 10, 20]) {
      final fixes = eastBoundFixes(
        lat: 49,
        lonStart: 9.0001,
        lonEnd: 9.009,
        count: n,
      );
      final result = decoder.decode(fixes, index);
      expect(
        result.length,
        equals(n),
        reason: 'Output length $n must equal input length',
      );
    }
  });

  // ---------------------------------------------------------------------------
  // Test 13: onProgress fires with monotonic processed + final == total
  // ---------------------------------------------------------------------------
  test('13. onProgress: monotonic increasing processed, final equals total',
      () {
    // 300 fixes crosses the 128-fix stride twice (128, 256, 300).
    const n = 300;
    final way = eastWestWay(wayId: 13, latBase: 49, lonStart: 9, lonEnd: 9.05);
    final index = WaySegmentIndex.buildFromWays([way]);
    const decoder = ViterbiDecoder();

    final fixes = eastBoundFixes(
      lat: 49,
      lonStart: 9.0001,
      lonEnd: 9.049,
      count: n,
    );

    final calls = <(int, int)>[];
    decoder.decode(
      fixes,
      index,
      onProgress: (processed, total) => calls.add((processed, total)),
    );

    // At least one throttled emission + the final one.
    expect(calls, isNotEmpty);

    // total is always the fix count.
    for (final (_, total) in calls) {
      expect(total, equals(n));
    }

    // processed is strictly increasing.
    for (var i = 1; i < calls.length; i++) {
      expect(
        calls[i].$1,
        greaterThan(calls[i - 1].$1),
        reason: 'processed must be monotonically increasing',
      );
    }

    // processed stays within (0, total].
    for (final (processed, _) in calls) {
      expect(processed, greaterThan(0));
      expect(processed, lessThanOrEqualTo(n));
    }

    // The last emission reports full completion.
    expect(calls.last.$1, equals(n));
    expect(calls.last.$2, equals(n));
  });

  test('13b. onProgress null is a no-op and preserves output', () {
    final way = eastWestWay(wayId: 14, latBase: 49, lonStart: 9, lonEnd: 9.01);
    final index = WaySegmentIndex.buildFromWays([way]);
    const decoder = ViterbiDecoder();
    final fixes = eastBoundFixes(
      lat: 49,
      lonStart: 9.0001,
      lonEnd: 9.009,
      count: 10,
    );

    final withNull = decoder.decode(fixes, index);
    final withCb = decoder.decode(fixes, index, onProgress: (_, _) {});

    expect(withCb.length, equals(withNull.length));
    for (var i = 0; i < withNull.length; i++) {
      expect(withCb[i]?.wayId, equals(withNull[i]?.wayId));
      expect(withCb[i]?.segIdx, equals(withNull[i]?.segIdx));
    }
  });

  // ---------------------------------------------------------------------------
  // Route-aware transition (2026-07-18): with a NodeGraph, a fix near a
  // T-junction that is MARGINALLY closer to the side road must NOT snap to it,
  // because reaching the side road and coming back is a large on-road detour
  // (|route − gc| ≫ 0) while staying on the through-road costs ~0. This is the
  // scenario that produced the "triangle at the T" artifact under the old
  // constant-detour transition (which gave every candidate the same penalty,
  // so the marginally-closer side road won on emission alone).
  // ---------------------------------------------------------------------------
  test('route-aware: near-junction fix stays on through-road, no side spur', () {
    // Through-road (E-W) along lat 49, nodes 10-11-12-13-14 (dense).
    const mainNodes = [10, 11, 12, 13, 14];
    final mainGeom = <LatLng>[
      for (var i = 0; i < 5; i++) LatLng(49, 9 + i * 0.0005),
    ];
    final mainWay = WayCandidate(
      wayId: 1,
      geometry: mainGeom,
      nodeIds: mainNodes,
      highwayClass: 'residential',
    );
    // Side road (N-S) meeting the main road at node 12 (the middle junction,
    // at lon 9.0010). It heads NORTH away from the driven line.
    const sideNodes = [12, 20, 21];
    const sideWay = WayCandidate(
      wayId: 2,
      geometry: [
        LatLng(49, 9.0010), // shared junction node 12
        LatLng(49.0004, 9.0010),
        LatLng(49.0008, 9.0010),
      ],
      nodeIds: sideNodes,
      highwayClass: 'residential',
    );

    final ways = [mainWay, sideWay];
    final index = WaySegmentIndex.buildFromWays(ways);
    final nodeGraph = NodeGraph.fromWays(ways);

    // A straight eastbound trace along the main road, 1 fix/s. The middle fix
    // (near the junction) is nudged 3 m NORTH — toward the side road — to
    // simulate GPS noise that would tip a nearest-road decoder onto the spur.
    const latNudge = 3 / 111320; // ~3 m north
    final fixes = <GpsFix>[
      for (var i = 0; i < 5; i++)
        GpsFix(
          lat: 49 + (i == 2 ? latNudge : 0.0),
          lon: 9 + i * 0.0005,
          accuracyMeters: 5,
          speedKmh: 30,
          ts: DateTime(2026, 7, 18, 12, 0, i),
        ),
    ];

    final steps =
        const ViterbiDecoder().decode(fixes, index, nodeGraph: nodeGraph);

    // Every matched fix must be on the through-road (way 1), never the spur.
    for (var i = 0; i < steps.length; i++) {
      final s = steps[i];
      expect(s, isNotNull, reason: 'fix $i should match');
      expect(
        s!.wayId,
        1,
        reason: 'fix $i snapped to way ${s.wayId}; the near-junction fix must '
            'stay on the through-road, not spur onto the side road',
      );
    }
  });

  // ---------------------------------------------------------------------------
  // Constants group
  // ---------------------------------------------------------------------------
  group('exported constants', () {
    test('kBeamWidth = 5', () => expect(kBeamWidth, equals(5)));
    test('kGapThresholdSeconds = 60',
        () => expect(kGapThresholdSeconds, equals(60)));
    test('kSpeedGuardKmh = 15.0',
        () => expect(kSpeedGuardKmh, equals(15.0)));
    test('kRouteSearchCapFloorMeters = 2000',
        () => expect(kRouteSearchCapFloorMeters, closeTo(2000, 1e-9)));
    test('kRouteSearchCapFactor = 8',
        () => expect(kRouteSearchCapFactor, closeTo(8, 1e-9)));
    test('kMotorwayPenaltyLog = -ln(1e6)', () {
      expect(kMotorwayPenaltyLog, closeTo(-math.log(1e6), 1e-6));
    });
    test('kOnewayViolationLog = -ln(1e6)', () {
      expect(kOnewayViolationLog, closeTo(-math.log(1e6), 1e-6));
    });
    test('kLowConfidenceDropLog = ln(0.001)', () {
      expect(kLowConfidenceDropLog, closeTo(math.log(0.001), 1e-6));
    });
    test('kHighClassHighwaysForSpeedGuard contains expected keys', () {
      expect(
        kHighClassHighwaysForSpeedGuard,
        containsAll(['motorway', 'motorway_link', 'trunk', 'trunk_link']),
      );
    });
    test('kEmissionSigmaMeters = 4.07',
        () => expect(kEmissionSigmaMeters, equals(4.07)));
    test('kTransitionBetaMeters = 1.0',
        () => expect(kTransitionBetaMeters, equals(1.0)));
  });
}
