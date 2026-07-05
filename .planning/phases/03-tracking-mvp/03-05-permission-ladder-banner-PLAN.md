---
id: 03-05
phase: 03-tracking-mvp
plan: 05
type: execute
wave: 2
depends_on: [03-03]
files_modified:
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
  - test/features/onboarding/onboarding_ladder_test.dart
  - test/features/onboarding/tracking_capability_repository_test.dart
  - test/features/map/permission_denial_banner_test.dart
autonomous: false
requirements_addressed: [TRK-10, TRK-11]

user_setup: []

must_haves:
  truths:
    - "First-launch onboarding walks the user through three back-to-back permission steps with rationale copy between them: whenInUse → Always → Motion(iOS)/Notification+BatteryOpt(Android)"
    - "If Always is denied, tracking_capability is persisted as `manualOnly`; if Notification is denied on Android 13+, tracking_capability is `manualOnly`"
    - "OS permission dialog is never re-requested after a single denial (per CONTEXT); recovery goes through the yellow banner + openAppSettings()"
    - "PermissionDenialBanner is visible on the map screen whenever `Permission.locationAlways.status.isDenied` OR `Permission.notification.status.isDenied` (Android 13+) — else invisible"
    - "Tapping the banner calls `openAppSettings()` from permission_handler"
    - "Banner re-evaluates on `didChangeAppLifecycleState.resumed` — comes back from Settings with Always granted → banner disappears"
    - "`tracking_capability` value survives app restart (persisted in AppPrefs via shared_preferences)"
  artifacts:
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
      to: "permission_handler + BackgroundGeolocationFacade.showIgnoreBatteryOptimizations"
      via: "sequential await Permission.X.request() + facade call"
      pattern: "Permission\\.locationAlways\\.request"
    - from: "permission_denial_banner.dart"
      to: "permission_handler.openAppSettings"
      via: "onTap → await openAppSettings()"
      pattern: "openAppSettings"
    - from: "map_screen.dart"
      to: "permission_denial_banner.dart"
      via: "Stack slot at top of map, below any AppBar-equivalent chrome"
      pattern: "PermissionDenialBanner"
---

<objective>
Replace Phase 1's single-tap onboarding with a 3-page permission ladder (whenInUse → Always → Motion/Notification+BatteryOpt), persist the resulting `TrackingCapability`, and add a yellow denial banner on the map screen that deep-links to OS Settings when Always is missing.

Purpose: TRK-10 (iOS whenInUse→Always ladder), TRK-11 (Android FGS + battery-optimization prompt). This is the only P3 UI-facing change outside of the FAB/overlay in 03-06.

