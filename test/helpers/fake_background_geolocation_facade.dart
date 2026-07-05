import 'dart:async';

import 'package:auto_explore/features/trips/data/background_geolocation_facade.dart';
import 'package:auto_explore/features/trips/domain/trip_fix_input.dart';

/// Test double for [BackgroundGeolocationFacade].
///
/// Records calls and provides no-op implementations. Used in widget and
/// unit tests to avoid native FGB initialization.
class FakeBackgroundGeolocationFacade implements BackgroundGeolocationFacade {
  int readyCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;
  int showIgnoreBatteryOptimizationsCalls = 0;

  final _locations = StreamController<FixInput>.broadcast();
  final _motions = StreamController<MotionChange>.broadcast();
  final _activities = StreamController<ActivityChange>.broadcast();

  @override
  Future<void> ready() async => readyCalls++;

  @override
  Future<void> start() async => startCalls++;

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> changePace({required bool moving}) async {}

  @override
  Future<void> setNotificationText(String text) async {}

  @override
  Future<void> showIgnoreBatteryOptimizations() async =>
      showIgnoreBatteryOptimizationsCalls++;

  @override
  Stream<FixInput> get onLocation => _locations.stream;

  @override
  Stream<MotionChange> get onMotionChange => _motions.stream;

  @override
  Stream<ActivityChange> get onActivityChange => _activities.stream;

  @override
  Future<FgbState> currentState() async =>
      const FgbState(enabled: false, isMoving: false);

  void dispose() {
    unawaited(_locations.close());
    unawaited(_motions.close());
    unawaited(_activities.close());
  }
}
