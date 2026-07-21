// Trailblazer Phase 7 (07-03), reworked 2026-07-18 (clipped-geometry):
// Unit tests for DrivenWayGeometryResolver + watchUnionBbox reactivity.
//
// The resolver now renders each driven way CLIPPED to its driven union
// interval(s), deduped per wayId across trips, always solid (every drawn metre
// was driven). It fetches RAW gzipped tiles (fetchRawTilesInBbox) and does the
// parse + clip on a compute() isolate. There is no partial-floor / isFull
// gradient anymore — that lived in the old whole-way render.
//
// Test inventory:
//   1. resolve returns .empty when no intervals exist.
//   2. fully-driven way → clipped geometry, solid.
//   3. partially-driven way → clipped to the driven sub-segment only.
//   4. way driven by TWO trips (overlapping passes) → deduped to ONE feature.
//   5. geometry cache-miss → skipped.
//   6. watchUnionBbox reactivity (unchanged from 07-06).

// hide isNull / isNotNull from drift to avoid ambiguous_import with flutter_test.
import 'dart:convert';
import 'dart:io' show gzip;

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/features/coverage/data/coverage_overlay_data.dart';
import 'package:auto_explore/features/coverage/data/driven_way_geometry_resolver.dart';
import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/data/trips_dao_inbox_queries.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng, LatLngBounds;

// ---------------------------------------------------------------------------
// Fake WayCandidateSource — serves the given ways as ONE raw gzipped Overpass
// tile (the resolver decodes + clips on a compute isolate). Coordinate order
// in the emitted JSON is Overpass's {lat, lon} per geometry point.
// ---------------------------------------------------------------------------

class _FakeWayCandidateSource implements WayCandidateSource {
  _FakeWayCandidateSource(this.ways);

  final List<WayCandidate> ways;

  Uint8List _gzippedEnvelope() {
    final elements = [
      for (final w in ways)
        {
          'type': 'way',
          'id': w.wayId,
          'geometry': [
            for (final p in w.geometry) {'lat': p.latitude, 'lon': p.longitude},
          ],
          'tags': {'highway': w.highwayClass},
        },
    ];
    final body = jsonEncode({'version': 0.6, 'elements': elements});
    return Uint8List.fromList(gzip.encode(utf8.encode(body)));
  }

  @override
  Future<List<WayCandidate>> fetchWaysInBbox({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    bool throwOnError = true,
    Set<TileId>? restrictTiles,
    void Function(int done, int total)? onTileProgress,
  }) async =>
      ways;

  @override
  Future<List<RawTilePayload>> fetchRawTilesInBbox({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    bool throwOnError = true,
    Set<TileId>? restrictTiles,
    void Function(int done, int total)? onTileProgress,
  }) async {
    if (ways.isEmpty) return const [];
    return [
      RawTilePayload(
        payloadGzip: _gzippedEnvelope(),
        bbox: const LatLonBbox(
          minLat: 49,
          minLon: 9,
          maxLat: 50,
          maxLon: 10,
        ),
      ),
    ];
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Builds a straight 3-point WayCandidate of known Haversine length.
///
/// Three points at (lat, lon), (lat+0.001, lon), (lat+0.002, lon).
/// Haversine distance per 0.001° latitude ≈ 111.19 m; total ≈ 222.4 m.
WayCandidate _straightWay(int wayId, {double lat = 49, double lon = 9}) {
  return WayCandidate(
    wayId: wayId,
    highwayClass: 'residential',
    geometry: [
      LatLng(lat, lon),
      LatLng(lat + 0.001, lon),
      LatLng(lat + 0.002, lon),
    ],
  );
}

/// Nominal bounds used as the union bbox argument to `resolve()`.
LatLngBounds get _dummyBounds => LatLngBounds(
      southwest: const LatLng(49, 9),
      northeast: const LatLng(50, 10),
    );

// ---------------------------------------------------------------------------
// Test setup helpers
// ---------------------------------------------------------------------------

/// Seed a minimal closed trip with bbox columns populated so watchUnionBbox
/// can aggregate. Status defaults to `matched`.
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
  await (dao.attachedDatabase.update(dao.trips)
        ..where((t) => t.id.equals(tripId)))
      .write(
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

/// Insert a driven interval row for [wayId] on [tripId].
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late AppDatabase db;
  late DrivenWayIntervalsDao intervalsDao;
  late TripsDao tripsDao;
  late TripsInboxDao inboxDao;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    intervalsDao = DrivenWayIntervalsDao(db);
    tripsDao = TripsDao(db);
    inboxDao = TripsInboxDao(db);
    // Trigger beforeOpen PRAGMAs (foreign_keys=ON etc.).
    await db.customSelect('SELECT 1').getSingle();
  });

