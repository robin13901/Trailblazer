// Hide the Drift-generated TripPoint row class to avoid ambiguous_import.
import 'package:auto_explore/core/db/app_database.dart' hide TripPoint;
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/data/trips_repository.dart';
import 'package:auto_explore/features/trips/data/trips_repository_points_sink.dart';
import 'package:auto_explore/features/trips/domain/tracking_service.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/domain/trip_fix_input.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_background_geolocation_facade.dart';

/// Regression tests for 03-1-RESEARCH H3 verdict (REFUTED).
///
/// H3 hypothesised that the TRK-01 automotive motion filter was gating
/// manual-trip fixes. Research §4 established that the filter only runs
/// on `motion=true` events *while `_currentState is TrackingIdle`*.
/// `startManual()` explicitly transitions to `TrackingRecording` before any
/// subsequent event, so the filter never fires for manual trips. Similarly,
/// `_onLocation` has no activity gate at all.
///
/// These tests lock in that invariant so a future refactor that (e.g.)
/// hoists the activity check to a shared helper cannot silently break
/// manual recording. They do NOT drive a fix — they codify current-correct
/// behavior as a regression tripwire.
///
/// If any of the "manual bypasses gate" assertions fail on first run, the
/// research verdict was wrong: production has a real bug and belongs in
/// 03-1-02, not here.
void main() {
  late AppDatabase db;
  late TripsRepository repo;
  late TripsRepositoryPointsSink sink;
  late FakeBackgroundGeolocationFacade facade;

  TrackingService makeService() {
    return TrackingService(
      facade: facade,
      repository: repo,
      pointsSink: sink,
    );
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = TripsRepository(TripsDao(db));
    sink = TripsRepositoryPointsSink(repo);
    facade = FakeBackgroundGeolocationFacade();
  });

  tearDown(() async {
    facade.dispose();
    await db.close();
  });

  group('TrackingService — H3 regression: startManual bypasses activity gate',
      () {
    test(
        'manual trip accepts a fix when _lastActivityType has never been set '
        '(default "unknown")', () async {
      // GIVEN: TrackingService with fake facade; no activity events ever fired.
      //        (_lastActivityType defaults to "unknown", _lastActivityAt=null).
      final svc = makeService();
      await svc.init();

      expect(svc.diagnostics.lastActivityType, 'unknown');
      expect(svc.diagnostics.lastActivityAt, isNull);

      // WHEN: startManual() then a single onLocation fix from the facade.
      await svc.startManual();
      expect(svc.currentState, isA<TrackingRecording>());

      // Fixture-timestamp discipline (STATE Plan 03-04): use DateTime.now()-
      // relative timestamps so the ingestor's rate-limit / gap logic behaves
      // as it would in production.
      facade.emitFix(FixInput(
        ts: DateTime.now(),
        lat: 52.5200,
        lon: 13.4050,
        accuracyMeters: 5,
        speedMps: 8.33, // ~30 km/h
        // Deliberately omit activityType — defaults to null, i.e. no
        // activity classification attached to the fix itself.
        uuid: 'uuid-h3-unknown-1',
      ));
      // Yield to the fake facade's stream controller.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // THEN: fix accepted (acceptCount incremented, state still Recording).
      expect(svc.diagnostics.acceptCount, 1,
          reason: 'H3 regression: manual trip must accept fixes '
              'irrespective of _lastActivityType');
      expect(svc.diagnostics.rejectCount, 0);
      expect(svc.currentState, isA<TrackingRecording>());
      expect((svc.currentState as TrackingRecording).pointCount, 1);

      await svc.dispose();
    });

    test(
        'manual trip accepts a fix even when _lastActivityType is a '
        'non-vehicle value like "on_foot"', () async {
      // GIVEN: activity fires "on_foot" (explicitly non-vehicle), then
      //        startManual — the filter, if it wrongly applied to manual
      //        trips, would reject subsequent fixes on the "not in_vehicle"
      //        branch.
      final svc = makeService();
      await svc.init();

      facade.emitActivity('on_foot');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(svc.diagnostics.lastActivityType, 'on_foot');

      await svc.startManual();
      expect(svc.currentState, isA<TrackingRecording>());

      facade.emitFix(FixInput(
        ts: DateTime.now(),
        lat: 52.5205,
        lon: 13.4050,
        accuracyMeters: 5,
        speedMps: 8.33,
        uuid: 'uuid-h3-onfoot-1',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // THEN: fix accepted regardless of the non-vehicle activity signal.
      expect(svc.diagnostics.acceptCount, 1,
          reason: 'H3 regression: activity gate must not apply to manual '
              'trips even when _lastActivityType is non-vehicle');
      expect((svc.currentState as TrackingRecording).pointCount, 1);

      await svc.dispose();
    });

    test(
        'stateStream re-emits TrackingRecording on the first manual accepted '
        'fix (proof the "unknown" activity path emits, not just start)',
        () async {
      // GIVEN: no activity, no motion — pure manual path.
      final svc = makeService();
      await svc.init();

      final recordingEmissions = <TrackingRecording>[];
      final sub = svc.stateStream.listen((s) {
        if (s is TrackingRecording) recordingEmissions.add(s);
      });

      // WHEN: startManual + one fix.
      await svc.startManual();
      facade.emitFix(FixInput(
        ts: DateTime.now(),
        lat: 52.5210,
        lon: 13.4050,
        accuracyMeters: 5,
        speedMps: 8.33,
        uuid: 'uuid-h3-stream-1',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await sub.cancel();

      // THEN: at least two TrackingRecording emissions — one for start
      //        (pointCount=0) and one for the accepted fix (pointCount=1).
      //        This proves the acceptance path actually runs, not just the
      //        start transition.
      expect(recordingEmissions.length, greaterThanOrEqualTo(2),
          reason: 'expected start-emission + per-fix emission');
      expect(recordingEmissions.first.pointCount, 0);
      expect(recordingEmissions.last.pointCount, 1);
      expect(recordingEmissions.last.currentSpeedKmh,
          closeTo(8.33 * 3.6, 0.5));

      await svc.dispose();
    });

    // -------------------------------------------------------------------------
    // Plan 06-08: automatic recording removed. Motion while idle must NEVER
    // open a trip — regardless of activity classification. This subsumes the
    // old "TRK-01 gate" assertion (idle stays idle) and hardens it: not even
    // a fresh in_vehicle signal opens a trip anymore.
    // -------------------------------------------------------------------------
    test(
        'motion=true while idle never opens a trip (manual-only, Plan 06-08)',
        () async {
      // GIVEN: TrackingService in TrackingIdle, no activity events, no manual
      //        start.
      final svc = makeService();
      await svc.init();
      expect(svc.currentState, isA<TrackingIdle>());
      expect(svc.diagnostics.lastActivityType, 'unknown');

      // WHEN: motion=true arrives while idle, without any preceding
      //        in_vehicle activity signal.
      facade.emitMotion(isMoving: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // THEN: state remains Idle — no auto-trip opened.
      expect(svc.currentState, isA<TrackingIdle>(),
          reason: 'Plan 06-08: motion=true must never auto-open a trip');
      expect(svc.diagnostics.currentTripId, isNull);

      // Even a fresh in_vehicle activity + motion must not open a trip now.
      facade.emitActivity('in_vehicle');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      facade.emitMotion(isMoving: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(svc.currentState, isA<TrackingIdle>(),
          reason: 'Plan 06-08: even fresh in_vehicle + motion stays Idle');
      expect(facade.startCalls, 0,
          reason: 'no speculative FGB start() on motion');

      await svc.dispose();
    });
  });
}
