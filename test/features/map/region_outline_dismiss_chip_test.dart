// Trailblazer region-outline overlay:
// Widget tests for RegionOutlineDismissChip — visible only while an outline is
// shown; tapping it clears regionOutlineProvider.
//
// Uses the GlassPill fallback path (LiquidGlassSettings.platformBlurEnabled =
// false) to avoid the shader render path in the headless test environment.

import 'package:auto_explore/core/theme/liquid_glass_settings.dart';
import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/map/presentation/providers/region_outline_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/region_outline_dismiss_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

AdminRegion _region() => const AdminRegion(
      osmId: 1,
      adminLevel: 8,
      name: 'Test',
      bboxMinLat: 48,
      bboxMinLon: 11,
      bboxMaxLat: 49,
      bboxMaxLon: 12,
      polygons: [],
    );

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    const ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: RegionOutlineDismissChip()),
      ),
    ),
  );
}

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(
      tester.element(find.byType(RegionOutlineDismissChip)),
    );

void main() {
  setUp(() {
    LiquidGlassSettings.platformBlurEnabled = false;
  });
  tearDown(() {
    LiquidGlassSettings.platformBlurEnabled = false;
  });

  group('RegionOutlineDismissChip', () {
    testWidgets('hidden (no text) when no outline is shown', (tester) async {
      await _pump(tester);
      expect(find.text('Umriss ausblenden'), findsNothing);
    });

    testWidgets('visible when an outline is shown', (tester) async {
      await _pump(tester);
      _container(tester).read(regionOutlineProvider.notifier).show(_region());
      await tester.pump();
      expect(find.text('Umriss ausblenden'), findsOneWidget);
    });

    testWidgets('tap clears the outline provider', (tester) async {
      await _pump(tester);
      final container = _container(tester);
      container.read(regionOutlineProvider.notifier).show(_region());
      await tester.pump();

      await tester.tap(find.text('Umriss ausblenden'));
      await tester.pump();

      expect(container.read(regionOutlineProvider), isNull);
      expect(find.text('Umriss ausblenden'), findsNothing);
    });
  });
}
