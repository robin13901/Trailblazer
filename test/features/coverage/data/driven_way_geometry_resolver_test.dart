// Trailblazer: DrivenWayGeometryResolver tests (v10 — durable geometry DB).
//
// The resolver now reads geometry from driven_way_geometry (not tiles).
// Tests pre-populate the geometry table and verify that resolve() clips
// correctly — no WayCandidateSource involved.
//
// Test inventory:
//   1. resolve returns .empty when no intervals exist.
//   2. resolve returns .empty when geometry table is empty (backfill pending).
//   3. fully-driven way → clipped geometry, solid.
//   4. partially-driven way → clipped to driven sub-segment only.
//   5. same way driven by TWO trips (overlapping) → deduped to ONE feature.
//   6. geometry cache-miss for a way → skipped (no throw).
//   7. durable cache tests (same as before, now geometry-table-based).
//   8. watchUnionBbox reactivity (unchanged).

import 'dart:convert';

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/daos/driven_way_geometry_dao.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/features/coverage/data/coverage_overlay_data.dart';
import 'package:auto_explore/features/coverage/data/driven_way_geometry_codec.dart';
import 'package:auto_explore/features/coverage/data/driven_way_geometry_resolver.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/data/trips_dao_inbox_queries.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng, LatLngBounds;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

LatLngBounds get _dummyBounds => LatLngBounds(
  southwest: const LatLng(49, 9),
  northeast: const LatLng(50, 10),
);

/// Straight 3-point way at ~(lat, lon). Length ~222 m (0.002° lat).
List<LatLng> _straightGeom({double lat = 49, double lon = 9}) => [
  LatLng(lat, lon),
  LatLng(lat + 0.001, lon),
  LatLng(lat + 0.002, lon),
];

Future<int> _seedMatchedTrip(
  TripsDao dao, {
  double minLat = 49,
  double minLon = 9,
  double maxLat = 49.5,
  double maxLon = 9.5,
}) async {
  final tripId = await dao.openTrip(
    startedAt: DateTime.now(),
    manuallyStarted: true,
  );
  await (dao.attachedDatabase.update(
    dao.trips,
  )..where((t) => t.id.equals(tripId))).write(
    TripsCompanion(
      endedAt: Value(DateTime.now().add(const Duration(minutes: 5))),
      durationSeconds: const Value(300),
      distanceMeters: const Value(1000),
      avgSpeedKmh: const Value(20),
      maxSpeedKmh: const Value(40),
      pointCount: const Value(10),
      bboxMinLat: Value(minLat),
      bboxMinLon: Value(minLon),
      bboxMaxLat: Value(maxLat),
      bboxMaxLon: Value(maxLon),
      autoStopped: const Value(false),
      status: const Value(TripStatus.matched),
    ),
  );
  return tripId;
}

Future<void> _seedInterval(
  DrivenWayIntervalsDao dao, {
  required int tripId,
  required int wayId,
  required double startMeters,
  required double endMeters,
}) {
  return dao.insertBatch([
    DrivenWayIntervalsCompanion.insert(
      wayId: wayId,
      tripId: Value(tripId),
      startMeters: startMeters,
      endMeters: endMeters,
      matchedAt: Value(DateTime.now()),
    ),
  ]);
}

