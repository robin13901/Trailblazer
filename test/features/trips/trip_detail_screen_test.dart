// Trailblazer Phase 6, Plan 06-05 Task 3 tests:
// TripDetailScreen + loadTripDetailData.
//
// Two layers of coverage:
//   1. loadTripDetailData (pure) — fail-matched, non-fail (raw + matched
//      segments + matched%), and the two offline fallbacks (Issue 6). Uses an
//      in-memory Drift DB + a fake WayCandidateSource.
//   2. TripDetailScreen (widget) — delete → dialog → discardTrip + pop; the
//      fail-matched + offline banners; the stat strip; and the style-swap
//      re-apply (Pitfall Q1). The overlay applier is overridden with a
//      recording fake so the raw/matched adds are observable without a live
//      MapLibre platform view.

import 'dart:async';

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/app_database_providers.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/features/map/presentation/providers/location_permission_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/map_widget.dart';
import 'package:auto_explore/features/matching/data/matching_providers.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/data/trips_dao_inbox_queries.dart';
import 'package:auto_explore/features/trips/data/trips_repository_inbox_extensions.dart';
import 'package:auto_explore/features/trips/domain/trip_list_item.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:auto_explore/features/trips/presentation/trip_detail_screen.dart';
import 'package:auto_explore/features/trips/presentation/widgets/trip_overlay_layers.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../helpers/fake_maplibre_platform.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

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
  }) async {
    if (throwError) {
      throw const NetworkError('offline', statusCode: 0);
    }
    return ways;
  }
}

/// Records raw/matched adds so tests can assert which overlay branch ran.
class _RecordingApplier implements TripOverlayApplier {
  final List<String> log = [];

  @override
  Future<void> addRawPolyline(
    MapLibreMapController? controller, {
    required int tripId,
    required List<LatLng> polyline,
    required Color color,
  }) async {
    log.add('raw');
  }

  @override
  Future<void> addMatchedIntervalLayers(
    MapLibreMapController? controller, {
    required int tripId,
    required List<List<LatLng>> matchedSegments,
    required Color color,
  }) async {
    log.add('matched');
  }

  @override
  Future<void> removeTripOverlay(
    MapLibreMapController? controller,
    int tripId,
  ) async {
    log.add('remove');
  }
}

/// Records discard calls; returns a canned Result.
class _FakeInboxRepo implements TripsInboxRepository {
  _FakeInboxRepo();

  final Result<void> discardResult = const Ok(null);
  int? discardedId;

  @override
  Future<Result<void>> confirmTrip(int tripId) async => const Ok(null);

  @override
  Future<Result<void>> discardTrip(int tripId) async {
    discardedId = tripId;
    return discardResult;
  }

  @override
  Stream<List<TripListItem>> watchInboxItems() => const Stream.empty();

  @override
  Stream<List<TripListItem>> watchHistoryItems() => const Stream.empty();

  @override
  Stream<int> watchInFlightCount() => const Stream.empty();
}

/// Stub location permission notifier — avoids the permission_handler channel.
class _FakeLocationPermissionNotifier extends AsyncNotifier<PermissionStatus>
    implements LocationPermissionNotifier {
  @override
  Future<PermissionStatus> build() async => PermissionStatus.granted;

  @override
  Future<PermissionStatus> requestOnce() async => PermissionStatus.granted;

  @override
  Future<void> refresh() async {}
}

