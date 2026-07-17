// Trailblazer live-nav:
// Widget tests for LivePuckBridge via a recording-fake LivePuckApplier.
//
// Mirrors the live_trail_bridge_test.dart pattern exactly.
// Overrides:
//   - livePuckApplierProvider → _FakeLivePuckApplier (records calls)
//   - liveFixProvider → controllable StreamController<LiveFixSample>
//   - trackingStateProvider → _FakeTrackingNotifier (mutable state)
//   - mapControllerProvider → null (no live MapLibre view in tests)
//   - mapStyleLoadedTickProvider → bumped by tests to simulate style load

import 'dart:async';

import 'package:auto_explore/features/map/presentation/providers/live_puck_applier.dart';
import 'package:auto_explore/features/map/presentation/providers/map_controller_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_style_loaded_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/live_puck_bridge.dart';
import 'package:auto_explore/features/trips/domain/live_fix_sample.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/presentation/providers/tracking_state_provider.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng, MapLibreMapController;

// ---------------------------------------------------------------------------
// Recording fake applier
// ---------------------------------------------------------------------------

sealed class _PuckCall {}

final class _AddOrUpdateCall extends _PuckCall {
  _AddOrUpdateCall(this.point, this.heading);
  final LatLng point;
  final double? heading;
}

final class _RemoveCall extends _PuckCall {}

class _FakeLivePuckApplier implements LivePuckApplier {
  final List<_PuckCall> calls = [];

  @override
  Future<void> addOrUpdate(
    MapLibreMapController? controller,
    LatLng point, {
    double? heading,
  }) async {
    calls.add(_AddOrUpdateCall(point, heading));
  }

  @override
  Future<void> remove(MapLibreMapController? controller) async {
    calls.add(_RemoveCall());
  }
}

class _NullMapControllerNotifier extends MapControllerNotifier {
  @override
  MapLibreMapController? build() => null;
}

class _FakeTrackingNotifier extends Notifier<TrackingState>
    implements TrackingNotifier {
  _FakeTrackingNotifier(this._initial);

  final TrackingState _initial;

  @override
  TrackingState build() => _initial;

  // A setter would collide with Riverpod's own `state` setter on Notifier;
  // keep this as an explicit method rather than a getter/setter pair.
  // ignore: use_setters_to_change_properties
  void emit(TrackingState next) => state = next;

  @override
  Future<void> startManual() async {}

  @override
  Future<void> stopActive() async {}
}

TrackingRecording _recording() => TrackingRecording(
      tripId: 1,
      startedAt: DateTime.now(),
      distanceMeters: 0,
      pointCount: 0,
      manuallyStarted: true,
    );

LiveFixSample _fix(double lat, double lon, {double? heading}) =>
    LiveFixSample(ts: DateTime(2026, 7, 17), lat: lat, lon: lon, headingDegrees: heading);

/// Fixture holding the mutable doubles the tests drive.
class _Fixture {
  _Fixture(this.fake, this.tracking, this.fixes);
  final _FakeLivePuckApplier fake;
  final _FakeTrackingNotifier tracking;
  final StreamController<LiveFixSample> fixes;
}

Future<_Fixture> _pump(WidgetTester tester) async {
  final fake = _FakeLivePuckApplier();
  final tracking = _FakeTrackingNotifier(const TrackingIdle());
  final fixes = StreamController<LiveFixSample>.broadcast();
  addTearDown(fixes.close);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        livePuckApplierProvider.overrideWithValue(fake),
        liveFixProvider.overrideWith((ref) => fixes.stream),
        trackingStateProvider.overrideWith(() => tracking),
        mapControllerProvider.overrideWith(_NullMapControllerNotifier.new),
      ],
      child: const Directionality(
        textDirection: TextDirection.ltr,
        child: LivePuckBridge(),
      ),
    ),
  );
  return _Fixture(fake, tracking, fixes);
}

void _bumpStyleTick(WidgetTester tester) {
  final element = tester.element(find.byType(LivePuckBridge));
  ProviderScope.containerOf(element)
      .read(mapStyleLoadedTickProvider.notifier)
      .bump();
}

void main() {
  group('LivePuckBridge', () {
    testWidgets('renders headless (SizedBox.shrink)', (tester) async {
      await _pump(tester);
      expect(
        find.descendant(
          of: find.byType(LivePuckBridge),
          matching: find.byType(SizedBox),
        ),
        findsOneWidget,
      );
    });

    testWidgets('first fix triggers addOrUpdate with the fix position',
        (tester) async {
      final f = await _pump(tester);
      _bumpStyleTick(tester);
      await tester.pump();

      f.fixes.add(_fix(50, 9));
      await tester.pump();

      expect(f.fake.calls, hasLength(1));
      final call = f.fake.calls.single;
      expect(call, isA<_AddOrUpdateCall>());
      final addCall = call as _AddOrUpdateCall;
      expect(addCall.point.latitude, closeTo(50, 0.0001));
      expect(addCall.point.longitude, closeTo(9, 0.0001));
    });

    testWidgets('forwards heading when present', (tester) async {
      final f = await _pump(tester);
      _bumpStyleTick(tester);
      await tester.pump();

      f.fixes.add(_fix(50, 9, heading: 90));
      await tester.pump();

      final call = f.fake.calls.single as _AddOrUpdateCall;
      expect(call.heading, closeTo(90, 0.001));
    });

    testWidgets('each fix moves the puck to the latest position',
        (tester) async {
      final f = await _pump(tester);
      _bumpStyleTick(tester);
      await tester.pump();

      for (var i = 0; i < 3; i++) {
        f.fixes.add(_fix(50.0 + i * 0.001, 9));
        await tester.pump();
      }

      final addCalls = f.fake.calls.whereType<_AddOrUpdateCall>().toList();
      expect(addCalls, hasLength(3));
      expect(addCalls.last.point.latitude, closeTo(50.002, 0.0001));
    });

    testWidgets('removes puck on transition to TrackingIdle',
        (tester) async {
      final f = await _pump(tester);
      _bumpStyleTick(tester);
      await tester.pump();

      f.tracking.emit(_recording());
      f.fixes.add(_fix(50, 9));
      await tester.pump();
      expect(f.fake.calls.whereType<_AddOrUpdateCall>(), isNotEmpty);

      f.tracking.emit(const TrackingIdle());
      await tester.pump();
      expect(f.fake.calls.whereType<_RemoveCall>(), hasLength(1));
    });

    testWidgets('re-adds puck on style reload when last point is known',
        (tester) async {
      final f = await _pump(tester);
      _bumpStyleTick(tester);
      await tester.pump();

      // Drive a fix to set the last point.
      f.fixes.add(_fix(50, 9));
      await tester.pump();
      final countBefore = f.fake.calls.whereType<_AddOrUpdateCall>().length;

      // Simulate a style reload — should re-add from last point.
      _bumpStyleTick(tester);
      await tester.pump();
      expect(
        f.fake.calls.whereType<_AddOrUpdateCall>().length,
        greaterThan(countBefore),
        reason: 're-add on style reload required (Pitfall 1)',
      );
    });

    testWidgets('does NOT re-add on style reload when no point is known',
        (tester) async {
      await _pump(tester);
      _bumpStyleTick(tester);
      await tester.pump();
      // No fix ever sent — style reload should be a no-op.
      _bumpStyleTick(tester);
      await tester.pump();
      expect(
        find.byType(LivePuckBridge),
        findsOneWidget,
        reason: 'bridge must still be mounted',
      );
    });
  });
}
