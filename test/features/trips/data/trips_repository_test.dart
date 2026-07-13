import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/data/trips_repository.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:auto_explore/features/trips/domain/trip_summary.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late TripsRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = TripsRepository(TripsDao(db));
  });

  tearDown(() => db.close());

  group('TripsRepository', () {
    test('openTrip → activeTrip returns recording row with null endedAt',
        () async {
      final now = DateTime.now();
      final openResult = await repo.openTrip(
        startedAt: now,
        manuallyStarted: true,
      );
      expect(openResult.isOk, isTrue);
      final tripId = openResult.when(ok: (v) => v, err: (_) => -1);

      final activeTripResult = await repo.activeTrip();
      expect(activeTripResult.isOk, isTrue);
      final active = activeTripResult.when(ok: (v) => v, err: (_) => null);
      expect(active, isNotNull);
      expect(active!.id, tripId);
      expect(active.status, TripStatus.recording);
      expect(active.endedAt, isNull);
      expect(active.manuallyStarted, isTrue);
    });

    test('appendPoints then closeTrip → activeTrip returns null', () async {
      final now = DateTime.now();
      final openResult = await repo.openTrip(
        startedAt: now,
        manuallyStarted: false,
      );
      final tripId = openResult.when(ok: (v) => v, err: (_) => -1);

      final points = [
        TripPointsCompanion.insert(
          tripId: tripId,
          seq: 0,
          ts: now,
          lat: 49,
          lon: 8,
        ),
        TripPointsCompanion.insert(
          tripId: tripId,
          seq: 1,
          ts: now.add(const Duration(seconds: 5)),
          lat: 49.001,
          lon: 8.001,
        ),
      ];
      final appendResult = await repo.appendPoints(tripId, points);
      expect(appendResult.isOk, isTrue);

      final summary = TripSummary(
        startedAt: now,
        endedAt: now.add(const Duration(seconds: 5)),
        durationSeconds: 5,
        distanceMeters: 137.4,
        avgSpeedKmh: 98.9,
        maxSpeedKmh: 110,
        pointCount: 2,
        bboxMinLat: 49,
        bboxMinLon: 8,
        bboxMaxLat: 49.001,
        bboxMaxLon: 8.001,
        autoStopped: false,
      );
      final closeResult = await repo.closeTrip(tripId, summary);
      expect(closeResult.isOk, isTrue);

      // After close, activeTrip must return null (trip has endedAt set).
      final activeTripResult = await repo.activeTrip();
      final active = activeTripResult.when(ok: (v) => v, err: (_) => null);
      expect(active, isNull);
    });

    test('closeTrip writes bbox + pointCount correctly', () async {
      final now = DateTime.now();
      final openResult = await repo.openTrip(
        startedAt: now,
        manuallyStarted: false,
      );
      final tripId = openResult.when(ok: (v) => v, err: (_) => -1);

      final summary = TripSummary(
        startedAt: now,
        endedAt: now.add(const Duration(minutes: 10)),
        durationSeconds: 600,
        distanceMeters: 5000,
        avgSpeedKmh: 30,
        maxSpeedKmh: 60,
        pointCount: 100,
        bboxMinLat: 48,
        bboxMinLon: 7.5,
        bboxMaxLat: 48.5,
        bboxMaxLon: 8,
        autoStopped: true,
      );
      final closeResult = await repo.closeTrip(tripId, summary);
      expect(closeResult.isOk, isTrue);

      // Read the row back to check bbox and pointCount.
      final rows = await db
          .customSelect(
            'SELECT * FROM trips WHERE id = ?',
            variables: [Variable<int>(tripId)],
          )
          .get();
      expect(rows, hasLength(1));
      final row = rows.first;
      expect(row.read<double?>('bbox_min_lat'), 48);
      expect(row.read<double?>('bbox_min_lon'), 7.5);
      expect(row.read<double?>('bbox_max_lat'), 48.5);
      expect(row.read<double?>('bbox_max_lon'), 8);
      expect(row.read<int?>('point_count'), 100);
      expect(row.read<String>('status'), 'pending');
      expect(row.read<int>('auto_stopped'), 1);
    });

    test('deleteTrip removes row and points (CASCADE)', () async {
      final now = DateTime.now();
      final openResult = await repo.openTrip(
        startedAt: now,
        manuallyStarted: false,
      );
      final tripId = openResult.when(ok: (v) => v, err: (_) => -1);

      // Insert a point.
      await repo.appendPoints(tripId, [
        TripPointsCompanion.insert(
          tripId: tripId,
          seq: 0,
          ts: now,
          lat: 49,
          lon: 8,
        ),
      ]);

      // Confirm point exists.
      final pointsBefore = await db
          .customSelect(
            'SELECT COUNT(*) as cnt FROM trip_points WHERE trip_id = ?',
            variables: [Variable<int>(tripId)],
          )
          .get();
      expect(pointsBefore.first.read<int>('cnt'), 1);

      // Delete trip.
      final deleteResult = await repo.deleteTrip(tripId);
      expect(deleteResult.isOk, isTrue);

      // Trip row must be gone.
      final tripRows = await db
          .customSelect(
            'SELECT * FROM trips WHERE id = ?',
            variables: [Variable<int>(tripId)],
          )
          .get();
      expect(tripRows, isEmpty);

      // Points must be cascade-deleted.
      final pointsAfter = await db
          .customSelect(
            'SELECT COUNT(*) as cnt FROM trip_points WHERE trip_id = ?',
            variables: [Variable<int>(tripId)],
          )
          .get();
      expect(pointsAfter.first.read<int>('cnt'), 0);
    });
  });
}
