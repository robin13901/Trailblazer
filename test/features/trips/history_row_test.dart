// Trailblazer Phase 6, Plan 06-05 Task 1 tests:
// HistoryRow — status pill branches (confirmed/fail-matched/pending/
// pendingRoadData) + row-tap navigation.

import 'package:auto_explore/core/theme/app_theme.dart';
import 'package:auto_explore/features/matching/data/match_progress_provider.dart';
import 'package:auto_explore/features/trips/data/trip_place_lookup_providers.dart';
import 'package:auto_explore/features/trips/domain/trip_list_item.dart';
import 'package:auto_explore/features/trips/domain/trip_place_lookup.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:auto_explore/features/trips/presentation/widgets/history_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
Future<void> _pumpRow(
  WidgetTester tester,
  TripListItem item, {
  Map<int, double>? progress,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ..._overrides,
        if (progress != null)
          matchProgressProvider.overrideWith(
            () => _FixedProgressNotifier(progress),
          ),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: HistoryRow(item: item)),
      ),
    ),
  );
  await tester.pump();
}

/// Test double seeding [matchProgressProvider] with a fixed map.
class _FixedProgressNotifier extends MatchProgressNotifier {
  _FixedProgressNotifier(this._initial);

  final Map<int, double> _initial;

  @override
  Map<int, double> build() => _initial;
}

void main() {
  testWidgets('confirmed trip → no status pill', (tester) async {
    await _pumpRow(tester, _item(status: TripStatus.confirmed));
    expect(find.text('Keine Straßen abgeglichen'), findsNothing);
    expect(find.text('Wird abgeglichen …'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('matched + 0 intervals → "No roads matched" warning chip', (
    tester,
  ) async {
    await _pumpRow(
      tester,
      _item(status: TripStatus.matched, intervalCount: 0),
    );
    expect(find.text('Keine Straßen abgeglichen'), findsOneWidget);

    // The chip text uses the theme error color.
    final textWidget = tester.widget<Text>(find.text('Keine Straßen abgeglichen'));
    expect(textWidget.style?.color, AppTheme.light.colorScheme.error);
  });

  testWidgets('pending trip → "Matching…" + spinner', (tester) async {
    await _pumpRow(tester, _item(status: TripStatus.pending, intervalCount: 0));
    expect(find.text('Wird abgeglichen …'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('pendingRoadData trip → same as pending', (tester) async {
    await _pumpRow(
      tester,
      _item(status: TripStatus.pendingRoadData, intervalCount: 0),
    );
    expect(find.text('Wird abgeglichen …'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('in-flight with progress → determinate % + value', (
    tester,
  ) async {
    await _pumpRow(
      tester,
      _item(id: 42, status: TripStatus.pending, intervalCount: 0),
      progress: const {42: 0.37},
    );

    // Real percentage rendered (37% = round(0.37 * 100)).
    expect(find.text('Wird abgeglichen … 37 %'), findsOneWidget);
    expect(find.text('Wird abgeglichen …'), findsNothing);

    // The spinner is determinate: value is set.
    final indicator = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(indicator.value, closeTo(0.37, 1e-9));
  });

  testWidgets('in-flight without progress for this trip → indeterminate', (
    tester,
  ) async {
    // Progress map holds a DIFFERENT trip; this row falls back to spinner.
    await _pumpRow(
      tester,
      _item(id: 42, status: TripStatus.pending, intervalCount: 0),
      progress: const {7: 0.5},
    );

    expect(find.text('Wird abgeglichen …'), findsOneWidget);
    final indicator = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(indicator.value, isNull, reason: 'indeterminate spinner');
  });

  testWidgets('row tap opens the trip detail sheet', (tester) async {
    await _pumpRow(tester, _item(id: 77, status: TripStatus.confirmed));
    await tester.tap(find.text('Miltenberg → Aschaffenburg'));
    await tester.pumpAndSettle();
    // The sheet surfaces the stats (top of the sheet, above the fold).
    expect(find.text('Dauer'), findsOneWidget);
    expect(find.text('Ø-Tempo'), findsOneWidget);
  });
}
