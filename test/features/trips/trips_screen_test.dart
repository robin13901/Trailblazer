// Trailblazer — TripsScreen tests (history-only, 2026-07-13).
//
// The Inbox/History sub-tabs were removed; the screen now shows the trip
// history list directly with the MatchingQueuePill above it.
//
// Thumbnails render purely on the Canvas via `thumbnailRendererProvider`
// (overridden with a no-op here). tripPlaces is stubbed for the row place
// names.

import 'dart:typed_data';

import 'package:auto_explore/features/trips/data/thumbnail_cache.dart';
import 'package:auto_explore/features/trips/data/thumbnail_providers.dart';
import 'package:auto_explore/features/trips/data/thumbnail_renderer.dart';
import 'package:auto_explore/features/trips/data/trip_place_lookup_providers.dart';
import 'package:auto_explore/features/trips/domain/trip_list_item.dart';
import 'package:auto_explore/features/trips/domain/trip_place_lookup.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:auto_explore/features/trips/presentation/providers/inbox_providers.dart';
import 'package:auto_explore/features/trips/presentation/trips_screen.dart';
import 'package:auto_explore/features/trips/presentation/widgets/history_empty_state.dart';
import 'package:auto_explore/features/trips/presentation/widgets/history_row.dart';
import 'package:auto_explore/features/trips/presentation/widgets/matching_queue_pill.dart';
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
  }) async =>
      Uint8List(0);
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
          (ref, coords) async =>
              const TripPlaces(startName: 'Aschaffenburg', endName: 'Miltenberg'),
        ),
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
}
