import 'package:auto_explore/features/map/presentation/widgets/trip_fab.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/presentation/providers/tracking_state_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fake notifier that tracks call counts
// ---------------------------------------------------------------------------

class _FakeTrackingNotifier extends Notifier<TrackingState>
    implements TrackingNotifier {
  _FakeTrackingNotifier(this._initial);

  final TrackingState _initial;
  int startManualCalled = 0;
  int stopActiveCalled = 0;

  @override
  TrackingState build() => _initial;

  @override
  Future<void> startManual() async => startManualCalled++;

  @override
  Future<void> stopActive() async => stopActiveCalled++;
}

// ---------------------------------------------------------------------------
// Helper: pump TripFab with a pre-constructed fake notifier
// ---------------------------------------------------------------------------

Future<void> _pumpFab(
  WidgetTester tester,
  _FakeTrackingNotifier fake,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        trackingStateProvider.overrideWith(() => fake),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Center(child: TripFab()),
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('TripFab morph', () {
    testWidgets('idle state: shows _StartVariant (ValueKey start)', (
      tester,
    ) async {
      await _pumpFab(tester, _FakeTrackingNotifier(const TrackingIdle()));

      // _StartVariant is identified by its ValueKey.
      expect(find.byKey(const ValueKey('start')), findsOneWidget);
      expect(find.byKey(const ValueKey('stop')), findsNothing);
    });

    testWidgets('idle state: Semantics label is "Start trip"', (tester) async {
      await _pumpFab(tester, _FakeTrackingNotifier(const TrackingIdle()));

      expect(
        tester.getSemantics(find.byType(TripFab)),
        matchesSemantics(
          label: 'Fahrt starten',
          isButton: true,
          hasTapAction: true,
        ),
      );
    });

    testWidgets('recording state: shows _StopVariant (ValueKey stop)', (
      tester,
    ) async {
      await _pumpFab(
        tester,
        _FakeTrackingNotifier(TrackingRecording(
          tripId: 1,
          startedAt: DateTime.now(),
          distanceMeters: 0,
          pointCount: 0,
          manuallyStarted: true,
        )),
      );

      expect(find.byKey(const ValueKey('stop')), findsOneWidget);
      expect(find.byKey(const ValueKey('start')), findsNothing);
    });

    testWidgets('recording state: Semantics label is "Stop trip"', (
      tester,
    ) async {
      await _pumpFab(
        tester,
        _FakeTrackingNotifier(TrackingRecording(
          tripId: 1,
          startedAt: DateTime.now(),
          distanceMeters: 0,
          pointCount: 0,
          manuallyStarted: true,
        )),
      );

      expect(
        tester.getSemantics(find.byType(TripFab)),
        matchesSemantics(
          label: 'Fahrt beenden',
          isButton: true,
          hasTapAction: true,
        ),
      );
    });

    testWidgets('recording state: stop variant container is red 0xFFD32F2F', (
      tester,
    ) async {
      await _pumpFab(
        tester,
        _FakeTrackingNotifier(TrackingRecording(
          tripId: 1,
          startedAt: DateTime.now(),
          distanceMeters: 0,
          pointCount: 0,
          manuallyStarted: true,
        )),
      );

      // Find the Container inside the _StopVariant via its key.
      final stopWidget = tester.widget<Container>(
        find.descendant(
          of: find.byKey(const ValueKey('stop')),
          matching: find.byType(Container),
        ),
      );
      final decoration = stopWidget.decoration! as BoxDecoration;
      expect(decoration.color, const Color(0xFFD32F2F));
    });

    testWidgets('tap in idle calls startManual once', (tester) async {
      final fake = _FakeTrackingNotifier(const TrackingIdle());
      await _pumpFab(tester, fake);

      final gd = tester.widget<GestureDetector>(
        find.descendant(
          of: find.byType(TripFab),
          matching: find.byType(GestureDetector),
        ),
      );
      gd.onTap?.call();
      await tester.pump();

      expect(fake.startManualCalled, 1);
      expect(fake.stopActiveCalled, 0);
    });

    testWidgets('tap in recording calls stopActive once', (tester) async {
      final fake = _FakeTrackingNotifier(TrackingRecording(
        tripId: 1,
        startedAt: DateTime.now(),
        distanceMeters: 0,
        pointCount: 0,
        manuallyStarted: true,
      ));
      await _pumpFab(tester, fake);

      final gd = tester.widget<GestureDetector>(
        find.descendant(
          of: find.byType(TripFab),
          matching: find.byType(GestureDetector),
        ),
      );
      gd.onTap?.call();
      await tester.pump();

      expect(fake.stopActiveCalled, 1);
      expect(fake.startManualCalled, 0);
    });
  });
}
