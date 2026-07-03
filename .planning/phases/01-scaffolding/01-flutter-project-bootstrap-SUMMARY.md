---
phase: 01-scaffolding
plan: "01"
subsystem: infra
tags: [flutter, dart, riverpod, go_router, drift, very_good_analysis, scaffolding]

# Dependency graph
requires: []
provides:
  - "Runnable Flutter shell (auto_explore package) with ProviderScope mounted at root"
  - "Pinned Phase 1 dependency set (drift_flutter 0.3, flutter_riverpod 3.3, go_router 17.3, drift 2.34, path_provider 2.1, logging 1.3, shared_preferences 2.5)"
  - "very_good_analysis lint baseline with generated-code excludes"
  - "Feature-first lib/ tree (features/{map,trips,vehicles,regions,settings,onboarding}, core/{db,errors,logging,routing})"
  - "Riverpod provider seam for GoRouter (appRouterProvider stub — Plan 03 wires real routes)"
  - "Logger initialization seam (setupLogging stub — Plan 04 wires real logger + error hooks)"
  - "build.yaml drift_dev target pointing at lib/core/db/app_database.dart (Plan 02 consumes)"
affects: [02-persistence, 03-routing, 04-logging, 05-map-tile-cache, 06-ci]

# Tech tracking
tech-stack:
  added:
    - "flutter_riverpod ^3.3.2 + riverpod_annotation ^4.0.3"
    - "go_router ^17.3.0"
    - "drift ^2.34.0 + drift_flutter ^0.3.0 (sqlite3 platform setup — no sqlite3_flutter_libs)"
    - "path_provider ^2.1.6 + path ^1.9.0"
    - "logging ^1.3.0 + shared_preferences ^2.5.5"
    - "build_runner ^2.15.0 + drift_dev ^2.34.0 + riverpod_generator ^4.0.4"
    - "very_good_analysis ^10.3.0"
    - "mocktail ^1.0.5 + remove_from_coverage ^2.0.0"
  patterns:
    - "Feature-first lib/features/<feature> layout with lib/core/<seam> for cross-cutting concerns"
    - "package: import prefix everywhere (satisfies always_use_package_imports)"
    - "Alphabetically sorted pubspec (satisfies sort_pub_dependencies)"
    - "Generated code excluded from analyzer + gitignored (*.g.dart, *.freezed.dart, *.drift.dart)"

key-files:
  created:
    - "pubspec.yaml — pinned dependency set"
    - "analysis_options.yaml — very_good_analysis include + generated excludes"
    - "build.yaml — drift_dev codegen target"
    - "lib/main.dart — WidgetsFlutterBinding + setupLogging + ProviderScope(App) entry"
    - "lib/app.dart — MaterialApp.router driven by appRouterProvider"
    - "lib/core/routing/app_router.dart — GoRouter Provider stub"
    - "lib/core/logging/app_logger.dart — setupLogging() stub"
    - "test/widget_test.dart — boot smoke test"
    - "android/, ios/ platform scaffolding via flutter create"
  modified:
    - ".gitignore — appended generated-code + coverage + build artifact patterns"

key-decisions:
  - "Dropped custom_lint ^0.8.1 and riverpod_lint ^3.1.4 from pubspec — irresolvable analyzer version conflict with drift_dev 2.34 (analyzer ^13 vs custom_lint 0.8.1 pinning analyzer ^8). Documented for re-introduction when custom_lint publishes an analyzer 13-compatible release."
  - "Upgraded local Flutter toolchain from 3.38.1 → 3.44.4 to satisfy pubspec constraint (>=3.44.0)."
  - "custom_lint plugin reference removed from analysis_options.yaml (dependency dropped — plugins list omitted)."

patterns-established:
  - "Riverpod provider seams: stubs live in lib/core/<subsystem>/*.dart and are replaced in later plans (routing → Plan 03, logging → Plan 04)"
  - "Test file layout mirrors lib/ (test/widget_test.dart smoke-tests the app root)"
  - "Import ordering: package: imports alphabetical; no relative imports inside lib/"

# Metrics
duration: ~18 min (excluding 6m Flutter SDK upgrade)
completed: 2026-07-03
---

# Phase 01 Plan 01: Flutter Project Bootstrap Summary

**Runnable Flutter shell for `auto_explore` (Trailblazer): ProviderScope root, MaterialApp.router wired through a Riverpod GoRouter provider, feature-first lib/ tree, very_good_analysis lint baseline — `flutter analyze`, `dart format`, and `flutter test` all exit 0.**

## Performance

- **Duration:** ~18 min execution + 6 min Flutter SDK upgrade
- **Started:** 2026-07-03T07:42:00Z (approximate)
- **Completed:** 2026-07-03T08:01:26Z
- **Tasks:** 3/3
- **Files created/modified:** ~90 (73 from `flutter create` + 17 hand-authored)

