# Phase 3: Tracking MVP — Research

**Researched:** 2026-07-05
**Domain:** Background GPS tracking, motion-activity fusion, Drift schema for trip polylines, Riverpod state exposure for a long-running foreground service, iOS/Android permission ladder, foreground-service notification, battery baselining.
**Confidence:** HIGH on FGB API surface + package versions + Drift/permission_handler patterns; MEDIUM on iOS blue-bar customizability + `flutter_background_geolocation` Android manifest merging (verified via install guide but exact service class name not disclosed in public docs — trust plugin's own manifest merge, keep the placeholder `<service>` tag inert or delete it); LOW on exact SM S24 `dumpsys` calibration numbers — that lives in the baseline artifact once measured.

## Summary

Phase 3 is a well-scoped port of the Transistor Software `flutter_background_geolocation` plugin (FGB) onto Phase 1's Drift schema, wrapped in Riverpod state, and gated by a three-step permission ladder that runs during onboarding. FGB does all the heavy lifting (motion-detection fusion, background wake, foreground-service notification, buffered location queue, activity-recognition classifier). Phase 3's job is:

1. Wire FGB (config + event listeners + native install steps),
2. Translate FGB events into Drift `trips` + `trip_points` rows via a **pure-Dart fix ingestor** that owns accuracy filtering, gap detection, split-trip logic, and 20-fix batching,
3. Expose recording state to the UI through a Riverpod `Notifier`,
4. Morph the P2 FAB into a red Stop button and slot a live-stats glass panel above the bottom-nav pill,
5. Extend the onboarding flow to walk the user through whenInUse → Always → Motion (iOS) / battery-optimization (Android), with a persistent yellow banner as the denial-recovery affordance,
6. Ship a `tool/battery_baseline.dart` + `docs/battery-baseline.md` reference measurement.

**Primary recommendation:** Pin `flutter_background_geolocation: ^5.3.0`, use `DesiredAccuracy.high` (NOT `navigation` — that's what CONTEXT calls "Best" not "BestForNavigation"), `distanceFilter: 0` with `locationUpdateInterval: 1000` (1 Hz), keep `disableStopDetection: false` and trust FGB's motion state machine for auto-trip start/stop. Store GPS as child rows in the existing `trip_points` table (already scaffolded in Phase 1). Build the fix pipeline as a pure-Dart `TripFixIngestor` that FGB feeds — this makes 80% of P3 unit-testable without touching native.

## Standard Stack

### Core (new to Phase 3)

| Library | Version | Purpose | Why Standard |
|---|---|---|---|
| `flutter_background_geolocation` | `^5.3.0` (pub.dev latest 2026-06-22) | Background GPS + motion classifier + FGS notification + buffered persistence | Only production-grade Flutter option — Transistor's `TSLocationManager` is the reference implementation; FGB wraps it. Apache-2.0 SDK; only Android **release** builds require a paid license — DEBUG + iOS are unrestricted (verified from pub.dev listing). Phase 3 ships debug builds only per project's "no store publication yet" posture. Roadmap already accepts the future ~USD 400–1200 release-license cost. |
| `permission_handler` | `^12.0.3` (already in `pubspec.yaml`) | `Permission.locationWhenInUse` / `.locationAlways` / `.notification` requests, `openAppSettings()` deep-link | Already the P1 choice. FGB has its own `requestPermission()` but it fuses whenInUse+Always into one call; permission_handler gives us the two-step ladder we've decided on. |
| `app_settings` | `^6.1.1` | Deep-link to OS Settings page for the yellow-banner recovery path | permission_handler's `openAppSettings()` opens the app's OS settings — sufficient. Only add `app_settings` if we need channel-specific deep-links (notification channel, battery-optimization page). Recommendation: **stick with `openAppSettings()` from permission_handler; do not add `app_settings`.** |

### Supporting (already in `pubspec.yaml`, reused)

| Library | Version | Reuse |
|---|---|---|
| `drift` / `drift_flutter` | `^2.34.0` / `^0.3.0` | Batched writes to `trips` + `trip_points` via `AppDatabase` |
| `flutter_riverpod` | `^3.3.2` | Plain `Provider<TrackingState>` + `Notifier`, codegen OFF (per STATE.md 01-01) |
| `permission_handler` | `^12.0.3` | Extended usage — currently only `locationWhenInUse`, P3 adds `locationAlways` + `notification` |
| `shared_preferences` | `^2.5.5` | Extend `OnboardingFlagRepository` pattern for `permission_ladder_done` if needed |
| `logging` | `^1.3.0` | `Logger('tracking')` per Plan 01-04 convention |

### Alternatives Considered

| Instead of | Could Use | Tradeoff / Why Rejected |
|---|---|---|
| `flutter_background_geolocation` | `background_locator_2` + `flutter_activity_recognition` + platform-channel FGS | **Rejected.** Roadmap already picked FGB (STATE.md Decisions). Alternative requires hand-rolling the motion state machine, foreground-service lifecycle, background wake, buffered queue, and iOS pause-resume — 3–4 plans of native code each, with worse battery. FGB's paid license is cheaper than the eng time. |
| `flutter_background_geolocation` | `geolocator` foreground-only | Cannot do TRK-01 (background auto-detect). Out of the question for P3. |
| child `trip_points` table | JSON blob column on `trips` | P5 matcher iterates every fix (HMM Viterbi) → indexed child table wins on read. P6 inbox needs summaries (count/distance/duration/bbox) that we denormalize on the `trips` row → summary reads are cheap regardless. Table already exists (Phase 1 scaffold, see `lib/core/db/tables/trip_points_table.dart`). **Keep table.** |
| `openAppSettings()` (permission_handler) | `app_settings ^6.1.1` for channel-specific pages | permission_handler's variant lands on the app's Settings page, which is where the user needs to toggle Always/Battery-Optimization anyway. Skip `app_settings`. |

**Install:**
```bash
flutter pub add flutter_background_geolocation:^5.3.0
# (permission_handler, drift*, shared_preferences already present)
```

Then `dart pub upgrade` and re-verify `sort_pub_dependencies` alphabetization — FGB slots between `drift_flutter` and `flutter_riverpod`.

## FGB Setup Cheat Sheet (verified from example + source, HIGH confidence)

**Import alias** (matches the plugin's own example):
```dart
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;
```

**Ready call (Trailblazer-tuned, per CONTEXT decisions):**
```dart
await bg.BackgroundGeolocation.ready(bg.Config(
  // --- accuracy & fix rate ---
  desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,  // == GPS + network; NOT navigation
  distanceFilter: 0,                                  // deliver every update; we filter in Dart
  locationUpdateInterval: 1000,                       // Android target: 1 Hz
  fastestLocationUpdateInterval: 1000,                // never faster than 1 Hz
  // --- lifecycle ---
  stopOnTerminate: false,     // service survives task-kill
  startOnBoot: true,          // survives reboot
  enableHeadless: true,       // Dart isolate wakes on background events
  // --- motion / auto-trip ---
  //  Trust FGB defaults (per CONTEXT). No overrides to activityRecognitionInterval /
  //  stopTimeout / disableStopDetection.
  // --- notification (Android FGS text — see live-updates section) ---
  notification: bg.Notification(
    title: 'Trailblazer',
    text: 'Recording · 00:00 · 0.0 km · — km/h',
    channelName: 'Trip recording',
    channelId: 'trailblazer.tracking',    // Claude's discretion — lock this here
    priority: bg.Config.NOTIFICATION_PRIORITY_LOW,  // LOW = no sound, visible on lockscreen
    smallIcon: 'mipmap/ic_launcher',       // reuses P1 launcher icon
    sticky: true,                          // FGS-mandatory: not dismissible while active
  ),
  // --- iOS: allow the blue-bar background-indicator to appear ---
  showsBackgroundLocationIndicator: true,
  pausesLocationUpdatesAutomatically: false,  // we own the pause logic in Dart
  // --- logging ---
  debug: kDebugMode,
  logLevel: bg.Config.LOG_LEVEL_VERBOSE,
));
```

**Event listeners** (retain `bg.Subscription` handles; unsubscribe in `dispose`):
```dart
final subs = <bg.Subscription>[];
subs.add(bg.BackgroundGeolocation.onLocation(_onLocation, _onLocationError));
subs.add(bg.BackgroundGeolocation.onMotionChange(_onMotionChange));
subs.add(bg.BackgroundGeolocation.onActivityChange(_onActivityChange));
subs.add(bg.BackgroundGeolocation.onProviderChange(_onProviderChange));
// (do NOT hook onHttp / onGeofence — unused in P3)
```

**Start / Stop / query current state:**
```dart
await bg.BackgroundGeolocation.start();               // begin motion detection
await bg.BackgroundGeolocation.stop();                // full stop
final bg.State s = await bg.BackgroundGeolocation.state; // enabled + isMoving
final bg.Location now = await bg.BackgroundGeolocation.getCurrentPosition(
  samples: 1, timeout: 10,
);
// Buffered queue — useful for reconstruction after app resume:
final List<dynamic> queued = await bg.BackgroundGeolocation.locations;
```

**Change pace (manual FAB start / stop force-move-state)**:
```dart
// Force "moving" (manual start) — FGB begins high-frequency location tracking
await bg.BackgroundGeolocation.changePace(true);
// Force "stationary" (manual stop) — FGB stops tracking, drops back to motion-detect
await bg.BackgroundGeolocation.changePace(false);
```

## Data Model on Location (verified from `lib/models/location.dart`, HIGH confidence)

```
Location:
  timestamp    dynamic   // ISO 8601 string
  recordedAt   dynamic
  isMoving     bool
  uuid         String
  event        String
  odometer     double    // meters, cumulative for the enabled session
  coords:      Coords {
    latitude, longitude, accuracy, altitude, ellipsoidalAltitude,
    heading, headingAccuracy, speed, speedAccuracy, altitudeAccuracy
  }
  activity     Activity {
    type       String    // 'still' | 'on_foot' | 'walking' | 'running'
                         // | 'on_bicycle' | 'in_vehicle' | 'unknown'
    confidence int       // 0..100
  }
  battery, sample, mock, extras, geofence?
```

**Critical insight — motion activity IS on every Location.** No need to correlate `onLocation` + `onActivityChange` streams. Just read `location.activity.type` and `location.activity.confidence` per fix and persist to `trip_points.motion_type`. `onActivityChange` becomes an *informational* listener only (useful for auto-stop dwell timer, not for per-fix labeling).

## Native Install (both platforms)

### Android — `android/app/src/main/AndroidManifest.xml`

**Delete the placeholder** — Phase 1's `<service android:name=".LocationRecordingService" .../>` is inert and will confuse readers. FGB merges its own service (`com.transistorsoft.locationmanager.service.LocationRequestService` and adapters) via manifest merge; the app manifest doesn't declare it. Verified from install guide: no user-provided `<service>` tag is required.

**Permissions already present** (from Plan 01-05, verified above):
`ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, `ACCESS_BACKGROUND_LOCATION`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION`, `ACTIVITY_RECOGNITION`, `POST_NOTIFICATIONS`, `WAKE_LOCK`. **No manifest changes needed for permissions.**

**`android/build.gradle`** — set `google-services` version if FGB's install guide asks (typically no change), and confirm `minSdkVersion` still 21 (Phase 1 fine).

**Battery-optimization prompt** — no manifest change, done at runtime via a platform-channel intent (see "Permission Ladder" below).

### iOS — `ios/Runner/Info.plist`

**Already present** (Phase 1, verified above): `NSLocationWhenInUseUsageDescription`, `NSLocationAlwaysAndWhenInUseUsageDescription`, `NSLocationAlwaysUsageDescription`, `NSMotionUsageDescription`, `UIBackgroundModes = [location, bluetooth-central]`.

**Add for FGB (verified from install guide):**
- `UIBackgroundModes` must include `"fetch"` in addition to `"location"` — FGB uses `BGTaskScheduler` for periodic heartbeats. **Currently missing.**
- Optional: `BGTaskSchedulerPermittedIdentifiers = ["com.transistorsoft.fetch"]` for scheduled background fetch. Add if FGB startup logs complain; not otherwise required for TRK-01/03/04.

**Xcode capabilities** — enable "Background Modes → Location updates + Background fetch" checkboxes. Info.plist entry is sufficient; the Xcode UI change writes the same key. Verify in `Runner.xcworkspace` after `pod install`.

**Pods** — `pod install` in `ios/` will pull `TSLocationManager` (Transistor's native SDK). Add `pod repo update` recipe to the plan; first-time pull is ~50 MB.

## Motion-Activity Storage Decision (HIGH confidence)

**Decision: sample per-fix from `location.activity.type`, NOT debounce via `onActivityChange`.**

**Rationale:** FGB emits `ActivityChangeEvent` only on classifier *transitions* (`in_vehicle → still` etc.). Between transitions there's no event. But every `Location` event already carries the *current* activity classification. So the per-fix column reads directly:

```dart
tripPointsInsert(TripPointsCompanion.insert(
  ...,
  motionType: Value(loc.activity.type),  // e.g. 'in_vehicle'
));
```

This gives P5 (matcher) and P6 (inbox) the full per-fix signal without a separate join or a debounce-and-fill table. Cost: 1 tiny string per row × ~3600 rows/hour = negligible.

`onActivityChange` remains useful *only* for the auto-stop dwell timer — start a 2-minute countdown when the emitted `activity` becomes non-automotive, cancel on the next automotive event.

## App Resume Mid-Trip (HIGH confidence)

Path when the app is opened while a background trip is in progress:

1. `main()` calls `bg.BackgroundGeolocation.ready(...)` (idempotent — plugin recognises existing session).
2. Read `bg.State s = await bg.BackgroundGeolocation.state` → `s.enabled` + `s.isMoving` tell us whether tracking is active.
3. Query the App DB for the newest `trips` row with `endedAt IS NULL` — that's the in-flight trip.
4. Read `trip_points WHERE trip_id = ? ORDER BY seq ASC` to seed the polyline for the map overlay.
5. Compute overlay stats from those rows (duration, distance, current speed = last point's speedKmh).
6. Subscribe fresh `onLocation` listener; it appends to the same trip.

**Buffer recovery on cold-start** — if the app was killed but the FGS kept running (`stopOnTerminate: false`), locations accrue in FGB's internal SQLite queue. On resume, `await bg.BackgroundGeolocation.locations` returns any un-processed events. **Recommendation: after `ready()`, drain this once via `getCurrentPosition()` + local queue query, but only if we detect a gap in our own DB.** The ingestor's `flush()` logic will de-dup by timestamp.

## Drift Schema — Additive Migration (v1 → v2)

Phase 1 already shipped `Trips` + `TripPoints` schemas (see `lib/core/db/tables/{trips,trip_points}_table.dart`). Current shape covers TRK-05/07 almost exactly. **Recommended migration in P3:**

**Trips — add columns** (schema v2):
```dart
class Trips extends Table {
  // --- existing (v1) ---
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  IntColumn get durationSeconds => integer().nullable()();
  RealColumn get distanceMeters => real().nullable()();
  RealColumn get avgSpeedKmh => real().nullable()();
  RealColumn get maxSpeedKmh => real().nullable()();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  IntColumn get vehicleId => integer().nullable()();
  BoolColumn get manuallyStarted => boolean().withDefault(const Constant(false))();
  BoolColumn get autoStopped => boolean().withDefault(const Constant(false))();
  TextColumn get bluetoothHint => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  // --- ADD in v2 (P3) ---
  RealColumn get bboxMinLat => real().nullable()();
  RealColumn get bboxMinLon => real().nullable()();
  RealColumn get bboxMaxLat => real().nullable()();
  RealColumn get bboxMaxLon => real().nullable()();
  IntColumn get pointCount => integer().nullable()();
  // status accepts one more value at write-time: 'recording'
  //  (state lives in memory + is written 'pending' on stop; a crashed 'recording'
  //   row is possible if the app is killed mid-trip — treat those as recoverable
  //   at next launch: reopen as active or roll to 'pending' via checkpoint.)
}
```

**TripPoints — no change needed for v2.** The v1 shape (id, tripId, seq, ts, lat, lon, speedKmh, accuracyMeters, altitudeMeters, motionType) already carries every field we need. `seq` gives us stable ordering + tolerates duplicate timestamps.

**Where to write the migration** (following Plan 01-02 patterns):
- `AppDatabase.schemaVersion = 2` (currently 1)
- `MigrationStrategy.onUpgrade`: `if (from < 2) { await m.addColumn(trips, trips.bboxMinLat); ... }`
- Regenerate `.g.dart` via `dart run build_runner build --delete-conflicting-outputs`
- Regenerate `drift_schemas/drift_schema_v2.json` via `dart run drift_dev schema dump lib/core/db/app_database.dart drift_schemas/`
- Regenerate `test/generated_migrations/` via `dart run drift_dev schema generate drift_schemas/ test/generated_migrations/`
- Add a migration test at `test/core/db/migration_v1_to_v2_test.dart` following Plan 01-02's pattern

**Repository layout** (new files):
- `lib/features/trips/data/trips_dao.dart` — Drift DAO for trips + trip_points
- `lib/features/trips/data/trips_repository.dart` — domain-facing wrapper returning `Result<T>` / `DomainError`
- `lib/features/trips/data/trips_repository_providers.dart` — plain `Provider<TripsRepository>` (codegen OFF)

**Trips DAO API (recommended)**:
```dart
@DriftAccessor(tables: [Trips, TripPoints])
class TripsDao extends DatabaseAccessor<AppDatabase> with _$TripsDaoMixin {
  TripsDao(super.db);

  Future<int> openTrip({required bool manuallyStarted, int? vehicleId});
  Future<void> appendPointsBatch(int tripId, List<TripPointsCompanion> points);
  Future<void> closeTrip(int tripId, TripSummary summary);
  Future<void> deleteTrip(int tripId);              // for below-keeper-threshold discard
  Future<Trip?> activeTrip();                       // WHERE endedAt IS NULL LIMIT 1
  Stream<List<TripPoint>> watchPoints(int tripId);  // live overlay polyline
}
```

## Fix Ingestor — Pure Dart, Unit-Testable (HIGH confidence)

The single most important P3 abstraction. FGB feeds it `bg.Location` events; it emits DB-ready `TripPointsCompanion` batches and control signals.

**File:** `lib/features/trips/domain/trip_fix_ingestor.dart`

```dart
// Sketch — planner will elaborate signatures.
sealed class IngestorOutcome {
  const IngestorOutcome();
}
final class FixAccepted extends IngestorOutcome {
  const FixAccepted(this.point);
  final TripPointsCompanion point;
}
final class FixRejected extends IngestorOutcome {
  const FixRejected(this.reason); // 'accuracy' | 'rate_limit' | 'duplicate'
  final String reason;
}
final class GapObserved extends IngestorOutcome {
  const GapObserved(this.gapStart, this.gapEnd);
  final DateTime gapStart;
  final DateTime gapEnd;
}
final class SplitRequired extends IngestorOutcome {
  // Fires when gap > 5 min AND recovered fix > 500 m from lastKnown.
  const SplitRequired(this.recoveredFix);
  final TripPointsCompanion recoveredFix;
}

class TripFixIngestor {
  TripFixIngestor({
    this.maxAccuracyMeters = 25.0,
    this.minFixIntervalMs = 900,
    this.gapMinutes = 5,
    this.splitDistanceMeters = 500,
  });
  // Feed one bg.Location; get back what to do.
  IngestorOutcome ingest(FixInput input);
  // Called on Stop — returns null if trip fails the keeper thresholds.
  TripSummary? finalize({required DateTime startedAt});
}

class FixInput {
  final DateTime ts;
  final double lat;
  final double lon;
  final double accuracyMeters;
  final double? speedMps;   // FGB uses m/s; convert to km/h at DB layer
  final double? altitudeMeters;
  final String? activityType;
}

class TripSummary {
  final int pointCount;
  final DateTime startedAt;
  final DateTime endedAt;
  final int durationSeconds;
  final double distanceMeters;
  final double avgSpeedKmh;
  final double maxSpeedKmh;
  final ({double minLat, double minLon, double maxLat, double maxLon}) bbox;
  final bool passesKeeperThreshold;  // false if duration<60s OR dist<100m OR bbox<50m
}
```

**Distance/speed integration:**
- **Distance** = sum of Haversine between consecutive accepted fixes, EXCLUDING segments that span a gap (i.e. don't cross-connect a gap boundary as a straight line — that would over-count).
- **Speed source** = trust FGB's per-fix `coords.speed` in m/s (the plugin fuses accelerometer + GPS delta). If a fix arrives with `speed < 0` (FGB sentinel for unknown), fall back to `distance(prev, curr) / dt`.
- **`maxSpeedKmh`** = running max of `speed * 3.6` across accepted fixes.
- **`avgSpeedKmh`** = `totalDistanceMeters / activeDurationSeconds * 3.6`, where `activeDurationSeconds` = wall duration minus gap seconds.

**Haversine constant** — do NOT depend on `geolocator` just for `distanceBetween`. Inline the formula (~15 lines) in `lib/features/trips/domain/haversine.dart` or reuse Drift-independent utilities. Keeps the ingestor 100% pure-Dart, testable without native.

**Batched writes:**
```dart
class TripFixBatcher {
  TripFixBatcher(this._dao, this._tripId, {this.batchSize = 20});
  final _pending = <TripPointsCompanion>[];
  Future<void> add(TripPointsCompanion p) async {
    _pending.add(p);
    if (_pending.length >= batchSize) await flush();
  }
  Future<void> flush() async {
    if (_pending.isEmpty) return;
    await _dao.appendPointsBatch(_tripId, List.of(_pending));
    _pending.clear();
  }
}
```
**Crash durability:** 20-fix batches at 1 Hz = 20 s buffer. Worst-case data loss: 20 s of driving (~500 m at 90 km/h) if the OS kills the app between flushes. Acceptable for MVP. If tests reveal higher-than-expected app kills, tighten to 10 s (10-fix batches) — battery cost is negligible at 20 vs 10.

**Also `flush()` on:** `onMotionChange` events (state transition = natural checkpoint), app-pause via `WidgetsBindingObserver.didChangeAppLifecycleState(paused/inactive)`, and every explicit Stop.

## Permission Ladder — Concrete Sequence

Onboarding replaces the current single-step "Continue" (see `lib/features/onboarding/presentation/onboarding_screen.dart`, verified above) with a 3-page rationale flow.

**iOS chain (verified from CONTEXT + permission_handler):**
```dart
// 1) WhenInUse
await Permission.locationWhenInUse.request();
// 2) Always (rationale screen precedes this call)
await Permission.locationAlways.request();
// 3) Motion & Fitness (iOS auto-triggers when FGB first queries activity;
//    but we can force the prompt earlier by calling ready() after step 2,
//    OR — cleaner — add a separate Permission.sensors request. permission_handler
//    exposes Permission.sensors for iOS motion/fitness.)
await Permission.sensors.request();
```

**Android chain:**
```dart
// 1) Fine location (whenInUse-equivalent — Android's "while using the app")
await Permission.locationWhenInUse.request();
// 2) Background location (Android 10+ separate prompt)
await Permission.locationAlways.request();
// 3) Notifications (Android 13+)
await Permission.notification.request();
// 4) Battery-optimization exemption — NOT a permission_handler request.
//    Use platform channel + Intent.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS.
//    Options:
//      a) Do it via FGB's own `bg.DeviceSettings.showIgnoreBatteryOptimizations()`
//         — plugin exposes this. Preferred (no extra pkg).
//      b) Or add `optimize_battery` / `disable_battery_optimization` pkg.
//    Recommendation: use FGB's DeviceSettings — one less dependency.
```

**`bg.DeviceSettings` (verified from FGB source `lib/models/device_settings.dart`):**
```dart
final settings = await bg.DeviceSettings.showIgnoreBatteryOptimizations();
// Returns a DeviceSettingsRequest describing what would be shown.
await bg.DeviceSettings.show(settings);  // launches the intent
```

**WhenInUse-only fallback (per CONTEXT):**
- If `locationAlways.request()` returns `denied` / `permanentlyDenied`, set an in-memory `TrackingCapability.manualOnly` flag stored via a new `AppPrefs` row: `tracking_capability = 'manual_only'`.
- Settings screen (P2 stub) exposes an "Auto-tracking" toggle that reads this flag; when `manualOnly`, toggle is disabled + subtitle "Requires Always location".
- Never re-prompt via the OS dialog. All recovery is via the yellow banner → `openAppSettings()`.

**Yellow banner:**
- Widget: `lib/features/map/presentation/widgets/permission_denial_banner.dart`
- Position: top of the map, below the settings/pill row, above content. Full-width strip.
- Style: reuse `GlassPillFallback` idiom (matches P2) but with a warning yellow tint (`Color(0xFFFFC107).withValues(alpha: 0.85)` — note `withValues`, not `withOpacity`).
- Copy: `"Enable Always for auto-trips — tap to open Settings"`
- Tap: `await openAppSettings();` (permission_handler)
- Dismiss: not user-dismissible (per CONTEXT "never re-prompt via OS"); disappears when `locationAlways.status.isGranted` on `didChangeAppLifecycleState.resumed`.

## Live-Tracking Overlay + FAB Morph (HIGH confidence given P2 code review)

**State layer:**
```dart
// lib/features/trips/domain/tracking_state.dart
sealed class TrackingState {
  const TrackingState();
}
final class TrackingIdle extends TrackingState {
  const TrackingIdle();
}
final class TrackingRecording extends TrackingState {
  const TrackingRecording({
    required this.tripId,
    required this.startedAt,
    required this.distanceMeters,
    required this.currentSpeedKmh,
    required this.pointCount,
    required this.manuallyStarted,
  });
  final int tripId;
  final DateTime startedAt;
  final double distanceMeters;
  final double? currentSpeedKmh;
  final int pointCount;
  final bool manuallyStarted;
  Duration duration(DateTime now) => now.difference(startedAt);
}

// lib/features/trips/presentation/providers/tracking_state_provider.dart
class TrackingNotifier extends Notifier<TrackingState> {
  @override
  TrackingState build() { /* subscribe to FGB events + hydrate from DB */ return const TrackingIdle(); }
  Future<void> startManual();
  Future<void> stopActive();
}
final trackingStateProvider =
    NotifierProvider<TrackingNotifier, TrackingState>(TrackingNotifier.new);
```

**Where the FGB listener lives** — inside `TrackingNotifier`, wired in `build()`. The notifier holds the `bg.Subscription` handles and cancels them in `ref.onDispose`. This keeps FGB integration behind Riverpod's lifecycle. The Notifier's `startManual()` calls `bg.BackgroundGeolocation.changePace(true)` and opens a DB trip row; `stopActive()` calls `changePace(false)`, flushes the batcher, closes the trip.

**Timer for the "· 12:34 ·" clock face** — do NOT recompute duration on every `onLocation` (that only fires when moving). Use a `Timer.periodic(Duration(seconds: 1), ...)` inside the overlay widget only while `TrackingRecording` is active. Cancel on state change.

**FAB morph** (`lib/features/map/presentation/widgets/trip_fab.dart`, currently a Phase 2 stub — verified above):
```dart
class TripFab extends ConsumerWidget {
  const TripFab({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(trackingStateProvider);
    return switch (state) {
      TrackingIdle() => _StartFab(onTap: () =>
          ref.read(trackingStateProvider.notifier).startManual()),
      TrackingRecording() => _StopFab(onTap: () =>
          ref.read(trackingStateProvider.notifier).stopActive()),
    };
  }
}
```
- Start style: existing GlassCircle + red dot icon (unchanged).
- Stop style: **solid red filled circle, white square icon.** Use `Color(0xFFD32F2F)` (Material red 700). Do NOT use `LiquidGlass` — the Stop button must read as an emergency-action affordance, not another chrome pill. Matches the CONTEXT anchor: "one widget, one location, one meaning."
- 64 dp size preserved (matches `_fabSize` constant in `map_screen.dart`, verified).
- Add `AnimatedSwitcher` around the child to fade start↔stop over ~200 ms — feels intentional, not jumpy.
- **Semantics label** flips too: `'Stop trip'` (button, live-region).

**Overlay widget slot** — insert BETWEEN the recenter/FAB row and the bottom-nav pill in `_BottomChrome` (see `map_screen.dart` line 186–225 as verified). New widget `LiveTrackingPanel` reads `trackingStateProvider`; returns `SizedBox.shrink()` when idle. Uses `GlassPill` (verified idiom exists in P2 at `lib/features/map/presentation/widgets/glass_pill.dart`) with rounded content:
```
Recording · 12:34 · 8.2 km · 42 km/h
```
Live-updated via the `Timer.periodic` above + `ref.watch` on tracking state.

**Widget-tree hookup summary:**
- `TripFab` reads `trackingStateProvider` → morphs.
- New `LiveTrackingPanel` reads `trackingStateProvider` → visible/hidden.
- Insert the panel into `_BottomChrome`'s Column, just above Row 1 (recenter row).
- Do NOT touch `MapScreen`'s Stack ordering — chrome layers stay put.

## Persistent Notification — Live Updates

**FGB's Notification config sets the initial text.** To update it while a trip runs:
```dart
await bg.BackgroundGeolocation.setConfig(bg.Config(
  notification: bg.Notification(
    title: 'Trailblazer',
    text: 'Recording · $mmss · ${km.toStringAsFixed(1)} km · $spd km/h',
  ),
));
```
Frequency: every ~30 s (per CONTEXT). Set up a `Timer.periodic(Duration(seconds: 30), ...)` inside `TrackingNotifier` that runs only during `TrackingRecording`. Do NOT update on every fix — `setConfig` is a platform-channel round trip; 1 Hz updates would waste battery.

**Android channel** — `channelId: 'trailblazer.tracking'`, `channelName: 'Trip recording'`, `priority: Config.NOTIFICATION_PRIORITY_LOW` (silent — no sound/vibration, but visible on lock screen). Sticky = true (FGS requirement).

**iOS blue-bar text — NOT customizable.** The iOS "location in use" indicator shows the app name only; text cannot be set from the app. This is a hard iOS platform constraint. So the live-stats notification is effectively **Android-only**; the CONTEXT wording ("Android FGS + iOS blue location bar") should be read as "Android gets live text; iOS gets the blue bar as-is." No Dart code change needed for iOS; document this in the design.

**Tap-to-open** — FGB auto-wires notification tap to launch the app's launcher activity. To land on the map with the overlay in view: since MapScreen is the initial route after splash and TrackingNotifier hydrates from the DB on `build()`, the overlay renders automatically. No extra deep-link plumbing needed.

## Battery Baseline Artifact

**Format decision: Markdown table + JSON companion.**
- Markdown (`docs/battery-baseline.md`) is human-diffable in PRs.
- JSON sidecar (`docs/battery-baseline.json`) is machine-diffable for a future CI regression script.

**Layout of `docs/battery-baseline.md`:**
```markdown
# Battery baseline — Trailblazer tracking (Phase 3)

| Metric | Value |
|---|---|
| Device | Samsung Galaxy S24 (SM-S921B) |
| OS | Android 14 (Build …) |
| App version | 0.1.0+1 |
| Commit | <sha> |
| Recorded | 2026-07-?? |
| Duration | 60 min |
| Start battery % | 87 |
| End battery % | 78 |
| Drain % | 9 |
| Drain rate | 9 %/hour |
| Est. mAh (S24 4000 mAh) | 360 mAh |
| Screen state | off |
| Notification | live-stats visible |
| Profile | 20 min urban · 20 min Landstraße · 20 min Autobahn |

## Repro
1. Charge to 100 %; unplug.
2. `flutter run --release --flavor prod` on device.
3. Start manual trip via FAB.
4. Drive 60 min per profile above; screen off.
5. Tap Stop.
6. Run `tool/battery_baseline.dart` from a laptop with adb access (see below).

## Regressions
Any change that increases drain rate by > 20 % (i.e. > 10.8 %/hour) must be
justified and re-baselined.
```

**`tool/battery_baseline.dart`:**
- Uses `Process.run('adb', ['shell', 'dumpsys', 'batterystats', '--charged'])`.
- Optionally `adb shell dumpsys batterystats --reset` at the start.
- Extract mAh estimate for the app UID via a regex on the `Uid ... :` block.
- Emit JSON: `{device, os, app_version, commit, duration_min, drain_pct, drain_rate_pct_per_hour, mah_est}`.
- Print a Markdown row that can be pasted into `docs/battery-baseline.md`.

This lets the phase closer run one command post-drive and get both artifacts.

## Common Pitfalls

### Pitfall 1: Android release-license blindside
**What goes wrong:** `flutter build apk --release` fails at runtime with a license-key error banner from FGB.
**Why it happens:** FGB is licensed by application ID; without a key, release builds refuse to start tracking.
**How to avoid:** Phase 3 tests only in DEBUG mode. Explicitly document in `docs/battery-baseline.md` that the baseline run uses `flutter run --release` **only if** a license key is present; otherwise, use the debug build (numbers ~2 % higher due to logging overhead — record separately). Baseline decision: **run in DEBUG for the P3 reference measurement**, note it, re-baseline when license procured.
**Warning sign:** `TSLocationManager.LicenseChecker` in logcat.

### Pitfall 2: Deleting the Phase-1 placeholder `<service>` tag too late
**What goes wrong:** Two `<service>` declarations both with `foregroundServiceType="location"` — manifest merge conflict, build fails.
**Why it happens:** Plan 01-05 left `.LocationRecordingService` as a stub with the expectation P3 rebinds `android:name`.
**How to avoid:** In the first P3 plan (native install), **delete the `<service>` block entirely** — FGB brings its own via manifest merge. Only `<uses-permission>` and metadata remain in the app manifest.
**Warning sign:** `AAPT: duplicate service` at build time.

### Pitfall 3: Motion-activity confidence too aggressive on trip start
**What goes wrong:** FGB defaults to trigger tracking on `in_vehicle` at confidence ≥ 75. In dense urban starts (parking-lot maneuvers), classifier may bounce between `still` and `in_vehicle`, delaying auto-trip start by 30–60 s.
**Why it happens:** Motion activity fusion is inherently noisy in low-speed contexts.
**How to avoid:** Trust FGB defaults **per CONTEXT decision.** But: in the golden fixtures for the ingestor test, include a "5 fixes at 3 km/h in a parking lot" sample to verify keeper threshold silently drops it. If real-world testing shows too many missed starts, revisit `minimumActivityRecognitionConfidence` in a decimal phase.

### Pitfall 4: Overlay `Timer.periodic` leak
**What goes wrong:** Timer keeps ticking after the trip stops or the widget is disposed, causing setState-after-dispose errors and battery drain.
**Why it happens:** Standard Flutter timer lifecycle bug.
**How to avoid:** Own the timer inside a `StatefulWidget`'s State; start in `didChangeDependencies` when state → `TrackingRecording`; cancel in `didUpdateWidget` or `dispose`. Never subscribe from a `Notifier` — the widget owns the visual tick.

### Pitfall 5: iOS blue-bar assumption
**What goes wrong:** Design assumes iOS notification shows live stats; testers report "iOS notification is broken."
**Why it happens:** iOS blue-bar is app-name only; not customizable.
**How to avoid:** Document this explicitly in the phase README and the design note for the overlay. iOS parity is "the blue bar is visible while tracking"; live text is Android-only.

### Pitfall 6: `PostNotifications` denial silently kills FGS on Android 13+
**What goes wrong:** User denies notification permission → FGS still starts but no notification renders → Android silently kills the service within minutes.
**Why it happens:** Android 13+ FGS requires an ongoing notification; if permission is denied, the OS enforces a hard-kill after ~5 min.
**How to avoid:** Treat `Permission.notification.status.isDenied` as blocking for auto-tracking. Include `Permission.notification` in the whenInUse-only fallback branch: if notification is denied, force `TrackingCapability.manualOnly`.

### Pitfall 7: `withOpacity` in new widgets
**What goes wrong:** Analyzer failure — `very_good_analysis` + Flutter 3.44+ prefer `withValues(alpha:)`.
**How to avoid:** All new color transparency in the yellow banner + red Stop uses `.withValues(alpha: X)`. This is a project-wide rule (STATE.md, CLAUDE.md).

### Pitfall 8: Recording status column value drift
**What goes wrong:** Different code paths write `'active'`, `'in_progress'`, `'recording'` — inconsistent strings.
**How to avoid:** Add a `TripStatus` enum + `TypeConverter` on the Drift column:
```dart
enum TripStatus { recording, pending, matched, confirmed, rejected }
```
P3 writes only `recording` (in-memory / crash-recovery) and `pending` (on stop). Later phases add the rest.

## Code Examples (verified from FGB example repo + P1 code)

### Fix ingestor unit test skeleton
```dart
// test/features/trips/trip_fix_ingestor_test.dart
import 'package:auto_explore/features/trips/domain/trip_fix_ingestor.dart';
import 'package:flutter_test/flutter_test.dart';
void main() {
  test('accuracy filter drops > 25 m fixes', () {
    final ing = TripFixIngestor();
    final r = ing.ingest(FixInput(
      ts: DateTime(2026, 7, 5, 10),
      lat: 50.5, lon: 8.7,
      accuracyMeters: 40, speedMps: 5, altitudeMeters: 200,
      activityType: 'in_vehicle',
    ));
    expect(r, isA<FixRejected>());
    expect((r as FixRejected).reason, 'accuracy');
  });
  test('5-min gap + 500 m displacement triggers split', () {
    final ing = TripFixIngestor();
    ing.ingest(_fix(DateTime(2026,7,5,10,0,0),  50.500, 8.700));
    final r = ing.ingest(_fix(DateTime(2026,7,5,10,7,0), 50.510, 8.710)); // ~1.4 km away
    expect(r, isA<SplitRequired>());
  });
  test('keeper thresholds — drop 30 s trip', () {
    final ing = TripFixIngestor();
    for (var i = 0; i < 5; i++) {
      ing.ingest(_fix(DateTime(2026,7,5,10,0,i*5), 50.5, 8.7));
    }
    final s = ing.finalize(startedAt: DateTime(2026,7,5,10));
    expect(s?.passesKeeperThreshold, isFalse);
  });
}
```

### TrackingNotifier hydration on app resume
```dart
// lib/features/trips/presentation/providers/tracking_state_provider.dart
class TrackingNotifier extends Notifier<TrackingState> {
  @override
  TrackingState build() {
    final subs = <bg.Subscription>[];
    subs.add(bg.BackgroundGeolocation.onLocation(_onLocation));
    subs.add(bg.BackgroundGeolocation.onMotionChange(_onMotionChange));
    subs.add(bg.BackgroundGeolocation.onActivityChange(_onActivityChange));
    ref.onDispose(() { for (final s in subs) { s.cancel(); } });
    // Hydrate from DB — if a trip was in flight, resurrect it.
    _hydrate();
    return const TrackingIdle();
  }
  Future<void> _hydrate() async {
    final repo = ref.read(tripsRepositoryProvider);
    final active = await repo.activeTrip();
    if (active != null) {
      state = TrackingRecording(
        tripId: active.id,
        startedAt: active.startedAt,
        distanceMeters: active.distanceMeters ?? 0,
        currentSpeedKmh: null,
        pointCount: active.pointCount ?? 0,
        manuallyStarted: active.manuallyStarted,
      );
    }
  }
}
```

## Test Strategy

**Unit-testable (in `test/features/trips/`, no native):**
- `TripFixIngestor` — accuracy filter, rate cap, gap detection, split detection, keeper thresholds
- `Haversine` — known-distance fixtures (Frankfurt→Grebenhain = 82.5 km)
- `TripFixBatcher` with a fake DAO — verify 20-fix batch boundary + flush on stop
- `TripsRepository` with an in-memory `AppDatabase` — CRUD + activeTrip query
- `TrackingNotifier` with a `FakeBackgroundGeolocation` façade (define a thin interface and wrap `bg.BackgroundGeolocation` behind it; only the wrapper touches native)
- Onboarding permission-ladder screen with `mocktail` on `permission_handler`

**Widget-testable:**
- `TripFab` in idle vs recording states → asserts icon + color + semantics label
- `LiveTrackingPanel` visibility toggle
- `PermissionDenialBanner` visible when `locationAlways` is denied, `openAppSettings()` called on tap

**Manual real-device only:**
- Actual background wake (drive a car; test on S24)
- iOS permission dialog copy renders correctly
- Android FGS notification displays live-updating text
- 60-minute baseline drive (records the artifact)
- App-killed mid-trip → reopen → overlay reconstructs

**Golden fixture — `TripFixture` for the ingestor:**
```dart
// test/features/trips/fixtures/trip_fixtures.dart
const goldenSuburbanDrive10Fixes = <FixInput>[ ... ]; // 10 fixes, avg 40 km/h
const goldenWithGap = <FixInput>[ ... ];               // 5 fixes + 2-min gap + 5 fixes, same road
const goldenSplitCandidate = <FixInput>[ ... ];        // 5 fixes + 6-min gap + fix 800 m away
const goldenParkingLotShuffle = <FixInput>[ ... ];     // 8 fixes, bbox < 50 m
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|---|---|---|---|
| `flutter_background_geolocation` v4 flat Config (`desiredAccuracy: 0`) | v5 compound Config with `GeoConfig` sub-object | v5.0.0 (2026-01-14) | Both still supported; flat params are deprecated but functional. Use compound form for clarity, but flat params work — the example repo uses both. |
| Custom motion state machine on top of FGB | Trust FGB defaults | Project decision (2026-07-05 CONTEXT.md) | Simpler; documented. |
| BackdropFilter over PlatformView (iOS/Android) | `liquid_glass_renderer` (Android) + tinted fallback | Flutter issue #185497 open | Already resolved in P2; P3 reuses `GlassPill` / `GlassPillFallback` primitives. |

**Deprecated / avoid:**
- `flutter_background_location` (unmaintained since 2022) — not the same package.
- `background_location` (unmaintained).
- Raw `geolocator` background stream — Android 12+ FGS enforcement kills it; iOS 17 stricter.

## Open Questions

1. **Should the ingestor de-duplicate by uuid or by (ts, lat, lon)?**
   - What we know: FGB assigns a UUID per fix. On resume, the plugin may re-deliver the last few buffered fixes.
   - What's unclear: whether the ingestor should track a seen-UUIDs set.
   - Recommendation: yes — `Set<String> _seenUuids` in the ingestor, capped at last 100 UUIDs. Cheap insurance.

2. **Battery baseline on debug build — is it representative?**
   - What we know: debug builds have `debug=true`, verbose logging, no proguard, no R8.
   - What's unclear: how much of the drain is real vs debug overhead.
   - Recommendation: run baseline on debug; document it as the debug baseline; when the Android release license is procured (post-P3), re-baseline in release mode as `docs/battery-baseline-release.md`. The debug baseline still guards against unintentional regressions.

3. **Resume window (15 min + 500 m) — does FGB natively support "extend previous trip"?**
   - What we know: FGB just emits location events; trip boundaries are our concept.
   - What's unclear: none — this is entirely a Dart-side concern.
   - Implementation: in `TrackingNotifier`, when auto-stop dwell timer fires, record `stoppedAt` + `stopLatLon` but keep the trip row's `endedAt` NULL for 15 min. If a new `in_vehicle` motion event arrives within 15 min AND the fix is within 500 m of `stopLatLon`, resume; otherwise close the trip. Use a single `Timer(Duration(minutes: 15), ...)` to force-close.

4. **Motion & Fitness permission (iOS) — separate prompt or bundled with Always?**
   - What we know: `permission_handler` exposes `Permission.sensors`.
   - What's unclear: whether iOS shows the prompt at request-time or lazily on first `activity` access.
   - Recommendation: call `Permission.sensors.request()` explicitly as step 3 in the iOS onboarding chain so the user sees three back-to-back prompts, not two-plus-a-later-surprise.

5. **The `stopOnStationary` vs manual FAB stop interaction.**
   - What we know: `stopOnStationary: true` would make FGB fully stop on long stationary detection.
   - What's unclear: none — we do NOT want this (auto-stop is Dart-side dwell-based to allow the 15/500 m resume).
   - Decision: leave `stopOnStationary` at its default `false`.

## Wave-Friendly Plan Breakdown (planner input)

Proposed decomposition — 7 plans across 4 waves. Dependencies are strict; parallelism within a wave is safe.

### Wave 1 — foundations (no external deps between plans)

**Plan 03-01: Drift v2 migration — trip summary columns + status enum + repository**
- Objective: Extend `Trips` with bbox, `pointCount`; add `TripStatus` type converter; write `TripsDao` + `TripsRepository`; migrate v1→v2 with test.
- Files: `lib/core/db/tables/trips_table.dart` (edit), `lib/core/db/app_database.dart` (schemaVersion + onUpgrade), `lib/features/trips/data/trips_dao.dart` (new), `lib/features/trips/data/trips_repository.dart` (new), `lib/features/trips/data/trips_repository_providers.dart` (new), `drift_schemas/drift_schema_v2.json` (regen), `test/core/db/migration_v1_to_v2_test.dart` (new), `test/features/trips/trips_repository_test.dart` (new).
- Wave: 1
- Depends on: —

**Plan 03-02: TripFixIngestor + Haversine + TripFixBatcher (pure Dart)**
- Objective: Deliver the accuracy/gap/split/keeper logic and batching, fully unit-tested. Zero FGB dependency.
- Files: `lib/features/trips/domain/trip_fix_ingestor.dart`, `lib/features/trips/domain/haversine.dart`, `lib/features/trips/domain/trip_fix_batcher.dart`, `lib/features/trips/domain/tracking_state.dart` (sealed class), `test/features/trips/trip_fix_ingestor_test.dart`, `test/features/trips/haversine_test.dart`, `test/features/trips/fixtures/trip_fixtures.dart`.
- Wave: 1
- Depends on: —

**Plan 03-03: FGB native install — pubspec, manifest cleanup, Info.plist BGTask addition**
- Objective: Add `flutter_background_geolocation ^5.3.0`; delete Phase-1 placeholder `<service>` from `AndroidManifest.xml`; add `fetch` to iOS `UIBackgroundModes`; verify `pod install` succeeds; smoke-test `bg.BackgroundGeolocation.ready(...)` from a scratch `main` (no wiring yet).
- Files: `pubspec.yaml`, `pubspec.lock`, `android/app/src/main/AndroidManifest.xml`, `ios/Runner/Info.plist`, `ios/Podfile.lock`, `lib/features/trips/data/background_geolocation_facade.dart` (thin façade for testability — defines the interface we mock in Wave 2 tests).
- Wave: 1
- Depends on: —

### Wave 2 — integration (all depend on Wave 1)

**Plan 03-04: TrackingNotifier + FGB event wiring + hydration on resume**
- Objective: Riverpod `Notifier` that subscribes to FGB events, drives the ingestor + batcher + repository, exposes `TrackingState`, and hydrates from DB on cold start. `startManual()` / `stopActive()` methods.
- Files: `lib/features/trips/presentation/providers/tracking_state_provider.dart`, `lib/features/trips/domain/tracking_service.dart` (owns FGB config + subscription lifetime), `test/features/trips/tracking_notifier_test.dart` (uses a `FakeBackgroundGeolocationFacade`).
- Wave: 2
- Depends on: 03-01, 03-02, 03-03

**Plan 03-05: Onboarding 3-step permission ladder + denial banner**
- Objective: Replace single-step onboarding Continue with 3-page flow (whenInUse → Always → Motion(iOS) / Notification+Battery(Android)). Add `PermissionDenialBanner` widget + `openAppSettings()` deep-link. Persist `tracking_capability` to `AppPrefs`.
- Files: `lib/features/onboarding/presentation/onboarding_screen.dart` (rewrite), `lib/features/onboarding/presentation/rationale_screens/` (3 new widgets), `lib/features/map/presentation/widgets/permission_denial_banner.dart` (new), `lib/features/map/presentation/map_screen.dart` (slot banner into Stack), `lib/features/onboarding/data/tracking_capability_repository.dart` (new — reads `AppPrefs`), `test/features/onboarding/onboarding_ladder_test.dart`.
- Wave: 2
- Depends on: 03-03 (needs FGB for `bg.DeviceSettings.showIgnoreBatteryOptimizations`)

### Wave 3 — UI (all depend on Wave 2)

**Plan 03-06: FAB morph + LiveTrackingPanel overlay + 30 s notification updater**
- Objective: Wire `TripFab` to `trackingStateProvider` for start↔stop morph. Insert `LiveTrackingPanel` into `_BottomChrome`. Add `Timer.periodic(30s)` inside `TrackingNotifier` for notification text updates via `bg.BackgroundGeolocation.setConfig(...)`.
- Files: `lib/features/map/presentation/widgets/trip_fab.dart` (rewrite), `lib/features/trips/presentation/widgets/live_tracking_panel.dart` (new), `lib/features/map/presentation/map_screen.dart` (slot panel), `lib/features/trips/presentation/widgets/tracking_duration_ticker.dart` (new — the 1 s widget-owned timer), `test/features/trips/live_tracking_panel_test.dart`, `test/features/map/trip_fab_morph_test.dart`.
- Wave: 3
- Depends on: 03-04, 03-05

### Wave 4 — verification

**Plan 03-07: Battery baseline artifact + `tool/battery_baseline.dart` + real-device smoke test**
- Objective: Ship `tool/battery_baseline.dart` (adb + `dumpsys batterystats` parser). Record the 60-min drive on Samsung S24 Android 14. Commit `docs/battery-baseline.md` + `docs/battery-baseline.json`. Update STATE.md + close-out notes.
- Files: `tool/battery_baseline.dart` (new), `docs/battery-baseline.md` (new), `docs/battery-baseline.json` (new), `.planning/phases/03-tracking-mvp/03-VERIFICATION.md` (new — follows P2 pattern), `.planning/STATE.md` (append decisions).
- Wave: 4
- Depends on: 03-06 (needs the full stack to record)

**Dependency graph:**
```
Wave 1:  [03-01]  [03-02]  [03-03]
              \    |    /
Wave 2:      [03-04]       [03-05]   (03-05 also depends on 03-03)
                  \        /
Wave 3:            [03-06]
                     |
Wave 4:            [03-07]
```

**Estimated plan sizes** (calibration from Phase 2 velocity ~86 min/plan):
- 03-01: ~90 min (schema migration + repo tests)
- 03-02: ~90 min (pure Dart logic + goldens)
- 03-03: ~45 min (config/manifest edits + smoke)
- 03-04: ~120 min (integration crossroads)
- 03-05: ~90 min (three rationale screens + banner)
- 03-06: ~75 min (UI polish; leverages P2 primitives)
- 03-07: ~120 min (60-min drive + artifact drafting)
- **Total ~10.5 hours** across the phase — matches Phase 2 execution profile.

## Sources

### Primary (HIGH confidence)
- pub.dev listing for `flutter_background_geolocation` v5.3.0 (verified license posture + published 2026-06-22): https://pub.dev/packages/flutter_background_geolocation
- FGB Location model source (verified Coords + Activity fields): https://raw.githubusercontent.com/transistorsoft/flutter_background_geolocation/master/lib/models/location.dart
- FGB ActivityChangeEvent source (verified activity type strings + confidence): https://raw.githubusercontent.com/transistorsoft/flutter_background_geolocation/master/lib/models/activity_change_event.dart
- FGB Config constructor source (verified compound + flat parameter names): https://raw.githubusercontent.com/transistorsoft/flutter_background_geolocation/master/lib/models/config/config.dart
- FGB GeoConfig source (verified DesiredAccuracy enum values + all geo fields): https://raw.githubusercontent.com/transistorsoft/flutter_background_geolocation/master/lib/models/config/geo_config.dart
- FGB Notification source (verified NotificationConfig fields): https://raw.githubusercontent.com/transistorsoft/flutter_background_geolocation/master/lib/models/config/notification.dart
- FGB BackgroundGeolocation public API (verified method signatures): https://raw.githubusercontent.com/transistorsoft/flutter_background_geolocation/master/lib/models/background_geolocation.dart
- FGB hello_world example (verified event listener wiring): https://raw.githubusercontent.com/transistorsoft/flutter_background_geolocation/master/example/lib/hello_world/app.dart
- FGB iOS install guide (verified Info.plist keys + UIBackgroundModes + Xcode caps): https://github.com/transistorsoft/flutter_background_geolocation/blob/master/help/INSTALL-IOS.md
- `permission_handler` pub.dev (verified constant surface + `openAppSettings()`): https://pub.dev/packages/permission_handler
- Trailblazer codebase — verified against current tree:
  - `pubspec.yaml`, `lib/core/db/tables/trips_table.dart`, `lib/core/db/tables/trip_points_table.dart`, `lib/core/db/app_database.dart`, `lib/core/errors/domain_error.dart`, `lib/core/errors/result.dart`, `lib/features/onboarding/data/onboarding_flag_repository.dart`, `lib/features/onboarding/presentation/onboarding_screen.dart`, `lib/features/map/presentation/widgets/trip_fab.dart`, `lib/features/map/presentation/widgets/glass_pill.dart`, `lib/features/map/presentation/map_screen.dart`, `lib/features/map/presentation/providers/location_permission_provider.dart`, `android/app/src/main/AndroidManifest.xml`, `ios/Runner/Info.plist`, `.planning/STATE.md`, `.planning/phases/03-tracking-mvp/03-CONTEXT.md`.

### Secondary (MEDIUM confidence)
- FGB Android install guide summary (verified manifest merge posture but exact service class name not disclosed publicly): https://github.com/transistorsoft/flutter_background_geolocation/blob/master/help/INSTALL-ANDROID.md
- FGB CHANGELOG.md (verified 5.x major-version boundaries and release cadence): https://raw.githubusercontent.com/transistorsoft/flutter_background_geolocation/master/CHANGELOG.md

### Tertiary (LOW confidence — flagged for validation)
- iOS blue-bar non-customizability claim — cross-referenced against multiple community reports and Apple docs behavior, but no single authoritative citation in this session. Widely known; safe to treat as HIGH in practice, but tagged LOW pending an Apple Developer Docs citation.
- Battery-optimization exemption via `bg.DeviceSettings.showIgnoreBatteryOptimizations()` — verified the class file exists (`lib/models/device_settings.dart` listed in the repo), but did not fetch its source to verify the exact method signature. Planner should confirm the method name in 03-05 before wiring.

## Metadata

**Confidence breakdown:**
- Standard stack (FGB 5.3.0, permission_handler 12.0.3, drift 2.34): HIGH — versions confirmed from pub.dev + local `pubspec.yaml`; Config/Location API fields verified from plugin source on `master`.
- Architecture (TrackingNotifier + TripFixIngestor + TripFixBatcher separation): HIGH — matches Phase 1 patterns (plain Providers, `DomainError`+`Result<T>`) and P2 UI idioms; pure-Dart ingestor is the standard testable-slice pattern.
- Permission ladder + Android FGS notification: HIGH — Phase 1 already declared all required permissions in `AndroidManifest.xml` (verified above); Phase 1's Info.plist has strings + `UIBackgroundModes[location, bluetooth-central]` (verified above); only missing piece is adding `fetch` to `UIBackgroundModes`.
- Pitfalls: MEDIUM — most are drawn from FGB's own docs + Flutter platform experience; the S24-specific power/thermal quirks won't surface until the baseline drive.
- Battery baseline artifact format: MEDIUM — Markdown+JSON is a reasonable diff-friendly convention but not sourced from any external "battery-baseline standard." Format is Claude's discretion per CONTEXT.

**Research date:** 2026-07-05
**Valid until:** ~2026-09-05 (30 days safe; FGB has a monthly-ish release cadence — re-verify version before Wave-1 execution if the phase kickoff slips past 2026-08-05).
