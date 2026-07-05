---
id: 03-03
phase: 03-tracking-mvp
plan: 03
type: execute
wave: 1
depends_on: []
files_modified:
  - pubspec.yaml
  - pubspec.lock
  - android/app/src/main/AndroidManifest.xml
  - ios/Runner/Info.plist
  - ios/Podfile.lock
  - lib/features/trips/data/background_geolocation_facade.dart
  - lib/features/trips/data/fgb_background_geolocation_facade.dart
  - test/features/trips/data/background_geolocation_facade_test.dart
autonomous: true
requirements_addressed: [TRK-01, TRK-10, TRK-11]

must_haves:
  truths:
    - "`flutter_background_geolocation ^5.3.0` is a direct dependency in pubspec.yaml, alphabetized"
    - "Android manifest no longer contains the Phase-1 placeholder `<service android:name=\".LocationRecordingService\" ...>` block — FGB merges its own service via manifest merge"
    - "iOS Info.plist `UIBackgroundModes` array includes both `location` AND `fetch` (fetch was missing in P1)"
    - "A thin `BackgroundGeolocationFacade` interface exists that Wave 2 code depends on — the real FGB call sites live only inside `FgbBackgroundGeolocationFacade`"
    - "`bg.BackgroundGeolocation.ready(...)` can be invoked from a scratch smoke test main without native crashes (pod install / manifest merge succeed)"
  artifacts:
    - path: "pubspec.yaml"
      provides: "FGB dependency"
      contains: "flutter_background_geolocation:"
    - path: "lib/features/trips/data/background_geolocation_facade.dart"
      provides: "Abstract interface — start/stop/changePace/onLocation/onMotionChange/setNotificationText/state"
      contains: "abstract interface class BackgroundGeolocationFacade"
    - path: "lib/features/trips/data/fgb_background_geolocation_facade.dart"
      provides: "Real FGB-backed impl"
      contains: "class FgbBackgroundGeolocationFacade"
    - path: "android/app/src/main/AndroidManifest.xml"
      provides: "Manifest without placeholder service; permissions intact"
    - path: "ios/Runner/Info.plist"
      provides: "UIBackgroundModes with location + fetch"
      contains: "fetch"
  key_links:
    - from: "lib/features/trips/data/fgb_background_geolocation_facade.dart"
      to: "package:flutter_background_geolocation/flutter_background_geolocation.dart"
      via: "import as bg — the only file in the tree that imports FGB directly"
      pattern: "flutter_background_geolocation.*as bg"
    - from: "Wave 2 (tracking_service, tracking_state_provider)"
      to: "background_geolocation_facade.dart interface"
      via: "constructor injection of BackgroundGeolocationFacade"
      pattern: "BackgroundGeolocationFacade"
---

<objective>
Land the FGB dependency + native install steps, delete the Phase-1 placeholder Android service, add the missing iOS `fetch` background mode, and introduce a thin `BackgroundGeolocationFacade` interface that isolates every FGB call site to a single file. Wave 2 (TrackingNotifier + tracking_service) depends on this seam for testability — the interface is the ONLY thing that leaves this file.

Purpose: TRK-01 (background tracking via FGB) and TRK-10/11 (permission ladder + FGS notification) require the plugin to be installed and its native pieces correctly wired. Facade-first also unblocks Plan 03-04 from being blocked on real FGB behavior — Wave 2's tests can inject a fake.

Output: FGB installed cleanly on both platforms, manifest hygiene done, facade interface + concrete FGB impl, one smoke test that verifies the abstract interface is stable.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/STATE.md
@.planning/phases/03-tracking-mvp/03-CONTEXT.md
@.planning/phases/03-tracking-mvp/03-RESEARCH.md

# Files being touched
@pubspec.yaml
@android/app/src/main/AndroidManifest.xml
@ios/Runner/Info.plist

# STATE.md 01-05 decision: `.LocationRecordingService` was a P1 placeholder — P3 must rebind or delete.
# RESEARCH.md §"Android — AndroidManifest.xml" and §"Pitfall 2" say DELETE, not rebind.

# Package name is `auto_explore` — use `package:auto_explore/…` in all imports.
</context>

<tasks>