## Accomplishments

- `flutter create` scaffolded iOS + Android platform folders under org `de.autoexplore` with package name `auto_explore`.
- Pinned Phase 1 dependency set installed via `flutter pub get` — resolved cleanly on Flutter 3.44.4.
- `analysis_options.yaml` upgraded from default `flutter_lints` to `very_good_analysis` with generated-file excludes.
- `build.yaml` targets `drift_dev` at `lib/core/db/app_database.dart` (empty seam for Plan 02).
- `lib/main.dart` mounts `ProviderScope(App)` after `WidgetsFlutterBinding.ensureInitialized()` + `setupLogging()`.
- `lib/app.dart` consumes `appRouterProvider` via `ref.watch` and builds `MaterialApp.router`.
- Feature-first `lib/` tree instantiated with `.gitkeep` files across `features/{map,trips,vehicles,regions,settings,onboarding}` and `core/{db,errors,logging,routing}`.
- Widget smoke test (`App boots without crashing`) passes.
- Verification suite: `flutter analyze --fatal-infos` → 0 issues; `dart format --set-exit-if-changed .` → 0 changed; `flutter test` → 1/1 passed.

## Task Commits

1. **Task 1.1: flutter create + reset boilerplate** — `8bddd6c` (feat)
2. **Task 1.2: install pinned Phase 1 dependency set** — `4b9cb4f` (feat)
3. **Task 1.3: wire ProviderScope root, add lints, folder skeleton, stubs** — `2e2b3f8` (feat)

**Plan metadata commit:** (staged next — `docs(01-01): complete flutter-project-bootstrap plan`)

## Files Created/Modified

Hand-authored:
- `pubspec.yaml` — Trailblazer-scoped dependency pins (alphabetized to satisfy `sort_pub_dependencies`)
- `analysis_options.yaml` — very_good_analysis include + generated-file excludes
- `build.yaml` — drift_dev codegen target
- `.gitignore` — appended generated-code, coverage, build artifact patterns
- `lib/main.dart` — WidgetsFlutterBinding + setupLogging + ProviderScope entry
- `lib/app.dart` — MaterialApp.router consuming appRouterProvider
- `lib/core/routing/app_router.dart` — GoRouter Provider stub (Plan 03 replaces)
- `lib/core/logging/app_logger.dart` — setupLogging() stub (Plan 04 replaces)
- `lib/features/{map,trips,vehicles,regions,settings,onboarding}/.gitkeep`
- `lib/core/{db,errors}/.gitkeep`
- `tool/.gitkeep`
- `test/widget_test.dart` — boot smoke test asserting `Auto-Explore` renders

Generated by `flutter create`:
- `android/` (Kotlin app module, Gradle build config, launch resources)
- `ios/` (Swift Runner, xcodeproj, xcworkspace, Info.plist)
- `README.md`, `.metadata`, `auto_explore.iml`

## Decisions Made

- **Flutter SDK upgrade to 3.44.4** — Local toolchain was 3.38.1; pubspec constraint `>=3.44.0` (per RESEARCH.md) required the upgrade. `flutter upgrade` completed cleanly on the `stable` channel.
- **Drop `custom_lint` + `riverpod_lint`** — Dependency solver could not satisfy `drift_dev ^2.34.0` (needs `analyzer ^13.0.0`) alongside `custom_lint ^0.8.1` (pins `analyzer ^8.0.0`). No overlapping resolution exists in the current pub.dev index. The lints are optional (they surface `riverpod_generator` misuse); regular analyzer + `very_good_analysis` still catches everything else. Re-introduce when a `custom_lint` release supports `analyzer ^13`.
- **Analysis plugin block removed** — Since `custom_lint` is out, the `analyzer.plugins:` section was omitted from `analysis_options.yaml` (would have failed with "plugin not found"). Everything else in RESEARCH.md's lint pattern is preserved.
- **Alphabetized `pubspec.yaml`** — `very_good_analysis` enforces `sort_pub_dependencies`. Kept the sqlite3 comment adjacent to `drift_flutter` for context.
- **`package:` imports everywhere** — `very_good_analysis` enforces `always_use_package_imports`, so `lib/main.dart`, `lib/app.dart`, and `test/widget_test.dart` use `package:auto_explore/…` rather than relative paths.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking] Upgraded Flutter SDK 3.38.1 → 3.44.4**
- **Found during:** Task 1.2 (`flutter pub get`)
- **Issue:** `pubspec.yaml` requires `flutter >=3.44.0` but installed toolchain was 3.38.1 — pub resolution refused.
- **Fix:** Ran `flutter upgrade` on the `stable` channel (took ~6 min).
- **Files modified:** none (toolchain change only)
- **Verification:** `flutter --version` reports 3.44.4; `flutter pub get` succeeds.
- **Committed in:** N/A (toolchain state, not repo)

