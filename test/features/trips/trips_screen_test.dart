// Trailblazer — TripsScreen tests (history-only, 2026-07-13).
//
// The Inbox/History sub-tabs were removed; the screen now shows the trip
// history list directly with the MatchingQueuePill above it.
//
// Thumbnails render purely on the Canvas via `thumbnailRendererProvider`
// (overridden with a no-op here). tripPlaces is stubbed for the row place
// names.

import 'dart:typed_data';

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/admin/data/admin_region_lookup.dart';
import 'package:auto_explore/features/coverage/data/coverage_cache_dao.dart';
import 'package:auto_explore/features/coverage/data/coverage_invalidator.dart';
import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/regions/data/coverage_compute_job.dart';
import 'package:auto_explore/features/regions/data/coverage_compute_service.dart';
import 'package:auto_explore/features/regions/data/region_totals_lookup.dart';
import 'package:auto_explore/features/trips/data/thumbnail_cache.dart';
import 'package:auto_explore/features/trips/data/thumbnail_providers.dart';
import 'package:auto_explore/features/trips/data/thumbnail_renderer.dart';
import 'package:auto_explore/features/trips/data/trip_place_lookup_providers.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/data/trips_dao_inbox_queries.dart';
import 'package:auto_explore/features/trips/data/trips_repository_inbox_extensions.dart';
import 'package:auto_explore/features/trips/domain/trip_list_item.dart';
import 'package:auto_explore/features/trips/domain/trip_place_lookup.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:auto_explore/features/trips/presentation/providers/inbox_providers.dart';
import 'package:auto_explore/features/trips/presentation/trips_screen.dart';
import 'package:auto_explore/features/trips/presentation/widgets/discard_confirmation_dialog.dart';
import 'package:auto_explore/features/trips/presentation/widgets/history_empty_state.dart';
import 'package:auto_explore/features/trips/presentation/widgets/history_row.dart';
import 'package:auto_explore/features/trips/presentation/widgets/matching_queue_pill.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

class _NoopThumbnailCache extends ThumbnailCache {
  @override
  ThumbnailCacheState build() => const ThumbnailCacheState.empty();
  @override
  Future<void> delete(int tripId) async {}
}

class _NoopRenderer extends ThumbnailRenderer {
  _NoopRenderer() : super(mapStyleUrl: '');
  @override
  Future<Uint8List> renderFallback({
    required List<LatLng> polyline,
    required LatLngBounds bbox,
  }) async => Uint8List(0);
}

/// Trivial [CoverageInvalidator] fake — never exercised (discardTrip is
/// overridden in [_RecordingInboxRepo]), just satisfies the constructor.
class _NoopInvalidator implements CoverageInvalidator {
  @override
  Future<Result<int>> invalidateForTrip(int tripId) async => const Ok(0);
  @override
  Future<Result<int>> invalidateForTripDelete(int tripId) async => const Ok(0);
  @override
  Future<Result<int>> invalidateAll() async => const Ok(0);
}

/// Minimal fake AdminRegionLookup — always returns null (see extensions test).
class _NullAdminRegionLookup implements AdminRegionLookup {
  @override
  Future<void> ensureLoaded() async {}
  @override
  Future<AdminRegion?> regionAt(double lat, double lon, int adminLevel) async =>
      null;
  @override
  void invalidate() {}
  @override
  AdminRegion? regionByOsmId(int osmId) => null;
  @override
  int get regionCount => 0;
  @override
  int get bundleLoadCount => 0;
}

/// Minimal fake WayCandidateSource — always empty (see extensions test).
class _EmptyWayCandidateSource implements WayCandidateSource {
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
  }) async => const [];

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
  }) async => const [];
}

/// Stand-in attribution runner — never invoked (recompute is overridden).
Future<List<WayRegionAttributionRow>> _unusedCompute(
  List<Uint8List> gzippedTiles,
  List<LatLonBbox> tileBboxes,
  Set<int> alreadyAttributedWayIds,
) async => const [];

/// No-op CoverageComputeService (mirrors the stub in the extensions test).
class _NoopComputeService extends CoverageComputeService {
  _NoopComputeService(AppDatabase db)
    : super(
        intervalsDao: DrivenWayIntervalsDao(db),
        waySource: _EmptyWayCandidateSource(),
        regionLookup: _NullAdminRegionLookup(),
        cacheDao: CoverageCacheDao(db),
        tripsDao: TripsDao(db),
        totalsLookup: RegionTotalsLookup(),
        compute: _unusedCompute,
      );
  @override
  Future<Result<int>> recompute({
    CoverageRecomputeProgress? onProgress,
  }) async => const Ok(0);
}

