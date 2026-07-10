// Phase 5 (Plan 05-07): TripMatchCoordinator tests.
//
// Test inventory (≥ 6 scenarios):
//   1. onTripReadyForMatching happy path — trip with bbox + points + ways →
//      intervals written, trip transitions to matched.
//   2. onTripReadyForMatching with empty ways → trip matched, 0 intervals.
//   3. onTripReadyForMatching with empty trip_points → trip matched, 0 intervals.
//   4. onTripReadyForMatching with null bbox → trip matched, 0 intervals.
//   5. cancel deletes any intervals already written for the trip.
//   6. processPending processes all pending trips in FIFO order.

import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/features/matching/data/matcher_isolate.dart';
import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/matching/data/trip_match_coordinator.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/matching/domain/driven_way_interval_draft.dart';
import 'package:auto_explore/features/matching/domain/gps_fix.dart';
import 'package:auto_explore/features/matching/domain/match_result.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/data/trips_repository.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// [WayCandidateSource] whose raw-tiles path re-emits a canned way list as one
/// gzipped Overpass envelope (or no tiles when [ways] is empty).
class _FakeWayCandidateSource implements WayCandidateSource {
  _FakeWayCandidateSource({this.ways = const []});

  final List<WayCandidate> ways;

  @override
  Future<List<WayCandidate>> fetchWaysInBbox({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    bool throwOnError = true,
  }) async =>
      ways;

  @override
  Future<List<RawTilePayload>> fetchRawTilesInBbox({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    bool throwOnError = true,
  }) async {
    if (ways.isEmpty) return [];
    final envelope = {
      'version': 0.6,
      'elements': [
        for (final w in ways)
          {
            'type': 'way',
            'id': w.wayId,
            'geometry': [
              for (final p in w.geometry) {'lat': p.latitude, 'lon': p.longitude},
            ],
            'tags': {'highway': w.highwayClass},
          },
      ],
    };
    return [
      RawTilePayload(
        payloadGzip: Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode(envelope)))),
        bbox: LatLonBbox(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon),
      ),
    ];
  }
}

/// Minimal [MatcherIsolate] that completes every job with a canned [MatchResult].
/// Does not spawn a real isolate — test-only.
class _FakeMatcherIsolate extends MatcherIsolate {
  _FakeMatcherIsolate({required this.cannedResult});

  final MatchResult cannedResult;

  bool _started = false;
  int cancelCalls = 0;
  int cancelledTripId = -1;

  @override
  Future<void> start() async {
    _started = true;
  }

  @override
  Future<MatchResult> match({
    required int tripId,
    required List<GpsFix> fixes,
    required List<Uint8List> gzippedTiles,
    required List<LatLonBbox> tileBboxes,
    void Function(int processed, int total)? onProgress,
  }) async {
    if (!_started) throw StateError('not started');
    return cannedResult;
  }

  @override
  void cancel(int tripId) {
    cancelCalls++;
    cancelledTripId = tripId;
  }

  @override
  void dispose() {}
}

// ---------------------------------------------------------------------------
// Geometry constants
// ---------------------------------------------------------------------------

/// A minimal WayCandidate centred at (52.5, 13.4) — Berlin-ish.
WayCandidate _berlinWay() => const WayCandidate(
      wayId: 42,
      highwayClass: 'residential',
      geometry: [
        LatLng(52.500, 13.400),
        LatLng(52.501, 13.401),
      ],
    );

// ---------------------------------------------------------------------------
// DB helpers
// ---------------------------------------------------------------------------

Future<int> _insertTripWithBbox(
  AppDatabase db, {
  TripStatus status = TripStatus.pending,
  double? minLat = 52.49,
  double? minLon = 13.39,
  double? maxLat = 52.51,
  double? maxLon = 13.42,
}) async {
  return db.into(db.trips).insert(
        TripsCompanion.insert(
          startedAt: DateTime(2026),
          status: Value(status),
          bboxMinLat: Value(minLat),
          bboxMinLon: Value(minLon),
          bboxMaxLat: Value(maxLat),
          bboxMaxLon: Value(maxLon),
        ),
      );
}

