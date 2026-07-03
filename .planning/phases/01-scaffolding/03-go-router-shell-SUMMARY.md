---
phase: 01-scaffolding
plan: "03"
subsystem: ui
tags: [go_router, riverpod, shared_preferences, onboarding, navigation, flutter]

# Dependency graph
requires:
  - phase: 01-scaffolding
    provides: "Riverpod ProviderScope root, appRouterProvider stub, App widget wiring MaterialApp.router, pinned go_router 17.3.0 + shared_preferences 2.5.5"
provides:
  - "Real GoRouter with /splash, /onboarding, / (placeholder-home) routes exposed via appRouterProvider"
  - "OnboardingFlagRepository around SharedPreferencesAsync — persists the one-shot `onboarding_done` flag"
  - "Splash → onboarding (first launch) → home (subsequent) flow with async prefs read gated in SplashScreen"
  - "PlaceholderHomeScreen at `/` — Phase 2 replaces with StatefulShellRoute + real map"
  - "Widget tests covering both launch paths + repo unit tests"
affects: ["02-realtime-tracking", "03-osm-extract", "04-hmm-map-matcher", "07-map-rendering"]

# Tech tracking
tech-stack:
  added:
    - "go_router ^17.3.0 (activated — stub replaced)"
    - "shared_preferences_platform_interface ^2.4.2 (dev only — for InMemorySharedPreferencesAsync in tests)"
  patterns:
    - "Plain `Provider<T>` for router/repository providers — no @Riverpod code-gen (project-wide decision from Plan 01-01)"
    - "First-launch gating inside SplashScreen (reads flag once, `context.go`) rather than a top-level `GoRouter.redirect` — keeps the router synchronous"
    - "Feature slice layout: `lib/features/<name>/{data,presentation}` (onboarding, map)"

key-files:
  created:
    - "lib/features/onboarding/data/onboarding_flag_repository.dart"
    - "lib/features/onboarding/presentation/splash_screen.dart"
    - "lib/features/onboarding/presentation/onboarding_screen.dart"
    - "lib/features/map/presentation/placeholder_home_screen.dart"
    - "test/features/onboarding/onboarding_flag_repository_test.dart"
    - "test/core/routing/app_router_test.dart"
  modified:
    - "lib/core/routing/app_router.dart (stub → real GoRouter with 3 routes)"
    - "test/widget_test.dart (asserts first-launch onboarding text; installs InMemorySharedPreferencesAsync)"
    - "pubspec.yaml (added shared_preferences_platform_interface to dev_dependencies)"

key-decisions:
  - "Ship plain `Provider<GoRouter>` and `Provider<OnboardingFlagRepository>` — @Riverpod codegen intentionally disabled while custom_lint/riverpod_lint are out (STATE.md Plan 01-01)."
  - "Onboarding gate lives inside SplashScreen microtask, not a top-level GoRouter redirect — synchronous router, no re-reads on every nav."
  - "Onboarding-done key = literal string `onboarding_done` (exposed as `OnboardingFlagRepository.prefsKey` for tests)."
  - "SharedPreferencesAsync (not the legacy sync API) — matches RESEARCH.md pitfall #4 and long-term Flutter direction."

patterns-established:
  - "Feature slice: `lib/features/<slice>/{data,presentation}` — data holds repositories, presentation holds screens/widgets."
  - "Repository construction via constructor-injected platform dependency (`SharedPreferencesAsync`) — swappable for `InMemorySharedPreferencesAsync` in tests."
  - "Router provider is a top-level `Provider<GoRouter>` in `lib/core/routing/app_router.dart`; the `App` widget `ref.watch`es it and passes to `MaterialApp.router`."

# Metrics
duration: ~22 min
completed: 2026-07-03
---

# Phase 01 Plan 03: go-router-shell Summary

**Live GoRouter with splash → onboarding → placeholder-home flow, gated by a `SharedPreferencesAsync`-backed `onboarding_done` flag; first-launch onboarding shown exactly once.**

## Performance

- **Duration:** ~22 min
- **Started:** 2026-07-03T08:00Z (approx, session began at Wave-2 spawn)
- **Completed:** 2026-07-03T08:23Z
- **Tasks:** 3/3
- **Files created:** 6 (4 lib + 2 test)
- **Files modified:** 3 (`app_router.dart`, `widget_test.dart`, `pubspec.yaml`)

## Accomplishments

