// Hide the Drift-generated TripPoint row class to avoid ambiguous_import with
// the domain TripPoint DTO. Only Trip/TripPointsCompanion needed from this lib.
import 'package:auto_explore/core/db/app_database.dart' hide TripPoint;
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/data/trips_repository.dart';
import 'package:auto_explore/features/trips/data/trips_repository_points_sink.dart';
import 'package:auto_explore/features/trips/domain/trip_point.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

void main() {
  late AppDatabase db;
  late TripsRepository repo;
  late TripsRepositoryPointsSink sink;
  late int tripId;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = TripsRepository(TripsDao(db));
    sink = TripsRepositoryPointsSink(repo);

    // Open a trip row so appendPoints has a valid FK target.
    final openResult = await repo.openTrip(
      startedAt: DateTime.utc(2026, 7, 5, 8),
      manuallyStarted: true,
    );
    tripId = openResult.when(ok: (v) => v, err: (_) => -1);
    expect(tripId, isNot(-1));
  });

  tearDown(() => db.close());

  group('TripsRepositoryPointsSink', () {
    test('appendPoints with empty list → repository not called (no rows)',
        () async {
      await sink.appendPoints(tripId, []);

      // No points should be in the table.
      final rows = await db
          .customSelect(
            'SELECT COUNT(*) as cnt FROM trip_points WHERE trip_id = ?',
            variables: [Variable<int>(tripId)],
          )
          .get();
      expect(rows.first.read<int>('cnt'), 0);
    });

    test('appendPoints with 3 TripPoints → 3 rows land in trip_points',
        () async {
      final base = DateTime.utc(2026, 7, 5, 8);
      final points = [
        TripPoint(
          tripId: tripId,
          seq: 0,
          ts: base,
          lat: 49.001,
          lon: 8.001,
          speedKmh: 50,
          accuracyMeters: 8,
          altitudeMeters: 100,
          motionType: 'in_vehicle',
        ),
        TripPoint(
          tripId: tripId,
          seq: 1,
          ts: base.add(const Duration(seconds: 1)),
          lat: 49.002,
          lon: 8.002,
          speedKmh: 55,
          accuracyMeters: 7,
        ),
        TripPoint(
          tripId: tripId,
          seq: 2,
          ts: base.add(const Duration(seconds: 2)),
          lat: 49.003,
          lon: 8.003,
        ),
      ];

      await sink.appendPoints(tripId, points);

      final rows = await db
          .customSelect(
            'SELECT * FROM trip_points WHERE trip_id = ? ORDER BY seq',
            variables: [Variable<int>(tripId)],
          )
          .get();
      expect(rows, hasLength(3));

      // Verify seq values.
      expect(rows[0].read<int>('seq'), 0);
      expect(rows[1].read<int>('seq'), 1);
      expect(rows[2].read<int>('seq'), 2);

      // Verify lat/lon.
      expect(rows[0].read<double>('lat'), closeTo(49.001, 0.0001));
      expect(rows[1].read<double>('lat'), closeTo(49.002, 0.0001));
      expect(rows[2].read<double>('lat'), closeTo(49.003, 0.0001));
    });

    test(
        'appendPoints when repository returns Err → sink completes normally '
        '(does not rethrow), warning is logged', () async {
      // Capture log records.
      final warnings = <LogRecord>[];
      final testLogger = Logger('test.points_sink');
      final sinkWithTestLogger =
          TripsRepositoryPointsSink(repo, logger: testLogger);
      final sub = testLogger.onRecord.listen(warnings.add);

      // Close the database to force a repository error.
      await db.close();

      // Should complete without throwing.
      await expectLater(
        sinkWithTestLogger.appendPoints(tripId, [
          TripPoint(
            tripId: tripId,
            seq: 0,
            ts: DateTime.utc(2026, 7, 5, 8),
            lat: 49,
            lon: 8,
          ),
        ]),
        completes,
      );

      // A warning must have been logged.
      expect(
        warnings.any((r) => r.level == Level.WARNING && r.message.contains('appendPoints failed')),
        isTrue,
        reason: 'Expected a WARNING log containing "appendPoints failed"',
      );

      await sub.cancel();
    });
  });
}
