// Trailblazer trips: widget tests for the trip detail bottom sheet
// (showTripDetailSheet) — stats content + "Auf Karte anzeigen" wiring.

import 'package:auto_explore/features/map/presentation/providers/selected_trip_provider.dart';
import 'package:auto_explore/features/trips/data/trip_place_lookup_providers.dart';
import 'package:auto_explore/features/trips/domain/trip_list_item.dart';
import 'package:auto_explore/features/trips/domain/trip_place_lookup.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:auto_explore/features/trips/presentation/widgets/trip_detail_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

TripListItem _item({int id = 7}) => TripListItem(
      id: id,
      status: TripStatus.confirmed,
      startedAt: DateTime(2026, 7, 8, 14, 32),
      endedAt: DateTime(2026, 7, 8, 15, 14),
      distanceMeters: 28400,
      durationSeconds: 42 * 60,
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

// Riverpod override list type is not cleanly nameable.
// ignore: specify_nonobvious_property_types
final _overrides = [
  tripPlacesProvider.overrideWith(
    (ref, coords) async =>
        const TripPlaces(startName: 'Miltenberg', endName: 'Aschaffenburg'),
  ),
];

/// Pumps a button that opens the sheet, taps it, and settles.
Future<ProviderContainer> _openSheet(
  WidgetTester tester,
  TripListItem item,
) async {
  late ProviderContainer container;
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context);
              return TextButton(
                onPressed: () => showTripDetailSheet(context, ref, item),
                child: const Text('open'),
              );
            },
          ),
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('sheet shows duration / distance / avg-speed stats',
      (tester) async {
    await _openSheet(tester, _item());

    expect(find.text('Dauer'), findsOneWidget);
    expect(find.text('42 min'), findsOneWidget);
    expect(find.text('Distanz'), findsOneWidget);
    expect(find.text('28,4 km'), findsOneWidget);
    expect(find.text('Ø-Tempo'), findsOneWidget);
    // 28400 m / 2520 s * 3.6 ≈ 41 km/h.
    expect(find.text('41 km/h'), findsOneWidget);
  });

  testWidgets('sheet shows place-name title + Start/Ziel rows', (tester) async {
    await _openSheet(tester, _item());

    expect(find.text('Miltenberg → Aschaffenburg'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    // "Ziel" sits lower in the scrollable sheet body — scroll it into view.
    await tester.scrollUntilVisible(find.text('Ziel'), 120);
    expect(find.text('Ziel'), findsOneWidget);
  });

  testWidgets('"Auf Karte anzeigen" sets selectedTripProvider to the trip id',
      (tester) async {
    final container = await _openSheet(tester, _item(id: 42));
    expect(container.read(selectedTripProvider), isNull);

    await tester.scrollUntilVisible(find.text('Auf Karte anzeigen'), 120);
    await tester.tap(find.text('Auf Karte anzeigen'));
    await tester.pumpAndSettle();

    expect(container.read(selectedTripProvider), 42);
  });
}