<task type="auto">
  <name>Task 1: Add FGB dependency + native install (manifest + Info.plist + pod install)</name>
  <files>
    - pubspec.yaml
    - pubspec.lock
    - android/app/src/main/AndroidManifest.xml
    - ios/Runner/Info.plist
    - ios/Podfile.lock
  </files>
  <action>
    1. Add FGB to `pubspec.yaml`:
       ```yaml
       dependencies:
         # … alphabetized:
         flutter_background_geolocation: ^5.3.0
       ```
       Slots between `drift_flutter` and `flutter_riverpod` (verify against STATE.md 01-01: `sort_pub_dependencies` lint enforces alphabetization — the linter WILL fail the build if this is out of order).

    2. `flutter pub get` — verify `pubspec.lock` updates cleanly. No `pub upgrade` unless dependency resolution fails.

    3. Edit `android/app/src/main/AndroidManifest.xml`:
       - **Delete** the placeholder `<service android:name=".LocationRecordingService" ...>` block introduced in Plan 01-05 (see STATE.md 01-05 decision). Do NOT rebind it to FGB's real service class — FGB merges its own `<service>` via manifest merge (verified from RESEARCH.md sources; confirmed via the FGB Android install guide). Keeping our own placeholder AND letting FGB merge in its own would trigger `AAPT: duplicate service` at build time (Pitfall 2).
       - Leave every `<uses-permission>` line untouched (`ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, `ACCESS_BACKGROUND_LOCATION`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION`, `ACTIVITY_RECOGNITION`, `POST_NOTIFICATIONS`, `WAKE_LOCK` per STATE.md 01-05).
       - Leave `<application android:label="Trailblazer" …>` and everything else alone.

    4. Edit `ios/Runner/Info.plist`:
       - Locate the `UIBackgroundModes` array. Current value from Plan 01-05: `[location, bluetooth-central]`.
       - Add a third string: `<string>fetch</string>`. Final array: `[location, bluetooth-central, fetch]`.
       - Do NOT add `BGTaskSchedulerPermittedIdentifiers` in this plan — RESEARCH.md flags it as "add if FGB startup logs complain". Wave 4 real-device smoke test will surface the need.
       - Leave `NSLocationWhenInUseUsageDescription`, `NSLocationAlwaysAndWhenInUseUsageDescription`, `NSLocationAlwaysUsageDescription`, `NSMotionUsageDescription` unchanged — Plan 01-05 already renamed them for Trailblazer.

    5. iOS pods:
       ```bash
       cd ios && pod repo update && pod install && cd ..
       ```
       First install pulls `TSLocationManager` (~50 MB). Verify `ios/Podfile.lock` updates.

       **Note on Windows dev boxes:** `pod install` requires macOS. If executing on Windows (per this session's env), document the step in the SUMMARY and defer to the user's next macOS session or CI's `iOS Build` workflow. The Android side and Dart-level facade Task 2 CAN be completed on Windows. Do NOT skip Task 2 waiting for pod install.

    Anti-patterns to avoid:
    - Do NOT rebind `android:name` on the placeholder service to some FGB class name (STATE.md 01-05 mentioned "rebind" as one option; RESEARCH.md later determined DELETE is correct).
    - Do NOT bump `minSdkVersion` — STATE.md 01-05 explicitly locked "no minSdk bump — permissions gated at runtime".
    - Do NOT add `optimize_battery` / `disable_battery_optimization` packages — Wave 2 uses FGB's `bg.DeviceSettings.showIgnoreBatteryOptimizations()` (per RESEARCH.md §"Permission Ladder").
    - Do NOT add `app_settings` — Wave 2 uses `permission_handler`'s `openAppSettings()` for the yellow-banner deep-link.
  </action>
  <verify>
    - `flutter pub get` clean, `flutter analyze` clean
    - `flutter build apk --debug` succeeds (no duplicate-service AAPT error)
    - `pubspec.yaml` still passes `sort_pub_dependencies` (alphabetized)
    - `grep -n "LocationRecordingService" android/app/src/main/AndroidManifest.xml` returns nothing
    - `grep -n "fetch" ios/Runner/Info.plist` — one match inside `UIBackgroundModes`
  </verify>
  <done>
    FGB installed, manifest cleaned, `UIBackgroundModes` gains `fetch`, Android debug APK builds without duplicate-service errors. If on Windows, iOS pods are documented as a pending step in SUMMARY.
  </done>
</task>

<task type="auto">
  <name>Task 2: BackgroundGeolocationFacade interface + FGB-backed impl + interface stability test</name>
  <files>
    - lib/features/trips/data/background_geolocation_facade.dart
    - lib/features/trips/data/fgb_background_geolocation_facade.dart
    - test/features/trips/data/background_geolocation_facade_test.dart
  </files>
  <action>
    1. `lib/features/trips/data/background_geolocation_facade.dart` — the ONLY interface Wave 2 imports:
       ```dart
       import 'package:auto_explore/features/trips/domain/trip_fix_input.dart';

       abstract interface class BackgroundGeolocationFacade {
         /// Initialise the plugin. Idempotent — calling twice is a no-op on the second call.
         Future<void> ready();
         Future<void> start();
         Future<void> stop();
         /// Force motion state — used by the manual FAB. true = start recording, false = stop.
         Future<void> changePace({required bool moving});
         /// Update the sticky notification text (Android FGS). No-op on iOS.
         Future<void> setNotificationText(String text);
         /// Ask FGB to open Android's Ignore-Battery-Optimizations settings. No-op on iOS.
         Future<void> showIgnoreBatteryOptimizations();

         Stream<FixInput> get onLocation;
         Stream<MotionChange> get onMotionChange;
         Stream<ActivityChange> get onActivityChange;

         /// Current in-flight state, for cold-start hydration.
         Future<FgbState> currentState();
       }

       class MotionChange {
         const MotionChange({required this.isMoving, required this.ts});
         final bool isMoving;
         final DateTime ts;
       }

       class ActivityChange {
         const ActivityChange({required this.activityType, required this.confidence, required this.ts});
         final String activityType; // 'still' | 'in_vehicle' | ...
         final int confidence;
         final DateTime ts;
       }

       class FgbState {
         const FgbState({required this.enabled, required this.isMoving});
         final bool enabled;
         final bool isMoving;
       }
       ```

    2. `lib/features/trips/data/fgb_background_geolocation_facade.dart` — the only file in `lib/` that imports FGB:
       ```dart
       import 'dart:async';
       import 'package:flutter/foundation.dart';
       import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;

       import 'package:auto_explore/features/trips/data/background_geolocation_facade.dart';
       import 'package:auto_explore/features/trips/domain/trip_fix_input.dart';

       class FgbBackgroundGeolocationFacade implements BackgroundGeolocationFacade {
         FgbBackgroundGeolocationFacade();

         final _locations = StreamController<FixInput>.broadcast();
         final _motions = StreamController<MotionChange>.broadcast();
         final _activities = StreamController<ActivityChange>.broadcast();
         bool _ready = false;

         @override
         Future<void> ready() async {
           if (_ready) return;
           await bg.BackgroundGeolocation.ready(bg.Config(
             desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
             distanceFilter: 0,
             locationUpdateInterval: 1000,
             fastestLocationUpdateInterval: 1000,
             stopOnTerminate: false,
             startOnBoot: true,
             enableHeadless: true,
             notification: bg.Notification(
               title: 'Trailblazer',
               text: 'Recording · 00:00 · 0.0 km · — km/h',
               channelName: 'Trip recording',
               channelId: 'trailblazer.tracking',
               priority: bg.Config.NOTIFICATION_PRIORITY_LOW,
               smallIcon: 'mipmap/ic_launcher',
               sticky: true,
             ),
             showsBackgroundLocationIndicator: true,
             pausesLocationUpdatesAutomatically: false,
             debug: kDebugMode,
             logLevel: bg.Config.LOG_LEVEL_VERBOSE,
           ));

           bg.BackgroundGeolocation.onLocation((bg.Location loc) {
             _locations.add(_toFixInput(loc));
           }, (bg.LocationError err) {
             // Log via project logger, but do not surface as a Dart error — FGB errors
             // include "user cancelled" and permission denials that are expected.
           });
           bg.BackgroundGeolocation.onMotionChange((bg.Location loc) {
             _motions.add(MotionChange(
               isMoving: loc.isMoving,
               ts: DateTime.parse(loc.timestamp as String),
             ));
           });
           bg.BackgroundGeolocation.onActivityChange((bg.ActivityChangeEvent e) {
             _activities.add(ActivityChange(
               activityType: e.activity,
               confidence: e.confidence,
               ts: DateTime.now(),
             ));
           });
           _ready = true;
         }

         FixInput _toFixInput(bg.Location loc) {
           return FixInput(
             ts: DateTime.parse(loc.timestamp as String),
             lat: loc.coords.latitude,
             lon: loc.coords.longitude,
             accuracyMeters: loc.coords.accuracy,
             speedMps: loc.coords.speed >= 0 ? loc.coords.speed : null,
             altitudeMeters: loc.coords.altitude,
             activityType: loc.activity.type,
             uuid: loc.uuid,
           );
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
           // Guard by Platform check — the API is Android-only in FGB.
           // Verify exact method name at execute-time (RESEARCH.md flagged as LOW-confidence);
           // fallback: use permission_handler openAppSettings() if this method is renamed.
           try {
             final req = await bg.DeviceSettings.showIgnoreBatteryOptimizations();
             await bg.DeviceSettings.show(req);
           } catch (_) {
             // Method may be named differently in 5.3.0; caller falls back to openAppSettings.
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
           return FgbState(enabled: s.enabled, isMoving: s.isMoving);
         }
       }
       ```
       Wrap non-DomainError throwables with `DomainError.wrap(e, st)` inside `ready()` / `start()` / `stop()` and rethrow if it's helpful for the caller — but consider: since Wave 2's TrackingNotifier is the caller and it does Result<T> boundaries there, it's simpler to let raw exceptions bubble here and wrap once at the notifier boundary. **Decision:** raw here, wrap in Wave 2. Document this choice inline as a comment.

    3. `test/features/trips/data/background_geolocation_facade_test.dart` — a small "interface exists" smoke test. This is NOT a functional test of FGB (that needs a real device). It's a stability contract test:
       ```dart
       import 'package:auto_explore/features/trips/data/background_geolocation_facade.dart';
       import 'package:auto_explore/features/trips/domain/trip_fix_input.dart';
       import 'package:flutter_test/flutter_test.dart';

       class _FakeFacade implements BackgroundGeolocationFacade { /* stub every method */ }

       void main() {
         test('BackgroundGeolocationFacade can be implemented by a fake', () {
           final f = _FakeFacade();
           expect(f, isA<BackgroundGeolocationFacade>());
         });
         test('MotionChange / ActivityChange / FgbState are const-constructable', () {
           const mc = MotionChange(isMoving: true, ts: /*const DateTime not allowed*/ …);
           // Since DateTime isn't const, verify normal construction instead.
           final s = const FgbState(enabled: true, isMoving: false);
           expect(s.enabled, true);
         });
       }
       ```
       This test is a canary: if a later plan renames or removes a facade method, this test fails immediately.

    Anti-patterns to avoid:
    - Do NOT let ANY file outside `fgb_background_geolocation_facade.dart` import `package:flutter_background_geolocation/...`. Wave 2 and beyond depend on the abstract interface only. Add a comment at the top of the facade explaining this rule.
    - Do NOT expose `bg.Location` from the facade. Convert to `FixInput` at the seam.
    - Do NOT provide a Riverpod provider for the facade in this plan — that's Wave 2's `tracking_service_providers.dart`. Keep 03-03 free of Wave-2 leakage.
    - Do NOT commit the smoke-test `main.dart` snippet from RESEARCH.md's cheat sheet. That was verification-only; the real integration lives in Wave 2.
  </action>
  <verify>
    - `flutter analyze` clean — no unused imports, no analyzer warnings from FGB usage
    - `flutter test test/features/trips/data/background_geolocation_facade_test.dart` green
    - `grep -rn "package:flutter_background_geolocation" lib/` — matches ONLY `lib/features/trips/data/fgb_background_geolocation_facade.dart`
  </verify>
  <done>
    Wave 2 has a clean seam: a `BackgroundGeolocationFacade` interface (7 methods + 3 streams) and one concrete FGB-backed implementation. Interface is the single import surface for downstream code.
  </done>
</task>

</tasks>

<verification>
- `flutter analyze` clean
- `flutter test` green (unit tests unaffected by native)
- `flutter build apk --debug` builds successfully — no manifest merge errors
- `pubspec.yaml` alphabetization holds (`sort_pub_dependencies`)
- No file outside the facade imports FGB directly
- Commit: `feat(03-03): install flutter_background_geolocation + facade seam`
</verification>

<success_criteria>
- FGB 5.3.0 installed, manifest hygiene done, iOS `fetch` mode added
- Wave 2 has exactly one interface (`BackgroundGeolocationFacade`) to depend on — enables `FakeBackgroundGeolocationFacade` in unit tests without native
- Every Phase-1 permission from Plan 01-05 remains declared (no regression)
</success_criteria>

<output>
After completion, create `.planning/phases/03-tracking-mvp/03-03-SUMMARY.md`
</output>