**2. [Rule 3 — Blocking] Dropped `custom_lint ^0.8.1` and `riverpod_lint ^3.1.4`**
- **Found during:** Task 1.2 (`flutter pub get`, second attempt after Flutter upgrade)
- **Issue:** Version solver reported `drift_dev >=2.32.1 is incompatible with custom_lint` because `drift_dev ^2.34.0` needs `analyzer ^13.0.0` while every published `custom_lint` (up to 0.8.1) tops out at `analyzer ^8.0.0`. Loosening to `any` didn't help — no overlap exists.
- **Fix:** Removed both `custom_lint` and `riverpod_lint` from `dev_dependencies` with an inline comment documenting the reason and re-introduction condition. Also removed the `analyzer.plugins: - custom_lint` block from `analysis_options.yaml` to keep the analyzer happy.
- **Files modified:** `pubspec.yaml`, `analysis_options.yaml`
- **Verification:** `flutter pub get` completes; `flutter analyze --fatal-infos` returns 0 issues.
- **Committed in:** `4b9cb4f` (Task 1.2) + `2e2b3f8` (Task 1.3)

**3. [Rule 1 — Bug] Fixed `always_use_package_imports` + `unused_import` + `sort_pub_dependencies` analyzer infos/warnings**
- **Found during:** Task 1.3 verification (`flutter analyze --fatal-infos` reported 6 issues on first run)
- **Issue:** Plan's file bodies used relative imports (`import 'app.dart';`), the widget test imported unused `flutter/material.dart`, and `pubspec.yaml` grouped deps by concern rather than alphabetically — all three flagged by `very_good_analysis`.
- **Fix:**
  1. Switched all lib/ imports and the test to `package:auto_explore/…`.
  2. Removed `import 'package:flutter/material.dart'` from the widget test.
  3. Alphabetized `pubspec.yaml` (kept the sqlite3 comment context).
- **Files modified:** `lib/main.dart`, `lib/app.dart`, `test/widget_test.dart`, `pubspec.yaml`
- **Verification:** `flutter analyze --fatal-infos` → 0 issues.
- **Committed in:** `2e2b3f8` (Task 1.3)

---

**Total deviations:** 3 auto-fixed (2 blocking, 1 bug).
**Impact on plan:** All deviations are mechanical — no scope change, no architectural shift. The `custom_lint`/`riverpod_lint` drop is the only substantive one: Riverpod misuse detection loses its dedicated custom lints, but the analyzer + human review still catch the common footguns. Re-add in a future plan (or the phase's follow-up commit) once upstream compatibility lands.

## Issues Encountered

- **Flutter version mismatch** (3.38.1 vs pubspec >=3.44.0) — resolved via `flutter upgrade`.
- **Analyzer version conflict** between `drift_dev` and `custom_lint`/`riverpod_lint` — resolved by dropping the two lint packages (documented).
- **Line-ending warnings** (`LF will be replaced by CRLF`) — cosmetic on Windows; not blocking any verification.

## User Setup Required

None — all setup was automated. Optional local sanity: `flutter build apk --debug` (untested here — Android toolchain missing `cmdline-tools`, per `flutter doctor`; CI in Plan 06 will cover this).

## Next Phase Readiness

Ready for Plans 02–05 in Wave 2:
- **Plan 02 (persistence):** `build.yaml` already points `drift_dev` at `lib/core/db/app_database.dart`; the empty seam is in place.
- **Plan 03 (routing):** `appRouterProvider` seam exists at `lib/core/routing/app_router.dart` — replace the stub with real routes.
- **Plan 04 (logging):** `setupLogging()` seam exists at `lib/core/logging/app_logger.dart` — replace no-op with real logger + `FlutterError.onError` + `PlatformDispatcher.instance.onError`.
- **Plan 05 (map tile cache):** `lib/features/map/` folder ready.
- **Plan 06 (CI):** Verification commands already exit 0 locally — CI can enforce the same.

Blockers/concerns:
- **`custom_lint` + `riverpod_lint` re-integration** — carry as a small follow-up in the phase (or a Phase 2 chore) once upstream publishes an analyzer 13-compatible build. Non-blocking.
- **Android toolchain** — `flutter doctor` reports missing `cmdline-tools` and Visual Studio C++ workload. Only matters when we build/deploy locally; CI (Plan 06) will supply a clean image.

---
*Phase: 01-scaffolding*
*Completed: 2026-07-03*
