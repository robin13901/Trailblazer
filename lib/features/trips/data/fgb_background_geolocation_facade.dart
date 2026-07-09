// IMPORTANT: This is the ONLY file in lib/ that imports
// package:flutter_background_geolocation/... . All other code depends on the
// BackgroundGeolocationFacade interface only. This rule must be preserved
// across all future plans — it keeps FGB wiring testable and replaceable.
//
// Exception handling: raw exceptions are allowed to bubble from ready(),
// start(), and stop(). Wave 2's TrackingNotifier is the Result<T> boundary;
// wrapping here would lose the original stack trace and add no value for the
// caller.

import 'dart:async';

import 'package:auto_explore/features/trips/data/background_geolocation_facade.dart';
import 'package:auto_explore/features/trips/domain/tracking_diagnostics.dart';
import 'package:auto_explore/features/trips/domain/trip_fix_input.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as bg;
import 'package:logging/logging.dart';

/// FGB-backed implementation of [BackgroundGeolocationFacade].
///
/// Wraps every call to the native [bg.BackgroundGeolocation] API. No other
/// file in lib/ may import flutter_background_geolocation directly.
class FgbBackgroundGeolocationFacade implements BackgroundGeolocationFacade {
  FgbBackgroundGeolocationFacade();

  static final _log = Logger('fgb_facade');

  final _locations = StreamController<FixInput>.broadcast();
  final _motions = StreamController<MotionChange>.broadcast();
  final _activities = StreamController<ActivityChange>.broadcast();
  bool _ready = false;
  FacadeReadyOutcome _readyOutcome = const FacadeReadyPending();

  @override
  FacadeReadyOutcome get currentReadyOutcome => _readyOutcome;

  @override
  Future<void> ready() async {
    if (_ready) return;
    try {
      await bg.BackgroundGeolocation.ready(bg.Config(
        // Accuracy & fix rate
        desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
        distanceFilter: 0,
        locationUpdateInterval: 1000,
        fastestLocationUpdateInterval: 1000,
        // Lifecycle — Plan 06-08: manual-only recording. FGB is started only
        // for the duration of a manual trip and stopped on stopActive(), so
        // there is no idle foreground-service notification and no motion-wake
        // when the user is not recording.
        //   stopOnTerminate: true  → the service does not survive app kill
        //                            (no resurrection to record silently).
        //   startOnBoot: false     → the service does not auto-start on device
        //                            boot / motion (no spurious walk trips).
        //   enableHeadless: false  → headless was only needed for auto-wake;
        //                            manual trips run with the app alive.
        stopOnTerminate: true,
        startOnBoot: false,
        enableHeadless: false,
        // Android FGS notification (iOS shows the blue location bar; text is
        // not customisable on iOS — this config is Android-only in effect)
        notification: bg.Notification(
          title: 'Trailblazer',
          text: 'Recording · 00:00 · 0.0 km · — km/h',
          channelName: 'Trip recording',
          channelId: 'trailblazer.tracking',
          priority: bg.NotificationPriority.low,
          smallIcon: 'mipmap/ic_launcher',
          sticky: true,
        ),
        // iOS: show the blue background-location indicator bar
        showsBackgroundLocationIndicator: true,
        pausesLocationUpdatesAutomatically: false,
        // Logging
        // NOTE: FGB's `debug: true` plays audible diagnostic tones on every
        // location fix, motion change, and activity change. Off unconditionally
        // — the HUD (Plan 3.1-01) is the visual replacement.
        debug: false,
        logLevel: bg.Config.LOG_LEVEL_VERBOSE,
      ));

      bg.BackgroundGeolocation.onLocation(
        (loc) {
          _locations.add(_toFixInput(loc));
        },
        // Ignore location errors — FGB errors include expected states such as
        // "user cancelled" and permission denials. Wave 2's TrackingNotifier
        // surfaces permission issues via the permission-ladder flow.
        (_) {},
      );
      bg.BackgroundGeolocation.onMotionChange((loc) {
        _motions.add(MotionChange(
          isMoving: loc.isMoving,
          ts: _parseTimestamp(loc.timestamp),
        ));
      });
      bg.BackgroundGeolocation.onActivityChange((e) {
        _activities.add(ActivityChange(
          activityType: e.activity,
          confidence: e.confidence,
          ts: DateTime.now(),
        ));
      });
      _ready = true;
      _readyOutcome = const FacadeReadySuccess();
      // The raw exception continues to bubble to the caller. Wave 2's
      // TrackingService will add a Result<T>/DomainError boundary — this file
      // only records the outcome for the debug HUD.
    } on Object catch (e) {
      _readyOutcome = FacadeReadyFailed(e.toString());
      rethrow;
    }
  }

