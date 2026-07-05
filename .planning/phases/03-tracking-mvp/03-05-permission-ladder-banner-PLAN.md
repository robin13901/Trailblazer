---
id: 03-05
phase: 03-tracking-mvp
plan: 05
type: execute
wave: 2
depends_on: [03-03]
files_modified:
  - lib/features/onboarding/data/permission_service.dart
  - lib/features/onboarding/data/permission_service_provider.dart
  - lib/features/onboarding/presentation/onboarding_screen.dart
  - lib/features/onboarding/presentation/widgets/permission_rationale_page.dart
  - lib/features/onboarding/presentation/pages/permission_when_in_use_page.dart
  - lib/features/onboarding/presentation/pages/permission_always_page.dart
  - lib/features/onboarding/presentation/pages/permission_motion_notification_page.dart
  - lib/features/onboarding/data/tracking_capability.dart
  - lib/features/onboarding/data/tracking_capability_repository.dart
  - lib/features/onboarding/data/tracking_capability_providers.dart
  - lib/features/map/presentation/widgets/permission_denial_banner.dart
  - lib/features/map/presentation/map_screen.dart
  - test/features/onboarding/fakes/fake_permission_service.dart
  - test/features/onboarding/onboarding_ladder_test.dart
  - test/features/onboarding/tracking_capability_repository_test.dart
  - test/features/map/permission_denial_banner_test.dart
autonomous: false
requirements_addressed: [TRK-10, TRK-11]

user_setup: []

must_haves:
  truths:
    - "First-launch onboarding walks the user through three back-to-back permission steps with rationale copy between them: whenInUse → Always → Motion(iOS)/Notification+BatteryOpt(Android)"
    - "If Always is not currently granted (`!Permission.locationAlways.status.isGranted`), tracking_capability is persisted as `manualOnly`; if Notification is not granted on Android 13+, tracking_capability is `manualOnly`"
    - "OS permission dialog is never re-requested after a single denial (per CONTEXT); recovery goes through the yellow banner + openAppSettings()"
    - "PermissionDenialBanner is visible on the map screen whenever `!Permission.locationAlways.status.isGranted` OR (on Android 13+) `!Permission.notification.status.isGranted` — else invisible. This covers `denied`, `restricted`, `limited`, and `permanentlyDenied` uniformly."
    - "Tapping the banner calls `openAppSettings()` from permission_handler"
    - "Banner re-evaluates on `didChangeAppLifecycleState.resumed` — comes back from Settings with Always granted → banner disappears"
    - "`tracking_capability` value survives app restart (persisted in AppPrefs via shared_preferences)"
    - "All permission-handler calls in production code and tests go through `PermissionService` — no direct `Permission.X.request()` outside the service impl and no permission_handler method-channel mocks in tests"
  artifacts:
    - path: "lib/features/onboarding/data/permission_service.dart"
      provides: "Injection seam for OS permission requests — abstract PermissionService + PermissionHandlerService real impl"
      contains: "abstract interface class PermissionService"
    - path: "lib/features/onboarding/data/permission_service_provider.dart"
      provides: "Riverpod provider exposing PermissionService (override target for tests)"
      contains: "permissionServiceProvider"
    - path: "test/features/onboarding/fakes/fake_permission_service.dart"
      provides: "Reusable in-memory PermissionService fake for widget + unit tests"
      contains: "class FakePermissionService"
    - path: "lib/features/onboarding/presentation/onboarding_screen.dart"
      provides: "PageView-driven 3-page permission flow replacing the Phase-1 single Continue button"
      contains: "PageView"
    - path: "lib/features/onboarding/data/tracking_capability_repository.dart"
      provides: "Persistence for TrackingCapability { fullAuto, manualOnly }"
      contains: "class TrackingCapabilityRepository"
    - path: "lib/features/map/presentation/widgets/permission_denial_banner.dart"
      provides: "Yellow glass banner strip"
      contains: "class PermissionDenialBanner"
  key_links:
    - from: "onboarding_screen.dart"
      to: "permissionServiceProvider + BackgroundGeolocationFacade.showIgnoreBatteryOptimizations"
      via: "sequential `await ref.read(permissionServiceProvider).requestX()` + facade call"
      pattern: "permissionServiceProvider"
    - from: "permission_denial_banner.dart"
      to: "permissionServiceProvider.openAppSettings"
      via: "onTap → await service.openAppSettings()"
      pattern: "openAppSettings"
    - from: "map_screen.dart"
      to: "permission_denial_banner.dart"
      via: "Stack slot at top of map, below any AppBar-equivalent chrome"
      pattern: "PermissionDenialBanner"
