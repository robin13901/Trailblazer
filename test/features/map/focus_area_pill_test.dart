// Trailblazer Phase 8, Plan 08-04 (Wave 2):
// FocusAreaPill widget tests.
//
// Tests:
//   1. With a seeded FocusPillState(name: 'Grebenhain', percentLabel: '26.4%')
//      → both texts render.
//   2. With empty FocusPillState() (initial, no value) → placeholder texts
//      'Standort' + '—%' render and the widget does NOT throw.
//      Exercises the GlassPillFallback path (platformBlurEnabled = false).

import 'package:auto_explore/core/theme/liquid_glass_settings.dart';
import 'package:auto_explore/features/map/presentation/widgets/focus_area_pill.dart';
import 'package:auto_explore/features/map/presentation/widgets/glass_pill.dart';
import 'package:auto_explore/features/regions/presentation/providers/focus_pill_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Helper
// ---------------------------------------------------------------------------

/// Pumps [FocusAreaPill] inside a [ProviderScope] and [MaterialApp] with
/// [focusPillProvider] overridden to [state].
Future<void> _pumpPill(
  WidgetTester tester,
  FocusPillState state,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        focusPillProvider.overrideWith(() => _FixedFocusPillNotifier(state)),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Center(child: FocusAreaPill()),
        ),
      ),
    ),
  );
}

/// Notifier that returns a fixed [FocusPillState] without touching any I/O.
/// Extends [FocusPillNotifier] so it satisfies the provider's type constraint.
class _FixedFocusPillNotifier extends FocusPillNotifier {
  _FixedFocusPillNotifier(this._fixed);
  final FocusPillState _fixed;

  @override
  FocusPillState build() => _fixed;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // Force GlassPillFallback path: headless tests have no real renderer.
  setUp(() {
    LiquidGlassSettings.platformBlurEnabled = false;
  });

  tearDown(() {
    LiquidGlassSettings.platformBlurEnabled = false;
  });

  group('FocusAreaPill', () {
    testWidgets(
      '1. seeded state renders name + percentLabel',
      (tester) async {
        await _pumpPill(
          tester,
          const FocusPillState(
            name: 'Grebenhain',
            percentLabel: '26.4%',
          ),
        );

        expect(find.text('Grebenhain'), findsOneWidget);
        expect(find.text('26.4%'), findsOneWidget);
      },
    );

    testWidgets(
      '2. empty state renders placeholder texts and does not throw',
      (tester) async {
        await tester.runAsync(() async {
          await _pumpPill(tester, const FocusPillState());
        });

        // Placeholder texts from hold-last-value fallback.
        expect(find.text('Standort'), findsOneWidget);
        expect(find.text('—%'), findsOneWidget);
      },
    );

    testWidgets(
      '3. empty state exercises GlassPillFallback path (no 0-dim crash)',
      (tester) async {
        await _pumpPill(tester, const FocusPillState());

        // platformBlurEnabled = false → GlassPillFallback should be rendered.
        expect(find.byType(GlassPillFallback), findsOneWidget);
      },
    );

    testWidgets(
      '4. null percentLabel renders dash placeholder',
      (tester) async {
        // Region resolved but no cache row → percentLabel is null.
        await _pumpPill(
          tester,
          const FocusPillState(name: 'Grebenhain'),
        );

        expect(find.text('Grebenhain'), findsOneWidget);
        expect(find.text('—%'), findsOneWidget);
      },
    );
  });
}