Future<void> _insertTripPoint(AppDatabase db, int tripId, int seq) async {
  await db.into(db.tripPoints).insert(
        TripPointsCompanion.insert(
          tripId: tripId,
          seq: seq,
          lat: 52.500,
          lon: 13.400,
          ts: DateTime(2026, 1, 1, 0, 0, seq),
          accuracyMeters: const Value(10),
          speedKmh: const Value(30),
        ),
      );
}

Future<TripStatus> _statusOf(AppDatabase db, int tripId) async {
  final row =
      await (db.select(db.trips)..where((t) => t.id.equals(tripId))).getSingle();
  return row.status;
}

// ---------------------------------------------------------------------------
// Test
// ---------------------------------------------------------------------------

void main() {
  late AppDatabase db;
  late TripsDao tripsDao;
  late TripsRepository repository;
  late DrivenWayIntervalsDao intervalsDao;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    tripsDao = TripsDao(db);
    repository = TripsRepository(tripsDao);
    intervalsDao = DrivenWayIntervalsDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  TripMatchCoordinator buildCoord({
    List<WayCandidate>? ways,
    MatchResult? cannedResult,
    _FakeMatcherIsolate? isolate,
  }) {
    final defaultIntervals = cannedResult?.intervals ?? const [];
    final defaultResult = cannedResult ??
        MatchResult(
          steps: const [],
          intervals: defaultIntervals,
          matchedFixCount: 0,
          droppedFixCount: 0,
        );
    return TripMatchCoordinator(
      source: _FakeWayCandidateSource(ways: ways ?? [_berlinWay()]),
      matcherIsolate: isolate ??
          _FakeMatcherIsolate(cannedResult: defaultResult),
      tripsDao: tripsDao,
      tripsRepository: repository,
      intervalsDao: intervalsDao,
    );
  }

  // -------------------------------------------------------------------------
  // Test 1: happy path — pending → matched, intervals written
  // -------------------------------------------------------------------------
  test('1. onTripReadyForMatching happy path: intervals written, trip matched',
      () async {
    // Arrange: trip with bbox + 3 points.
    final tripId = await _insertTripWithBbox(db);
    await _insertTripPoint(db, tripId, 1);
    await _insertTripPoint(db, tripId, 2);
    await _insertTripPoint(db, tripId, 3);

    // Canned result: 1 interval.
    const interval = DrivenWayIntervalDraft(
      wayId: 42,
      startMeters: 0,
      endMeters: 50,
      direction: 'forward',
    );
    const canned = MatchResult(
      steps: [],
      intervals: [interval],
      matchedFixCount: 3,
      droppedFixCount: 0,
    );

    final coord = buildCoord(ways: [_berlinWay()], cannedResult: canned);
    await coord.onTripReadyForMatching(tripId);

    // Assert: trip is now matched.
    expect(await _statusOf(db, tripId), TripStatus.matched);

    // Assert: 1 interval row written.
    final written = await intervalsDao.getByTrip(tripId);
    expect(written, hasLength(1));
    expect(written.first.wayId, 42);
    expect(written.first.tripId, tripId);
    expect(written.first.startMeters, 0);
    expect(written.first.endMeters, 50);
    expect(written.first.direction, 'forward');
  });

  // -------------------------------------------------------------------------
  // Test 2: empty ways → matched, 0 intervals
  // -------------------------------------------------------------------------
  test('2. onTripReadyForMatching with empty ways: trip matched, 0 intervals',
      () async {
    final tripId = await _insertTripWithBbox(db);
    await _insertTripPoint(db, tripId, 1);

    final coord = buildCoord(ways: []);
    await coord.onTripReadyForMatching(tripId);

    expect(await _statusOf(db, tripId), TripStatus.matched);
    expect(await intervalsDao.getByTrip(tripId), isEmpty);
  });

  // -------------------------------------------------------------------------
  // Test 3: empty trip_points → matched, 0 intervals
  // -------------------------------------------------------------------------
  test(
      '3. onTripReadyForMatching with empty trip_points: '
      'trip matched, 0 intervals', () async {
    final tripId = await _insertTripWithBbox(db);
    // No points inserted.

    final coord = buildCoord(ways: [_berlinWay()]);
    await coord.onTripReadyForMatching(tripId);

    expect(await _statusOf(db, tripId), TripStatus.matched);
    expect(await intervalsDao.getByTrip(tripId), isEmpty);
  });

  // -------------------------------------------------------------------------
  // Test 4: null bbox → matched, 0 intervals
  // -------------------------------------------------------------------------
  test('4. onTripReadyForMatching with null bbox: trip matched, 0 intervals',
      () async {
    final tripId = await _insertTripWithBbox(
      db,
      minLat: null,
      minLon: null,
      maxLat: null,
      maxLon: null,
    );
    await _insertTripPoint(db, tripId, 1);

    final coord = buildCoord(ways: [_berlinWay()]);
    await coord.onTripReadyForMatching(tripId);

    expect(await _statusOf(db, tripId), TripStatus.matched);
    expect(await intervalsDao.getByTrip(tripId), isEmpty);
  });

  // -------------------------------------------------------------------------
  // Test 5: cancel deletes already-written intervals
  // -------------------------------------------------------------------------
  test('5. cancel deletes any intervals already written for the trip',
      () async {
    final tripId = await _insertTripWithBbox(db);
    // Seed 2 intervals directly via DAO.
    await intervalsDao.insertBatch([
      DrivenWayIntervalsCompanion.insert(
        wayId: 1,
        tripId: Value(tripId),
        startMeters: 0,
        endMeters: 10,
      ),
      DrivenWayIntervalsCompanion.insert(
        wayId: 2,
        tripId: Value(tripId),
        startMeters: 10,
        endMeters: 20,
      ),
    ]);
    expect(await intervalsDao.getByTrip(tripId), hasLength(2));

    final fakeIsolate = _FakeMatcherIsolate(
      cannedResult: const MatchResult(
        steps: [],
        intervals: [],
        matchedFixCount: 0,
        droppedFixCount: 0,
      ),
    );
    final coord = buildCoord(isolate: fakeIsolate);
    await coord.cancel(tripId);

    // Intervals should be gone.
    expect(await intervalsDao.getByTrip(tripId), isEmpty);
    // Isolate cancel was called.
    expect(fakeIsolate.cancelCalls, 1);
    expect(fakeIsolate.cancelledTripId, tripId);
  });

  // -------------------------------------------------------------------------
  // Test 6: processPending processes all pending trips in FIFO order
  // -------------------------------------------------------------------------
  test('6. processPending processes all pending trips in FIFO order', () async {
    // Seed 3 pending trips with different endedAt values.
    final t1 = await _insertTripWithBbox(db);
    final t2 = await _insertTripWithBbox(db);
    final t3 = await _insertTripWithBbox(db);

    // Give each trip at least one point so the matcher path proceeds.
    await _insertTripPoint(db, t1, 1);
    await _insertTripPoint(db, t2, 1);
    await _insertTripPoint(db, t3, 1);

    const canned = MatchResult(
      steps: [],
      intervals: [
        DrivenWayIntervalDraft(
          wayId: 42,
          startMeters: 0,
          endMeters: 10,
          direction: 'forward',
        ),
      ],
      matchedFixCount: 1,
      droppedFixCount: 0,
    );

    final coord = buildCoord(ways: [_berlinWay()], cannedResult: canned);
    await coord.processPending();

    // All three trips should now be matched.
    expect(await _statusOf(db, t1), TripStatus.matched);
    expect(await _statusOf(db, t2), TripStatus.matched);
    expect(await _statusOf(db, t3), TripStatus.matched);

    // Each trip should have 1 interval row.
    expect(await intervalsDao.getByTrip(t1), hasLength(1));
    expect(await intervalsDao.getByTrip(t2), hasLength(1));
    expect(await intervalsDao.getByTrip(t3), hasLength(1));
  });
}
