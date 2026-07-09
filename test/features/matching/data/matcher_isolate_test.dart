// Phase 5 (Plan 05-06): MatcherIsolate tests.
//
// Test inventory (4 scenarios):
//   1. start + one match roundtrip: spawn, send a trivial job (2 fixes on a
//      2-node way), await MatchResult, assert non-null + matchedFixCount > 0,
//      dispose. Must complete in < 30 s.
//
//   2. Two concurrent jobs return correctly-keyed results: spawn, fire both
//      jobs (different ways with distinct wayIds) simultaneously, await both
//      futures concurrently, assert each Future resolves with a MatchResult
//      whose intervals reference the correct input way (verified by wayId).
//
//   3. Cancel before job starts → MatcherCancelledException (or success):
//      enqueue a blocker job, enqueue a cancellable job, immediately cancel,
//      await the outcome. Accepts either MatcherCancelledException (cancel won
//      the race) or success (job started before cancel arrived). Documents v1
//      pre-check semantics — whichever outcome occurs, only
//      MatcherCancelledException or null error is acceptable.
//
//   4. dispose without hanging: start(), dispose() immediately (no jobs), no
//      exception, no lingering isolate.
//
// Timeout per test: 30 s (see Timeout annotations) to fail fast on hangs.

import 'package:auto_explore/features/matching/data/match_job.dart';
import 'package:auto_explore/features/matching/data/matcher_isolate.dart';
import 'package:auto_explore/features/matching/domain/gps_fix.dart';
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

/// Build a [GpsFix] at a local offset from the base point.
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

/// A simple 2-node east-running way: 100 m long.
WayCandidate _simpleWay({int id = 1}) => WayCandidate(
      wayId: id,
      highwayClass: 'residential',
      geometry: [_ll(0, 0), _ll(0, 100)],
    );

/// A 4-node way running east along the baseline (y=0),
/// nodes at x=0,100,200,300 m.
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

