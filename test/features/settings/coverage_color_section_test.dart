// Trailblazer Phase 7, Plan 07-05:
// Widget tests for CoverageColorSection.

import 'package:auto_explore/features/coverage/domain/coverage_color_preset.dart';
import 'package:auto_explore/features/coverage/presentation/coverage_preset_provider.dart';
import 'package:auto_explore/features/settings/presentation/widgets/coverage_color_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

Widget _wrap(Widget child, {List<Object> overrides = const []}) {
  return ProviderScope(
    overrides: overrides.cast(),
    child: MaterialApp(
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets('renders both swatch rows (driven + undriven)', (tester) async {
    await tester.pumpWidget(_wrap(const CoverageColorSection()));
    await tester.pumpAndSettle();

    // Each preset appears twice — once in the driven row, once in the
    // undriven row.
    for (final preset in CoverageColorPreset.values) {
      expect(
        find.bySemanticsLabel(preset.label),
        findsNWidgets(2),
        reason: '${preset.label} swatch should appear in both rows',
      );
    }
  });

  testWidgets('defaults: amber (driven) + blue (undriven) selected', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const CoverageColorSection()));
    await tester.pumpAndSettle();

    // Two check icons: one per row's selected swatch (amber + blue).
    expect(find.byIcon(Icons.check), findsNWidgets(2));
  });

  testWidgets('tapping green in the driven row updates the driven preset', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const CoverageColorSection()));
    await tester.pumpAndSettle();

    // The driven row renders first, so .first is its "Grün" swatch.
    await tester.tap(find.bySemanticsLabel('Grün').first);
    await tester.pumpAndSettle();

    final element = tester.element(find.byType(CoverageColorSection));
    final container = ProviderScope.containerOf(element);
    expect(
      container.read(coveragePresetProvider).value,
      CoverageColorPreset.green,
    );
    // Undriven preset is untouched (still default blue).
    expect(
      container.read(undrivenPresetProvider).value,
      CoverageColorPreset.blue,
    );
  });

  testWidgets('tapping red in the undriven row updates only the undriven preset', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const CoverageColorSection()));
    await tester.pumpAndSettle();

    // The undriven row renders second, so .last is its "Rot" swatch.
    await tester.tap(find.bySemanticsLabel('Rot').last);
    await tester.pumpAndSettle();

    final element = tester.element(find.byType(CoverageColorSection));
    final container = ProviderScope.containerOf(element);
    expect(
      container.read(undrivenPresetProvider).value,
      CoverageColorPreset.red,
    );
    // Driven preset is untouched (still default amber).
    expect(
      container.read(coveragePresetProvider).value,
      CoverageColorPreset.amber,
    );
  });

  testWidgets('provider override: purple driven swatch renders as selected', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const CoverageColorSection(),
        overrides: [
          coveragePresetValueProvider.overrideWithValue(
            CoverageColorPreset.purple,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // Two check icons: purple (driven, overridden) + blue (undriven, default).
    expect(find.byIcon(Icons.check), findsNWidgets(2));
  });
}