Future<void> _seedGeometry(
  DrivenWayGeometryDao dao,
  int wayId, {
  List<LatLng>? geom,
  List<int>? nodeIds,
}) {
  final g = geom ?? _straightGeom();
  return dao.upsertBatch([
    DrivenWayGeometryCompanion.insert(
      wayId: Value(wayId),
      geometryJson: encodeWayGeometry(g),
      nodeIdsJson: Value(encodeNodeIds(nodeIds ?? const [])),
    ),
  ]);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late AppDatabase db;
  late DrivenWayIntervalsDao intervalsDao;
  late DrivenWayGeometryDao geometryDao;
  late TripsDao tripsDao;
  late TripsInboxDao inboxDao;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    intervalsDao = DrivenWayIntervalsDao(db);
    geometryDao = DrivenWayGeometryDao(db);
    tripsDao = TripsDao(db);
    inboxDao = TripsInboxDao(db);
    await db.customSelect('SELECT 1').getSingle();
  });

  tearDown(() async {
    await db.close();
  });

  DrivenWayGeometryResolver buildResolver() => DrivenWayGeometryResolver(
    intervalsDao: intervalsDao,
    geometryDao: geometryDao,
  );

  group('DrivenWayGeometryResolver.resolve', () {
    test('returns empty when no intervals exist', () async {
      final result = await buildResolver().resolve(_dummyBounds);
      expect(result, equals(CoverageOverlayData.empty));
    });

    test('returns empty when geometry table is empty (backfill pending)',
        () async {
      final trip = await _seedMatchedTrip(tripsDao);
      await _seedInterval(
        intervalsDao,
        tripId: trip,
        wayId: 42,
        startMeters: 0,
        endMeters: 222,
      );
      // No geometry seeded → resolver returns empty (backfill not yet done).
      final result = await buildResolver().resolve(_dummyBounds);
      expect(result, equals(CoverageOverlayData.empty));
    });

    test('fully-driven way → one solid clipped feature', () async {
      final trip = await _seedMatchedTrip(tripsDao);
      await _seedInterval(
        intervalsDao,
        tripId: trip,
        wayId: 42,
        startMeters: 0,
        endMeters: 222,
      );
      await _seedGeometry(geometryDao, 42);

      final result = await buildResolver().resolve(_dummyBounds);
      expect(result.ways, hasLength(1));
      expect(result.ways.first.wayId, 42);
      expect(result.ways.first.datum.isFull, isTrue);
      expect(result.ways.first.geometry.length, greaterThanOrEqualTo(2));
    });

    test('partially-driven way → clipped to driven sub-segment only',
        () async {
      final trip = await _seedMatchedTrip(tripsDao);
      await _seedInterval(
        intervalsDao,
        tripId: trip,
        wayId: 7,
        startMeters: 0,
        endMeters: 100,
      );
      await _seedGeometry(geometryDao, 7);

      final result = await buildResolver().resolve(_dummyBounds);
      expect(result.ways, hasLength(1));
      final way = result.ways.first;
      final maxLat = way.geometry
          .map((p) => p.latitude)
          .reduce((a, b) => a > b ? a : b);
      expect(maxLat, lessThan(49.0015),
          reason: 'partial drive must not paint the whole way');
    });

    test(
        'same way driven by TWO trips (overlapping) → deduped to ONE feature',
        () async {
      final tripA = await _seedMatchedTrip(tripsDao);
      final tripB = await _seedMatchedTrip(tripsDao);
      await _seedInterval(
        intervalsDao,
        tripId: tripA,
        wayId: 5,
        startMeters: 0,
        endMeters: 150,
      );
      await _seedInterval(
        intervalsDao,
        tripId: tripB,
        wayId: 5,
        startMeters: 100,
        endMeters: 222,
      );
      await _seedGeometry(geometryDao, 5);

      final result = await buildResolver().resolve(_dummyBounds);
      expect(result.ways, hasLength(1));
      expect(result.ways.first.wayId, 5);
    });

    test('geometry missing for a driven way → skipped (no throw)', () async {
      final trip = await _seedMatchedTrip(tripsDao);
      await _seedInterval(
        intervalsDao,
        tripId: trip,
        wayId: 55,
        startMeters: 0,
        endMeters: 200,
      );
      // Intentionally no _seedGeometry → way is silently skipped.
      await _seedGeometry(geometryDao, 99); // unrelated row to make table non-empty

      final result = await buildResolver().resolve(_dummyBounds);
      expect(result.ways, isEmpty);
    });
  });

  group('TripsDao.watchUnionBbox', () {
    test('emits null when no matched/confirmed trips exist', () async {
      final first = await tripsDao.watchUnionBbox().first;
      expect(first, isNull);
    });

    test('emits LatLngBounds when a matched trip has bbox columns populated',
        () async {
      await _seedMatchedTrip(tripsDao);
      final bounds = await tripsDao.watchUnionBbox().first;
      expect(bounds, isNotNull);
      expect(bounds!.southwest.latitude, closeTo(49, 1e-6));
    });

    test('re-emits when a second matched trip is inserted', () async {
      final emissions = <LatLngBounds?>[];
      final sub = tripsDao.watchUnionBbox().listen(emissions.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);
      await _seedMatchedTrip(tripsDao);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(emissions.length, greaterThanOrEqualTo(2));
      expect(emissions.last, isNotNull);
    });

    test('re-emits on confirmTrip (matched→confirmed status flip)', () async {
      final tripId = await _seedMatchedTrip(tripsDao);
      final emissions = <LatLngBounds?>[];
      final sub = tripsDao.watchUnionBbox().listen(emissions.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);
      await inboxDao.transitionToConfirmed(tripId);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(emissions.length, greaterThanOrEqualTo(2));
    });

    test(
        're-emits on driven_way_intervals write — readsFrom includes that table',
        () async {
      final tripId = await _seedMatchedTrip(tripsDao);
      final emissions = <LatLngBounds?>[];
      final sub = tripsDao.watchUnionBbox().listen(emissions.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);
      await _seedInterval(
        intervalsDao,
        tripId: tripId,
        wayId: 123,
        startMeters: 0,
        endMeters: 100,
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(emissions.length, greaterThanOrEqualTo(2));
    });
  });
}
