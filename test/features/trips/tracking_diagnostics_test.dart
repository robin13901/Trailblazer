import 'package:auto_explore/core/db/app_database.dart' hide TripPoint;
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/data/trips_repository.dart';
import 'package:auto_explore/features/trips/data/trips_repository_points_sink.dart';
import 'package:auto_explore/features/trips/domain/tracking_diagnostics.dart';
import 'package:auto_explore/features/trips/domain/tracking_service.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/domain/trip_fix_input.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_background_geolocation_facade.dart';

/// Tests for the TrackingDiagnostics DTO + `TrackingService.diagnostics`
/// getter added in Plan 03-1-01 (debug HUD plumbing).
///
/// These tests use only the domain layer + the fake facade — no widget layer.
/// The HUD screen has its own widget test in `test/features/settings/`.
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

  group('TrackingDiagnostics', () {
    test('initial snapshot: pending outcome, zero counters, idle trip',
        () async {
      final svc = makeService();
      await svc.init();

      final diag = svc.diagnostics;
      expect(diag.facadeReadyOutcome, isA<FacadeReadyPending>());
      expect(diag.acceptCount, 0);
      expect(diag.rejectCount, 0);
      expect(diag.gapCount, 0);
      expect(diag.splitCount, 0);
      expect(diag.lastAcceptedFix, isNull);
      expect(diag.lastRejectedReason, isNull);
      expect(diag.lastRejectedAt, isNull);
      expect(diag.lastActivityType, 'unknown');
      expect(diag.lastActivityAt, isNull);
      expect(diag.currentTripId, isNull);

      await svc.dispose();
    });

    test('facade ready() success flips outcome to FacadeReadySuccess',
        () async {
      final svc = makeService();
      await svc.init();
      // Trigger _ensureFacadeReady() via startManual.
      await svc.startManual();

      expect(svc.diagnostics.facadeReadyOutcome, isA<FacadeReadySuccess>());
      expect(facade.readyCalls, 1);
      expect(svc.diagnostics.currentTripId, isNotNull);

      await svc.stopActive();
      await svc.dispose();
    });

    test('facade ready() throwing sets FacadeReadyFailed with the message',
        () async {
      final svc = makeService();
      await svc.init();

      // Configure the fake to throw on the next ready() call.
      facade.readyError = StateError('license validation failed');

      // startManual awaits _ensureFacadeReady which will rethrow — the caller
      // (TrackingNotifier / FAB) does not wrap it today, so we catch here.
      try {
        await svc.startManual();
      } on Object {
        // Expected — Wave 2 (Plan 03-1-02) adds a Result<T>/DomainError wrap.
      }

      final outcome = svc.diagnostics.facadeReadyOutcome;
      expect(outcome, isA<FacadeReadyFailed>());
      expect((outcome as FacadeReadyFailed).message,
          contains('license validation failed'));

      await svc.dispose();
    });

    test('three accepted fixes → acceptCount==3, lastAcceptedFix matches last',
        () async {
      final svc = makeService();
      await svc.init();
      await svc.startManual();

      final start = DateTime.now();
      for (var i = 0; i < 3; i++) {
        facade.emitFix(FixInput(
          ts: start.add(Duration(seconds: i)),
          lat: 49.0 + i * 0.00025,
          lon: 8,
          accuracyMeters: 8,
          speedMps: 27.8,
          activityType: 'in_vehicle',
          uuid: 'uuid-accept-$i',
        ));
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final diag = svc.diagnostics;
      expect(diag.acceptCount, 3);
      expect(diag.rejectCount, 0);
      expect(diag.lastAcceptedFix, isNotNull);
      expect(diag.lastAcceptedFix!.lat, closeTo(49.0005, 1e-9));
      expect(diag.lastAcceptedFix!.lon, closeTo(8, 1e-9));
      expect(diag.lastAcceptedFix!.accuracyMeters, 8);
      expect(diag.lastAcceptedFix!.speedKmh, closeTo(27.8 * 3.6, 1e-9));
      expect(diag.currentTripId, isNotNull);
      expect(svc.currentState, isA<TrackingRecording>());

      await svc.dispose();
    });

    test('one rejected fix (accuracy > threshold) → rejectCount==1',
        () async {
      final svc = makeService();
      await svc.init();
      await svc.startManual();

      facade.emitFix(FixInput(
        ts: DateTime.now(),
        lat: 49,
        lon: 8,
        accuracyMeters: 500, // well above default 25 m maxAccuracyMeters
        speedMps: 10,
        activityType: 'in_vehicle',
        uuid: 'uuid-bad-1',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final diag = svc.diagnostics;
      expect(diag.rejectCount, 1);
      expect(diag.acceptCount, 0);
      expect(diag.lastRejectedReason, 'accuracy');
      expect(diag.lastRejectedAt, isNotNull);

      await svc.dispose();
    });

    test('activity change updates lastActivityType + lastActivityAt',
        () async {
      final svc = makeService();
      await svc.init();

      facade.emitActivity('in_vehicle');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final diag = svc.diagnostics;
      expect(diag.lastActivityType, 'in_vehicle');
      expect(diag.lastActivityAt, isNotNull);

      await svc.dispose();
    });
  });
}
