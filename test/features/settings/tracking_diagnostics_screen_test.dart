import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/app_database_providers.dart';
import 'package:auto_explore/features/matching/data/matching_providers.dart';
import 'package:auto_explore/features/onboarding/data/permission_service_provider.dart';
import 'package:auto_explore/features/settings/presentation/tracking_diagnostics_screen.dart';
import 'package:auto_explore/features/trips/data/background_geolocation_facade_provider.dart';
import 'package:auto_explore/features/trips/domain/tracking_diagnostics.dart';
import 'package:auto_explore/features/trips/presentation/providers/tracking_diagnostics_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_background_geolocation_facade.dart';
import '../../helpers/fixture_way_candidate_source.dart';
import '../onboarding/fakes/fake_permission_service.dart';

/// Widget test for the dev-only `TrackingDiagnosticsScreen` (Plan 03-1-01).
///
/// Injects a fixed [TrackingDiagnostics] snapshot via `overrideWithValue`
/// so the screen renders deterministically. The 500 ms polling timer is
/// NOT exercised — pumping fake time would add flakiness without value; the
/// TrackingDurationTicker pattern (Plan 03-06 STATE decision) is the shape
/// of record.
///
/// Enlarges the test surface via `setSurfaceSize` so the full HUD ListView
/// mounts every ListTile eagerly (the default 800×600 test window would
/// leave lower sections lazy-off-viewport, hiding several of the assertions).
void main() {
  Future<void> pumpScreen(
    WidgetTester tester,
    TrackingDiagnostics snapshot,
  ) async {
    // Tall surface so every ListTile in the diagnostics HUD mounts eagerly
    // (default 800×600 leaves lower sections lazy-offstage which trips the
    // trailing-text finders below).
    await tester.binding.setSurfaceSize(const Size(800, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(const Size(800, 600)));

    // In-memory DB so readDiagnosticsMetrics (pendingRoadFetchesDao.listPending)
    // never touches the drift_flutter path_provider channel.
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          trackingDiagnosticsProvider.overrideWithValue(snapshot),
          permissionServiceProvider.overrideWithValue(FakePermissionService()),
          backgroundGeolocationFacadeProvider
              .overrideWithValue(FakeBackgroundGeolocationFacade()),
          // Override DB so pendingRoadFetchesDao.listPending() uses in-memory
          // storage instead of real drift_flutter (requires path_provider).
          appDatabaseProvider.overrideWithValue(db),
          // Override wayCandidateSourceProvider so readDiagnosticsMetrics can
          // read cache counters without touching the network or a real DB.
          wayCandidateSourceProvider.overrideWithValue(
            FixtureWayCandidateSource(ways: const []),
          ),
        ],
        child: const MaterialApp(
          home: TrackingDiagnosticsScreen(),
        ),
      ),
    );
    // Let the async-refresh microtasks complete without letting the polling
    // Timer tick a second time (pump uses zero-duration frame).
    await tester.pump();
  }

  testWidgets('renders every diagnostic field from the fixed snapshot',
      (tester) async {
    final now = DateTime(2026, 7, 6, 12);
    final snapshot = TrackingDiagnostics(
      facadeReadyOutcome: const FacadeReadySuccess(),
      facadeCurrentState: null,
      lastAcceptedFix: LastFixSample(
        ts: now.subtract(const Duration(seconds: 3)),
        lat: 49.12345,
        lon: 8.67890,
        accuracyMeters: 8,
        speedKmh: 42.5,
      ),
      lastRejectedReason: 'accuracy',
      lastRejectedAt: now.subtract(const Duration(seconds: 12)),
      lastActivityType: 'in_vehicle',
      lastActivityAt: now.subtract(const Duration(seconds: 5)),
      acceptCount: 7,
      rejectCount: 3,
      gapCount: 1,
      splitCount: 0,
      currentTripId: 42,
    );

    await pumpScreen(tester, snapshot);

    // FGB ready outcome
    expect(find.text('success'), findsOneWidget);

    // Counters — every distinct value appears exactly once in this snapshot.
    expect(find.text('7'), findsOneWidget);

    // Last activity type
    expect(find.text('in_vehicle'), findsOneWidget);

    // Last rejected reason
    expect(find.text('accuracy'), findsOneWidget);

    // Current trip id
    expect(find.text('42'), findsOneWidget);

    // Last accepted fix formatted coords
    expect(find.text('49.12345, 8.67890'), findsOneWidget);
  });

  testWidgets('idle state: no fix, no trip, empty placeholders',
      (tester) async {
    const snapshot = TrackingDiagnostics(
      facadeReadyOutcome: FacadeReadyPending(),
      facadeCurrentState: null,
      lastAcceptedFix: null,
      lastRejectedReason: null,
      lastRejectedAt: null,
      lastActivityType: 'unknown',
      lastActivityAt: null,
      acceptCount: 0,
      rejectCount: 0,
      gapCount: 0,
      splitCount: 0,
      currentTripId: null,
    );

    await pumpScreen(tester, snapshot);

    expect(find.text('pending'), findsOneWidget);
    expect(find.text('idle'), findsOneWidget);
    expect(find.text('no fix accepted yet'), findsOneWidget);
    expect(find.text('unknown'), findsOneWidget);
  });
}