- **Real GoRouter live.** Stub at `lib/core/routing/app_router.dart` replaced with a three-route `GoRouter` (initialLocation `/splash`, then `/onboarding` and `/` = placeholder home). Router still lives inside a plain `Provider<GoRouter>` so `App.ref.watch(appRouterProvider)` continues to work unchanged.
- **First-launch persistence works.** `OnboardingFlagRepository` wraps `SharedPreferencesAsync` with `isDone / markDone / reset`. The splash screen reads the flag once on `initState`'s microtask and routes accordingly — no top-level `redirect:`, so navigation stays synchronous.
- **Onboarding UI.** `OnboardingScreen` is a minimal `ConsumerWidget` with a title, blurb ("Every road you drive gets painted onto the map. That view is the whole point."), and a `FilledButton` that flips the flag then `context.go('/')`.
- **Placeholder home.** `PlaceholderHomeScreen` renders `Scaffold` + centered `'Auto-Explore'` text — Phase 2 replaces this with the real map behind a `StatefulShellRoute`.
- **Six passing tests.** 3 repo unit tests + 2 router widget flow tests + 1 smoke test. Runs green under `flutter test` in ~2 s.

## Task Commits

1. **Task 3.1: onboarding_flag_repository + tests** — `7690287` (feat)
2. **Task 3.2: real GoRouter + splash/onboarding/home screens** — `c48b62b` (feat)
3. **Task 3.3: widget tests for splash → onboarding → home flow** — `0dc3eae` (test)

**Plan metadata commit:** _pending_ (`docs(01-03): complete go-router-shell plan`).

## Files Created/Modified

**Created:**

- `lib/features/onboarding/data/onboarding_flag_repository.dart` — `SharedPreferencesAsync` wrapper for the `onboarding_done` flag; exposes `Provider<OnboardingFlagRepository>`.
- `lib/features/onboarding/presentation/splash_screen.dart` — `ConsumerStatefulWidget` that reads the flag on a microtask and `context.go`s to `/onboarding` or `/`.
- `lib/features/onboarding/presentation/onboarding_screen.dart` — `ConsumerWidget` welcome/continue UI; marks the flag done then navigates to `/`.
- `lib/features/map/presentation/placeholder_home_screen.dart` — Phase 2 stub for the map root.
- `test/features/onboarding/onboarding_flag_repository_test.dart` — 3 unit tests (default false, mark→true, reset→false).
- `test/core/routing/app_router_test.dart` — 2 widget tests (first-launch full flow, second-launch bypass).

**Modified:**

- `lib/core/routing/app_router.dart` — Plan 01 stub replaced with real 3-route `GoRouter`. Kept as plain `Provider<GoRouter>` (no `@Riverpod` codegen) per Plan 01-01 decision.
- `test/widget_test.dart` — Assertion updated from immediate `'Auto-Explore'` text to `'Welcome to Auto-Explore'` (first-launch onboarding), plus `InMemorySharedPreferencesAsync` install so the smoke test runs offline of any platform channel.
- `pubspec.yaml` — Added `shared_preferences_platform_interface: ^2.4.2` under `dev_dependencies` so tests can import `InMemorySharedPreferencesAsync` (avoids `depend_on_referenced_packages` violation).

## Decisions Made

- **Plain `Provider<T>` over `@Riverpod` code-gen.** Plan 03 samples used `@Riverpod`, but STATE.md locks Plan 01-01's decision to disable riverpod_generator features while `custom_lint`/`riverpod_lint` are out. Kept both `appRouterProvider` and `onboardingFlagRepositoryProvider` as plain `Provider` — no generated `.g.dart` files, no dependency on the code-gen pipeline for routing/onboarding.
- **Gate onboarding in SplashScreen (not top-level `redirect:`).** The plan explicitly notes this choice; kept as-is because it (a) prevents re-running the async prefs read on every navigation and (b) keeps the router pure/synchronous. Deep-linked users transit through splash first, which is fine for a personal-use app.
- **Expose `OnboardingFlagRepository.prefsKey` as a public static const.** Not strictly required but makes the prefs key one source of truth if a future test wants to assert the raw stored value.
- **Skipped `flutter build apk --debug`.** Plan 3.2 lists it but STATE.md's Plan 01-01 note flags Windows-local Android SDK/licenses as unresolved; CI in Plan 06 will run the debug build. Analyzer + tests still fully green.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Replaced `@Riverpod` code-gen with plain `Provider<T>`.**