---

<objective>
Replace Phase 1's single-tap onboarding with a 3-page permission ladder (whenInUse → Always → Motion/Notification+BatteryOpt), persist the resulting `TrackingCapability`, and add a yellow denial banner on the map screen that deep-links to OS Settings when Always is missing.

Purpose: TRK-10 (iOS whenInUse→Always ladder), TRK-11 (Android FGS + battery-optimization prompt). This is the only P3 UI-facing change outside of the FAB/overlay in 03-06.

All permission-handler access flows through a `PermissionService` seam — clean test story (a Riverpod-overridable fake, no method-channel mocking), consistent with the Phase 1 pattern of putting platform SDKs behind narrow interfaces.

Output: 1 permission service (abstract + real impl) + 1 provider + 1 fake + 3 onboarding pages + capability repo + denial banner + map-screen integration + 4 test files. Contains a **checkpoint** at the end to visually review the copy on device.

Note: This plan is `autonomous: false` because the rationale-screen copy is user-facing and CONTEXT gave Claude discretion on wording — a human-verify checkpoint at the end lets the user review the final flow on device (or emulator) before Phase 3 signs off.
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
@.planning/phases/03-tracking-mvp/03-03-SUMMARY.md

# Files being replaced/edited
@lib/features/onboarding/presentation/onboarding_screen.dart
@lib/features/onboarding/data/onboarding_flag_repository.dart
@lib/features/map/presentation/map_screen.dart

# Phase 2 glass idioms to reuse
@lib/features/map/presentation/widgets/glass_pill.dart

# Package name is `auto_explore`.
</context>

<tasks>

