// #6 (2026-07-25): TripFab post-stop "finishing" spinner test.
//
// After Stop is tapped the FAB shows the idle liquid-glass circle with a
// centered CircularProgressIndicator (the finishing variant) until matching for
// the just-ended trip has completed AND the coverage overlay has emitted. This
// test drives the tracking state idle→recording→idle and the
// inFlightCount / overlay providers to walk the FAB through the finishing state
// and back to the normal start variant.

import 'dart:async';

import 'package:auto_explore/features/coverage/data/coverage_overlay_data.dart';
import 'package:auto_explore/features/coverage/data/coverage_overlay_providers.dart';
import 'package:auto_explore/features/map/presentation/widgets/trip_fab.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/presentation/providers/inbox_providers.dart';
import 'package:auto_explore/features/trips/presentation/providers/tracking_state_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tracking notifier whose state can be driven from the test, and whose
/// stopActive() flips it to idle (as the real one does after finalising).
class _ControllableTrackingNotifier extends Notifier<TrackingState>
    implements TrackingNotifier {
  _ControllableTrackingNotifier(this._initial);
  final TrackingState _initial;

  @override
  TrackingState build() => _initial;

  @override
  Future<void> startManual() async {}

  @override
  Future<void> stopActive() async {
    state = const TrackingIdle();
  }
}

TrackingState _recording() => TrackingRecording(
      tripId: 1,
      startedAt: DateTime(2026, 7, 25),
      distanceMeters: 0,
      pointCount: 0,
      manuallyStarted: true,
    );

void main() {
  testWidgets(
    'Stop → finishing spinner until matching done + overlay emitted, then '
    'back to start variant',
    (tester) async {
      final tracking = _ControllableTrackingNotifier(_recording());
      final inFlight = StreamController<int>.broadcast();
      final overlay = StreamController<CoverageOverlayData>.broadcast();
      addTearDown(inFlight.close);
      addTearDown(overlay.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            trackingStateProvider.overrideWith(() => tracking),
            inFlightCountProvider.overrideWith((ref) => inFlight.stream),
            coverageOverlayDataProvider.overrideWith((ref) => overlay.stream),
          ],
          child: const MaterialApp(
            home: Scaffold(body: Center(child: TripFab())),
          ),
        ),
      );
      await tester.pump();

      // Recording → stop variant.
      expect(find.byKey(const ValueKey('stop')), findsOneWidget);

      // Tap stop → notifier flips to idle, FAB enters finishing state.
      await tester.tap(find.byType(TripFab));
      await tester.pump(); // stopActive() microtask
      await tester.pump(); // rebuild after idle transition

      expect(find.byKey(const ValueKey('finishing')), findsOneWidget,
          reason: 'spinner shows right after Stop');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Matching starts (count > 0) — still finishing.
      inFlight.add(1);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('finishing')), findsOneWidget);

      // Matching finishes (count back to 0) AND overlay emits → line drawn.
      inFlight.add(0);
      overlay.add(CoverageOverlayData.empty);
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const ValueKey('finishing')), findsNothing,
          reason: 'spinner clears once matching done + overlay emitted');
      expect(find.byKey(const ValueKey('start')), findsOneWidget);
    },
  );
}
