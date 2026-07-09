import 'dart:async';

// Hide the Drift-generated TripPoint row class to avoid ambiguous_import.
import 'package:auto_explore/core/db/app_database.dart' hide TripPoint;
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/data/trips_repository.dart';
import 'package:auto_explore/features/trips/data/trips_repository_points_sink.dart';
import 'package:auto_explore/features/trips/domain/tracking_service.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/domain/trip_fix_input.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/fake_background_geolocation_facade.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build 10 in-vehicle fixes spaced 1 s apart at 100 km/h (~27.8 m/s).
/// Each fix advances lat by 0.00025° ≈ 27.8 m northward.
/// [from] anchors the timestamp so the trip's startedAt ≈ from.
List<FixInput> buildFixesFrom(DateTime from, int count,
    {double baseLat = 49.0, double baseLon = 8.0, int startSeq = 0}) {
  return List.generate(count, (i) {
    return FixInput(
      ts: from.add(Duration(seconds: startSeq + i)),
      lat: baseLat + (startSeq + i) * 0.00025,
      lon: baseLon,
      accuracyMeters: 8,
      speedMps: 27.8, // ≈ 100 km/h → ~27.8 m/s → each step ~27.8 m
      activityType: 'in_vehicle',
      uuid: 'uuid-fix-${startSeq + i}',
    );
  });
}

