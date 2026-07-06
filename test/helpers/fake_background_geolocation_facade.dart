import 'dart:async';

import 'package:auto_explore/features/trips/data/background_geolocation_facade.dart';
import 'package:auto_explore/features/trips/domain/tracking_diagnostics.dart';
import 'package:auto_explore/features/trips/domain/trip_fix_input.dart';

/// In-memory fake of [BackgroundGeolocationFacade] for unit tests.
///
/// Tracks call counts (for backwards-compatible callers) and exposes richer
/// state properties + emitter helpers used by TrackingService / TrackingNotifier
/// tests. The [notificationTexts] list accumulates every text so tests can
/// assert on notification history without fake_async.
class FakeBackgroundGeolocationFacade implements BackgroundGeolocationFacade {
  // Call count tracking (backwards-compat with existing callers).
  int readyCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;
  int showIgnoreBatteryOptimizationsCalls = 0;

  // Richer state flags used by TrackingService tests.
  bool get started => startCalls > 0 && stopCalls < startCalls;
  bool moving = false;
  bool get readyCalled => readyCalls > 0;

  /// When non-null, [ready] rethrows this instance (after recording the
  /// [FacadeReadyFailed] outcome). Lets diagnostics tests exercise the
  /// failed-ready code path without running native FGB.
  Object? readyError;

  FacadeReadyOutcome _readyOutcome = const FacadeReadyPending();

  @override
  FacadeReadyOutcome get currentReadyOutcome => _readyOutcome;

  final List<String> notificationTexts = [];
  String? get lastNotificationText =>
      notificationTexts.isEmpty ? null : notificationTexts.last;

  final _locations = StreamController<FixInput>.broadcast();
  final _motions = StreamController<MotionChange>.broadcast();
  final _activities = StreamController<ActivityChange>.broadcast();

  @override
  Future<void> ready() async {
    readyCalls++;
    final err = readyError;
    if (err != null) {
      _readyOutcome = FacadeReadyFailed(err.toString());
      // Rethrow arbitrary object so tests can force `_facade.ready()` failure
      // paths (matches the FGB facade's `on Object catch (e) { … rethrow; }`).
      // ignore: only_throw_errors
      throw err;
    }
    _readyOutcome = const FacadeReadySuccess();
  }

  @override
  Future<void> start() async => startCalls++;

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> changePace({required bool moving}) async => this.moving = moving;

  @override
  Future<void> setNotificationText(String text) async =>
      notificationTexts.add(text);

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
      FgbState(enabled: started, isMoving: moving);

  // ---------------------------------------------------------------------------
  // Test-only emitters
  // ---------------------------------------------------------------------------

  /// Emit a raw [FixInput] on the location stream.
  void emitFix(FixInput fix) => _locations.add(fix);

  /// Emit a [MotionChange] with the given [isMoving] flag and current time.
  void emitMotion({required bool isMoving}) => _motions.add(
    MotionChange(isMoving: isMoving, ts: DateTime.now()),
  );

  /// Emit an [ActivityChange] with [type] and optional [confidence].
  void emitActivity(String type, {int confidence = 90}) => _activities.add(
    ActivityChange(
      activityType: type,
      confidence: confidence,
      ts: DateTime.now(),
    ),
  );

  /// Close all stream controllers. Call in tearDown after the service is disposed.
  void dispose() {
    unawaited(_locations.close());
    unawaited(_motions.close());
    unawaited(_activities.close());
  }
}