- **Found during:** Task 3.1 (repository) and Task 3.2 (router)
- **Issue:** Plan snippets used `@Riverpod(keepAlive: true)` with `part '<file>.g.dart'`, but Plan 01-01 dropped `riverpod_generator` from active use (custom_lint / analyzer conflict with `drift_dev` ^13). Running `build_runner` for these files would either fail or add generated code the project intentionally avoids.
- **Fix:** Rewrote both providers as top-level `final xxxProvider = Provider<T>(...)`. Matches the existing stub in `app_router.dart` (Plan 01) and the STATE.md decision. `keepAlive` is the default for plain `Provider`, so behavior is equivalent.
- **Files modified:** `lib/features/onboarding/data/onboarding_flag_repository.dart`, `lib/core/routing/app_router.dart`
- **Verification:** `flutter analyze --fatal-infos` clean on all scoped files; all 6 tests pass.
- **Committed in:** `7690287` (Task 3.1), `c48b62b` (Task 3.2).

**2. [Rule 3 - Blocking] Imported test helpers from `shared_preferences_platform_interface` and declared it as a dev dependency.**

- **Found during:** Task 3.1 (writing the repo test)
- **Issue:** Plan sample referenced `InMemorySharedPreferencesAsync` and `SharedPreferencesAsyncPlatform` as if they were exported by `shared_preferences`. They are not — `shared_preferences.dart` public API only re-exports the async and legacy client classes, not the platform-interface classes. Without a direct dep on `shared_preferences_platform_interface`, importing those symbols is either impossible (transitive-only) or trips `depend_on_referenced_packages`.
- **Fix:** Added `shared_preferences_platform_interface: ^2.4.2` under `dev_dependencies` in `pubspec.yaml` (kept alphabetical); import test helpers directly from that package (`in_memory_shared_preferences_async.dart`, `shared_preferences_async_platform_interface.dart`).
- **Files modified:** `pubspec.yaml`, `test/features/onboarding/onboarding_flag_repository_test.dart`, `test/core/routing/app_router_test.dart`, `test/widget_test.dart`.
- **Verification:** `flutter pub get` resolves cleanly; all 6 tests pass. `flutter analyze` reports no `depend_on_referenced_packages` warning.
- **Committed in:** `7690287` (task 3.1), `0dc3eae` (task 3.3 also uses these imports).

**3. [Rule 3 - Blocking] Widget smoke test's ordering vs Task 3.2's `<verify>` block.**

- **Found during:** Task 3.2 verify
- **Issue:** Task 3.2 `<verify>` requires `flutter test` to pass, but the plan-supplied smoke test only asserts `'Auto-Explore'` text — which after 3.2 is no longer visible on first launch (onboarding shows instead). Task 3.3 explicitly updates the smoke test. That's an internal plan ordering conflict.
- **Fix:** Committed Task 3.2 with analyzer + format clean (both green), then Task 3.3 landed the widget_test update. Net effect: after both commits `flutter test` is fully green.
- **Files modified:** `test/widget_test.dart`.
- **Verification:** `flutter test` all pass after `0dc3eae`.
- **Committed in:** `0dc3eae` (task 3.3).

---

**Total deviations:** 3 auto-fixed (all Rule 3 — blocking).
**Impact on plan:** No scope creep. All three deviations preserve the plan's intent (real router, persistent flag, correct tests) while reconciling code-gen constraints and test-helper packaging. No architectural changes.

## Issues Encountered

- **Parallel Wave-2 sibling plans wrote to my working tree during execution.**
  Plans 02 (Drift) and 04 (errors/logging) landed commits into `lib/core/db/`, `lib/core/errors/`, and `lib/main.dart`. `flutter analyze lib/` at the whole-tree level shows errors from Plan 02's `.g.dart` not-yet-generated. Mitigation: analyzed and format-checked only Plan 03's scoped paths (`lib/core/routing lib/features/onboarding lib/features/map lib/app.dart` + corresponding test dirs). All Plan 03 scope is fully clean and green. Whole-tree cleanliness is the orchestrator's concern once all Wave 2 plans complete.
- **`main.dart` modifications from Plan 04.** Plan 04 committed real `FlutterError.onError`/`PlatformDispatcher.onError` hooks; I did not need to touch `main.dart` at all (router is consumed via the unchanged `App` widget). No conflict.

## Next Phase Readiness

**Ready for Phase 2:**

- `/` route is a placeholder — Phase 2 (`02-realtime-tracking`) can wrap it in a `StatefulShellRoute` with the real map view without touching splash/onboarding.
- `appRouterProvider` is Riverpod-exposed, so tests can override it easily.
- Onboarding done-flag persists across restarts via `SharedPreferencesAsync`.

**Blockers/concerns:**

- **`flutter build apk --debug` not locally verified this session** — deferred to Plan 06 CI (matches STATE.md).
- **Riverpod codegen still off** — future feature slices that expect `@Riverpod` conventions should keep using plain `Provider` / hand-written `NotifierProvider` until the `custom_lint` analyzer-13 unblock lands.

---
*Phase: 01-scaffolding*
*Completed: 2026-07-03*
