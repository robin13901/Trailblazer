// Trailblazer Phase 8, Plan 08-05 (Wave 2):
// regions_screen_test.dart — widget smoke test for RegionsScreen.
//
// Validates:
//   - Region cards render (names + % labels visible).
//   - Search field exists.
//   - Typing in the search field filters the visible cards.
//   - Empty-state messages appear correctly.
//
// Modal sheet is NOT opened (sheet coverage is separate; keep smoke test minimal).
//
// ProviderScope overrides: regionBrowserProvider returns a fixed list.
// LiquidGlassSettings.platformBlurEnabled = false (no PlatformView in tests).

import 'package:auto_explore/core/theme/liquid_glass_settings.dart';
import 'package:auto_explore/features/regions/domain/region_coverage.dart';
import 'package:auto_explore/features/regions/presentation/providers/region_browser_provider.dart';
import 'package:auto_explore/features/regions/presentation/regions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Test data
// ---------------------------------------------------------------------------

const _kRegions = [
  RegionCoverage(
    osmId: 1001,
    adminLevel: 8,
    name: 'Kleinheubach',
    drivenLengthM: 600,
    totalLengthM: 1000,
  ),
  RegionCoverage(
    osmId: 1002,
    adminLevel: 10,
    name: 'Ortsteil Süd',
    drivenLengthM: 200,
    totalLengthM: 1000,
  ),
  RegionCoverage(
    osmId: 1003,
    adminLevel: 4,
    name: 'Bayern',
    drivenLengthM: 50,
    totalLengthM: 1000,
  ),
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Widget _buildApp({required List<RegionCoverage> regions}) {
  return ProviderScope(
    overrides: [
      regionBrowserProvider.overrideWith(
        (_) => Stream.value(List<RegionCoverage>.from(regions)),
      ),
    ],
    child: const MaterialApp(home: RegionsScreen()),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(() {
    // Disable LiquidGlass blur — no PlatformView available in widget tests.
    LiquidGlassSettings.platformBlurEnabled = false;
  });

  testWidgets('renders region cards with name and percent label',
      (tester) async {
    await tester.pumpWidget(_buildApp(regions: _kRegions));
    await tester.pumpAndSettle();

    // All three region names visible.
    expect(find.text('Kleinheubach'), findsOneWidget);
    expect(find.text('Ortsteil Süd'), findsOneWidget);
    expect(find.text('Bayern'), findsOneWidget);

    // % labels visible (one decimal, with % suffix).
    expect(find.text('60,0 %'), findsOneWidget);
    expect(find.text('20,0 %'), findsOneWidget);
    expect(find.text('5,0 %'), findsOneWidget);

    // Search field present.
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('typing in search field filters cards', (tester) async {
    await tester.pumpWidget(_buildApp(regions: _kRegions));
    await tester.pumpAndSettle();

    // All three visible before typing.
    expect(find.text('Kleinheubach'), findsOneWidget);
    expect(find.text('Bayern'), findsOneWidget);

    // 'klein' only matches 'Kleinheubach'.
    await tester.enterText(find.byType(TextField), 'klein');
    await tester.pumpAndSettle();

    expect(find.text('Kleinheubach'), findsOneWidget);
    expect(find.text('Bayern'), findsNothing);
    expect(find.text('Ortsteil Süd'), findsNothing);

    // Clear → all three visible again.
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();

    expect(find.text('Kleinheubach'), findsOneWidget);
    expect(find.text('Bayern'), findsOneWidget);
    expect(find.text('Ortsteil Süd'), findsOneWidget);
  });

  testWidgets('empty state shows message when no regions', (tester) async {
    await tester.pumpWidget(_buildApp(regions: const []));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Noch keine befahrenen Regionen'),
      findsOneWidget,
    );
  });

  testWidgets('no-match empty state when query returns nothing', (tester) async {
    await tester.pumpWidget(_buildApp(regions: _kRegions));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'xyzxyz');
    await tester.pumpAndSettle();

    expect(find.textContaining('Keine Treffer'), findsOneWidget);
  });
}