<task type="auto">
  <name>Task 1: PermissionService seam + TrackingCapability model/repository + rationale-page widget scaffolding</name>
  <files>
    - lib/features/onboarding/data/permission_service.dart
    - lib/features/onboarding/data/permission_service_provider.dart
    - test/features/onboarding/fakes/fake_permission_service.dart
    - lib/features/onboarding/data/tracking_capability.dart
    - lib/features/onboarding/data/tracking_capability_repository.dart
    - lib/features/onboarding/data/tracking_capability_providers.dart
    - lib/features/onboarding/presentation/widgets/permission_rationale_page.dart
    - test/features/onboarding/tracking_capability_repository_test.dart
  </files>
  <action>
    1. `lib/features/onboarding/data/permission_service.dart` — the injection seam. All permission_handler usage in the codebase goes through this:
       ```dart
       import 'package:permission_handler/permission_handler.dart';

       /// Narrow seam over permission_handler. Widget code, providers, and tests
       /// go through here — no direct `Permission.X.request()` anywhere else.
       abstract interface class PermissionService {
         Future<PermissionStatus> requestWhenInUse();
         Future<PermissionStatus> requestAlways();
         Future<PermissionStatus> requestSensors();     // iOS Motion & Fitness
         Future<PermissionStatus> requestNotification(); // Android 13+
         Future<PermissionStatus> statusAlways();
         Future<PermissionStatus> statusNotification();
         Future<bool> openAppSettings();
       }

       class PermissionHandlerService implements PermissionService {
         const PermissionHandlerService();
         @override Future<PermissionStatus> requestWhenInUse() =>
             Permission.locationWhenInUse.request();
         @override Future<PermissionStatus> requestAlways() =>
             Permission.locationAlways.request();
         @override Future<PermissionStatus> requestSensors() =>
             Permission.sensors.request();
         @override Future<PermissionStatus> requestNotification() =>
             Permission.notification.request();
         @override Future<PermissionStatus> statusAlways() =>
             Permission.locationAlways.status;
         @override Future<PermissionStatus> statusNotification() =>
             Permission.notification.status;
         @override Future<bool> openAppSettings() => openAppSettings();
         // Note: shadowing — use `import ... as ph;` if the top-level
         // openAppSettings collides. Prefer `import 'package:permission_handler/permission_handler.dart' as ph;`
         // and call `ph.openAppSettings()`.
       }
       ```
       Fix the `openAppSettings` shadow with a prefixed import (`as ph`) so the real impl calls `ph.openAppSettings()`.

    2. `lib/features/onboarding/data/permission_service_provider.dart`:
       ```dart
       import 'package:flutter_riverpod/flutter_riverpod.dart';
       import 'package:auto_explore/features/onboarding/data/permission_service.dart';

       final permissionServiceProvider = Provider<PermissionService>((ref) {
         return const PermissionHandlerService();
       });
       ```
       Codegen OFF (STATE.md 01-01) — plain `Provider<T>`.

    3. `test/features/onboarding/fakes/fake_permission_service.dart`:
       ```dart
       import 'package:permission_handler/permission_handler.dart';
       import 'package:auto_explore/features/onboarding/data/permission_service.dart';

       /// Test double — records each call and lets tests script the returned status.
       class FakePermissionService implements PermissionService {
         FakePermissionService({
           this.whenInUseResult = PermissionStatus.granted,
           this.alwaysResult = PermissionStatus.granted,
           this.sensorsResult = PermissionStatus.granted,
           this.notificationResult = PermissionStatus.granted,
         });
         PermissionStatus whenInUseResult;
         PermissionStatus alwaysResult;
         PermissionStatus sensorsResult;
         PermissionStatus notificationResult;
         PermissionStatus? _alwaysStatusOverride;
         PermissionStatus? _notificationStatusOverride;
         int openAppSettingsCalls = 0;
         final List<String> requestLog = [];

         void setAlwaysStatus(PermissionStatus s) => _alwaysStatusOverride = s;
         void setNotificationStatus(PermissionStatus s) =>
             _notificationStatusOverride = s;

         @override Future<PermissionStatus> requestWhenInUse() async {
           requestLog.add('whenInUse'); return whenInUseResult;
         }
         @override Future<PermissionStatus> requestAlways() async {
           requestLog.add('always'); return alwaysResult;
         }
         @override Future<PermissionStatus> requestSensors() async {
           requestLog.add('sensors'); return sensorsResult;
         }
         @override Future<PermissionStatus> requestNotification() async {
           requestLog.add('notification'); return notificationResult;
         }
         @override Future<PermissionStatus> statusAlways() async =>
             _alwaysStatusOverride ?? alwaysResult;
         @override Future<PermissionStatus> statusNotification() async =>
             _notificationStatusOverride ?? notificationResult;
         @override Future<bool> openAppSettings() async {
           openAppSettingsCalls++; return true;
         }
       }
       ```
       Committed alongside the real code so Task 2 tests and Task 3 tests share the same fake.

    4. `lib/features/onboarding/data/tracking_capability.dart`:
       ```dart
       enum TrackingCapability { fullAuto, manualOnly }
       ```

    5. `lib/features/onboarding/data/tracking_capability_repository.dart`:
       ```dart
       import 'package:shared_preferences/shared_preferences.dart';
       import 'package:auto_explore/features/onboarding/data/tracking_capability.dart';

       class TrackingCapabilityRepository {
         TrackingCapabilityRepository(this._prefs);
         final SharedPreferencesAsync _prefs;

         static const prefsKey = 'tracking_capability';

         Future<TrackingCapability> load() async {
           final v = await _prefs.getString(prefsKey);
           return v == 'manual_only'
               ? TrackingCapability.manualOnly
               : TrackingCapability.fullAuto;
         }
         Future<void> save(TrackingCapability c) =>
             _prefs.setString(prefsKey,
                 c == TrackingCapability.manualOnly ? 'manual_only' : 'full_auto');
       }
       ```
       Follow the Plan 01-03 pattern (public `prefsKey`, `SharedPreferencesAsync` constructor injection for test-time `InMemorySharedPreferencesAsync`).

    6. `lib/features/onboarding/data/tracking_capability_providers.dart`:
       ```dart
       final trackingCapabilityRepositoryProvider =
           Provider<TrackingCapabilityRepository>((ref) {
         return TrackingCapabilityRepository(SharedPreferencesAsync());
       });
       final trackingCapabilityProvider = FutureProvider<TrackingCapability>((ref) {
         return ref.watch(trackingCapabilityRepositoryProvider).load();
       });
       ```
       Codegen OFF — plain `Provider<T>` / `FutureProvider<T>`.

    7. `lib/features/onboarding/presentation/widgets/permission_rationale_page.dart` — the shared page widget layout every rationale page reuses (single concern: icon + title + body + primary button):
       ```dart
       class PermissionRationalePage extends StatelessWidget {
         const PermissionRationalePage({
           required this.icon,
           required this.title,
           required this.body,
           required this.primaryLabel,
           required this.onPrimary,
           this.secondaryLabel,
           this.onSecondary,
           super.key,
         });
         final IconData icon;
         final String title;
         final String body;
         final String primaryLabel;
         final VoidCallback onPrimary;
         final String? secondaryLabel;
         final VoidCallback? onSecondary;
         // Layout: centered Column with big icon, headline, body, filled primary button,
         //   optional text button below. Use Theme.of(context).textTheme.
         @override Widget build(BuildContext context) { ... }
       }
       ```
       Consistent visuals, no color transparency yet. Keep it a plain `StatelessWidget`.

    8. `test/features/onboarding/tracking_capability_repository_test.dart`:
       - Use `SharedPreferencesAsync.setMockInitialValues` or `InMemorySharedPreferencesAsync` (Plan 01-03 pattern).
       - Cases:
         - `load()` on empty prefs → `TrackingCapability.fullAuto`
         - `save(manualOnly)` then `load()` → `TrackingCapability.manualOnly`
         - `save(fullAuto)` then `load()` → `TrackingCapability.fullAuto`
         - `prefsKey == 'tracking_capability'` (public API contract test)

    Anti-patterns to avoid:
    - Do NOT couple TrackingCapability to any Drift table — this is a single boolean-ish flag, prefs is the right store.
    - Do NOT bake copy into `permission_rationale_page.dart` — pages inject their own strings.
    - Do NOT use `withOpacity` for icon color (STATE.md rule — mandatory `withValues(alpha:)`).
    - Do NOT call `Permission.X.request()` from anywhere in `lib/features/onboarding/presentation/**` — everything goes through `permissionServiceProvider`.
  </action>
  <verify>
    - `flutter analyze` clean
    - `flutter test test/features/onboarding/tracking_capability_repository_test.dart` green
  </verify>
  <done>
    PermissionService seam (interface + real impl + provider + fake) ready. Capability model + repository + provider + shared rationale page widget ready. Nothing wired to the UI yet.
  </done>