Output: 3 onboarding pages + capability repo + denial banner + map-screen integration + 3 test files. Contains a **checkpoint** at the end to visually review the copy on device.

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
  <name>Task 1: TrackingCapability model + repository + rationale-page widget scaffolding</name>
  <files>
    - lib/features/onboarding/data/tracking_capability.dart
    - lib/features/onboarding/data/tracking_capability_repository.dart
    - lib/features/onboarding/data/tracking_capability_providers.dart
    - lib/features/onboarding/presentation/widgets/permission_rationale_page.dart
    - test/features/onboarding/tracking_capability_repository_test.dart
  </files>
  <action>
    1. `lib/features/onboarding/data/tracking_capability.dart`:
       ```dart
       enum TrackingCapability { fullAuto, manualOnly }
       ```

    2. `lib/features/onboarding/data/tracking_capability_repository.dart`:
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

    3. `lib/features/onboarding/data/tracking_capability_providers.dart`:
       ```dart
       final trackingCapabilityRepositoryProvider =
           Provider<TrackingCapabilityRepository>((ref) {
         return TrackingCapabilityRepository(SharedPreferencesAsync());
       });
       final trackingCapabilityProvider = FutureProvider<TrackingCapability>((ref) {
         return ref.watch(trackingCapabilityRepositoryProvider).load();
       });
       ```
       Codegen OFF (STATE.md 01-01) — plain `Provider<T>` / `FutureProvider<T>`.

    4. `lib/features/onboarding/presentation/widgets/permission_rationale_page.dart` — the shared page widget layout every rationale page reuses (single concern: icon + title + body + primary button):
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
       Consistent visuals, no color transparency yet (avoid `withValues` unless needed). Keep it a plain `StatelessWidget`.

    5. `test/features/onboarding/tracking_capability_repository_test.dart`:
       - Use `SharedPreferencesAsync.setMockInitialValues` or `InMemorySharedPreferencesAsync` (Plan 01-03 pattern).
       - Cases:
         - `load()` on empty prefs → `TrackingCapability.fullAuto`
         - `save(manualOnly)` then `load()` → `TrackingCapability.manualOnly`
         - `save(fullAuto)` then `load()` → `TrackingCapability.fullAuto`
         - `prefsKey == 'tracking_capability'` (public API contract test)

    Anti-patterns to avoid:
    - Do NOT couple TrackingCapability to any Drift table — this is a single boolean-ish flag, prefs is the right store (matches STATE.md `AppPrefs` note but uses shared_preferences which is Phase 1's canonical prefs mechanism per Plan 01-03).
    - Do NOT bake copy into `permission_rationale_page.dart` — pages inject their own strings.
    - Do NOT use `withOpacity` for icon color (STATE.md rule).
  </action>
  <verify>
    - `flutter analyze` clean
    - `flutter test test/features/onboarding/tracking_capability_repository_test.dart` green
  </verify>
  <done>
    Capability model + repository + provider + shared rationale page widget ready. Nothing wired to the UI yet.
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
    1. Three `Consumer(Stateful)Widget` pages under `lib/features/onboarding/presentation/pages/`, each building `PermissionRationalePage`:

       **`permission_when_in_use_page.dart`** — "While using the app":
       - Icon: `Icons.location_on`
       - Title: `"Location while using Trailblazer"`
       - Body: `"Trailblazer draws the roads you drive on the map. It first needs permission to see your location while you're using the app."`
       - Primary: `"Continue"` → `await Permission.locationWhenInUse.request();` then `pageController.nextPage(...)` regardless of grant/deny. (If denied, the next page will still be shown; the user can back out.)

       **`permission_always_page.dart`** — "Always" upgrade:
       - Icon: `Icons.explore` (or similar)
       - Title: `"Log trips in the background"`
       - Body: `"Trailblazer records trips even when the app is closed — so we capture the whole drive, not just the moment you opened the app."`
       - Primary: `"Enable background location"` → `final s = await Permission.locationAlways.request();` — if denied, do NOT force `manualOnly` here yet (the last page also matters); just remember locally and continue.
       - Secondary: `"Manual only"` (text button) → skip forward with `_alwaysDenied = true`.

       **`permission_motion_notification_page.dart`** — platform-branched, last page:
       - Icon: `Icons.notifications_active`
       - Title (iOS): `"Motion & Fitness"`
       - Title (Android): `"Notifications and battery"`
       - Body (iOS): `"iOS's Motion & Fitness sensor helps distinguish driving from walking — this makes the auto-detect smarter."`
       - Body (Android): `"Trailblazer shows a persistent notification while recording (Android needs this to keep tracking alive). It also asks Android to ignore battery optimizations, so the OS doesn't kill tracking mid-trip."`
       - Primary (iOS): `"Continue"` → `await Permission.sensors.request();` (motion & fitness)
       - Primary (Android): `"Enable"` → `await Permission.notification.request();` then `await ref.read(backgroundGeolocationFacadeProvider).showIgnoreBatteryOptimizations();`
       - After primary → resolve final capability: read all statuses, compute:
         ```dart
         final always = await Permission.locationAlways.status;
         final notif  = Platform.isAndroid ? await Permission.notification.status : PermissionStatus.granted;
         final capability = (always.isGranted && !notif.isDenied)
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
       - Widget test. Use `mocktail` (already in devDeps? — if not, add to `dev_dependencies` alphabetized) OR write a hand-rolled `_FakePermissionCall` shim by wrapping calls through a small `PermissionService` abstraction. **Cleaner path:** introduce a thin `PermissionService` interface in `lib/features/onboarding/data/permission_service.dart` with methods `requestWhenInUse() / requestAlways() / requestSensors() / requestNotification()`, provide a real impl (calls permission_handler) and a fake for tests. Inject via a provider. Keep the interface small.
       - Cases:
         - All-granted path → onboarding_done flag=true, tracking_capability=fullAuto, navigator popped to `/`
         - Always-denied path → tracking_capability=manualOnly, onboarding_done=true, navigation still to `/`
         - Android notification denied → tracking_capability=manualOnly
         - Rationale page copy renders `find.text(...)` for a stable substring per page

    Anti-patterns to avoid:
    - Do NOT call `Permission.X.request()` twice for the same permission across pages — one request per permission (CONTEXT: "never re-prompt via OS dialog").
    - Do NOT use `Navigator.pop` — go_router only. `context.go('/')` is the exit.
    - Do NOT gate the Continue button on grant — the flow proceeds regardless; capability just reflects the outcome.
    - Do NOT call `pod install` / `flutter pub add mocktail` without checking existing devDeps for existing test helpers.
  </action>
  <verify>
    - `flutter analyze` clean
    - `flutter test test/features/onboarding/` all green
    - `flutter test test/features/map/map_widget_test.dart` still green (no regression on 02-03 pattern)
  </verify>
  <done>
    Three-page permission ladder replaces the P1 single Continue. Capability is persisted per branch. Existing widget tests continue to pass.
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
       - Watches a new provider `permissionDenialBannerVisibleProvider` (define locally in this file):
         ```dart
         final permissionDenialBannerVisibleProvider =
             FutureProvider<bool>((ref) async {
           final always = await Permission.locationAlways.status;
           if (!always.isGranted) return true;
           if (Platform.isAndroid) {
             final notif = await Permission.notification.status;
             if (notif.isDenied || notif.isPermanentlyDenied) return true;
           }
           return false;
         });
         ```
         The banner widget invalidates this provider in `didChangeAppLifecycleState(AppLifecycleState.resumed)` so it re-reads on return from Settings.
       - Visual: full-width strip, ~44 dp tall, yellow glass (`Color(0xFFFFC107).withValues(alpha: 0.85)`, per STATE.md — use `withValues`, NOT `withOpacity`), rounded corners `BorderRadius.circular(12)`, 12 dp horizontal margin, text "Enable Always for auto-trips — tap to open Settings", chevron icon on the right.
       - `onTap`: `await openAppSettings();` (permission_handler).
       - When `AsyncValue<bool>` resolves to `false` → return `const SizedBox.shrink()`.

    2. Edit `lib/features/map/presentation/map_screen.dart`:
       - Slot `PermissionDenialBanner` at the TOP of the map Stack, positioned via `Positioned(top: mediaquery.top + 12, left: 0, right: 0, child: ...)`. It sits above the map, below the top-of-screen safe area, does not overlap the FocusAreaPill (which is centred-top per P2).
       - Verify against `map_screen.dart`'s current Stack (per STATE.md 02-05): existing widgets stay where they are.
       - Banner is only shown when `currentIndex == 0` (Map tab) — reuse the pattern from Plan 02-06 that hides FAB/pill on other tabs.

    3. `test/features/map/permission_denial_banner_test.dart`:
       - Override `permissionDenialBannerVisibleProvider` with `AsyncValue.data(true)` → assert `find.byType(PermissionDenialBanner)` returns a non-empty widget with the copy visible.
       - Override with `AsyncValue.data(false)` → assert the banner effectively renders `SizedBox.shrink()`.
       - Tap test — mock `openAppSettings` (via `PermissionService` seam from Task 2 if it makes sense, else with `MethodChannel` mock). Assert `openAppSettings` was called once.

    Anti-patterns to avoid:
    - Do NOT use `withOpacity` — `withValues(alpha:)` is mandatory (STATE.md).
    - Do NOT put banner inside a `Column` that would push the map down — it overlays via `Stack + Positioned`.
    - Do NOT eagerly re-request the OS dialog (CONTEXT: "never re-prompt via OS") — the banner is the ONLY recovery path in P3 outside settings screens.
  </action>
  <verify>
    - `flutter analyze` clean
    - `flutter test test/features/map/` all green
  </verify>
  <done>
    Yellow banner visible on the map when Always is denied; tapping opens OS Settings; re-check runs on resume.
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
- Commit: `feat(03-05): permission ladder onboarding + denial banner`
</verification>

<success_criteria>
- Fresh install → 3-page rationale flow → capability persisted correctly per branch
- Denial recovery is a single tap on the yellow banner → OS Settings
- No re-prompt via OS after any single denial
- Existing Phase 2 map_widget_test / router_shell_test still green
</success_criteria>

<output>
After completion, create `.planning/phases/03-tracking-mvp/03-05-SUMMARY.md`
</output>
