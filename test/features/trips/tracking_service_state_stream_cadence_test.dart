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

/// Regression tests for 03-1-RESEARCH H4 verdict (REFUTED).
///
/// H4 hypothesised that `stateStream` did not re-emit per accepted fix,
/// leaving the live tracking panel stuck at zero. Research §5 established
/// that the `FixAccepted` branch in `_onLocation` (`tracking_service.dart:266`)
/// emits a fresh `TrackingRecording` on every accept, feeding the ingestor's
/// running `totalDistanceMeters` / `pointCount` and the incoming fix's
/// `speedKmh`. The failed drive symptom was caused by H1 (zero fixes ever
/// accepted), not by a cadence bug.
///
/// These tests lock in the per-fix cadence invariant so a future refactor
/// that (e.g.) throttles `_emitState` cannot silently break the live panel.
///
/// If either "N fixes → N emissions" assertion fails on first run, the
/// research verdict on H4 was wrong: production has a real bug and belongs
/// in 03-1-02 (or a new plan), not here.
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

  group('TrackingService — H4 regression: stateStream cadence', () {
    test(
        '10 accepted fixes produce >= 10 TrackingRecording emissions with '
        'monotonic pointCount + last currentSpeedKmh reflects the last fix',
        () async {
      final svc = makeService();
      await svc.init();
      await svc.startManual();

      final emissions = <TrackingRecording>[];
      final sub = svc.stateStream.listen((s) {
        if (s is TrackingRecording) emissions.add(s);
      });

      // 10 in-vehicle fixes 1 s apart at ~30 km/h (~8.33 m/s).
      // Each fix advances lat by 0.0005° (~55 m northward) — well above the
      // ingestor's zero-distance threshold, well within the accuracy filter
      // (5 m << 25 m), and spaced far enough to avoid the 1 Hz rate limit
      // (minFixIntervalMs=900). All 10 must be accepted.
      final baseTs = DateTime.now();
      for (var i = 0; i < 10; i++) {
        facade.emitFix(FixInput(
          ts: baseTs.add(Duration(seconds: i + 1)),
          lat: 52.5200 + i * 0.0005,
          lon: 13.4050,
          accuracyMeters: 5,
          speedMps: 8.33, // ~30 km/h
          activityType: 'in_vehicle',
          uuid: 'uuid-h4-cadence-$i',
        ));
        // Yield to the fake facade's broadcast stream after each emit so
        // TrackingService._onLocation runs and pushes its own emission before
        // the next fix arrives. Prevents batching / re-entry surprises.
        await Future<void>.delayed(Duration.zero);
      }
      // Let the event loop drain any residual microtasks.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      // Diagnostics must confirm all 10 were accepted (guards against a
      // scenario where the ingestor rejected some but tests still counted
      // the start-emission).
      expect(svc.diagnostics.acceptCount, 10,
          reason: 'all 10 fixes must be accepted by the ingestor');
      expect(svc.diagnostics.rejectCount, 0);

      // At least 10 TrackingRecording emissions — the start emission
      // (pointCount=0) + 10 accept emissions (pointCount=1..10). Assert
      // >= 10 rather than == 11 to remain robust against future re-emission
      // patterns (e.g. an extra emission on ingestor gap/split flush), but
      // never fewer.
      expect(emissions.length, greaterThanOrEqualTo(10),
          reason: 'stateStream must re-emit at least once per accepted fix');

      // Monotonic pointCount across all emissions.
      for (var i = 1; i < emissions.length; i++) {
        expect(
          emissions[i].pointCount,
          greaterThanOrEqualTo(emissions[i - 1].pointCount),
          reason: 'pointCount must be monotonically non-decreasing across '
              'stateStream emissions (i=$i)',
        );
      }

      // Last emission reflects the last fix's speed (converted to km/h).
      expect(emissions.last.currentSpeedKmh, closeTo(8.33 * 3.6, 0.5));
      // Last emission's pointCount must have reached 10 (all accepted).
      expect(emissions.last.pointCount, 10);

      await svc.dispose();
    });

    test(
        'per-fix distanceMeters is monotonically non-decreasing and '
        'accumulates > 200 m over 5 fixes ~110 m apart', () async {
      final svc = makeService();
      await svc.init();
      await svc.startManual();

      final distances = <double>[];
      final sub = svc.stateStream.listen((s) {
        if (s is TrackingRecording) distances.add(s.distanceMeters);
      });

      // 5 fixes 1 s apart, ~0.001° lat apart (~111 m/step at Berlin latitude).
      final baseTs = DateTime.now();
      for (var i = 0; i < 5; i++) {
        facade.emitFix(FixInput(
          ts: baseTs.add(Duration(seconds: i + 1)),
          lat: 52.5200 + i * 0.001,
          lon: 13.4050,
          accuracyMeters: 5,
          speedMps: 11.1, // ~40 km/h
          activityType: 'in_vehicle',
          uuid: 'uuid-h4-distance-$i',
        ));
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      expect(svc.diagnostics.acceptCount, 5);

      // Monotonic distance across all emissions.
      for (var i = 1; i < distances.length; i++) {
        expect(distances[i], greaterThanOrEqualTo(distances[i - 1]),
            reason: 'distanceMeters must be monotonically non-decreasing '
                '(i=$i)');
      }

      // At least one meaningful accumulation. 4 hops of ~111 m each between
      // the 5 fixes should land the running total well above 200 m; leave
      // headroom for haversine variation.
      expect(distances.last, greaterThan(200),
          reason: '5 fixes ~111 m apart should accumulate > 200 m');

      await svc.dispose();
    });

    test(
        'a rejected fix does NOT increment pointCount on the next stateStream '
        'emission (invariant holds even when the ingestor filters)', () async {
      // Guards against a future regression where TrackingService emits per
      // input fix (including rejects). The invariant is "emit per accepted
      // fix" — if it drifts to "emit per input fix" the pointCount would
      // stall between accepted fixes while emissions kept flowing.
      final svc = makeService();
      await svc.init();
      await svc.startManual();

      final pointCounts = <int>[];
      final sub = svc.stateStream.listen((s) {
        if (s is TrackingRecording) pointCounts.add(s.pointCount);
      });

      // Accept 1, reject 1 (accuracy=500 > 25 m threshold), accept 1.
      final baseTs = DateTime.now();
      facade.emitFix(FixInput(
        ts: baseTs,
        lat: 52.5200,
        lon: 13.4050,
        accuracyMeters: 5,
        speedMps: 8.33,
        activityType: 'in_vehicle',
        uuid: 'uuid-h4-mix-a',
      ));
      await Future<void>.delayed(Duration.zero);
      facade.emitFix(FixInput(
        ts: baseTs.add(const Duration(seconds: 1)),
        lat: 52.5205,
        lon: 13.4050,
        accuracyMeters: 500, // > maxAccuracyMeters (25) → rejected
        speedMps: 8.33,
        activityType: 'in_vehicle',
        uuid: 'uuid-h4-mix-b',
      ));
      await Future<void>.delayed(Duration.zero);
      facade.emitFix(FixInput(
        ts: baseTs.add(const Duration(seconds: 2)),
        lat: 52.5210,
        lon: 13.4050,
        accuracyMeters: 5,
        speedMps: 8.33,
        activityType: 'in_vehicle',
        uuid: 'uuid-h4-mix-c',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      // Ingestor diagnostics: 2 accepted, 1 rejected.
      expect(svc.diagnostics.acceptCount, 2);
      expect(svc.diagnostics.rejectCount, 1);

      // Emissions must reach exactly pointCount=2 at the end.
      expect(pointCounts.last, 2,
          reason: 'final emission must reflect 2 accepted fixes');
      // Monotonic non-decreasing.
      for (var i = 1; i < pointCounts.length; i++) {
        expect(pointCounts[i], greaterThanOrEqualTo(pointCounts[i - 1]));
      }

      await svc.dispose();
    });
  });
}