</task>

<task type="auto">
  <name>Task 2: Three onboarding pages + PageView flow + persistence</name>
  <files>
    - lib/features/onboarding/presentation/pages/permission_when_in_use_page.dart
    - lib/features/onboarding/presentation/pages/permission_always_page.dart
    - lib/features/onboarding/presentation/pages/permission_motion_notification_page.dart
    - lib/features/onboarding/presentation/onboarding_screen.dart
    - test/features/onboarding/onboarding_ladder_test.dart
  </files>
  <action>
    1. Three `Consumer(Stateful)Widget` pages under `lib/features/onboarding/presentation/pages/`, each building `PermissionRationalePage`. **All permission calls go via `ref.read(permissionServiceProvider).requestX()`** — no direct `Permission.X.request()`.

       **`permission_when_in_use_page.dart`** — "While using the app":
       - Icon: `Icons.location_on`
       - Title: `"Location while using Trailblazer"`
       - Body: `"Trailblazer draws the roads you drive on the map. It first needs permission to see your location while you're using the app."`
       - Primary: `"Continue"` → `await ref.read(permissionServiceProvider).requestWhenInUse();` then `pageController.nextPage(...)` regardless of grant/deny.

       **`permission_always_page.dart`** — "Always" upgrade:
       - Icon: `Icons.explore` (or similar)
       - Title: `"Log trips in the background"`
       - Body: `"Trailblazer records trips even when the app is closed — so we capture the whole drive, not just the moment you opened the app."`
       - Primary: `"Enable background location"` → `final s = await ref.read(permissionServiceProvider).requestAlways();` — do NOT force `manualOnly` here; the last page computes final capability.
       - Secondary: `"Manual only"` (text button) → skip forward.

       **`permission_motion_notification_page.dart`** — platform-branched, last page:
       - Icon: `Icons.notifications_active`
       - Title (iOS): `"Motion & Fitness"`
       - Title (Android): `"Notifications and battery"`
       - Body (iOS): `"iOS's Motion & Fitness sensor helps distinguish driving from walking — this makes the auto-detect smarter."`
       - Body (Android): `"Trailblazer shows a persistent notification while recording (Android needs this to keep tracking alive). It also asks Android to ignore battery optimizations, so the OS doesn't kill tracking mid-trip."`
       - Primary (iOS): `"Continue"` → `await ref.read(permissionServiceProvider).requestSensors();`
       - Primary (Android): `"Enable"` → `await ref.read(permissionServiceProvider).requestNotification();` then `await ref.read(backgroundGeolocationFacadeProvider).showIgnoreBatteryOptimizations();`
       - After primary → resolve final capability. Use `!isGranted` uniformly (covers `denied`, `restricted`, `limited`, `permanentlyDenied`):
         ```dart
         final svc = ref.read(permissionServiceProvider);
         final always = await svc.statusAlways();
         final notif  = Platform.isAndroid
             ? await svc.statusNotification()
             : PermissionStatus.granted;
         final capability = (always.isGranted && notif.isGranted)
             ? TrackingCapability.fullAuto
             : TrackingCapability.manualOnly;
         await ref.read(trackingCapabilityRepositoryProvider).save(capability);
         ```
       - Then mark onboarding done (existing `OnboardingFlagRepository.save(true)` from Plan 01-03) and `context.go('/')`.

       All three pages use `Platform.isIOS` / `Platform.isAndroid` (from `dart:io`) for branching. No `flutter_platform_widgets` dep.

    2. `lib/features/onboarding/presentation/onboarding_screen.dart` — REPLACE contents:
       - `PageView` with 3 pages, physics `NeverScrollableScrollPhysics()` (advance is programmatic-only).
       - PageController lifted to the parent widget.
       - Preserve the router-level entry from Plan 01-03; `SplashScreen` still calls `context.go('/onboarding')` on first launch.
       - The Phase 1 `FakeLocationPermissionNotifier` widget-test override (STATE.md 02-03) needs to keep working — verify by running `test/features/map/map_widget_test.dart` unchanged.

    3. `test/features/onboarding/onboarding_ladder_test.dart`:
       - Widget test. Override `permissionServiceProvider` with the `FakePermissionService` from Task 1.
       - Cases:
         - **All-granted path** → onboarding_done flag=true, tracking_capability=fullAuto, navigator popped to `/`. Assert `fakeService.requestLog` contains `['whenInUse', 'always', <'sensors' or 'notification'>]` in order.
         - **Always-denied path** (fake returns `PermissionStatus.denied` for always) → tracking_capability=manualOnly, onboarding_done=true, navigation still to `/`
         - **Always-permanently-denied path** (returns `PermissionStatus.permanentlyDenied`) → tracking_capability=manualOnly (confirms `!isGranted` covers this)
         - **Always-restricted path** (returns `PermissionStatus.restricted`) → tracking_capability=manualOnly (confirms `!isGranted` covers this)
         - **Android notification denied** → tracking_capability=manualOnly (regardless of always status)
         - **Rationale page copy renders** `find.text(...)` for a stable substring per page

    Anti-patterns to avoid:
    - Do NOT call `Permission.X.request()` directly — always through `permissionServiceProvider`. This is the whole point of the seam.
    - Do NOT call the same permission twice across pages — one request per permission (CONTEXT: "never re-prompt via OS dialog").
    - Do NOT use `Navigator.pop` — go_router only. `context.go('/')` is the exit.
    - Do NOT gate the Continue button on grant — the flow proceeds regardless; capability just reflects the outcome.
    - Do NOT use `.isDenied` as the "not granted" predicate — use `!isGranted`. `isDenied` excludes `restricted`, `limited`, and `permanentlyDenied`, giving false negatives.
  </action>
  <verify>
    - `flutter analyze` clean
    - `flutter test test/features/onboarding/` all green
    - `flutter test test/features/map/map_widget_test.dart` still green (no regression on 02-03 pattern)
  </verify>
  <done>
    Three-page permission ladder replaces the P1 single Continue. Capability is persisted per branch. All request paths go through `PermissionService`. `!isGranted` semantics uniformly applied. Existing widget tests continue to pass.
  </done>