  /// Convert a [bg.Location] into the FGB-agnostic [FixInput] DTO.
  FixInput _toFixInput(bg.Location loc) {
    return FixInput(
      ts: _parseTimestamp(loc.timestamp),
      lat: loc.coords.latitude,
      lon: loc.coords.longitude,
      accuracyMeters: loc.coords.accuracy,
      speedMps: loc.coords.speed >= 0 ? loc.coords.speed : null,
      // Course over ground (0..360). FGB reports -1 for unknown/invalid
      // (e.g. while stationary) — map any negative/out-of-range value to
      // null so TrackingService can fall back to the computed motion-vector
      // bearing (Plan 06-07).
      headingDegrees:
          loc.coords.heading >= 0 && loc.coords.heading <= 360
              ? loc.coords.heading
              : null,
      altitudeMeters: loc.coords.altitude,
      activityType: loc.activity.type,
      uuid: loc.uuid,
    );
  }

  /// Parse FGB's [dynamic] timestamp, which is either an ISO-8601 [String]
  /// (default `timestampFormat: "iso"`) or epoch-milliseconds [int]
  /// (`timestampFormat: "epoch"`). Falls back to [DateTime.now()] if the
  /// value cannot be parsed.
  static DateTime _parseTimestamp(dynamic value) {
    if (value is String && value.isNotEmpty) {
      return DateTime.parse(value);
    }
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value);
    }
    return DateTime.now();
  }

  @override
  Future<void> start() => bg.BackgroundGeolocation.start();

  @override
  Future<void> stop() => bg.BackgroundGeolocation.stop();

  @override
  Future<void> changePace({required bool moving}) =>
      bg.BackgroundGeolocation.changePace(moving);

  @override
  Future<void> setNotificationText(String text) async {
    await bg.BackgroundGeolocation.setConfig(bg.Config(
      notification: bg.Notification(title: 'Trailblazer', text: text),
    ));
  }

  @override
  Future<void> showIgnoreBatteryOptimizations() async {
    // bg.DeviceSettings is Android-only; on iOS this will throw, which we
    // swallow. Wave 2's TrackingNotifier guards with a Platform.isAndroid check
    // before calling this method.
    try {
      final req = await bg.DeviceSettings.showIgnoreBatteryOptimizations();
      await bg.DeviceSettings.show(req);
    } on Object catch (e, st) {
      // Plan 03-1-02 H5 fix: widened from `on Exception` to `on Object` so
      // Error subclasses (some OEM implementations throw `PlatformException`
      // or a Dart `Error`, not `Exception`) do not silently escape a
      // fire-and-forget helper. Caller (permission_motion_notification_page)
      // verifies the grant post-return via
      // PermissionService.statusIgnoreBatteryOptimizations.
      _log.warning('showIgnoreBatteryOptimizations failed: $e', e, st);
    }
  }

  @override
  Stream<FixInput> get onLocation => _locations.stream;

  @override
  Stream<MotionChange> get onMotionChange => _motions.stream;

  @override
  Stream<ActivityChange> get onActivityChange => _activities.stream;

  @override
  Future<FgbState> currentState() async {
    final s = await bg.BackgroundGeolocation.state;
    return FgbState(enabled: s.enabled, isMoving: s.isMoving ?? false);
  }
}
