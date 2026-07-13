// Trailblazer Phase 6, Plan 06-05 Task 1 tests:
// TripCard — place names (incl. loop), dormant vehicle chip, Keep/Discard
// repository wiring + thumbnail-cache clearing, and whole-card navigation.

import 'dart:typed_data';

import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/features/trips/data/thumbnail_cache.dart';
import 'package:auto_explore/features/trips/data/thumbnail_providers.dart';
import 'package:auto_explore/features/trips/data/thumbnail_renderer.dart';
import 'package:auto_explore/features/trips/data/trip_place_lookup_providers.dart';
import 'package:auto_explore/features/trips/data/trips_repository_inbox_extensions.dart';
import 'package:auto_explore/features/trips/domain/trip_list_item.dart';
import 'package:auto_explore/features/trips/domain/trip_place_lookup.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:auto_explore/features/trips/presentation/widgets/trip_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// Records confirm/discard calls; returns a canned Result.
class _FakeInboxRepo implements TripsInboxRepository {
  _FakeInboxRepo({this.discardResult = const Ok(null)});

  final Result<void> confirmResult = const Ok(null);
  final Result<void> discardResult;
  final List<String> log = [];
  int? confirmedId;
  int? discardedId;

  @override
  Future<Result<void>> confirmTrip(int tripId) async {
    log.add('confirmTrip');
    confirmedId = tripId;
    return confirmResult;
  }

  @override
  Future<Result<void>> discardTrip(int tripId) async {
    log.add('discardTrip');
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

/// Records `delete` calls; never touches disk.
class _RecordingThumbnailCache extends ThumbnailCache {
  final List<int> deleted = [];

  @override
  ThumbnailCacheState build() => const ThumbnailCacheState.empty();

  @override
  Future<void> delete(int tripId) async {
    deleted.add(tripId);
  }
}

/// Renderer whose fallback returns empty bytes — keeps TripThumbnail on its
/// placeholder branch (no image decode, no cache store).
class _NoopRenderer extends ThumbnailRenderer {
  _NoopRenderer() : super(mapStyleUrl: '');

  @override
  Future<Uint8List> renderFallback({
    required List<LatLng> polyline,
    required LatLngBounds bbox,
  }) async =>
      Uint8List(0);
}

TripListItem _item({
  int id = 7,
  TripStatus status = TripStatus.matched,
  double? startLat = 49.70,
  double? startLon = 9.26,
  double? endLat = 49.97,
  double? endLon = 9.15,
  int intervalCount = 5,
}) {
  return TripListItem(
    id: id,
    status: status,
    startedAt: DateTime(2026, 7, 8, 14, 32),
    endedAt: DateTime(2026, 7, 8, 15, 14),
    distanceMeters: 28400,
    durationSeconds: 42 * 60,
    startLat: startLat,
    startLon: startLon,
    endLat: endLat,
    endLon: endLon,
    intervalCount: intervalCount,
    bboxMinLat: 49.70,
    bboxMinLon: 9.15,
    bboxMaxLat: 49.97,
    bboxMaxLon: 9.26,
  );
}

void main() {
  late _FakeInboxRepo repo;
  late _RecordingThumbnailCache cache;

  setUp(() {
    repo = _FakeInboxRepo();
    cache = _RecordingThumbnailCache();
  });

  // Return type is Riverpod's `Override` list — not cleanly nameable from
  // the public export surface, so the type is left inferred.
  // ignore: always_declare_return_types
  overrides({
    TripPlaces places =
        const TripPlaces(startName: 'Miltenberg', endName: 'Aschaffenburg'),
  }) =>
      [
        tripsInboxRepositoryProvider.overrideWithValue(repo),
        thumbnailCacheProvider.overrideWith(() => cache),
        thumbnailRendererProvider.overrideWithValue(_NoopRenderer()),
        tripPlacesProvider.overrideWith((ref, coords) async => places),
      ];

  Future<void> pumpCard(
    WidgetTester tester,
    TripListItem item, {
    TripPlaces? places,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides:
            places == null ? overrides() : overrides(places: places),
        child: MaterialApp(
          home: Scaffold(body: TripCard(item: item)),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('renders start → end place names', (tester) async {
    await pumpCard(tester, _item());
    await tester.pump();
    expect(find.text('Miltenberg → Aschaffenburg'), findsOneWidget);
  });

  testWidgets('loop trip (start == end) shows a single name', (tester) async {
    await pumpCard(
      tester,
      _item(),
      places: const TripPlaces(startName: 'Miltenberg', endName: 'Miltenberg'),
    );
    await tester.pump();
    expect(find.text('Miltenberg'), findsOneWidget);
    expect(find.textContaining('→'), findsNothing);
  });

  testWidgets('Keep tap invokes confirmTrip(tripId)', (tester) async {
    await pumpCard(tester, _item(id: 42));
    await tester.tap(find.text('Keep'));
    await tester.pump();
    expect(repo.confirmedId, 42);
    expect(repo.log, contains('confirmTrip'));
  });

  testWidgets(
    'Discard confirm → discardTrip then thumbnailCache.delete',
    (tester) async {
      await pumpCard(tester, _item(id: 42));
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      // Modal is up — confirm it (the dialog's Discard button, not the card's).
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, 'Discard'),
        ),
      );
      await tester.pumpAndSettle();
      expect(repo.discardedId, 42);
      expect(cache.deleted, contains(42));
    },
  );

  testWidgets('Discard cancel → no repo call, no cache delete', (tester) async {
    await pumpCard(tester, _item(id: 42));
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(repo.discardedId, isNull);
    expect(cache.deleted, isEmpty);
  });

  testWidgets('Discard error → thumbnail NOT cleared, snackbar shown', (
    tester,
  ) async {
    repo = _FakeInboxRepo(discardResult: const Err(UnknownError('boom')));
    await pumpCard(tester, _item(id: 42));
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, 'Discard'),
      ),
    );
    await tester.pumpAndSettle();
    expect(repo.discardedId, 42);
    expect(cache.deleted, isEmpty);
    expect(find.textContaining('boom'), findsOneWidget);
  });

  testWidgets('whole-card tap pushes /trips/:id', (tester) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(body: TripCard(item: _item(id: 99))),
        ),
        GoRoute(
          path: '/trips/:id',
          builder: (context, state) =>
              Scaffold(body: Text('detail ${state.pathParameters['id']}')),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    // Tap the card body (title text region) — avoids the buttons.
    await tester.tap(find.text('Miltenberg → Aschaffenburg'));
    await tester.pumpAndSettle();
    expect(find.text('detail 99'), findsOneWidget);
  });
}
