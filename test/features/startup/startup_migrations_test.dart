// App startup-migration tests (2026-07-26).
//
// FIX 1 (guaranteed clear): `_AppState._runStartupMigrations` clears the
// app-wide recalc banner in a `finally`, so a stalled/failed coverage recompute
// can never strand the "Abdeckung wird neu berechnet …" banner spinning
// forever (the 20-minute stuck-banner bug).
//
// This boots the full [App] on the onboarding route (empty prefs) so the
// GlobalRecalcBanner never MOUNTS — its indeterminate animation would otherwise
// keep `pumpAndSettle` from ever settling. The migrations still run on the first
// post-frame callback regardless of route. The coverage-recompute service is
// overridden to return `Err`, and after the migrations settle the real
// `globalRecalcProgressProvider` MUST be back to null (banner cleared).

import 'package:auto_explore/app.dart';
import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/app_database_providers.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/features/admin/data/admin_region_lookup.dart';
import 'package:auto_explore/features/coverage/data/coverage_cache_dao.dart';
import 'package:auto_explore/features/map/presentation/providers/location_permission_provider.dart';
import 'package:auto_explore/features/onboarding/data/permission_service_provider.dart';
import 'package:auto_explore/features/regions/data/coverage_compute_providers.dart';
import 'package:auto_explore/features/regions/data/coverage_compute_service.dart';
import 'package:auto_explore/features/regions/data/region_totals_lookup.dart';
import 'package:auto_explore/features/startup/data/global_recalc_progress_provider.dart';
import 'package:auto_explore/features/trips/data/background_geolocation_facade_provider.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../../helpers/fake_background_geolocation_facade.dart';
import '../../helpers/fake_maplibre_platform.dart';
import '../../helpers/fixture_way_candidate_source.dart';
import '../onboarding/fakes/fake_permission_service.dart';

/// Stub notifier that returns [PermissionStatus.granted] without hitting the
/// permission_handler platform channel.
class _FakeLocationPermissionNotifier extends AsyncNotifier<PermissionStatus>
    implements LocationPermissionNotifier {
  @override
  Future<PermissionStatus> build() async => PermissionStatus.granted;

  @override
  Future<PermissionStatus> requestOnce() async => PermissionStatus.granted;

  @override
  Future<void> refresh() async {}
}

/// [CoverageComputeService] whose [recompute] ALWAYS returns [Err] (simulating a
/// failed/stalled coverage rebuild). The heavy deps are real but never touched —
/// [recompute] is fully overridden. Counts calls so the test can prove the Err
/// path actually ran before the banner cleared.
class _ErrRecomputeService extends CoverageComputeService {
  _ErrRecomputeService(AppDatabase db)
    : super(
        intervalsDao: DrivenWayIntervalsDao(db),
        waySource: FixtureWayCandidateSource(ways: const []),
        regionLookup: AdminRegionLookup(),
        cacheDao: CoverageCacheDao(db),
        tripsDao: TripsDao(db),
        totalsLookup: RegionTotalsLookup(),
        compute: (tiles, bboxes, already) async => const [],
      );

  int recomputeCalls = 0;

  @override
  Future<Result<int>> recompute({
    CoverageRecomputeProgress? onProgress,
    CoverageRecomputeProgress? onTileFetch,
  }) async {
    recomputeCalls++;
    return const Err(UnknownError('simulated recompute failure'));
  }
}

void main() {
  testWidgets(
    '_runStartupMigrations clears the recalc banner even when recompute '
    'returns Err (finally guarantee)',
    (tester) async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();

      // Fake MapLibre so the map platform view never throws if reached.
      final prev = MapLibrePlatform.createInstance;
      addTearDown(() => MapLibrePlatform.createInstance = prev);
      MapLibrePlatform.createInstance = FakeMapLibrePlatform.new;

      // In-memory DB so the stuck-fetch + rematch migrations run cleanly (empty
      // DB → no-ops) before the coverage recompute reaches our Err stub.
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final errService = _ErrRecomputeService(db);

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          coverageComputeServiceProvider.overrideWithValue(errService),
          locationPermissionProvider.overrideWith(
            _FakeLocationPermissionNotifier.new,
          ),
          permissionServiceProvider.overrideWithValue(FakePermissionService()),
          backgroundGeolocationFacadeProvider.overrideWithValue(
            FakeBackgroundGeolocationFacade(),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const App(),
        ),
      );
      // Let the first frame + post-frame migrations + async prefs read settle.
      await tester.pumpAndSettle(const Duration(seconds: 1));

      // The Err-returning recompute ran exactly once (coverage phase reached).
      expect(
        errService.recomputeCalls,
        1,
        reason: 'the coverage-recompute migration must have run and failed',
      );

      // FINALLY GUARANTEE: despite the Err, the banner state is back to null.
      expect(
        container.read(globalRecalcProgressProvider),
        isNull,
        reason: 'the finally block must clear the banner even on recompute Err',
      );
    },
  );
}
