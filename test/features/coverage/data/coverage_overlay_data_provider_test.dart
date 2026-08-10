// Trailblazer coverage overlay — provider-level reactivity (2026-07-30).
//
// Regression guard for THE "orange lines don't repaint until restart" bug:
// after finishing a trip, coverage % updated but the persistent coverage
// overlay did not repaint until an app restart.
//
// Root cause: coverageOverlayDataProvider re-resolved only when the value read
// from tripsUnionBoundsProvider CHANGED. That value is a maplibre LatLngBounds
// with VALUE equality — a trip driven WITHIN the already-covered union bbox
// re-emits an EQUAL bounds, which Riverpod deduplicates, so the overlay async*
// never re-ran and the resolver never re-read the freshly written intervals.
//
// Fix: coverageOverlayDataProvider additionally watches
// drivenWayIntervalsRevisionProvider (a strictly-monotonic MAX(id)+COUNT over
// driven_way_intervals), so the observed dependency changes on EVERY interval
// write regardless of whether the bbox moved.
//
// The existing driven_way_geometry_resolver_test proves the underlying Drift
// stream re-emits; these tests prove the RIVERPOD layer re-resolves (the layer
// where the dedup previously swallowed the update).

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/app_database_providers.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/features/coverage/data/coverage_overlay_data.dart';
import 'package:auto_explore/features/coverage/data/coverage_overlay_providers.dart';
import 'package:auto_explore/features/coverage/data/driven_way_geometry_resolver.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLngBounds;

// ---------------------------------------------------------------------------
// Call-counting fake resolver — records each resolve() invocation. The overlay
// provider re-resolves by calling resolve(); counting calls tells us whether
// the reactive chain fired, independent of tile parsing / compute isolates.
// ---------------------------------------------------------------------------

class _CountingResolver extends DrivenWayGeometryResolver {
  _CountingResolver({
    required super.intervalsDao,
    required super.waySource,
  });

  int resolveCalls = 0;
  LatLngBounds? lastBounds;

  @override
  Future<CoverageOverlayData> resolve(LatLngBounds unionBounds) async {
    resolveCalls++;
    lastBounds = unionBounds;
    // Return empty — geometry content is irrelevant to this reactivity test.
    return CoverageOverlayData.empty;
  }
}

// ---------------------------------------------------------------------------
// Seed helpers (mirror driven_way_geometry_resolver_test).
// ---------------------------------------------------------------------------

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
      pointCount: const Value(10),
      bboxMinLat: Value(minLat),
      bboxMinLon: Value(minLon),
      bboxMaxLat: Value(maxLat),
      bboxMaxLon: Value(maxLon),
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

void main() {
  late AppDatabase db;
  late DrivenWayIntervalsDao intervalsDao;
  late TripsDao tripsDao;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    intervalsDao = DrivenWayIntervalsDao(db);
    tripsDao = TripsDao(db);
    await db.customSelect('SELECT 1').getSingle();
  });

  tearDown(() async {
    await db.close();
  });

  /// Build a container wired to the in-memory DB with a counting resolver.
  ({ProviderContainer container, _CountingResolver resolver}) wire() {
    final resolver = _CountingResolver(
      intervalsDao: intervalsDao,
      // waySource is never invoked (resolve() is overridden) — but the base
      // ctor requires one; the real provider's source is irrelevant here.
      waySource: _UnusedWaySource(),
    );
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        drivenWayGeometryResolverProvider.overrideWithValue(resolver),
      ],
    );
    return (container: container, resolver: resolver);
  }

  /// Pump the microtask + timer queues until [predicate] holds or [tries] is
  /// exhausted. StreamProvider/async* propagation spans several event-loop
  /// turns (Drift watch → bounds provider → revision provider → overlay
  /// async*), so a single `Duration.zero` gap is not enough.
  Future<void> pumpUntil(
    bool Function() predicate, {
    int tries = 50,
  }) async {
    for (var i = 0; i < tries && !predicate(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  test(
    'interval write with UNCHANGED union bbox still re-resolves the overlay '
    '(the restart-only-repaint bug)',
    () async {
      // A trip already covering the union bbox. A second matched trip's
      // intervals will land INSIDE this same bbox, so watchUnionBbox emits an
      // EQUAL LatLngBounds — the exact dedup trap.
      final tripA = await _seedMatchedTrip(tripsDao);
      final tripB = await _seedMatchedTrip(tripsDao); // same bbox
      await _seedInterval(
        intervalsDao,
        tripId: tripA,
        wayId: 1,
        startMeters: 0,
        endMeters: 100,
      );

      final (:container, :resolver) = wire();
      addTearDown(container.dispose);

      // Subscribe so the async* body runs (listen keeps it alive & pulling).
      final sub = container.listen(
        coverageOverlayDataProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(sub.close);

      // The first resolve happens once the bounds stream has emitted the
      // seeded bbox (async* re-runs when bounds go null → non-null).
      await pumpUntil(() => resolver.resolveCalls >= 1);
      final callsAfterFirst = resolver.resolveCalls;
      expect(
        callsAfterFirst,
        greaterThanOrEqualTo(1),
        reason: 'overlay must resolve once the union bbox is available',
      );
      expect(resolver.lastBounds!.southwest.latitude, closeTo(49, 1e-6));

      // Now write NEW intervals for tripB — union bbox is UNCHANGED (tripB has
      // the identical bbox). Before the revision fix, tripsUnionBoundsProvider
      // emits an equal LatLngBounds, Riverpod dedups it, and the overlay never
      // re-resolves. With the fix, drivenWayIntervalsRevisionProvider advances
      // and forces a re-resolve.
      await _seedInterval(
        intervalsDao,
        tripId: tripB,
        wayId: 2,
        startMeters: 0,
        endMeters: 100,
      );

      await pumpUntil(() => resolver.resolveCalls > callsAfterFirst);

      expect(
        resolver.resolveCalls,
        greaterThan(callsAfterFirst),
        reason:
            'an interval write must re-resolve the overlay even when the union '
            'bbox value is unchanged — otherwise the orange lines only repaint '
            'after an app restart',
      );
    },
  );

  test(
    'resolves empty (no resolve call) when there are no matched trips',
    () async {
      final (:container, :resolver) = wire();
      addTearDown(container.dispose);

      final sub = container.listen(
        coverageOverlayDataProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(sub.close);

      // No trips → bounds stream stays null → async* yields empty, resolve()
      // is never invoked (the bounds == null short-circuit).
      await pumpUntil(
        () => container.read(coverageOverlayDataProvider).hasValue,
      );
      expect(
        container.read(coverageOverlayDataProvider).value,
        equals(CoverageOverlayData.empty),
      );
      expect(resolver.resolveCalls, 0);
    },
  );
}

// Minimal stand-in; resolve() is overridden so no method here is ever called.
class _UnusedWaySource implements WayCandidateSource {
  @override
  Object noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('waySource must not be used in this test');
}