// ---------------------------------------------------------------------------
// DB seeding helpers
// ---------------------------------------------------------------------------

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
  // -------------------------------------------------------------------------
  // loadTripDetailData (pure)
  // -------------------------------------------------------------------------
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

  // -------------------------------------------------------------------------
  // TripDetailScreen (widget)
  // -------------------------------------------------------------------------
  group('TripDetailScreen', () {
    late AppDatabase db;

    setUp(() {
      final prev = MapLibrePlatform.createInstance;
      addTearDown(() => MapLibrePlatform.createInstance = prev);
      MapLibrePlatform.createInstance = FakeMapLibrePlatform.new;
    });

    tearDown(() async {
      await db.close();
    });

    /// Build the screen inside a router (so context.pop works) with the DB +
    /// way source + overlay applier overridden.
    Future<int> pumpScreen(
      WidgetTester tester, {
      required TripStatus status,
      required List<WayCandidate> ways,
      bool throwError = false,
      List<({int wayId, double start, double end})> intervals = const [],
      TripOverlayApplier? applier,
      TripsInboxRepository? repo,
    }) async {
      db = AppDatabase(NativeDatabase.memory());
      await db.customSelect('SELECT 1').getSingle();
      final tripId = await _seedTrip(db, status: status);
      await _seedPoints(db, tripId);
      for (final iv in intervals) {
        await _seedInterval(
          db,
          tripId,
          wayId: iv.wayId,
          startMeters: iv.start,
          endMeters: iv.end,
        );
      }

      final router = GoRouter(
        initialLocation: '/home',
        routes: [
          GoRoute(
            path: '/home',
            builder: (context, state) => const Scaffold(body: Text('home')),
          ),
          GoRoute(
            path: '/trips/:id',
            builder: (context, state) => TripDetailScreen(
              tripId: int.parse(state.pathParameters['id']!),
            ),
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            wayCandidateSourceProvider.overrideWithValue(
              _FakeWaySource(ways: ways, throwError: throwError),
            ),
            if (applier != null)
              tripOverlayApplierProvider.overrideWithValue(applier),
            if (repo != null)
              tripsInboxRepositoryProvider.overrideWithValue(repo),
            locationPermissionProvider
                .overrideWith(_FakeLocationPermissionNotifier.new),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      // Push the detail on top of /home so context.pop() has a target (mirrors
      // the real app where the card/row pushes /trips/:id onto the shell).
      unawaited(router.push('/trips/$tripId'));
      // Resolve the FutureProvider + post-frame overlay apply, and advance past
      // the page-transition animation so the AppBar action is on-screen.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      return tripId;
    }

    testWidgets(
      'fail-matched: banner shown, matched adder NOT called, raw IS called',
      (tester) async {
        final applier = _RecordingApplier();
        await pumpScreen(
          tester,
          status: TripStatus.matched, // 0 intervals → fail-matched
          ways: const [],
          applier: applier,
        );
        await tester.pump();

        expect(find.textContaining('No roads matched'), findsOneWidget);
        expect(applier.log, contains('raw'));
        expect(applier.log, isNot(contains('matched')));
      },
    );

    testWidgets('non-fail: no banner, both raw + matched adders called',
        (tester) async {
      final applier = _RecordingApplier();
      await pumpScreen(
        tester,
        status: TripStatus.confirmed,
        ways: [_way(1)],
        intervals: const [(wayId: 1, start: 0, end: 50)],
        applier: applier,
      );
      await tester.pump();

      expect(find.textContaining('No roads matched'), findsNothing);
      expect(find.textContaining('unavailable offline'), findsNothing);
      expect(applier.log, contains('raw'));
      expect(applier.log, contains('matched'));
    });

    testWidgets('offline: banner shown, matched NOT called, raw IS called',
        (tester) async {
      final applier = _RecordingApplier();
      await pumpScreen(
        tester,
        status: TripStatus.confirmed,
        ways: const [],
        throwError: true,
        intervals: const [(wayId: 1, start: 0, end: 50)],
        applier: applier,
      );
      await tester.pump();

      expect(find.textContaining('unavailable offline'), findsOneWidget);
      expect(applier.log, contains('raw'));
      expect(applier.log, isNot(contains('matched')));
      // Delete button still present (functional).
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    });

    testWidgets(
      'offline: empty ways while intervals exist → same offline behavior',
      (tester) async {
        final applier = _RecordingApplier();
        await pumpScreen(
          tester,
          status: TripStatus.confirmed,
          ways: const [], // source returns nothing, no throw
          intervals: const [(wayId: 1, start: 0, end: 50)],
          applier: applier,
        );
        await tester.pump();

        expect(find.textContaining('unavailable offline'), findsOneWidget);
        expect(applier.log, isNot(contains('matched')));
      },
    );

    testWidgets('stat strip renders duration/distance/matched%',
        (tester) async {
      await pumpScreen(
        tester,
        status: TripStatus.confirmed,
        ways: [_way(1)],
        intervals: const [(wayId: 1, start: 0, end: 50)],
      );
      await tester.pump();

      expect(find.textContaining('Duration: 42 min'), findsOneWidget);
      expect(find.textContaining('Distance: 28.4 km'), findsOneWidget);
      expect(find.textContaining('Matched:'), findsOneWidget);
    });

    testWidgets('delete → dialog → discardTrip(tripId) + pop', (tester) async {
      final repo = _FakeInboxRepo();
      final tripId = await pumpScreen(
        tester,
        status: TripStatus.confirmed,
        ways: [_way(1)],
        intervals: const [(wayId: 1, start: 0, end: 50)],
        repo: repo,
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // Confirm in the dialog.
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, 'Discard'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(repo.discardedId, tripId);
      // Popped back to /home.
      expect(find.text('home'), findsOneWidget);
    });

    testWidgets('style-swap re-triggers the overlay apply routine',
        (tester) async {
      final applier = _RecordingApplier();
      await pumpScreen(
        tester,
        status: TripStatus.confirmed,
        ways: [_way(1)],
        intervals: const [(wayId: 1, start: 0, end: 50)],
        applier: applier,
      );
      await tester.pump();

      final callsAfterInitial = applier.log.length;
      expect(callsAfterInitial, greaterThan(0));

      // MapWidget.onStyleLoaded fires again on a brightness-driven style swap
      // (Pitfall Q1). Grab the wired callback and invoke it directly to prove
      // the overlay is re-applied (a fresh 'remove' + 'raw' + 'matched').
      final mapWidget = tester.widget<MapWidget>(find.byType(MapWidget));
      expect(mapWidget.onStyleLoaded, isNotNull);
      mapWidget.onStyleLoaded!.call();
      await tester.pump();
      await tester.pump();

      expect(applier.log.length, greaterThan(callsAfterInitial));
      expect(applier.log, contains('remove'));
    });
  });
}