</task>

<task type="auto">
  <name>Task 3: PermissionDenialBanner + map screen integration</name>
  <files>
    - lib/features/map/presentation/widgets/permission_denial_banner.dart
    - lib/features/map/presentation/map_screen.dart
    - test/features/map/permission_denial_banner_test.dart
  </files>
  <action>
    1. `lib/features/map/presentation/widgets/permission_denial_banner.dart`:
       - `ConsumerStatefulWidget` (needs to observe app lifecycle for the "back from Settings" re-check).
       - Watches a new provider `permissionDenialBannerVisibleProvider` (define locally in this file). **Predicate is `!isGranted` — matches CONTEXT ("Always is not currently granted → show banner"):**
         ```dart
         final permissionDenialBannerVisibleProvider =
             FutureProvider<bool>((ref) async {
           final svc = ref.watch(permissionServiceProvider);
           final always = await svc.statusAlways();
           if (!always.isGranted) return true; // covers denied/restricted/limited/permanentlyDenied
           if (Platform.isAndroid) {
             final notif = await svc.statusNotification();
             if (!notif.isGranted) return true;
           }
           return false;
         });
         ```
         The banner widget invalidates this provider in `didChangeAppLifecycleState(AppLifecycleState.resumed)` so it re-reads on return from Settings.
       - Visual: full-width strip, ~44 dp tall, yellow glass (`Color(0xFFFFC107).withValues(alpha: 0.85)`, per STATE.md — use `withValues`, NEVER `withOpacity`), rounded corners `BorderRadius.circular(12)`, 12 dp horizontal margin, text "Enable Always for auto-trips — tap to open Settings", chevron icon on the right.
       - `onTap`: `await ref.read(permissionServiceProvider).openAppSettings();` — routes through the seam.
       - When `AsyncValue<bool>` resolves to `false` → return `const SizedBox.shrink()`.

    2. Edit `lib/features/map/presentation/map_screen.dart`:
       - Slot `PermissionDenialBanner` at the TOP of the map Stack, positioned via `Positioned(top: mediaquery.top + 12, left: 0, right: 0, child: ...)`. It sits above the map, below the top-of-screen safe area, does not overlap the FocusAreaPill (which is centred-top per P2).
       - Verify against `map_screen.dart`'s current Stack (per STATE.md 02-05): existing widgets stay where they are.
       - Banner is only shown when `currentIndex == 0` (Map tab) — reuse the pattern from Plan 02-06 that hides FAB/pill on other tabs.

    3. `test/features/map/permission_denial_banner_test.dart`:
       - Override `permissionServiceProvider` with `FakePermissionService` (from Task 1) — tests script the always/notification statuses.
       - Override `permissionDenialBannerVisibleProvider` with `AsyncValue.data(true)` → assert `find.byType(PermissionDenialBanner)` returns a non-empty widget with the copy visible.
       - Override with `AsyncValue.data(false)` → assert the banner effectively renders `SizedBox.shrink()`.
       - Set `fakePermissionService.setAlwaysStatus(PermissionStatus.restricted)` → assert derived visibility resolves `true` (confirms `!isGranted` semantics on the banner path too).
       - Tap test — tap on visible banner, assert `fakePermissionService.openAppSettingsCalls == 1`. No method-channel mocks anywhere.

    Anti-patterns to avoid:
    - Do NOT use `withOpacity` — `withValues(alpha:)` is mandatory (STATE.md).
    - Do NOT gate visibility on `isDenied` — `!isGranted` is the CONTEXT contract and it covers more failure modes.
    - Do NOT put banner inside a `Column` that would push the map down — it overlays via `Stack + Positioned`.
    - Do NOT eagerly re-request the OS dialog (CONTEXT: "never re-prompt via OS") — the banner is the ONLY recovery path in P3 outside settings screens.
    - Do NOT mock `permission_handler` at the method-channel level — the `PermissionService` seam is the mocking boundary.
  </action>
  <verify>
    - `flutter analyze` clean
    - `flutter test test/features/map/` all green
  </verify>
  <done>
    Yellow banner visible on the map when Always is not granted (any non-granted status); tapping opens OS Settings via the PermissionService seam; re-check runs on resume.
  </done>
