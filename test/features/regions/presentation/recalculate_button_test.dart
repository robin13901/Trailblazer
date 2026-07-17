// Trailblazer Phase 10, Plan 10-05:
// recalculate_button_test.dart — widget test for RecalculateButton.
//
// Test inventory:
//  1. Button renders with "Regionen neu berechnen" label when idle.
//  2. Tap → confirmation dialog appears.
//  3. Cancel in dialog → action.run() NOT called.
//  4. Confirm in dialog → action.run() IS called; snackbar appears.
//  5. RecalculateButton widget is present in the Regions screen tree.

import 'dart:async';
import 'dart:typed_data';

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/core/theme/liquid_glass_settings.dart';
import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/admin/data/admin_region_lookup.dart';
import 'package:auto_explore/features/coverage/data/coverage_cache_dao.dart';
import 'package:auto_explore/features/matching/data/matcher_isolate.dart';
import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/matching/data/trip_match_coordinator.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/matching/domain/gps_fix.dart';
import 'package:auto_explore/features/matching/domain/match_result.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/regions/data/coverage_compute_service.dart';
import 'package:auto_explore/features/regions/data/recalculate_coverage_action.dart';
import 'package:auto_explore/features/regions/data/region_totals_lookup.dart';
import 'package:auto_explore/features/regions/presentation/providers/region_browser_provider.dart';
import 'package:auto_explore/features/regions/presentation/regions_screen.dart';
import 'package:auto_explore/features/regions/presentation/widgets/recalculate_button.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/data/trips_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Stubs for constructing a real RecalculateCoverageAction
// (run() is overridden, so these are never actually called)
// ---------------------------------------------------------------------------

class _NullWayCandidateSource implements WayCandidateSource {
  @override
  Future<List<WayCandidate>> fetchWaysInBbox({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    bool throwOnError = true,
  }) async =>
      const [];

  @override
  Future<List<RawTilePayload>> fetchRawTilesInBbox({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    bool throwOnError = true,
  }) async =>
      const [];
}

class _NullMatcherIsolate extends MatcherIsolate {
  @override
  Future<void> start() async {}

  @override
  Future<MatchResult> match({
    required int tripId,
    required List<GpsFix> fixes,
    required List<Uint8List> gzippedTiles,
    required List<LatLonBbox> tileBboxes,
    void Function(int processed, int total)? onProgress,
  }) async =>
      const MatchResult(
        steps: [],
        intervals: [],
        matchedFixCount: 0,
        droppedFixCount: 0,
      );

  @override
  void cancel(int tripId) {}

  @override
  void dispose() {}
}

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

class _NullRegionTotalsLookup extends RegionTotalsLookup {
  @override
  Future<void> ensureLoaded() async {}

  @override
  double? totalFor(String osmId) => null;
}

/// Real [RecalculateCoverageAction] subclass with [run] overridden to a fake
/// implementation. The super constructor receives valid stub collaborators so
/// the field assignments in RecalculateCoverageAction's constructor succeed —
/// they are never called because run() is entirely replaced.
class _FakeRecalculateCoverageAction extends RecalculateCoverageAction {
  _FakeRecalculateCoverageAction({required AppDatabase db})
      : super(
          matchCoordinator: TripMatchCoordinator(
            source: _NullWayCandidateSource(),
            matcherIsolate: _NullMatcherIsolate(),
            tripsDao: TripsDao(db),
            tripsRepository: TripsRepository(TripsDao(db)),
            intervalsDao: DrivenWayIntervalsDao(db),
          ),
          computeService: CoverageComputeService(
            intervalsDao: DrivenWayIntervalsDao(db),
            waySource: _NullWayCandidateSource(),
            regionLookup: _NullAdminRegionLookup(),
            cacheDao: CoverageCacheDao(db),
            tripsDao: TripsDao(db),
            totalsLookup: _NullRegionTotalsLookup(),
          ),
        );

  int runCallCount = 0;

  @override
  Future<Result<int>> run() async {
    runCallCount++;
    progressNotifier.value = const RecalculateRecomputing();
    await Future<void>.delayed(Duration.zero);
    progressNotifier.value = const RecalculateDone(rowsWritten: 3);
    return const Ok(3);
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Widget _buildApp(_FakeRecalculateCoverageAction fakeAction) {
  return ProviderScope(
    overrides: [
      regionBrowserProvider.overrideWith(
        (_) => Stream.value(const []),
      ),
      recalculateCoverageActionProvider.overrideWithValue(fakeAction),
    ],
    child: const MaterialApp(home: RegionsScreen()),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(() {
    LiquidGlassSettings.platformBlurEnabled = false;
  });

  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets(
    '1. idle state: button renders with "Regionen neu berechnen" label',
    (tester) async {
      final action = _FakeRecalculateCoverageAction(db: db);
      await tester.pumpWidget(_buildApp(action));
      await tester.pumpAndSettle();

      expect(find.text('Regionen neu berechnen'), findsOneWidget);
    },
  );

  testWidgets(
    '2. tapping button shows confirmation dialog',
    (tester) async {
      final action = _FakeRecalculateCoverageAction(db: db);
      await tester.pumpWidget(_buildApp(action));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Regionen neu berechnen'));
      await tester.pumpAndSettle();

      expect(find.text('Regionen neu berechnen?'), findsOneWidget);
      expect(find.text('Neu berechnen'), findsOneWidget);
      expect(find.text('Abbrechen'), findsOneWidget);
    },
  );

  testWidgets(
    '3. cancelling dialog does NOT call action.run()',
    (tester) async {
      final action = _FakeRecalculateCoverageAction(db: db);
      await tester.pumpWidget(_buildApp(action));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Regionen neu berechnen'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();

      expect(action.runCallCount, 0);
    },
  );

  testWidgets(
    '4. confirming dialog calls action.run() and shows snackbar',
    (tester) async {
      final action = _FakeRecalculateCoverageAction(db: db);
      await tester.pumpWidget(_buildApp(action));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Regionen neu berechnen'));
      await tester.pumpAndSettle();

      // "Neu berechnen" is the confirmation button in the dialog.
      await tester.tap(find.text('Neu berechnen'));
      await tester.pumpAndSettle();

      expect(action.runCallCount, 1);
      // Snackbar appears after completion.
      expect(find.textContaining('Regionen aktualisiert'), findsOneWidget);
    },
  );

  testWidgets(
    '5. RecalculateButton widget is present in the Regions screen tree',
    (tester) async {
      final action = _FakeRecalculateCoverageAction(db: db);
      await tester.pumpWidget(_buildApp(action));
      await tester.pumpAndSettle();

      expect(find.byType(RecalculateButton), findsOneWidget);
    },
  );
}
