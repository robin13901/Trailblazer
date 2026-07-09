// Trailblazer Phase 6, Plan 06-05 Task 1 tests:
// HistoryRow — status pill branches (confirmed/fail-matched/pending/
// pendingRoadData) + row-tap navigation.

import 'package:auto_explore/core/theme/app_theme.dart';
import 'package:auto_explore/features/trips/data/trip_place_lookup_providers.dart';
import 'package:auto_explore/features/trips/domain/trip_list_item.dart';
import 'package:auto_explore/features/trips/domain/trip_place_lookup.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:auto_explore/features/trips/presentation/widgets/history_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

TripListItem _item({
  required TripStatus status,
  int id = 3,
  int intervalCount = 5,
}) {
  return TripListItem(
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
    intervalCount: intervalCount,
  );
}

// Override list type is Riverpod-internal and not cleanly nameable.
// ignore: specify_nonobvious_property_types
final _overrides = [
  tripPlacesProvider.overrideWith(
    (ref, coords) async =>
        const TripPlaces(startName: 'Miltenberg', endName: 'Aschaffenburg'),
  ),
];
Future<void> _pumpRow(WidgetTester tester, TripListItem item) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides,
      child: MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: HistoryRow(item: item)),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('confirmed trip → no status pill', (tester) async {
    await _pumpRow(tester, _item(status: TripStatus.confirmed));
    expect(find.text('No roads matched'), findsNothing);
    expect(find.text('Matching…'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('matched + 0 intervals → "No roads matched" warning chip', (
    tester,
  ) async {
    await _pumpRow(
      tester,
      _item(status: TripStatus.matched, intervalCount: 0),
    );
    expect(find.text('No roads matched'), findsOneWidget);

    // The chip text uses the theme error color.
    final textWidget = tester.widget<Text>(find.text('No roads matched'));
    expect(textWidget.style?.color, AppTheme.light.colorScheme.error);
  });

  testWidgets('pending trip → "Matching…" + spinner', (tester) async {
    await _pumpRow(tester, _item(status: TripStatus.pending, intervalCount: 0));
    expect(find.text('Matching…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('pendingRoadData trip → same as pending', (tester) async {
    await _pumpRow(
      tester,
      _item(status: TripStatus.pendingRoadData, intervalCount: 0),
    );
    expect(find.text('Matching…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('row tap pushes /trips/:id', (tester) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: HistoryRow(item: _item(id: 77, status: TripStatus.confirmed)),
          ),
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
        overrides: _overrides,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Miltenberg → Aschaffenburg'));
    await tester.pumpAndSettle();
    expect(find.text('detail 77'), findsOneWidget);
  });
}
