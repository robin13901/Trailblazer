// Trailblazer Phase 6, Plan 06-04 Task 2 tests:
// MatchingQueuePill — count-driven copy + Liquid Glass shell + hidden at zero.
//
// `inFlightCountProvider` is overridden with a fixed AsyncData value per test.
// The G1 flag stays false (default) so the pill renders via GlassPillFallback,
// keeping the test off the liquid_glass_renderer paint path.

import 'package:auto_explore/core/theme/liquid_glass_settings.dart';
import 'package:auto_explore/features/map/presentation/widgets/glass_pill.dart';
import 'package:auto_explore/features/trips/presentation/providers/inbox_providers.dart';
import 'package:auto_explore/features/trips/presentation/widgets/matching_queue_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, int count) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        inFlightCountProvider.overrideWith((ref) => Stream.value(count)),
      ],
      child: const MaterialApp(
        home: Scaffold(body: Center(child: MatchingQueuePill())),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  tearDown(() {
    LiquidGlassSettings.platformBlurEnabled = false;
  });

  testWidgets('count == 0 → collapses to SizedBox.shrink, no text', (
    tester,
  ) async {
    await _pump(tester, 0);

    expect(find.byType(GlassPillFallback), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('matching'), findsNothing);
  });

  testWidgets('count == 1 → "1 trip matching…"', (tester) async {
    await _pump(tester, 1);

    expect(find.text('1 Fahrt wird abgeglichen …'), findsOneWidget);
  });

  testWidgets('count == 5 → "5 trips matching…"', (tester) async {
    await _pump(tester, 5);

    expect(find.text('5 Fahrten werden abgeglichen …'), findsOneWidget);
  });

  testWidgets('renders via GlassPill shell with a spinner when count > 0', (
    tester,
  ) async {
    await _pump(tester, 3);

    expect(find.byType(GlassPillFallback), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('does not use BackdropFilter (G1 fallback discipline)', (
    tester,
  ) async {
    await _pump(tester, 2);

    expect(find.byType(BackdropFilter), findsNothing);
  });
}
