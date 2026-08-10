import 'package:auto_explore/features/map/presentation/widgets/wakelock_sync.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/presentation/providers/tracking_state_provider.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

/// Fake [TrackingNotifier] that broadcasts a mutable [TrackingState] to
/// tests. `emit()` updates state synchronously, mimicking the real
/// notifier's stream-driven updates on accepted fixes.
class _FakeTrackingNotifier extends Notifier<TrackingState>
    implements TrackingNotifier {
  _FakeTrackingNotifier(this._initial);

  final TrackingState _initial;

  @override
  TrackingState build() => _initial;

  // A setter would collide with Riverpod's own `state` setter on Notifier.
  // ignore: use_setters_to_change_properties
  void emit(TrackingState next) {
    state = next;
  }

  @override
  Future<void> startManual() async {}

  @override
  Future<void> stopActive() async {}
}

/// Records every `toggle(enable:)` call so the test can assert the wakelock
/// was enabled on record-start and disabled on record-stop, with no platform
/// channel involved.
class _FakeWakelockPlatform extends WakelockPlusPlatformInterface {
  final List<bool> toggles = [];
  bool _enabled = false;

  @override
  Future<void> toggle({required bool enable}) async {
    _enabled = enable;
    toggles.add(enable);
  }

  @override
  Future<bool> get enabled async => _enabled;
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
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        trackingStateProvider.overrideWith(() => fake),
      ],
      child: const Directionality(
        textDirection: TextDirection.ltr,
        child: WakelockSync(),
      ),
    ),
  );
}

void main() {
  late _FakeWakelockPlatform platform;

  setUp(() {
    platform = _FakeWakelockPlatform();
    WakelockPlusPlatformInterface.instance = platform;
    // The `WakelockPlus` facade routes every call through this top-level var,
    // which is lazily captured from `WakelockPlusPlatformInterface.instance`
    // on first read and NEVER re-read afterwards. Reassigning only the static
    // `.instance` (as before) left tests 2+ still toggling test 1's leaked
    // fake — hence their empty `toggles`. Overriding the facade's own var per
    // test gives each test a truly fresh, isolated platform.
    wakelockPlusPlatformInstance = platform;
  });

  group('WakelockSync', () {
    testWidgets(
      'TrackingIdle → TrackingRecording enables the wakelock',
      (tester) async {
        final fake = _FakeTrackingNotifier(const TrackingIdle());
        await _pumpSync(tester, fake);

        fake.emit(_recording());
        await tester.pump();
        // Let the fire-and-forget toggle future complete before asserting.
        await tester.pumpAndSettle();

        expect(platform.toggles, [true]);
      },
    );

    testWidgets(
      'TrackingRecording → TrackingIdle disables the wakelock',
      (tester) async {
        final fake = _FakeTrackingNotifier(_recording());
        await _pumpSync(tester, fake);

        fake.emit(const TrackingIdle());
        await tester.pump();
        await tester.pumpAndSettle();

        expect(platform.toggles, [false]);
      },
    );

    testWidgets(
      'TrackingRecording → TrackingRecording re-emit does NOT re-toggle',
      (tester) async {
        final fake = _FakeTrackingNotifier(const TrackingIdle());
        await _pumpSync(tester, fake);
        fake.emit(_recording());
        await tester.pump();
        await tester.pumpAndSettle();
        expect(platform.toggles, [true]);

        // A subsequent recording re-emit (new distance) must not re-toggle.
        fake.emit(_recording(distanceMeters: 42));
        await tester.pump();
        await tester.pumpAndSettle();

        expect(platform.toggles, [true]);
      },
    );

    testWidgets('renders a SizedBox.shrink (no visible UI)', (tester) async {
      final fake = _FakeTrackingNotifier(const TrackingIdle());
      await _pumpSync(tester, fake);

      expect(
        find.descendant(
          of: find.byType(WakelockSync),
          matching: find.byType(SizedBox),
        ),
        findsOneWidget,
      );
    });
  });
}
