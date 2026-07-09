import 'package:auto_explore/core/db/app_database.dart' hide TripPoint;
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/data/trips_repository.dart';
import 'package:auto_explore/features/trips/data/trips_repository_points_sink.dart';
import 'package:auto_explore/features/trips/domain/tracking_service.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_background_geolocation_facade.dart';

/// Tests for the Plan 03-1-02 H1 fix: `bg.BackgroundGeolocation.start()`
/// must be invoked exactly once per real recording session — three call
/// sites in [TrackingService] (`startManual`, `_openAutoTrip`, `init()`
/// hydration branch) each call `_facade.start()` after `_ensureFacadeReady`.
///
/// The `readyCalls` / `startCalls` accessors on
/// [FakeBackgroundGeolocationFacade] cover invocation counting; ordering is
/// checked by asserting `readyCalls >= 1` before start ever fires.
void main() {
  late AppDatabase db;
  late TripsRepository repo;
  late TripsRepositoryPointsSink sink;
  late FakeBackgroundGeolocationFacade facade;

  TrackingService makeService() => TrackingService(
        facade: facade,
        repository: repo,
        pointsSink: sink,
      );

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

  group('TrackingService — H1 _facade.start() plumbing', () {
    test('startManual() calls _facade.start() exactly once after ready()',
        () async {
      final svc = makeService();
      await svc.init();

      expect(facade.startCalls, 0,
          reason: 'init() with no in-flight trip must not start FGB');
      expect(facade.readyCalls, 0,
          reason: 'ready() is deferred until first tracking engagement');

      await svc.startManual();

      expect(facade.readyCalls, 1);
      expect(facade.startCalls, 1);
      expect(svc.currentState, isA<TrackingRecording>());

      await svc.stopActive();
      await svc.dispose();
    });

    test(
        'startManual → stopActive → startManual: start() fires twice, '
        'one per session', () async {
      final svc = makeService();
      await svc.init();

      await svc.startManual();
      expect(facade.startCalls, 1);
      await svc.stopActive();
      expect(svc.currentState, isA<TrackingIdle>());

      await svc.startManual();
      expect(facade.startCalls, 2,
          reason: 'Each real recording session must invoke start() exactly once');

      // ready() is still cached — only fires once per service instance.
      expect(facade.readyCalls, 1);

      await svc.stopActive();
      await svc.dispose();
    });

    test(
        'cold init() with NO in-flight trip: start() is NOT called '
        '(no speculative FGS spin-up)', () async {
      final svc = makeService();
      await svc.init();

      expect(facade.startCalls, 0);
      expect(facade.readyCalls, 0);
      expect(svc.currentState, isA<TrackingIdle>());

      await svc.dispose();
    });

    test(
        'hydration branch: init() with an in-flight trip invokes '
        'start() exactly once (after ready)', () async {
      // Seed an active trip directly via repo, before service init.
      final seedResult = await repo.openTrip(
        startedAt: DateTime.now(),
        manuallyStarted: true,
      );
      final seededTripId = seedResult.when(ok: (v) => v, err: (_) => -1);
      expect(seededTripId, isNot(-1));

      final svc = makeService();
      await svc.init();

      expect(svc.currentState, isA<TrackingRecording>());
      expect(facade.readyCalls, 1,
          reason: 'Hydration must call ready() before start()');
      expect(facade.startCalls, 1,
          reason: 'Hydration must call start() exactly once');

      await svc.dispose();
    });

    test(
        'motion path (Plan 06-08): fresh in_vehicle + motion=true does NOT '
        'open a trip and does NOT start FGB', () async {
      final svc = makeService();
      await svc.init();

      expect(facade.startCalls, 0);

      facade.emitActivity('in_vehicle');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      facade.emitMotion(isMoving: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(svc.currentState, isA<TrackingIdle>(),
          reason: 'Plan 06-08: automatic recording removed — motion is inert');
      expect(facade.readyCalls, 0,
          reason: 'no speculative ready() on motion');
      expect(facade.startCalls, 0,
          reason: 'no speculative FGB start() on motion');

      await svc.dispose();
    });
  });
}
