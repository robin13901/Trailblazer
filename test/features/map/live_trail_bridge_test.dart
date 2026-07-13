// Trailblazer live-nav:
// Widget tests for LiveTrailBridge via a recording-fake LiveTrailApplier.
//
// The fake records addOrUpdate/remove calls regardless of controller null-ness
// (mapControllerProvider is overridden to null — no live MapLibre view in
// tests). Overrides:
//   - liveTrailApplierProvider → _FakeLiveTrailApplier (records calls)
//   - liveFixProvider → controllable StreamController<LiveFixSample>
//   - trackingStateProvider → _FakeTrackingNotifier (mutable state)
//   - mapControllerProvider → null
//   - mapStyleLoadedTickProvider → bumped by tests to simulate style load

import 'dart:async';

import 'package:auto_explore/features/map/presentation/providers/live_trail_applier.dart';
import 'package:auto_explore/features/map/presentation/providers/map_controller_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_style_loaded_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/live_trail_bridge.dart';
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

sealed class _TrailCall {}

final class _AddOrUpdateCall extends _TrailCall {
  _AddOrUpdateCall(this.trail);
  final List<LatLng> trail;
}

final class _RemoveCall extends _TrailCall {}

class _FakeLiveTrailApplier implements LiveTrailApplier {
  final List<_TrailCall> calls = [];

  @override
  Future<void> addOrUpdate(
    MapLibreMapController? controller,
    List<LatLng> trail, {
    String? colorHex,
  }) async {
    calls.add(_AddOrUpdateCall(List<LatLng>.of(trail)));
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

LiveFixSample _fix(double lat, double lon) =>
    LiveFixSample(ts: DateTime(2026, 7, 11), lat: lat, lon: lon);

/// Fixture holding the mutable doubles the tests drive.
class _Fixture {
  _Fixture(this.fake, this.tracking, this.fixes);
  final _FakeLiveTrailApplier fake;
  final _FakeTrackingNotifier tracking;
  final StreamController<LiveFixSample> fixes;
}

Future<_Fixture> _pump(WidgetTester tester) async {
  final fake = _FakeLiveTrailApplier();
  final tracking = _FakeTrackingNotifier(const TrackingIdle());
  final fixes = StreamController<LiveFixSample>.broadcast();
  addTearDown(fixes.close);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        liveTrailApplierProvider.overrideWithValue(fake),
        liveFixProvider.overrideWith((ref) => fixes.stream),
        trackingStateProvider.overrideWith(() => tracking),
        mapControllerProvider.overrideWith(_NullMapControllerNotifier.new),
      ],
      child: const Directionality(
        textDirection: TextDirection.ltr,
        child: LiveTrailBridge(),
      ),
    ),
  );
  return _Fixture(fake, tracking, fixes);
}

void _bumpStyleTick(WidgetTester tester) {
  final element = tester.element(find.byType(LiveTrailBridge));
  ProviderScope.containerOf(element)
      .read(mapStyleLoadedTickProvider.notifier)
      .bump();
}

void main() {
  group('LiveTrailBridge', () {
    testWidgets('renders headless (SizedBox.shrink)', (tester) async {
      await _pump(tester);
      expect(
        find.descendant(
          of: find.byType(LiveTrailBridge),
          matching: find.byType(SizedBox),
        ),
        findsOneWidget,
      );
    });

    testWidgets('does not draw until 2 points accumulate, then addOrUpdate',
        (tester) async {
      final f = await _pump(tester);
      _bumpStyleTick(tester);
      await tester.pump();

      f.fixes.add(_fix(50, 9));
      await tester.pump();
      expect(f.fake.calls, isEmpty);

      f.fixes.add(_fix(50.001, 9));
      await tester.pump();
      expect(f.fake.calls, hasLength(1));
      final call = f.fake.calls.single;
      expect(call, isA<_AddOrUpdateCall>());
      expect((call as _AddOrUpdateCall).trail, hasLength(2));
    });

    testWidgets('each subsequent fix updates the trail (growing point count)',
        (tester) async {
      final f = await _pump(tester);
      _bumpStyleTick(tester);
      await tester.pump();

      for (var i = 0; i < 4; i++) {
        f.fixes.add(_fix(50.0 + i * 0.001, 9));
        await tester.pump();
      }

      final addCalls = f.fake.calls.whereType<_AddOrUpdateCall>().toList();
      expect(addCalls, hasLength(3));
      expect(addCalls.first.trail, hasLength(2));
      expect(addCalls.last.trail, hasLength(4));
    });

    testWidgets('clears + removes the trail on stop (→ TrackingIdle)',
        (tester) async {
      final f = await _pump(tester);
      _bumpStyleTick(tester);
      await tester.pump();

      f.tracking.emit(_recording());
      f.fixes.add(_fix(50, 9));
      f.fixes.add(_fix(50.001, 9));
      await tester.pump();
      expect(f.fake.calls.whereType<_AddOrUpdateCall>(), isNotEmpty);

      f.tracking.emit(const TrackingIdle());
      await tester.pump();
      expect(f.fake.calls.whereType<_RemoveCall>(), hasLength(1));

      final before = f.fake.calls.whereType<_AddOrUpdateCall>().length;
      f.fixes.add(_fix(51, 9));
      await tester.pump();
      expect(
        f.fake.calls.whereType<_AddOrUpdateCall>().length,
        before,
        reason: 'single post-stop point is below the 2-point draw floor',
      );
    });
  });
}
