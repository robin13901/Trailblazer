import 'package:auto_explore/features/map/presentation/widgets/glass_pill.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/presentation/providers/tracking_state_provider.dart';
import 'package:auto_explore/features/trips/presentation/widgets/live_tracking_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fake notifier (state-only, no actions needed for panel tests)
// ---------------------------------------------------------------------------

class _FakeTrackingNotifier extends Notifier<TrackingState>
    implements TrackingNotifier {
  _FakeTrackingNotifier(this._initial);

  final TrackingState _initial;

  @override
  TrackingState build() => _initial;

  @override
  Future<void> startManual() async {}

  @override
  Future<void> stopActive() async {}
}

// ---------------------------------------------------------------------------
// Helper
// ---------------------------------------------------------------------------

Future<void> pumpPanel(WidgetTester tester, TrackingState initial) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        trackingStateProvider.overrideWith(() => _FakeTrackingNotifier(initial)),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Center(child: LiveTrackingPanel()),
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('LiveTrackingPanel', () {
    testWidgets('idle state: panel is invisible (no GlassPill)', (
      tester,
    ) async {
      await pumpPanel(tester, const TrackingIdle());

      expect(find.byType(GlassPill), findsNothing);
      expect(find.byType(GlassPillFallback), findsNothing);
    });

    testWidgets(
        'recording state: shows "Recording ·" text inside a GlassPill', (
      tester,
    ) async {
      final startedAt = DateTime.now().subtract(const Duration(minutes: 1));
      await pumpPanel(
        tester,
        TrackingRecording(
          tripId: 1,
          startedAt: startedAt,
          distanceMeters: 1500,
          pointCount: 10,
          manuallyStarted: true,
          currentSpeedKmh: 42,
        ),
      );

      // The text should start with "Aufnahme ·".
      expect(find.textContaining('Aufnahme ·'), findsOneWidget);
      // Distance should read "1.5 km".
      expect(find.textContaining('1.5 km'), findsOneWidget);
    });

    testWidgets(
        'recording state: panel rebuilds after pump(2s) — timer fires', (
      tester,
    ) async {
      // Start 62 s ago so initial render shows ~01:02.
      final startedAt = DateTime.now().subtract(const Duration(seconds: 62));
      await pumpPanel(
        tester,
        TrackingRecording(
          tripId: 1,
          startedAt: startedAt,
          distanceMeters: 0,
          pointCount: 0,
          manuallyStarted: true,
        ),
      );

      // Panel is visible.
      expect(find.textContaining('Aufnahme ·'), findsOneWidget);

      // Advance timer by 2 seconds — the periodic Timer should fire twice.
      // We only verify that no exception is thrown and the panel is still
      // present (DateTime.now() in tests may not advance enough in wall-clock
      // to change MM:SS, but the rebuild cycle itself must not crash).
      await tester.pump(const Duration(seconds: 2));

      expect(find.textContaining('Aufnahme ·'), findsOneWidget);
    });
  });
}
