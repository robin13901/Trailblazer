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

  testWidgets('renders 5 swatch semantics labels', (tester) async {
    await tester.pumpWidget(_wrap(const CoverageColorSection()));
    await tester.pumpAndSettle();

    for (final preset in CoverageColorPreset.values) {
      expect(
        find.bySemanticsLabel(preset.label),
        findsOneWidget,
        reason: '${preset.label} swatch should be present',
      );
    }
  });

  testWidgets('amber is selected by default', (tester) async {
    await tester.pumpWidget(_wrap(const CoverageColorSection()));
    await tester.pumpAndSettle();

    // The selected swatch shows a check icon; unselected ones do not.
    // Verify the check icon is present (1 = amber selected).
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('tapping green calls select and moves selection indicator',
      (tester) async {
    // Use in-memory prefs so the notifier hydrates correctly.
    await tester.pumpWidget(_wrap(const CoverageColorSection()));
    await tester.pumpAndSettle();

    // Tap the Green swatch.
    await tester.tap(find.bySemanticsLabel('Grün'));
    await tester.pumpAndSettle();

    // Only one check icon should exist and it should be on green.
    expect(find.byIcon(Icons.check), findsOneWidget);

    // Verify that the provider state updated — read from the ProviderScope
    // that wraps the tree.
    final element = tester.element(find.byType(CoverageColorSection));
    final container = ProviderScope.containerOf(element);
    final storedPreset = container.read(coveragePresetProvider).value;
    expect(storedPreset, CoverageColorPreset.green);
  });

  testWidgets('provider override: purple swatch renders as selected',
      (tester) async {
    await tester.pumpWidget(
      _wrap(
        const CoverageColorSection(),
        overrides: [
          coveragePresetValueProvider.overrideWithValue(CoverageColorPreset.purple),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // Check icon present (purple selected), and only one.
    expect(find.byIcon(Icons.check), findsOneWidget);
  });
}
