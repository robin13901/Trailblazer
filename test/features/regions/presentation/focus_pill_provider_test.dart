// Trailblazer Phase 8, Plan 08-04 (Wave 2):
// FocusPillNotifier unit tests — ProviderContainer with in-memory DB.
//
// Tests:
//   1. Successful resolve: camera over seeded region+cache row → state has
//      name and percentLabel after debounce.
//   2. Fallback chain: regionAt(level 9) null, regionAt(level 8) returns
//      region → state.name is the level-8 name.
//   3. Fallback chain (level 8 wins).
//   4. Outside Germany (all levels incl. L4 null) → pill shows "—".
//   5. Over Germany at country zoom / water (L4 probe hits, finer null) →
//      pill shows "Deutschland".
//   6. No-cache row → percentLabel is null (widget shows "— %").

import 'dart:async';

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/admin/data/admin_region_lookup.dart';
import 'package:auto_explore/features/admin/data/admin_region_providers.dart';
import 'package:auto_explore/features/coverage/data/coverage_cache_dao.dart';
import 'package:auto_explore/features/coverage/data/coverage_providers.dart';
import 'package:auto_explore/features/map/presentation/providers/live_camera_provider.dart';
import 'package:auto_explore/features/regions/presentation/providers/focus_pill_provider.dart';
import 'package:auto_explore/features/trips/domain/live_fix_sample.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/presentation/providers/tracking_state_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show CameraPosition, LatLng;

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Callable that maps (lat, lon, level) -> AdminRegion?
typedef _RegionResolver = AdminRegion? Function(double, double, int);

/// Fake AdminRegionLookup driven by a [_RegionResolver] callback.
class _FakeAdminRegionLookup implements AdminRegionLookup {
  _FakeAdminRegionLookup(this._resolver);
  final _RegionResolver _resolver;

  @override
  Future<void> ensureLoaded() async {}

  @override
  Future<AdminRegion?> regionAt(double lat, double lon, int adminLevel) async =>
      _resolver(lat, lon, adminLevel);

  @override
  void invalidate() {}

  @override
  AdminRegion? regionByOsmId(int osmId) => null;

  @override
  int get regionCount => 0;

