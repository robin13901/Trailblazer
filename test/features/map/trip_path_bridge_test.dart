// Trailblazer trip-path overlay:
// Widget tests for TripPathBridge via a recording-fake TripOverlayApplier.
//
// The fake records addMatchedIntervalLayers / removeTripOverlay calls
// regardless of controller null-ness (mapControllerProvider → null — no live
// MapLibre view in tests). tripDetailDataProvider is overridden with a canned
// TripDetailData so no DB / network is needed.
//
// Overrides:
//   - tripOverlayApplierProvider → _FakeTripOverlayApplier (records calls)
//   - mapControllerProvider → null
//   - tripDetailDataProvider(id) → canned data
//   - selectedTripProvider / mapStyleLoadedTickProvider driven by the tests

import 'package:auto_explore/features/map/presentation/providers/map_controller_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_style_loaded_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/selected_trip_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/trip_path_bridge.dart';
import 'package:auto_explore/features/trips/domain/trip_list_item.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:auto_explore/features/trips/presentation/providers/trip_path_data_provider.dart';
import 'package:auto_explore/features/trips/presentation/widgets/trip_overlay_layers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

sealed class _Call {}

final class _AddMatched extends _Call {
  _AddMatched(this.tripId, this.color, this.segmentCount);
  final int tripId;
  final Color color;
  final int segmentCount;
}

final class _Remove extends _Call {
  _Remove(this.tripId);
  final int tripId;
}

class _FakeTripOverlayApplier implements TripOverlayApplier {
  final List<_Call> calls = [];

  @override
  Future<void> addRawPolyline(
    MapLibreMapController? controller, {
    required int tripId,
    required List<LatLng> polyline,
    required Color color,
  }) async {}

  @override
  Future<void> addMatchedIntervalLayers(
    MapLibreMapController? controller, {
    required int tripId,
    required List<List<LatLng>> matchedSegments,
    required Color color,
  }) async {
    calls.add(_AddMatched(tripId, color, matchedSegments.length));
  }

  @override
  Future<void> removeTripOverlay(
    MapLibreMapController? controller,
    int tripId,
  ) async {
    calls.add(_Remove(tripId));
  }
}

class _NullMapControllerNotifier extends MapControllerNotifier {
  @override
  MapLibreMapController? build() => null;
}

TripListItem _item(int id) => TripListItem(
      id: id,
      status: TripStatus.confirmed,
      startedAt: DateTime(2026, 7, 9, 8),
      endedAt: DateTime(2026, 7, 9, 8, 42),
      distanceMeters: 28400,
      durationSeconds: 42 * 60,
      startLat: 49.79,
      startLon: 9.18,
      endLat: 49.81,
      endLon: 9.22,
      intervalCount: 1,
    );

TripDetailData _data(int id) => TripDetailData(
      item: _item(id),
      rawPolyline: const [LatLng(49.79, 9.18), LatLng(49.81, 9.22)],
      matchedSegments: const [
        [LatLng(49.79, 9.18), LatLng(49.80, 9.20)],
      ],
      bounds: LatLngBounds(
        southwest: const LatLng(49.79, 9.18),
        northeast: const LatLng(49.81, 9.22),
      ),
      matchedWayCount: 1,
      matchedFraction: 0.5,
      offline: false,
    );

Future<_FakeTripOverlayApplier> _pump(
  WidgetTester tester, {
  required Brightness brightness,
  int tripId = 7,
}) async {
  final fake = _FakeTripOverlayApplier();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripOverlayApplierProvider.overrideWithValue(fake),
        mapControllerProvider.overrideWith(_NullMapControllerNotifier.new),
        tripDetailDataProvider(tripId).overrideWith((ref) async => _data(tripId)),
      ],
      child: MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: const Scaffold(body: TripPathBridge()),
      ),
    ),
  );
  return fake;
}

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(
      tester.element(find.byType(TripPathBridge)),
    );

void main() {
  group('TripPathBridge', () {
    testWidgets('renders headless (SizedBox.shrink)', (tester) async {
      await _pump(tester, brightness: Brightness.dark);
      expect(
        find.descendant(
          of: find.byType(TripPathBridge),
          matching: find.byType(SizedBox),
        ),
        findsOneWidget,
      );
    });

    testWidgets('show → addMatchedIntervalLayers with dark turquoise',
        (tester) async {
      final fake = await _pump(tester, brightness: Brightness.dark);
      _container(tester).read(selectedTripProvider.notifier).show(7);
      await tester.pumpAndSettle();

      final adds = fake.calls.whereType<_AddMatched>().toList();
      expect(adds, hasLength(1));
      expect(adds.single.tripId, 7);
      expect(adds.single.color, kTripPathColorDark);
      expect(adds.single.segmentCount, 1);
    });

    testWidgets('show → light turquoise in light mode', (tester) async {
      final fake = await _pump(tester, brightness: Brightness.light);
      _container(tester).read(selectedTripProvider.notifier).show(7);
      await tester.pumpAndSettle();

      final adds = fake.calls.whereType<_AddMatched>().toList();
      expect(adds, hasLength(1));
      expect(adds.single.color, kTripPathColorLight);
    });

    testWidgets('clear → removeTripOverlay for the shown trip', (tester) async {
      final fake = await _pump(tester, brightness: Brightness.dark);
      final notifier = _container(tester).read(selectedTripProvider.notifier)
        ..show(7);
      await tester.pumpAndSettle();
      notifier.clear();
      await tester.pumpAndSettle();

      expect(
        fake.calls.whereType<_Remove>().where((c) => c.tripId == 7),
        isNotEmpty,
      );
    });

    testWidgets('style-load tick re-adds while a trip is shown (Pitfall 1)',
        (tester) async {
      final fake = await _pump(tester, brightness: Brightness.dark);
      final container = _container(tester);
      container.read(selectedTripProvider.notifier).show(7);
      await tester.pumpAndSettle();
      final before = fake.calls.whereType<_AddMatched>().length;

      container.read(mapStyleLoadedTickProvider.notifier).bump();
      await tester.pumpAndSettle();

      expect(
        fake.calls.whereType<_AddMatched>().length,
        greaterThan(before),
        reason: 'trip line re-added after style reload',
      );
    });

    testWidgets('style-load tick does NOT add when no trip is selected',
        (tester) async {
      final fake = await _pump(tester, brightness: Brightness.dark);
      _container(tester).read(mapStyleLoadedTickProvider.notifier).bump();
      await tester.pumpAndSettle();
      expect(fake.calls.whereType<_AddMatched>(), isEmpty);
    });
  });
}
