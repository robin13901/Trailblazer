// GlobalRecalcBanner widget tests (2026-07-26).
//
// Tests:
//   1. null state → banner renders nothing (SizedBox.shrink, no GlassPill).
//   2. rematching(3, 20) → shows "Fahrt 3/20" text + determinate bar.
//   3. recomputing (no count) → shows the coverage-rebuild text + indeterminate
//      bar.
//   4. recomputing(4, 10) → shows "… 4/10" text + determinate bar at 0.4.
//
// Forces the GlassPillFallback path (headless tests have no real renderer).

import 'package:auto_explore/core/theme/liquid_glass_settings.dart';
import 'package:auto_explore/features/coverage/domain/coverage_color_preset.dart';
import 'package:auto_explore/features/coverage/presentation/coverage_preset_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/glass_pill.dart';
import 'package:auto_explore/features/startup/data/global_recalc_progress_provider.dart';
import 'package:auto_explore/features/startup/presentation/widgets/global_recalc_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Notifier seeded with a fixed [GlobalRecalcState] (or null) without I/O.
class _FixedRecalcNotifier extends GlobalRecalcNotifier {
  _FixedRecalcNotifier(this._fixed);
  final GlobalRecalcState? _fixed;

  @override
  GlobalRecalcState? build() => _fixed;
}

Future<void> _pumpBanner(
  WidgetTester tester,
  GlobalRecalcState? state,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        globalRecalcProgressProvider
            .overrideWith(() => _FixedRecalcNotifier(state)),
        coveragePresetValueProvider
            .overrideWithValue(CoverageColorPreset.amber),
      ],
      child: const MaterialApp(
        home: Scaffold(body: Center(child: GlobalRecalcBanner())),
      ),
    ),
  );
}

void main() {
  setUp(() {
    LiquidGlassSettings.platformBlurEnabled = false;
  });

  tearDown(() {
    LiquidGlassSettings.platformBlurEnabled = false;
  });

  group('GlobalRecalcBanner', () {
    testWidgets('1. null state renders nothing', (tester) async {
      await _pumpBanner(tester, null);

      expect(find.byType(GlassPill), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('2. rematching(3, 20) shows Fahrt 3/20 + determinate bar',
        (tester) async {
      await _pumpBanner(
        tester,
        const GlobalRecalcState(
          phase: GlobalRecalcPhase.rematching,
          done: 3,
          total: 20,
        ),
      );

      expect(find.textContaining('3/20'), findsOneWidget);
      expect(find.textContaining('Neuberechnung'), findsOneWidget);

      // Determinate bar: value is 3/20.
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, closeTo(3 / 20, 1e-9));
    });

    testWidgets('3. recomputing shows coverage-rebuild text + indeterminate bar',
        (tester) async {
      await _pumpBanner(
        tester,
        const GlobalRecalcState(phase: GlobalRecalcPhase.recomputing),
      );

      expect(find.textContaining('Abdeckung wird neu berechnet'),
          findsOneWidget);

      // Indeterminate bar: value is null.
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, isNull);
    });

    testWidgets('4. recomputing(4, 10) shows N/M + determinate bar at 0.4',
        (tester) async {
      await _pumpBanner(
        tester,
        const GlobalRecalcState(
          phase: GlobalRecalcPhase.recomputing,
          done: 4,
          total: 10,
        ),
      );

      expect(find.textContaining('Abdeckung wird neu berechnet'),
          findsOneWidget);
      expect(find.textContaining('4/10'), findsOneWidget);

      // Determinate bar: value is 4/10.
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, closeTo(4 / 10, 1e-9));
    });
  });
}