  @override
  int get bundleLoadCount => 0;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// A tiny closed-ring polygon covering Grebenhain in Hessen (level 8).
AdminRegion _grebenhainRegion() => const AdminRegion(
      osmId: 62492,
      adminLevel: 8,
      name: 'Grebenhain',
      bboxMinLat: 50.46,
      bboxMinLon: 9.33,
      bboxMaxLat: 50.56,
      bboxMaxLon: 9.44,
      polygons: [
        [
          [
            [50.46, 9.33],
            [50.56, 9.33],
            [50.56, 9.44],
            [50.46, 9.44],
            [50.46, 9.33],
          ],
        ],
      ],
    );

/// Builds an in-memory AppDatabase and seeds a coverage_cache row for
/// [osmId] with 264 m driven / 1000 m total → 26.4%.
Future<AppDatabase> _dbWithCacheRow({required int osmId}) async {
  final db = AppDatabase(NativeDatabase.memory());
  final dao = CoverageCacheDao(db);
  await dao.upsert(
    regionId: osmId.toString(),
    drivenLengthM: 264,
    totalLengthM: 1000,
    updatedAt: DateTime(2026, 7, 11),
  );
  return db;
}

/// Fake TrackingNotifier that reports a fixed [TrackingState].
///
/// Overriding [trackingStateProvider] keeps the pill provider from pulling the
/// real TrackingService (FGB facade + DB) into these pure-container tests. The
/// pill only ever reads whether the state is [TrackingRecording].
class _FakeTrackingNotifier extends Notifier<TrackingState>
    implements TrackingNotifier {
  _FakeTrackingNotifier(this._state);
  final TrackingState _state;

  @override
  TrackingState build() => _state;

  @override
  Future<void> startManual() async {}

  @override
  Future<void> stopActive() async {}
}

TrackingState _recording() => TrackingRecording(
      tripId: 1,
      startedAt: DateTime(2026, 7, 21),
      distanceMeters: 0,
      pointCount: 0,
      manuallyStarted: true,
    );

/// Builds a ProviderContainer that overrides the lookup + cache providers.
///
/// [resolver] controls what regionAt returns.
/// [db] is the in-memory AppDatabase (its CoverageCacheDao is used).
/// [tracking] is the fixed tracking state (default: idle). Pass [_recording]
/// to exercise the live-fix-driven path.
/// [fixStream] is the live GPS fix stream (default: empty).
ProviderContainer _makeContainer({
  required _RegionResolver resolver,
  required AppDatabase db,
  TrackingState tracking = const TrackingIdle(),
  Stream<LiveFixSample> fixStream = const Stream<LiveFixSample>.empty(),
}) {
  return ProviderContainer(
    overrides: [
      adminRegionLookupProvider.overrideWithValue(
        _FakeAdminRegionLookup(resolver),
      ),
      coverageCacheDaoProvider.overrideWithValue(
        CoverageCacheDao(db),
      ),
      trackingStateProvider.overrideWith(() => _FakeTrackingNotifier(tracking)),
      liveFixProvider.overrideWith((ref) => fixStream),
    ],
  );
}

/// Pushes a camera over Grebenhain centre (50.51, 9.385) at zoom 14 and waits
/// for the debounce + async resolve to settle.
///
/// Reads [focusPillProvider] first to ensure [FocusPillNotifier.build] has run
/// (i.e. the `ref.listen` on liveCameraProvider is registered) before the
/// camera update fires. Without this, the update would be missed by a lazily-
/// initialized notifier.
Future<void> _pushCamera(ProviderContainer c) async {
  // Trigger lazy initialization of FocusPillNotifier.
  c.read(focusPillProvider);
  c.read(liveCameraProvider.notifier).update(
        const CameraPosition(
          target: LatLng(50.51, 9.385),
          zoom: 14,
        ),
      );
  // Wait longer than the 150 ms debounce + async I/O slack.
  await Future<void>.delayed(const Duration(milliseconds: 400));
}

/// Pushes a camera over a coordinate with no region (0°, 0°).
///
/// Call [_pushCamera] first in any test that uses this, so the notifier is
/// already initialized.
Future<void> _pushNoRegionCamera(ProviderContainer c) async {
  c.read(liveCameraProvider.notifier).update(
        const CameraPosition(
          target: LatLng(0, 0),
          zoom: 14,
        ),
      );
  await Future<void>.delayed(const Duration(milliseconds: 400));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('FocusPillNotifier', () {
    late AppDatabase db;

    setUp(() async {
      db = await _dbWithCacheRow(osmId: _grebenhainRegion().osmId);
    });

    tearDown(() async {
      await db.close();
    });

    test('1. initial state is blank (no name, no percent)', () {
      // Dart 3+ wildcard: all three params unused → all named _
      final c = _makeContainer(resolver: (_, _, _) => null, db: db);
      addTearDown(c.dispose);

      expect(c.read(focusPillProvider).hasValue, isFalse);
    });

    test(
      '2. resolve: camera over seeded region → name=Grebenhain, '
      'percentLabel=26,4 %',
      () async {
        final region = _grebenhainRegion();
        // zoom=14 → fallbackLevelsFrom(14)=[9,8,6,4,2]; level 9 null → 8 wins
        final c = _makeContainer(
          resolver: (_, _, level) => level == 8 ? region : null,
          db: db,
        );
        addTearDown(c.dispose);

        await _pushCamera(c);

        final s = c.read(focusPillProvider);
        expect(s.name, 'Grebenhain');
        expect(s.percentLabel, '26,4 %');
      },
    );

    test(
      '3. fallback chain: level 9 null, level 8 returns region',
      () async {
        final region = _grebenhainRegion();
        final c = _makeContainer(
          // zoom=14 → fallbackLevelsFrom(14)=[9,8,6,4,2]
          // level 9 → null, level 8 → region
          resolver: (_, _, level) => level == 8 ? region : null,
          db: db,
        );
        addTearDown(c.dispose);

        await _pushCamera(c);

        expect(c.read(focusPillProvider).name, 'Grebenhain');
      },
    );

    test(
      '4. outside Germany: all levels null → pill shows "—" (not a stale '
      'region)',
      () async {
        final region = _grebenhainRegion();
        final c = _makeContainer(
          resolver: (lat, _, level) {
            // Grebenhain area (lat > 50): level 8 resolves. Elsewhere (0,0):
            // ALL levels null, including level 4 → genuinely outside Germany.
            if (lat > 50) return level == 8 ? region : null;
            return null;
          },
          db: db,
        );
        addTearDown(c.dispose);

        // First: over Grebenhain → resolves to the region.
        await _pushCamera(c);
        expect(c.read(focusPillProvider).name, 'Grebenhain');

        // Second: pan to 0,0 (all levels null incl. L4) → outside Germany.
        // New behavior (2026-07-11): show neutral "—", do NOT freeze on the
        // last region.
        await _pushNoRegionCamera(c);
        final s = c.read(focusPillProvider);
        expect(
          s.name,
          '—',
          reason: 'Outside all German polygons → neutral placeholder',
        );
        expect(s.percentLabel, isNull);
      },
    );

    test(
      '5. over Germany at country zoom (chain is [2] only, L4 probe hits) → '
      'pill shows "Deutschland"',
      () async {
        final region = _grebenhainRegion();
        final c = _makeContainer(
          // Region resolves ONLY at level 4. At country zoom (zoom<6),
          // fallbackLevelsFrom = [2]; the loop skips level 2 and finds
          // nothing, so the explicit level-4 "are we over Germany?" probe
          // runs and hits → Deutschland.
          resolver: (_, _, level) => level == 4 ? region : null,
          db: db,
        );
        addTearDown(c.dispose);

        // Country-zoom camera (zoom 4) anywhere; only the L4 probe matters.
        c.read(focusPillProvider);
        c.read(liveCameraProvider.notifier).update(
              const CameraPosition(target: LatLng(51, 10), zoom: 4),
            );
        await Future<void>.delayed(const Duration(milliseconds: 400));

        final s = c.read(focusPillProvider);
        expect(s.name, 'Deutschland');
        expect(s.percentLabel, isNull);
      },
    );

    test(
      '6. no cache row → percentLabel is null (region exists, no coverage)',
      () async {
        final region = _grebenhainRegion();
        // DB does NOT have a row for this region (use a fresh empty db)
        final emptyDb = AppDatabase(NativeDatabase.memory());
        addTearDown(emptyDb.close);

        final c = _makeContainer(
          resolver: (_, _, level) => level == 8 ? region : null,
          db: emptyDb,
        );
        addTearDown(c.dispose);

        await _pushCamera(c);

        final s = c.read(focusPillProvider);
        expect(s.name, 'Grebenhain');
        expect(
          s.percentLabel,
          isNull,
          reason: 'No cache row → percentLabel null → widget shows —%',
        );
      },
    );

    test(
      '7. recording: live fix resolves the SMALLEST region (finest-first), '
      'independent of camera zoom',
      () async {
        final region = _grebenhainRegion();
        // Track which levels regionAt was probed at, in order.
        final probedLevels = <int>[];
        // Single-subscription (NOT broadcast): buffers the fix until the
        // StreamProvider subscribes, so adding it synchronously after init
        // can't be dropped before subscription.
        final fixes = StreamController<LiveFixSample>();
        addTearDown(fixes.close);

        final c = _makeContainer(
          resolver: (_, _, level) {
            probedLevels.add(level);
            // Region resolves at the finest level (10) — a coarser camera-zoom
            // chain would have skipped straight past it.
            return level == 10 ? region : null;
          },
          db: db,
          tracking: _recording(),
          fixStream: fixes.stream,
        );
        addTearDown(c.dispose);

        // Keep the notifier alive AND eagerly subscribe liveFixProvider by
        // listening (a bare read can settle before the StreamProvider wires its
        // subscription). Let that subscription establish before adding a fix.
        c
          ..listen(focusPillProvider, (_, _) {})
          ..listen(liveFixProvider, (_, _) {});
        await Future<void>.delayed(Duration.zero);
        // Even with a country-zoom camera (zoom 4), the recording path must
        // ignore the camera and resolve from the fix, finest-level-first.
        c.read(liveCameraProvider.notifier).update(
              const CameraPosition(target: LatLng(51, 10), zoom: 4),
            );

        fixes.add(
          LiveFixSample(ts: DateTime(2026, 7, 21), lat: 50.51, lon: 9.385),
        );
        await Future<void>.delayed(const Duration(milliseconds: 400));

        final s = c.read(focusPillProvider);
        expect(s.name, 'Grebenhain');
        // Finest-first: level 10 was probed before any coarser level.
        expect(probedLevels.first, 10);
      },
    );

    test(
      '8. recording: camera pan does NOT override the fix-driven region',
      () async {
        final region = _grebenhainRegion();
        final fixes = StreamController<LiveFixSample>();
        addTearDown(fixes.close);

        final c = _makeContainer(
          // Region resolves at level 10 for the Grebenhain area (lat > 50);
          // anywhere else returns null at every level.
          resolver: (lat, _, level) {
            if (lat > 50 && level == 10) return region;
            return null;
          },
          db: db,
          tracking: _recording(),
          fixStream: fixes.stream,
        );
        addTearDown(c.dispose);

        c
          ..listen(focusPillProvider, (_, _) {})
          ..listen(liveFixProvider, (_, _) {});
        await Future<void>.delayed(Duration.zero);

        // Live fix over Grebenhain → pill shows Grebenhain.
        fixes.add(
          LiveFixSample(ts: DateTime(2026, 7, 21), lat: 50.51, lon: 9.385),
        );
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(c.read(focusPillProvider).name, 'Grebenhain');

        // A camera move to (0,0) while recording MUST be suppressed — the pill
        // stays on the fix-driven region rather than flipping to "—".
        c.read(liveCameraProvider.notifier).update(
              const CameraPosition(target: LatLng(0, 0), zoom: 14),
            );
        await Future<void>.delayed(const Duration(milliseconds: 400));

        expect(
          c.read(focusPillProvider).name,
          'Grebenhain',
          reason: 'Recording suppresses the camera driver',
        );
      },
    );
  });
}
