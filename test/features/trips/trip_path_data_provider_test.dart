// Trailblazer trip-path data provider tests (salvaged 2026-07-22 from the
// retired trip_detail_screen_test.dart when loadTripDetailData moved into
// trip_path_data_provider.dart).
//
// Covers loadTripDetailData (pure): fail-matched, non-fail (raw + matched
// segments + matched%), and the two offline fallbacks. Uses an in-memory
// Drift DB + a fake WayCandidateSource.

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/data/trips_dao_inbox_queries.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:auto_explore/features/trips/presentation/providers/trip_path_data_provider.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// A [WayCandidateSource] that returns a canned list, or throws to simulate a
/// network error + cache miss (offline).
class _FakeWaySource implements WayCandidateSource {
  _FakeWaySource({this.ways = const [], this.throwError = false});

  final List<WayCandidate> ways;
  final bool throwError;

  @override
  Future<List<WayCandidate>> fetchWaysInBbox({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    bool throwOnError = true,
    Set<TileId>? restrictTiles,
    bool cacheOnly = false,
    void Function(int done, int total)? onTileProgress,
  }) async {
    if (throwError) {
      throw const NetworkError('offline', statusCode: 0);
    }
    return ways;
  }

  @override
  Future<List<RawTilePayload>> fetchRawTilesInBbox({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    bool throwOnError = true,
    Set<TileId>? restrictTiles,
    bool cacheOnly = false,
    void Function(int done, int total)? onTileProgress,
  }) async {
    if (throwError) {
      throw const NetworkError('offline', statusCode: 0);
    }
    return const [];
  }
}

Future<int> _seedTrip(
  AppDatabase db, {
  required TripStatus status,
}) {
  return db.into(db.trips).insert(
        TripsCompanion.insert(
          startedAt: DateTime(2026, 7, 9, 8),
          endedAt: Value(DateTime(2026, 7, 9, 8, 42)),
          durationSeconds: const Value(42 * 60),
          distanceMeters: const Value(28400),
          status: Value(status),
          manuallyStarted: const Value(false),
          bboxMinLat: const Value(49.79),
          bboxMinLon: const Value(9.18),
          bboxMaxLat: const Value(49.81),
          bboxMaxLon: const Value(9.22),
        ),
      );
}

Future<void> _seedPoints(AppDatabase db, int tripId) async {
  final coords = [
    (49.79, 9.18),
    (49.80, 9.20),
    (49.81, 9.22),
  ];
  for (var i = 0; i < coords.length; i++) {
    await db.into(db.tripPoints).insert(
          TripPointsCompanion.insert(
            tripId: tripId,
            seq: i,
            ts: DateTime(2026, 7, 9, 8, i),
            lat: coords[i].$1,
            lon: coords[i].$2,
          ),
        );
  }
}

Future<void> _seedInterval(
  AppDatabase db,
  int tripId, {
  required int wayId,
  double startMeters = 0,
  double endMeters = 100,
}) {
  return db.into(db.drivenWayIntervals).insert(
        DrivenWayIntervalsCompanion.insert(
          wayId: wayId,
          tripId: Value(tripId),
          startMeters: startMeters,
          endMeters: endMeters,
          matchedAt: Value(DateTime(2026, 7, 9, 10)),
        ),
      );
}

WayCandidate _way(int id) => WayCandidate(
      wayId: id,
      geometry: const [
        LatLng(49.79, 9.18),
        LatLng(49.80, 9.20),
        LatLng(49.81, 9.22),
      ],
      highwayClass: 'residential',
    );

void main() {
  group('loadTripDetailData', () {
    late AppDatabase db;
    late TripsInboxDao inboxDao;
    late TripsDao tripsDao;
    late DrivenWayIntervalsDao intervalsDao;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      inboxDao = TripsInboxDao(db);
      tripsDao = TripsDao(db);
      intervalsDao = DrivenWayIntervalsDao(db);
      await db.customSelect('SELECT 1').getSingle();
    });

    tearDown(() => db.close());

    test('fail-matched (0 intervals): no matched segments, no network call',
        () async {
      final tripId = await _seedTrip(db, status: TripStatus.matched);
      await _seedPoints(db, tripId);
      // A source that would throw if called — proves it is NOT called.
      final source = _FakeWaySource(throwError: true);

      final data = await loadTripDetailData(
        tripId: tripId,
        inboxDao: inboxDao,
        tripsDao: tripsDao,
        intervalsDao: intervalsDao,
        waySource: source,
      );

      expect(data.item.isFailMatched, isTrue);
      expect(data.matchedSegments, isEmpty);
      expect(data.offline, isFalse);
      expect(data.rawPolyline.length, 3);
    });

    test('non-fail: raw polyline + matched segments + matched fraction',
        () async {
      final tripId = await _seedTrip(db, status: TripStatus.confirmed);
      await _seedPoints(db, tripId);
      await _seedInterval(db, tripId, wayId: 1, endMeters: 50);
      final source = _FakeWaySource(ways: [_way(1)]);

      final data = await loadTripDetailData(
        tripId: tripId,
        inboxDao: inboxDao,
        tripsDao: tripsDao,
        intervalsDao: intervalsDao,
        waySource: source,
      );

      expect(data.offline, isFalse);
      expect(data.rawPolyline.length, 3);
      expect(data.matchedSegments, isNotEmpty);
      expect(data.matchedWayCount, 1);
      expect(data.matchedFraction, isNotNull);
      expect(data.matchedFraction, greaterThan(0));
    });

    test('offline: way source throws → offline, matched skipped, raw kept',
        () async {
      final tripId = await _seedTrip(db, status: TripStatus.confirmed);
      await _seedPoints(db, tripId);
      await _seedInterval(db, tripId, wayId: 1);
      final source = _FakeWaySource(throwError: true);

      final data = await loadTripDetailData(
        tripId: tripId,
        inboxDao: inboxDao,
        tripsDao: tripsDao,
        intervalsDao: intervalsDao,
        waySource: source,
      );

      expect(data.offline, isTrue);
      expect(data.matchedSegments, isEmpty);
      expect(data.matchedFraction, isNull);
      expect(data.rawPolyline.length, 3);
    });

    test('offline: empty ways while intervals exist → offline fallback',
        () async {
      final tripId = await _seedTrip(db, status: TripStatus.confirmed);
      await _seedPoints(db, tripId);
      await _seedInterval(db, tripId, wayId: 1);
      // Source succeeds but returns nothing (cache-expired scenario).
      final source = _FakeWaySource();

      final data = await loadTripDetailData(
        tripId: tripId,
        inboxDao: inboxDao,
        tripsDao: tripsDao,
        intervalsDao: intervalsDao,
        waySource: source,
      );

      expect(data.offline, isTrue);
      expect(data.matchedSegments, isEmpty);
    });

    test('missing trip throws DatabaseError (route stability)', () async {
      final source = _FakeWaySource();
      expect(
        () => loadTripDetailData(
          tripId: 999999,
          inboxDao: inboxDao,
          tripsDao: tripsDao,
          intervalsDao: intervalsDao,
          waySource: source,
        ),
        throwsA(isA<DatabaseError>()),
      );
    });
  });
}