/// Records the trip id passed to [discardTrip] without touching the DB. The
/// injected DAOs/invalidator/computeService are never invoked because
/// discardTrip is overridden.
class _RecordingInboxRepo extends TripsInboxRepository {
  _RecordingInboxRepo(AppDatabase db)
    : super(
        inboxDao: TripsInboxDao(db),
        tripsDao: TripsDao(db),
        intervalsDao: DrivenWayIntervalsDao(db),
        invalidator: _NoopInvalidator(),
        computeService: _NoopComputeService(db),
      );

  final List<int> discarded = <int>[];

  @override
  Future<Result<void>> discardTrip(int tripId) async {
    discarded.add(tripId);
    return const Ok(null);
  }
}

TripListItem _item(int id, TripStatus status) => TripListItem(
  id: id,
  status: status,
  startedAt: DateTime(2026, 7, 8, 14, 32),
  endedAt: DateTime(2026, 7, 8, 15, 14),
  distanceMeters: 12000,
  durationSeconds: 30 * 60,
  startLat: 49.70,
  startLon: 9.26,
  endLat: 49.97,
  endLon: 9.15,
  intervalCount: 5,
  bboxMinLat: 49.70,
  bboxMinLon: 9.15,
  bboxMaxLat: 49.97,
  bboxMaxLon: 9.26,
);

Future<void> _pump(
  WidgetTester tester, {
  required List<TripListItem> history,
  int inFlight = 0,
  TripsInboxRepository? inboxRepo,
}) async {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (context, state) => const TripsScreen()),
      GoRoute(
        path: '/trips/:id',
        builder: (context, state) => const Scaffold(body: Text('detail')),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // Inbox is no longer surfaced, but the provider still exists — stub it
        // empty so any transitive watcher stays satisfied.
        inboxTripsProvider.overrideWith((ref) => Stream.value(const [])),
        historyTripsProvider.overrideWith((ref) => Stream.value(history)),
        inFlightCountProvider.overrideWith((ref) => Stream.value(inFlight)),
        thumbnailCacheProvider.overrideWith(_NoopThumbnailCache.new),
        thumbnailRendererProvider.overrideWithValue(_NoopRenderer()),
        tripPlacesProvider.overrideWith(
          (ref, coords) async => const TripPlaces(
            startName: 'Aschaffenburg',
            endName: 'Miltenberg',
          ),
        ),
        if (inboxRepo != null)
          tripsInboxRepositoryProvider.overrideWithValue(inboxRepo),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pump(); // resolve streams
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('3 history trips → 3 HistoryRows, no TabBar', (tester) async {
    await _pump(
      tester,
      history: [
        _item(1, TripStatus.confirmed),
        _item(2, TripStatus.confirmed),
        _item(3, TripStatus.confirmed),
      ],
    );
    await tester.pump();
    expect(find.byType(HistoryRow), findsNWidgets(3));
    // The sub-tabs are gone entirely.
    expect(find.byType(TabBar), findsNothing);
    expect(find.byType(TabBarView), findsNothing);
  });

  testWidgets('empty history → HistoryEmptyState shown', (tester) async {
    await _pump(tester, history: const []);
    await tester.pump();
    expect(find.byType(HistoryEmptyState), findsOneWidget);
  });

  testWidgets('inFlightCount 3 → MatchingQueuePill visible with copy', (
    tester,
  ) async {
    await _pump(
      tester,
      history: [_item(1, TripStatus.confirmed)],
      inFlight: 3,
    );
    await tester.pump();
    expect(find.byType(MatchingQueuePill), findsOneWidget);
  });

  testWidgets('long-press → confirm dialog → discardTrip called with trip id', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = _RecordingInboxRepo(db);

    await _pump(
      tester,
      history: [_item(7, TripStatus.confirmed)],
      inboxRepo: repo,
    );
    await tester.pump();

    await tester.longPress(find.byType(HistoryRow));
    await tester.pumpAndSettle();

    // The shared discard-confirmation dialog is shown.
    expect(find.byType(DiscardConfirmationDialog), findsOneWidget);

    // Confirm ("Verwerfen" action in the dialog).
    await tester.tap(find.widgetWithText(TextButton, 'Verwerfen'));
    await tester.pumpAndSettle();

    expect(repo.discarded, [7]);
  });

  testWidgets('long-press → cancel dialog → discardTrip NOT called', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = _RecordingInboxRepo(db);

    await _pump(
      tester,
      history: [_item(7, TripStatus.confirmed)],
      inboxRepo: repo,
    );
    await tester.pump();

    await tester.longPress(find.byType(HistoryRow));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Abbrechen'));
    await tester.pumpAndSettle();

    expect(repo.discarded, isEmpty);
  });
}