/// Wait for the next emission on a stream and return it.
Future<T> nextState<T>(Stream<T> stream) {
  final completer = Completer<T>();
  late StreamSubscription<T> sub;
  sub = stream.listen((v) {
    if (!completer.isCompleted) {
      completer.complete(v);
      unawaited(sub.cancel());
    }
  });
  return completer.future;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late AppDatabase db;
  late TripsRepository repo;
  late TripsRepositoryPointsSink sink;
  late FakeBackgroundGeolocationFacade facade;

  /// Build a TrackingService with injected short timers for test speed.
  TrackingService makeService({
    Duration autoStopDwell = const Duration(minutes: 2),
    Duration resumeWindow = const Duration(minutes: 15),
    Duration activityFreshness = const Duration(seconds: 10),
    Duration notificationInterval = const Duration(seconds: 30),
  }) {
    return TrackingService(
      facade: facade,
      repository: repo,
      pointsSink: sink,
      autoStopDwell: autoStopDwell,
      resumeWindow: resumeWindow,
      activityFreshness: activityFreshness,
      notificationInterval: notificationInterval,
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

  group('TrackingService', () {
    // -------------------------------------------------------------------------
    // 1. Manual round-trip
    // -------------------------------------------------------------------------
    test('manual round-trip: start → 10 fixes → stop → 1 trip row, 10 points',
        () async {
      final svc = makeService();
      await svc.init();

      await svc.startManual();
      expect(svc.currentState, isA<TrackingRecording>());
      expect(facade.moving, isTrue);

      // Emit 65 in-vehicle fixes 1 s apart to exceed keeper threshold (>60 s, >100 m).
      final now = DateTime.now();
      for (final fix in buildFixesFrom(now, 65)) {
        facade.emitFix(fix);
        await Future<void>.delayed(Duration.zero); // yield to stream handler
      }
      // Allow batcher auto-flush future to complete.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await svc.stopActive();
      expect(svc.currentState, isA<TrackingIdle>());
      expect(facade.moving, isFalse);

      // Verify DB: 1 trip row with status=pending and 10 points.
      final tripRows = await db
          .customSelect('SELECT * FROM trips')
          .get();
      expect(tripRows, hasLength(1));
      expect(tripRows.first.read<String>('status'), 'pending');
      expect(tripRows.first.read<int?>('ended_at'), isNotNull);
      expect(tripRows.first.read<int>('auto_stopped'), 0);

      final pointCount = await db
          .customSelect('SELECT COUNT(*) as cnt FROM trip_points')
          .get();
      expect(pointCount.first.read<int>('cnt'), 65);

      await svc.dispose();
    });

    // -------------------------------------------------------------------------
    // 2. Manual below keeper threshold
    // -------------------------------------------------------------------------
    test('manual below keeper: 3 quick fixes → stopActive → 0 trip rows',
        () async {
      final svc = makeService();
      await svc.init();

      await svc.startManual();

      // 3 fixes within a tiny bbox (< 50 m total, < 30 s, < 100 m distance).
      final now = DateTime.now();
      for (var i = 0; i < 3; i++) {
        facade.emitFix(FixInput(
          ts: now.add(Duration(seconds: i)),
          lat: 49.0001 * i + 49,
          lon: 8,
          accuracyMeters: 8,
          speedMps: 2,
          activityType: 'in_vehicle',
          uuid: 'uuid-small-$i',
        ));
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await svc.stopActive();

      // Trip should be deleted (micro-trip below keeper).
      final tripRows =
          await db.customSelect('SELECT * FROM trips').get();
      expect(tripRows, isEmpty);

      final pointRows =
          await db.customSelect('SELECT * FROM trip_points').get();
      expect(pointRows, isEmpty);

      await svc.dispose();
    });

    // -------------------------------------------------------------------------
    // 3. Auto-start on motion + fresh in_vehicle
    // -------------------------------------------------------------------------
    test(
        'auto-start: fresh in_vehicle activity then motion=true → '
        'trip row created, state=TrackingRecording', () async {
      final svc = makeService(
      );
      await svc.init();
      expect(svc.currentState, isA<TrackingIdle>());

      // Emit fresh in_vehicle activity, then motion=true within freshness.
      facade.emitActivity('in_vehicle');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      facade.emitMotion(isMoving: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(svc.currentState, isA<TrackingRecording>());
      final state = svc.currentState as TrackingRecording;
      expect(state.manuallyStarted, isFalse);

      // DB should have 1 recording trip.
      final tripRows = await db.customSelect('SELECT * FROM trips').get();
      expect(tripRows, hasLength(1));
      expect(tripRows.first.read<String>('status'), 'recording');

      await svc.stopActive();
      await svc.dispose();
    });

    // -------------------------------------------------------------------------
    // 4. Auto-start DISCARDED on stale activity
    // -------------------------------------------------------------------------
    test(
        'auto-start discarded on stale activity: '
        'motion=true after freshness window expires → state stays Idle', () async {
      const freshnessMs = 100;
      final svc = makeService(
        activityFreshness: const Duration(milliseconds: freshnessMs),
      );
      await svc.init();

      // Emit activity, then wait past freshness window.
      facade.emitActivity('in_vehicle');
      await Future<void>.delayed(const Duration(milliseconds: freshnessMs + 50));

      // Motion arrives — activity is now stale → should be discarded.
      facade.emitMotion(isMoving: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(svc.currentState, isA<TrackingIdle>(),
          reason: 'Stale activity should discard the motion event');

      final tripRows = await db.customSelect('SELECT * FROM trips').get();
      expect(tripRows, isEmpty, reason: 'No trip should be opened');

      // Now emit a fresh activity and motion — should open a trip.
      facade.emitActivity('in_vehicle');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      facade.emitMotion(isMoving: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(svc.currentState, isA<TrackingRecording>(),
          reason: 'Fresh activity + motion should open a trip');

      await svc.stopActive();
      await svc.dispose();
    });

    // -------------------------------------------------------------------------
    // 5. Auto-start DISCARDED on non-automotive activity
    // -------------------------------------------------------------------------
    test(
        'auto-start discarded on non-automotive activity: '
        'walking + motion=true → state stays Idle', () async {
      final svc = makeService(
      );
      await svc.init();

      facade.emitActivity('walking');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      facade.emitMotion(isMoving: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(svc.currentState, isA<TrackingIdle>());

      final tripRows = await db.customSelect('SELECT * FROM trips').get();
      expect(tripRows, isEmpty);

      await svc.dispose();
    });

    // -------------------------------------------------------------------------
    // 6. Auto-stop after dwell
    // -------------------------------------------------------------------------
    test('auto-stop after dwell: still for dwell + resume window → trip closed',
        () async {
      const dwellMs = 100;
      const resumeMs = 200;
      final svc = makeService(
        autoStopDwell: const Duration(milliseconds: dwellMs),
        resumeWindow: const Duration(milliseconds: resumeMs),
      );
      await svc.init();

      // Auto-start with fresh in_vehicle.
      facade.emitActivity('in_vehicle');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      facade.emitMotion(isMoving: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(svc.currentState, isA<TrackingRecording>());

      // Emit 65 fixes at 1 Hz from now → 65 s ≥ 60 s keeper threshold.
      final startNow = DateTime.now();
      for (final fix in buildFixesFrom(startNow, 65)) {
        facade.emitFix(fix);
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Emit non-automotive activity → start dwell timer.
      facade.emitActivity('still');
      await Future<void>.delayed(const Duration(milliseconds: dwellMs + resumeMs + 100));

      // After dwell + resume window, trip should be auto-closed.
      expect(svc.currentState, isA<TrackingIdle>(),
          reason: 'Trip should be auto-stopped after dwell + resume window');

      final tripRows = await db.customSelect('SELECT * FROM trips').get();
      expect(tripRows, hasLength(1));
      expect(tripRows.first.read<int>('auto_stopped'), 1);
      expect(tripRows.first.read<int?>('ended_at'), isNotNull);

      await svc.dispose();
    });

    // -------------------------------------------------------------------------
    // 7. Resume window extends trip
    // -------------------------------------------------------------------------
    test(
        'resume window extends trip: in_vehicle activity within window → '
        'same trip continues (endedAt null)', () async {
      const dwellMs = 100;
      const resumeMs = 300;
      final svc = makeService(
        autoStopDwell: const Duration(milliseconds: dwellMs),
        resumeWindow: const Duration(milliseconds: resumeMs),
      );
      await svc.init();

      // Auto-start.
      facade.emitActivity('in_vehicle');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      facade.emitMotion(isMoving: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Emit a fix so _lastAcceptedFix is set.
      final resumeBase = DateTime.now();
      facade.emitFix(FixInput(
        ts: resumeBase,
        lat: 49,
        lon: 8,
        accuracyMeters: 8,
        speedMps: 27.8,
        activityType: 'in_vehicle',
        uuid: 'uuid-resume-1',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final recState = svc.currentState as TrackingRecording;
      final tripId = recState.tripId;

      // Emit non-automotive → start dwell.
      facade.emitActivity('still');
      // Wait for dwell to expire but NOT for resume window to expire.
      await Future<void>.delayed(const Duration(milliseconds: dwellMs + 50));

      // Trip should still be recording (resume window not expired).
      expect(svc.currentState, isA<TrackingRecording>());

      // Within resume window, emit in_vehicle activity + a fix nearby.
      facade.emitFix(FixInput(
        ts: resumeBase.add(const Duration(seconds: 1)),
        lat: 49.0001, // ~11 m north — within 500 m radius
        lon: 8,
        accuracyMeters: 8,
        speedMps: 27.8,
        activityType: 'in_vehicle',
        uuid: 'uuid-resume-2',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      facade.emitActivity('in_vehicle');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // State should still be TrackingRecording (same trip).
      expect(svc.currentState, isA<TrackingRecording>());
      expect((svc.currentState as TrackingRecording).tripId, tripId);

      // DB: trip row should have endedAt = null (still recording).
      final tripRows = await db
          .customSelect('SELECT * FROM trips WHERE id = ?', variables: [
        Variable<int>(tripId),
      ]).get();
      expect(tripRows, hasLength(1));
      expect(tripRows.first.read<int?>('ended_at'), isNull);

      // One row (not two).
      final allTrips = await db.customSelect('SELECT * FROM trips').get();
      expect(allTrips, hasLength(1));

      await svc.stopActive();
      await svc.dispose();
    });

    // -------------------------------------------------------------------------
    // 8. Manual trip ignores dwell
    // -------------------------------------------------------------------------
    test(
        'manual trip ignores dwell: non-automotive activity for long time → '
        'state stays TrackingRecording', () async {
      const dwellMs = 100;
      final svc = makeService(
        autoStopDwell: const Duration(milliseconds: dwellMs),
        resumeWindow: const Duration(milliseconds: 200),
      );
      await svc.init();

      await svc.startManual();
      expect(svc.currentState, isA<TrackingRecording>());

      // Emit some fixes anchored to now.
      final manualBase = DateTime.now();
      for (var i = 0; i < 5; i++) {
        facade.emitFix(FixInput(
          ts: manualBase.add(Duration(seconds: i)),
          lat: 49.0 + i * 0.001,
          lon: 8,
          accuracyMeters: 8,
          speedMps: 10,
          activityType: 'in_vehicle',
          uuid: 'uuid-manual-$i',
        ));
        await Future<void>.delayed(Duration.zero);
      }

      // Emit non-automotive for much longer than dwell.
      facade.emitActivity('still');
      // Duration uses a runtime expression (dwellMs * 5 + 200) — not const.
      // ignore: prefer_const_constructors
      await Future<void>.delayed(Duration(milliseconds: dwellMs * 5 + 200));

      // Manual trip should NOT have auto-stopped.
      expect(svc.currentState, isA<TrackingRecording>(),
          reason: 'Manual trip must not auto-stop');
      expect((svc.currentState as TrackingRecording).manuallyStarted, isTrue);

      final tripRows = await db.customSelect('SELECT * FROM trips').get();
      expect(tripRows, hasLength(1));
      expect(tripRows.first.read<int?>('ended_at'), isNull);

      await svc.stopActive();
      await svc.dispose();
    });

    // -------------------------------------------------------------------------
    // 9. Cold-start hydration
    // -------------------------------------------------------------------------
    test('cold-start hydration: existing active trip → init() → TrackingRecording',
        () async {
      // Seed an active trip directly via repo.
      final seedResult = await repo.openTrip(
        startedAt: DateTime.now(),
        manuallyStarted: true,
      );
      final seededTripId = seedResult.when(ok: (v) => v, err: (_) => -1);
      expect(seededTripId, isNot(-1));

      // Build service AFTER seeding.
      final svc = makeService();
      await svc.init();

      expect(svc.currentState, isA<TrackingRecording>());
      final state = svc.currentState as TrackingRecording;
      expect(state.tripId, seededTripId);
      expect(state.manuallyStarted, isTrue);

      await svc.dispose();
    });

    // -------------------------------------------------------------------------
    // 10. SplitRequired closes + opens
    // -------------------------------------------------------------------------
    test(
        'SplitRequired: fix then fix 6 min later at 800 m → '
        'two trip rows, first closed, second active', () async {
      final svc = makeService();
      await svc.init();

      await svc.startManual();
      final firstState = svc.currentState as TrackingRecording;
      final firstTripId = firstState.tripId;

      // Emit 65 fixes first so the first trip passes the keeper threshold.
      final splitBase = DateTime.now();
      for (var i = 0; i < 65; i++) {
        facade.emitFix(FixInput(
          ts: splitBase.add(Duration(seconds: i)),
          lat: 50.3 + i * 0.00025, // moving north ~27 m/step
          lon: 8.8,
          accuracyMeters: 8,
          speedMps: 10,
          activityType: 'in_vehicle',
          uuid: 'uuid-split-pre-$i',
        ));
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Last accepted fix is at (50.3 + 64*0.00025, 8.8).
      // Now emit a fix with 6-min gap AND ~800 m away → SplitRequired.
      // 0.0072° lat at 50°N ≈ 800 m.
      const lastLat = 50.3 + 64 * 0.00025;
      facade.emitFix(FixInput(
        ts: splitBase.add(const Duration(minutes: 6, seconds: 65)),
        lat: lastLat + 0.0072, // ~800 m further north
        lon: 8.801,
        accuracyMeters: 8,
        speedMps: 10,
        activityType: 'in_vehicle',
        uuid: 'uuid-split-second',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Two trip rows: first closed, second active.
      final allTrips =
          await db.customSelect('SELECT * FROM trips ORDER BY id').get();
      expect(allTrips, hasLength(2),
          reason: 'Split should create a second trip row');

      // First trip should be closed (endedAt set).
      expect(allTrips[0].read<int?>('ended_at'), isNotNull,
          reason: 'First trip must be closed after split');

      // Second trip should be active (endedAt null).
      expect(allTrips[1].read<int?>('ended_at'), isNull,
          reason: 'Second trip must be active after split');

      // Current state should reflect the new trip.
      expect(svc.currentState, isA<TrackingRecording>());
      final newState = svc.currentState as TrackingRecording;
      expect(newState.tripId, isNot(firstTripId));

      await svc.stopActive();
      await svc.dispose();
    });

    // -------------------------------------------------------------------------
    // 11. Notification ticker fires during manual trip
    // -------------------------------------------------------------------------
    test(
        'notification ticker: fires >= 3 times during a 350 ms manual trip, '
        'each text starts with "Recording · "', () async {
      const intervalMs = 100;
      final svc = makeService(
        notificationInterval: const Duration(milliseconds: intervalMs),
      );
      await svc.init();

      await svc.startManual();
      expect(svc.currentState, isA<TrackingRecording>());

      // Emit 65 fixes so the trip passes the keeper threshold on stop.
      final now = DateTime.now();
      for (final fix in buildFixesFrom(now, 65)) {
        facade.emitFix(fix);
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Wait long enough for the ticker to fire at least 3 times (3 × 100 ms).
      await Future<void>.delayed(const Duration(milliseconds: 350));

      expect(
        facade.notificationTexts.length,
        greaterThanOrEqualTo(3),
        reason: 'Ticker should fire at least 3 times in 350 ms with 100 ms interval',
      );
      for (final text in facade.notificationTexts) {
        expect(
          text,
          startsWith('Recording · '),
          reason: 'Every notification text must start with "Recording · "',
        );
      }

      final countBeforeStop = facade.notificationTexts.length;

      // Stop the trip — ticker must be cancelled.
      await svc.stopActive();
      expect(svc.currentState, isA<TrackingIdle>());

      // Wait another interval to confirm the ticker is no longer firing.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(
        facade.notificationTexts.length,
        countBeforeStop,
        reason: 'Ticker must stop firing after stopActive()',
      );

      await svc.dispose();
    });

    // -------------------------------------------------------------------------
    // 12. Notification duration format — hours segment (Plan 04-19)
    // -------------------------------------------------------------------------
    group('formatNotificationDuration', () {
      test('under 1h renders as mm:ss (no hours segment)', () {
        expect(formatNotificationDuration(Duration.zero), '00:00');
        expect(
          formatNotificationDuration(const Duration(seconds: 45)),
          '00:45',
        );
        expect(
          formatNotificationDuration(const Duration(minutes: 40, seconds: 3)),
          '40:03',
        );
        expect(
          formatNotificationDuration(
            const Duration(minutes: 59, seconds: 59),
          ),
          '59:59',
        );
      });

      test('exactly 1h renders as 1:00:00', () {
        expect(
          formatNotificationDuration(const Duration(hours: 1)),
          '1:00:00',
        );
      });

      test('100-min drive (Plan 04-19 regression case) renders as 1:40:XX',
          () {
        expect(
          formatNotificationDuration(
            const Duration(hours: 1, minutes: 40, seconds: 27),
          ),
          '1:40:27',
        );
      });

      test('10h+ trip renders with unpadded hours (10:03:12)', () {
        expect(
          formatNotificationDuration(
            const Duration(hours: 10, minutes: 3, seconds: 12),
          ),
          '10:03:12',
        );
      });
    });

    // -------------------------------------------------------------------------
    // 13. Motion-vector heading on TrackingRecording (Plan 06-07)
    // -------------------------------------------------------------------------
    group('motion-vector heading (Plan 06-07)', () {
      test(
          'computed bearing from consecutive fixes lands on '
          'TrackingRecording.headingDegrees (northward ≈ 0°)', () async {
        final svc = makeService();
        await svc.init();
        await svc.startManual();

        final headings = <double?>[];
        final sub = svc.stateStream.listen((s) {
          if (s is TrackingRecording) headings.add(s.headingDegrees);
        });

        // Two fixes moving due north (~55 m apart, > 5 m jitter guard). No
        // headingDegrees supplied → service must compute the bearing.
        final base = DateTime.now();
        facade.emitFix(FixInput(
          ts: base,
          lat: 49.0000,
          lon: 8.0,
          accuracyMeters: 5,
          speedMps: 10,
          activityType: 'in_vehicle',
          uuid: 'uuid-heading-n1',
        ));
        await Future<void>.delayed(Duration.zero);
        facade.emitFix(FixInput(
          ts: base.add(const Duration(seconds: 1)),
          lat: 49.0005, // ~55 m north
          lon: 8.0,
          accuracyMeters: 5,
          speedMps: 10,
          activityType: 'in_vehicle',
          uuid: 'uuid-heading-n2',
        ));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await sub.cancel();

        final last = svc.currentState as TrackingRecording;
        expect(last.headingDegrees, isNotNull);
        expect(last.headingDegrees, closeTo(0, 1),
            reason: 'northward motion → heading ≈ 0°');

        await svc.dispose();
      });

      test(
          'fix-supplied headingDegrees is preferred over the computed bearing',
          () async {
        final svc = makeService();
        await svc.init();
        await svc.startManual();

        // Two fixes moving north (computed bearing would be ~0°), but the
        // fixes carry an explicit course of 90° — the service must prefer it.
        final base = DateTime.now();
        facade.emitFix(FixInput(
          ts: base,
          lat: 49.0000,
          lon: 8.0,
          accuracyMeters: 5,
          speedMps: 10,
          headingDegrees: 90,
          activityType: 'in_vehicle',
          uuid: 'uuid-heading-pref1',
        ));
        await Future<void>.delayed(Duration.zero);
        facade.emitFix(FixInput(
          ts: base.add(const Duration(seconds: 1)),
          lat: 49.0005,
          lon: 8.0,
          accuracyMeters: 5,
          speedMps: 10,
          headingDegrees: 90,
          activityType: 'in_vehicle',
          uuid: 'uuid-heading-pref2',
        ));
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final last = svc.currentState as TrackingRecording;
        expect(last.headingDegrees, closeTo(90, 0.01),
            reason: 'fix course over ground must win over computed bearing');

        await svc.dispose();
      });

      test(
          'heading is retained (not reset) when two fixes are within the '
          '5 m jitter guard', () async {
        final svc = makeService();
        await svc.init();
        await svc.startManual();

        final base = DateTime.now();
        // Establish an eastward heading with a real hop first.
        facade.emitFix(FixInput(
          ts: base,
          lat: 49.0,
          lon: 8.0,
          accuracyMeters: 5,
          speedMps: 10,
          headingDegrees: 90,
          activityType: 'in_vehicle',
          uuid: 'uuid-jitter-1',
        ));
        await Future<void>.delayed(Duration.zero);
        // A near-stationary micro-move (< 5 m) with NO course over ground —
        // the computed branch must be skipped and the last heading retained.
        facade.emitFix(FixInput(
          ts: base.add(const Duration(seconds: 1)),
          lat: 49.00001, // ~1 m north
          lon: 8.0,
          accuracyMeters: 5,
          speedMps: 0.2,
          activityType: 'in_vehicle',
          uuid: 'uuid-jitter-2',
        ));
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final last = svc.currentState as TrackingRecording;
        expect(last.headingDegrees, closeTo(90, 0.01),
            reason: 'sub-5 m move must not overwrite the last heading');

        await svc.dispose();
      });
    });
  });
}