  tearDown(() async {
    await db.close();
  });

  // -------------------------------------------------------------------------
  // DrivenWayGeometryResolver.resolve — classification + skip paths
  // -------------------------------------------------------------------------

  group('DrivenWayGeometryResolver.resolve', () {
    test('returns empty when no intervals exist', () async {
      final resolver = DrivenWayGeometryResolver(
        intervalsDao: intervalsDao,
        waySource: _FakeWayCandidateSource([_straightWay(1)]),
      );

      final result = await resolver.resolve(_dummyBounds);
      expect(result, equals(CoverageOverlayData.empty));
      expect(result.ways, isEmpty);
    });

    test('fully-driven way → one solid clipped feature', () async {
      final trip = await _seedMatchedTrip(tripsDao);
      // Drive the whole ~222 m way.
      await _seedInterval(
        intervalsDao,
        tripId: trip,
        wayId: 42,
        startMeters: 0,
        endMeters: 222,
      );

      final resolver = DrivenWayGeometryResolver(
        intervalsDao: intervalsDao,
        waySource: _FakeWayCandidateSource([_straightWay(42)]),
      );

      final result = await resolver.resolve(_dummyBounds);
      expect(result.ways, hasLength(1));
      expect(result.ways.first.wayId, 42);
      // Clipped model is always solid — every drawn metre was driven.
      expect(result.ways.first.datum.isFull, isTrue);
      expect(result.ways.first.geometry.length, greaterThanOrEqualTo(2));
    });

    test(
      'partially-driven way → clipped to the driven sub-segment only',
      () async {
        final trip = await _seedMatchedTrip(tripsDao);
        // Drive only the first ~100 m of a ~222 m N-S way (lat 49 → 49.002).
        await _seedInterval(
          intervalsDao,
          tripId: trip,
          wayId: 7,
          startMeters: 0,
          endMeters: 100,
        );

        final resolver = DrivenWayGeometryResolver(
          intervalsDao: intervalsDao,
          waySource: _FakeWayCandidateSource([_straightWay(7)]),
        );

        final result = await resolver.resolve(_dummyBounds);
        expect(result.ways, hasLength(1));
        final way = result.ways.first;
        expect(way.wayId, 7);
        // The clipped sub-segment must be SHORTER than the full way: its
        // northern end should stop well below the way's last vertex (lat
        // 49.002). ~100 m ≈ lat 49.0009.
        final maxLat = way.geometry
            .map((p) => p.latitude)
            .reduce((a, b) => a > b ? a : b);
        expect(maxLat, lessThan(49.0015),
            reason: 'partial drive must not paint the whole way');
      },
    );

    test(
      'same way driven by TWO trips (overlapping) → deduped to ONE feature',
      () async {
        final tripA = await _seedMatchedTrip(tripsDao);
        final tripB = await _seedMatchedTrip(tripsDao);
        // Both trips drove way 5; overlapping passes.
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

        final resolver = DrivenWayGeometryResolver(
          intervalsDao: intervalsDao,
          waySource: _FakeWayCandidateSource([_straightWay(5)]),
        );

        final result = await resolver.resolve(_dummyBounds);
        // Two overlapping passes union into ONE [0..222] interval → ONE
        // feature, not two overlapping lines.
        expect(result.ways, hasLength(1));
        expect(result.ways.first.wayId, 5);
      },
    );

    test('geometry cache-miss → skipped (no throw)', () async {
      final trip = await _seedMatchedTrip(tripsDao);
      await _seedInterval(
        intervalsDao,
        tripId: trip,
        wayId: 55,
        startMeters: 0,
        endMeters: 200,
      );

      // Empty source — simulates offline + cache-miss for wayId 55.
      final resolver = DrivenWayGeometryResolver(
        intervalsDao: intervalsDao,
        waySource: _FakeWayCandidateSource([]),
      );

      final result = await resolver.resolve(_dummyBounds);
      expect(result.ways, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // TripsDao.watchUnionBbox — reactivity
  //
  // These tests prove the live-refresh chain that 07-06 truth #3 depends on:
  //   confirmTrip → trips write → watchUnionBbox re-emits → overlay re-resolves
  // -------------------------------------------------------------------------

  group('TripsDao.watchUnionBbox', () {
    test('emits null when no matched/confirmed trips exist', () async {
      final first = await tripsDao.watchUnionBbox().first;
      expect(first, isNull);
    });

    test(
      'emits LatLngBounds when a matched trip has bbox columns populated',
      () async {
        await _seedMatchedTrip(tripsDao);
        final bounds = await tripsDao.watchUnionBbox().first;
        expect(bounds, isNotNull);
        expect(bounds!.southwest.latitude, closeTo(49, 1e-6));
        expect(bounds.northeast.latitude, closeTo(49.5, 1e-6));
      },
    );

    test(
      're-emits when a second matched trip is inserted (new trips write)',
      () async {
        final emissions = <LatLngBounds?>[];
        final sub = tripsDao.watchUnionBbox().listen(emissions.add);
        addTearDown(sub.cancel);

        // Let the initial null emission land.
        await Future<void>.delayed(Duration.zero);
        expect(emissions, hasLength(1));
        expect(emissions.first, isNull);

        // Insert first matched trip.
        await _seedMatchedTrip(tripsDao);

        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(emissions.length, greaterThanOrEqualTo(2));
        expect(emissions.last, isNotNull);
        expect(emissions.last!.southwest.latitude, closeTo(49, 1e-6));
      },
    );

    test(
      're-emits on confirmTrip (matched→confirmed status flip) — '
      'crux of 07-06 live-refresh BLOCKER fix',
      () async {
        // Insert a matched trip with bbox.
        final tripId = await _seedMatchedTrip(tripsDao);

        // Start listening after the trip exists.
        final emissions = <LatLngBounds?>[];
        final sub = tripsDao.watchUnionBbox().listen(emissions.add);
        addTearDown(sub.cancel);

        await Future<void>.delayed(Duration.zero);
        expect(emissions, hasLength(1));
        expect(emissions.first, isNotNull); // matched trip has bbox

        // Flip to confirmed — writes to the trips table.
        // Even though status IN ('matched','confirmed') membership does not
        // change, Drift re-emits because any write to the watched table
        // invalidates the customSelect result. This is the table-write
        // invalidation mechanism (not value-diff) that drives 07-06 truth #3.
        await inboxDao.transitionToConfirmed(tripId);

        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(
          emissions.length,
          greaterThanOrEqualTo(2),
          reason:
              "watchUnionBbox MUST re-emit on confirmTrip. Drift's table-write "
              'invalidation fires on any trips table write, including a '
              'matched→confirmed status flip. This is the trigger for the '
              'coverageOverlayDataProvider to re-resolve and update the map.',
        );
        expect(emissions.last, isNotNull);
        expect(emissions.last!.southwest.latitude, closeTo(49, 1e-6));
      },
    );

    test(
      're-emits on driven_way_intervals write — readsFrom includes that table',
      () async {
        final tripId = await _seedMatchedTrip(tripsDao);

        final emissions = <LatLngBounds?>[];
        final sub = tripsDao.watchUnionBbox().listen(emissions.add);
        addTearDown(sub.cancel);

        await Future<void>.delayed(Duration.zero);
        expect(emissions, hasLength(1));
        expect(emissions.first, isNotNull);

        // Write to driven_way_intervals — should trigger re-emit because
        // the query declares readsFrom: {trips, drivenWayIntervals}.
        await _seedInterval(
          intervalsDao,
          tripId: tripId,
          wayId: 123,
          startMeters: 0,
          endMeters: 100,
        );

        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(
          emissions.length,
          greaterThanOrEqualTo(2),
          reason:
              'readsFrom: {trips, drivenWayIntervals} means any write to '
              'driven_way_intervals must trigger a watchUnionBbox re-emit, '
              'ensuring the overlay stays live even for intervals-only mutations '
              '(e.g. Phase-8 background backfill or re-match).',
        );
      },
    );
  });
}