</task>

<task type="checkpoint:human-verify" gate="blocking">
  <name>Task 4: On-device visual check of onboarding + banner</name>
  <what-built>
    Three-page permission ladder + yellow denial banner on the map screen, with `openAppSettings()` deep-link.
  </what-built>
  <how-to-verify>
    1. `flutter run --debug` on Samsung Galaxy S24 (Phase 2 reference device).
    2. Wipe app data (Settings → Apps → Trailblazer → Storage → Clear Data) OR uninstall and reinstall to force first-launch onboarding.
    3. Verify all 3 rationale pages render with correct copy, icons, and the "Manual only" text button on the Always page.
    4. Deny "Always" — verify the app still lands on the map and the yellow banner appears at the top.
    5. Tap the banner — verify OS Settings app opens on Trailblazer's app info page.
    6. Grant "Always" from Settings → return to app → verify banner disappears (may require pull-down / manual return).
    7. Re-open onboarding is NOT triggered (onboarding_done flag holds).
    8. Reject/deny each permission ONE time — verify no OS dialog re-appears afterwards (banner is the only nudge).
    Optional: iOS test if a macOS + iOS device is available; otherwise defer to a future device pass (STATE.md pending todo).
  </how-to-verify>
  <resume-signal>
    Type "approved" if the flow reads correctly, or describe copy/layout issues to iterate on.
  </resume-signal>
</task>

</tasks>

<verification>
- `flutter analyze` clean
- `flutter test` full suite green
- On-device Android smoke test passes checkpoint
- Grep check: `grep -r "Permission\." lib/features/onboarding/presentation/ lib/features/map/presentation/widgets/permission_denial_banner.dart` returns only the `PermissionStatus` enum references — zero `Permission.locationAlways.request()` / `.status` direct calls (all routed via `permissionServiceProvider`)
- Commit: `feat(03-05): permission ladder onboarding + denial banner`
</verification>

<success_criteria>
- Fresh install → 3-page rationale flow → capability persisted correctly per branch
- Denial recovery is a single tap on the yellow banner → OS Settings
- No re-prompt via OS after any single denial
- `!isGranted` predicate used consistently — `restricted`/`limited`/`permanentlyDenied` all treated as "not granted"
- Widget tests inject `FakePermissionService` — no permission_handler method-channel mocks anywhere in the test tree
- Existing Phase 2 map_widget_test / router_shell_test still green
</success_criteria>

<output>
After completion, create `.planning/phases/03-tracking-mvp/03-05-SUMMARY.md`
</output>
