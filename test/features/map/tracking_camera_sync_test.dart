import 'package:auto_explore/features/map/domain/follow_mode.dart';
import 'package:auto_explore/features/map/presentation/providers/camera_state_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/tracking_camera_sync.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/presentation/providers/tracking_state_provider.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake [TrackingNotifier] that broadcasts a mutable [TrackingState] to
/// tests. `emit()` updates state synchronously, mimicking the real
/// notifier's stream-driven updates on accepted fixes.
class _FakeTrackingNotifier extends Notifier<TrackingState>
    implements TrackingNotifier {
  _FakeTrackingNotifier(this._initial);

  final TrackingState _initial;

  @override
  TrackingState build() => _initial;

  // A setter would collide with Riverpod's own `state` setter on Notifier;
  // keep this as an explicit method rather than a getter/setter pair.
  // ignore: use_setters_to_change_properties
  void emit(TrackingState next) {
    state = next;
  }

  @override
  Future<void> startManual() async {}

  @override
  Future<void> stopActive() async {}
}

TrackingRecording _recording({double distanceMeters = 0}) => TrackingRecording(
      tripId: 1,
      startedAt: DateTime.now(),
      distanceMeters: distanceMeters,
      pointCount: 0,
      manuallyStarted: true,
    );

Future<void> _pumpSync(
  WidgetTester tester,
  _FakeTrackingNotifier fake,
) async {
  final scope = ProviderScope(
    overrides: [
      trackingStateProvider.overrideWith(() => fake),
    ],
    child: const Directionality(
      textDirection: TextDirection.ltr,
      child: TrackingCameraSync(),
    ),
  );
  await tester.pumpWidget(scope);
}

/// Reads [cameraStateProvider] via a probe [Consumer] mounted alongside
/// [TrackingCameraSync]. Avoids constructing a bare [ProviderContainer]
/// (which would run in a separate scope from the widget tree).
FollowMode _followModeOf(WidgetTester tester) {
  final element = tester.element(find.byType(TrackingCameraSync));
  final container = ProviderScope.containerOf(element);
  return container.read(cameraStateProvider).followMode;
}

void _setFollowMode(WidgetTester tester, FollowMode mode) {
  final element = tester.element(find.byType(TrackingCameraSync));
  final container = ProviderScope.containerOf(element);
  container.read(cameraStateProvider.notifier).setFollowMode(mode);
}

void main() {
  group('TrackingCameraSync', () {
    testWidgets(
      'TrackingIdle → TrackingRecording sets FollowMode.locationAndHeading',
      (tester) async {
        final fake = _FakeTrackingNotifier(const TrackingIdle());
        await _pumpSync(tester, fake);

        // Initial state: CameraState.initial.followMode = location.
        expect(_followModeOf(tester), FollowMode.location);

        fake.emit(_recording());
        await tester.pump();

        expect(_followModeOf(tester), FollowMode.locationAndHeading);
      },
    );

    testWidgets(
      'TrackingRecording → TrackingIdle sets FollowMode.none',
      (tester) async {
        final fake = _FakeTrackingNotifier(_recording());
        await _pumpSync(tester, fake);

        // Force follow mode on (mirrors the state after a start transition).
        _setFollowMode(tester, FollowMode.locationAndHeading);
        expect(_followModeOf(tester), FollowMode.locationAndHeading);

        fake.emit(const TrackingIdle());
        await tester.pump();

        expect(_followModeOf(tester), FollowMode.none);
      },
    );

    testWidgets(
      'TrackingRecording → TrackingRecording re-emit does NOT re-arm follow mode after a user pan',
      (tester) async {
        // Start recording — sync fires and arms heading-lock.
        final fake = _FakeTrackingNotifier(const TrackingIdle());
        await _pumpSync(tester, fake);
        fake.emit(_recording());
        await tester.pump();
        expect(_followModeOf(tester), FollowMode.locationAndHeading);

        // User pans mid-trip — MapWidget's onCameraTrackingDismissed
        // handler sets FollowMode.none. We simulate that directly.
        _setFollowMode(tester, FollowMode.none);
        expect(_followModeOf(tester), FollowMode.none);

        // Next accepted fix re-emits TrackingRecording with an updated
        // distance (per 03-1-RESEARCH §5.1). Sync must NOT override the
        // pan-dismiss — it stays at FollowMode.none.
        fake.emit(_recording(distanceMeters: 42));
        await tester.pump();

        expect(_followModeOf(tester), FollowMode.none);
      },
    );

    testWidgets('renders a SizedBox.shrink (no visible UI)', (tester) async {
      final fake = _FakeTrackingNotifier(const TrackingIdle());
      await _pumpSync(tester, fake);

      // Headless — the direct child is a SizedBox with no intrinsic size.
      // (Under an unconstrained root, the test viewport gives it 800x600;
      // inside a real Stack the shrink() collapses to 0.)
      expect(
        find.descendant(
          of: find.byType(TrackingCameraSync),
          matching: find.byType(SizedBox),
        ),
        findsOneWidget,
      );
    });
  });
}
