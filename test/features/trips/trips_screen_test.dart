// Trailblazer Phase 6, Plan 06-05 Task 2 tests:
// TripsScreen — landing-tab resolution, empty states, tab switching,
// MatchingQueuePill visibility, and the no-force-rejump guard.
//
// Thumbnails render purely on the Canvas via `thumbnailRendererProvider`
// (overridden with a no-op here). tripPlaces is stubbed for the card/row
// place names. (Plan 06-07: the offstage-map overlay provider was removed.)

import 'dart:async';
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
import 'package:auto_explore/features/trips/presentation/widgets/trip_card.dart';
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
  required List<TripListItem> inbox,
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
        inboxTripsProvider.overrideWith((ref) => Stream.value(inbox)),
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
  await tester.pump(); // post-frame tab jump
  // Advance past the tab-switch animation so the target tab's lazy body
  // builds. Fixed-duration pumps (not pumpAndSettle) because MatchingQueuePill
  // hosts a never-settling CircularProgressIndicator.
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('2 inbox items → lands on Inbox, 2 TripCards visible', (
    tester,
  ) async {
    await _pump(
      tester,
      inbox: [
        _item(1, TripStatus.matched),
        _item(2, TripStatus.matched),
      ],
      history: const [],
    );
    await tester.pump();
    expect(find.byType(TripCard), findsNWidgets(2));
    // Inbox is the active tab (index 1 after the 2026-07-10 History/Inbox swap).
    final tabView = tester.widget<TabBarView>(find.byType(TabBarView));
    expect(tabView.controller!.index, 1);
  });

  testWidgets('empty inbox + 3 history → lands on History, 3 HistoryRows', (
    tester,
  ) async {
    await _pump(
      tester,
      inbox: const [],
      history: [
        _item(1, TripStatus.confirmed),
        _item(2, TripStatus.confirmed),
        _item(3, TripStatus.confirmed),
      ],
    );
    await tester.pump();
    // History is the default tab (index 0 after the swap).
    final tabView = tester.widget<TabBarView>(find.byType(TabBarView));
    expect(tabView.controller!.index, 0);
    expect(find.byType(HistoryRow), findsNWidgets(3));
  });

  testWidgets('both empty → History default + HistoryEmptyState shown', (
    tester,
  ) async {
    // Documented choice: with no pending trips the landing tab is History
    // (index 0 after the swap), so the History empty state is what shows.
    await _pump(tester, inbox: const [], history: const []);
    await tester.pump();
    final tabView = tester.widget<TabBarView>(find.byType(TabBarView));
    expect(tabView.controller!.index, 0);
    expect(find.byType(HistoryEmptyState), findsOneWidget);
  });

  testWidgets('inFlightCount 3 → MatchingQueuePill visible with copy', (
    tester,
  ) async {
    await _pump(
      tester,
      inbox: [_item(1, TripStatus.matched)],
      history: const [],
      inFlight: 3,
    );
    await tester.pump();
    expect(find.byType(MatchingQueuePill), findsOneWidget);
    expect(find.text('3 trips matching…'), findsOneWidget);
  });

  testWidgets('tab switch Inbox ↔ History works', (tester) async {
    await _pump(
      tester,
      inbox: [_item(1, TripStatus.matched)],
      history: [_item(2, TripStatus.confirmed)],
    );
    await tester.pump();
    // Starts on Inbox.
    expect(find.byType(TripCard), findsOneWidget);
    // Switch to History.
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(find.byType(HistoryRow), findsOneWidget);
    // Back to Inbox.
    await tester.tap(find.text('Inbox'));
    await tester.pumpAndSettle();
    expect(find.byType(TripCard), findsOneWidget);
  });

  testWidgets('later inbox update does NOT force a re-jump', (tester) async {
    // Drive the inbox stream: first empty (→ lands History), then non-empty.
    final controller = StreamController<List<TripListItem>>();
    addTearDown(controller.close);
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (context, state) => const TripsScreen()),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inboxTripsProvider.overrideWith((ref) => controller.stream),
          historyTripsProvider.overrideWith((ref) => Stream.value(const [])),
          inFlightCountProvider.overrideWith((ref) => Stream.value(0)),
          thumbnailCacheProvider.overrideWith(_NoopThumbnailCache.new),
          thumbnailRendererProvider.overrideWithValue(_NoopRenderer()),
          tripPlacesProvider.overrideWith(
            (ref, coords) async => const TripPlaces(
              startName: 'Aschaffenburg',
              endName: 'Miltenberg',
            ),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    // First snapshot: empty inbox → lands on History (index 0 after swap).
    controller.add(const []);
    await tester.pump();
    await tester.pump();
    final tabView = tester.widget<TabBarView>(find.byType(TabBarView));
    expect(tabView.controller!.index, 0);

    // Later: inbox gains an item. Landing was already resolved → no re-jump.
    controller.add([_item(1, TripStatus.matched)]);
    await tester.pump();
    await tester.pump();
    expect(tabView.controller!.index, 0);
  });
}