/// A 4-node way running 500 m north of baseline, nodes at x=0,100,200,300 m.
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('MatcherIsolate', () {
    // -------------------------------------------------------------------------
    // Test 1: start + one match roundtrip
    // -------------------------------------------------------------------------
    test(
      '1. start + one match roundtrip — spawns, roundtrips, disposes cleanly',
      timeout: const Timeout(Duration(seconds: 30)),
      () async {
        final iso = MatcherIsolate();
        addTearDown(iso.dispose);
        await iso.start();

        final fixes = [
          _fix(0, 10),
          _fix(0, 50, dtSecs: 1),
        ];
        final ways = [_simpleWay()];

        final result = await iso.match(
          tripId: 1,
          fixes: fixes,
          ways: ways,
        );

        // The trivial 2-fix trace on a 100-m east way should produce at least
        // one matched fix.
        expect(result, isNotNull);
        expect(result.matchedFixCount + result.droppedFixCount, fixes.length);
        expect(result.matchedFixCount, greaterThan(0));
      },
    );

    // -------------------------------------------------------------------------
    // Test 2: Two concurrent jobs return correctly-keyed results
    // -------------------------------------------------------------------------
    test(
      '2. two concurrent jobs — futures resolve with correctly-keyed results',
      timeout: const Timeout(Duration(seconds: 30)),
      () async {
        final iso = MatcherIsolate();
        addTearDown(iso.dispose);
        await iso.start();

        // Job A: 3 fixes along the east way (wayId=1), at baseline y=0.
        final fixesA = [
          _fix(0, 50),
          _fix(0, 150, dtSecs: 1),
          _fix(0, 250, dtSecs: 2),
        ];
        final wayA = _eastWay();

        // Job B: 3 fixes along the north-offset way (wayId=2), at y=500 m.
        final fixesB = [
          _fix(500, 50),
          _fix(500, 150, dtSecs: 1),
          _fix(500, 250, dtSecs: 2),
        ];
        final wayB = _northOffsetWay();

        // Fire both jobs without awaiting the first one.
        final futureA = iso.match(tripId: 10, fixes: fixesA, ways: [wayA]);
        final futureB = iso.match(tripId: 20, fixes: fixesB, ways: [wayB]);

        // Await both concurrently.
        final results = await Future.wait([futureA, futureB]);
        final resultA = results[0];
        final resultB = results[1];

        // Job A: at least one fix matched; all intervals on wayId=1.
        expect(resultA.matchedFixCount, greaterThan(0));
        for (final interval in resultA.intervals) {
          expect(interval.wayId, 1,
              reason: 'Job A intervals should be on wayId=1');
        }

        // Job B: at least one fix matched; all intervals on wayId=2.
        expect(resultB.matchedFixCount, greaterThan(0));
        for (final interval in resultB.intervals) {
          expect(interval.wayId, 2,
              reason: 'Job B intervals should be on wayId=2');
        }
      },
    );

    // -------------------------------------------------------------------------
    // Test 3: Cancel before job starts → MatcherCancelledException (or success)
    // -------------------------------------------------------------------------
    test(
      '3. cancel — future completes with MatcherCancelledException or success',
      timeout: const Timeout(Duration(seconds: 30)),
      () async {
        final iso = MatcherIsolate();
        addTearDown(iso.dispose);
        await iso.start();

        // Enqueue a blocker job (job 1) to keep the worker busy, then
        // immediately enqueue + cancel job 2. In v1, the cancel-set is
        // consulted BEFORE starting each job. If the cancel message arrives
        // before the worker pops job 2, we get MatcherCancelledException.
        // If the worker starts job 2 first (race lost), we get a normal result.
        // Both outcomes are valid for v1.

        const cancelTripId = 99;

        final blocker = iso.match(
          tripId: 1,
          fixes: [
            _fix(0, 50),
            _fix(0, 150, dtSecs: 1),
            _fix(0, 250, dtSecs: 2),
          ],
          ways: [_eastWay()],
        );

        final cancellable = iso.match(
          tripId: cancelTripId,
          fixes: [
            _fix(0, 50),
            _fix(0, 150, dtSecs: 1),
          ],
          ways: [_eastWay()],
        );

        // Send cancel immediately after enqueueing job 2.
        iso.cancel(cancelTripId);

        // Await the blocker so the cancel message has time to propagate.
        await blocker;

        // Observe the cancellable job's outcome.
        Object? thrownError;
        try {
          await cancellable;
        } on MatcherCancelledException catch (e) {
          thrownError = e;
        } on Object catch (e) {
          thrownError = e;
        }

        // Either outcome is acceptable for v1:
        //   - MatcherCancelledException → cancel won the race.
        //   - null thrownError → job started before cancel arrived (also fine).
        if (thrownError != null) {
          expect(
            thrownError,
            isA<MatcherCancelledException>(),
            reason: 'When the future throws, it must be MatcherCancelledException',
          );
        }
      },
    );

    // -------------------------------------------------------------------------
    // Test 5: onProgress fires during a long job
    // -------------------------------------------------------------------------
    test(
      '5. onProgress — callback fires with processed<=total during match',
      timeout: const Timeout(Duration(seconds: 30)),
      () async {
        final iso = MatcherIsolate();
        addTearDown(iso.dispose);
        await iso.start();

        // A long east way + 300 fixes along it crosses the 128-fix decoder
        // progress stride, so at least one MatchJobProgress is emitted.
        final way = WayCandidate(
          wayId: 1,
          highwayClass: 'residential',
          geometry: [_ll(0, 0), _ll(0, 3000)],
        );
        final fixes = <GpsFix>[
          for (var i = 0; i < 300; i++)
            _fix(0, 10.0 + i * 10, dtSecs: i),
        ];

        final calls = <(int, int)>[];
        final result = await iso.match(
          tripId: 1,
          fixes: fixes,
          ways: [way],
          onProgress: (processed, total) => calls.add((processed, total)),
        );

        expect(result, isNotNull);
        expect(calls, isNotEmpty, reason: 'progress must fire for a long job');
        for (final (processed, total) in calls) {
          expect(total, equals(fixes.length));
          expect(processed, greaterThan(0));
          expect(processed, lessThanOrEqualTo(total));
        }
        // Final progress reports full completion.
        expect(calls.last.$1, equals(fixes.length));
      },
    );
  });
}
