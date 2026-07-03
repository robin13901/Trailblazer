---
phase: 01-scaffolding
plan: "04"
subsystem: infra
tags: [logging, error-handling, sealed-class, result-type, flutter, dart3]

# Dependency graph
requires:
  - phase: 01-scaffolding
    provides: "AppLogger stub, package auto_explore skeleton (Plan 01)"
provides:
  - "Real logging-backed AppLogger with kDebugMode-gated level (ALL vs WARNING)"
  - "Global FlutterError.onError + PlatformDispatcher.instance.onError funnels"
  - "Sealed DomainError hierarchy: DatabaseError, StorageError, PermissionDeniedError, NetworkError, UnknownError"
  - "DomainError.wrap() adapter for arbitrary throwables"
  - "Result<T> sum type (Ok<T>/Err<T>) with when() fold"
affects:
  - 02-location-collection
  - 03-osm-download
  - 04-hmm-matcher
  - 05-inbox
  - 06-map-rendering
  - 07-diagnostics
  - all downstream phases surfacing failures

# Tech tracking
tech-stack:
  added: []  # logging ^1.3.0 was already pinned in Plan 01
  patterns:
    - "sealed class DomainError (Dart 3 pattern-matching)"
    - "final class subclass extends sealed base (exhaustive switch)"
    - "Result<T> as sum type, use case failure without throwing"
    - "kDebugMode gate for logger level"
    - "package-scoped imports (package:auto_explore/...)"

key-files:
  created:
    - lib/core/errors/domain_error.dart
    - lib/core/errors/result.dart
    - test/core/errors/domain_error_test.dart
    - test/core/logging/app_logger_test.dart
  modified:
    - lib/core/logging/app_logger.dart
    - lib/main.dart

key-decisions:
  - "PermissionDeniedError carries a required `permission` field (Phase 3 permission_handler will attach the specific permission name)"
  - "NetworkError carries optional `statusCode` (Phase 5 OSM download needs HTTP status)"
  - "DomainError.toString() uses runtimeType with documented lint ignore — needed for diagnostic log clarity"
  - "PlatformDispatcher.instance.onError returns true (suppress OS crash) — dev-only decision consistent with CONTEXT.md 'no remote crash reporting'"
  - "Log format: plain-text for release (debugPrint), dart:developer.log() for debug (DevTools structured)"

patterns-established:
  - "Wrap non-DomainError throwables via DomainError.wrap() at error-boundary layer"
  - "Repositories/use-cases returning Result<T> when failure is data (not exceptional)"
  - "Global error hooks wired in main() BEFORE runApp(), after setupLogging()"

# Metrics
duration: ~25min
completed: 2026-07-03
---

# Phase 01 Plan 04: Error & Logging Infrastructure Summary

**logging-backed AppLogger with kDebugMode gate, global FlutterError + PlatformDispatcher hooks, sealed DomainError hierarchy (Database/Storage/Permission/Network/Unknown), and Result<T> sum type.**

## Performance

- **Duration:** ~25 min
- **Started:** 2026-07-03 (Wave 2 parallel execution)
- **Completed:** 2026-07-03
- **Tasks:** 3
- **Files modified:** 2 lib + 2 test files created; 1 lib file replaced; 1 lib main hooked
- **Total commits:** 4 (3 task commits + 1 cleanup)

## Accomplishments

- Replaced the Plan 01 AppLogger stub with a real `logging`-backed setup:
  debug builds log at `Level.ALL` via `dart:developer.log()` (DevTools structured
  output); release builds log at `Level.WARNING` via `debugPrint`.
- Sealed `DomainError` hierarchy with five concrete subtypes covering the four
  required categories (DB/Storage/Permission/Network) plus catch-all Unknown.
  `DomainError.wrap()` provides a safe adapter for arbitrary throwables and is
  now the single entry point at error boundaries.
- Minimal `Result<T>` sum type (`Ok<T>` / `Err<T>`) with an exhaustive
  `when()` fold — usable in Dart 3 pattern-matching switch statements.
- Global error hooks wired in `main.dart`: both `FlutterError.onError` and
  `PlatformDispatcher.instance.onError` funnel through `DomainError.wrap` and
  log at `severe`. `PlatformDispatcher` returns `true` to prevent OS-level
  crash (dev-only, matches CONTEXT.md "no remote crash reporting").
- Unit tests for logger enablement, `DomainError.wrap` pass-through and
  wrapping, and `Result.when()` for both branches (5 new tests total).
- Widget smoke test from Plan 01 preserved (still green after Plan 03's
  earlier splash-screen update + Plan 04's main.dart edits).

## Task Commits

1. **Task 4.1: Replace app_logger stub with real setupLogging()** — `670604c` (feat)
2. **Task 4.2: Sealed DomainError hierarchy + Result<T>** — `499b798` (feat)
   - Followup cleanup: removed now-redundant `.gitkeep` — `4cc7f64` (chore)
3. **Task 4.3: Wire FlutterError + PlatformDispatcher hooks in main.dart** — `3341081` (feat)

**Plan metadata:** (final `docs(01-04)` commit follows this SUMMARY)

## Files Created / Modified

- `lib/core/logging/app_logger.dart` — real `setupLogging()` (replaces Plan 01 stub)
- `lib/core/errors/domain_error.dart` — sealed hierarchy + `wrap()` factory
- `lib/core/errors/result.dart` — `sealed Result<T>` with `Ok`/`Err`
- `lib/main.dart` — additive: `FlutterError.onError` + `PlatformDispatcher.instance.onError` hooks
- `test/core/logging/app_logger_test.dart` — asserts logger enabled after `setupLogging()`
- `test/core/errors/domain_error_test.dart` — covers `wrap()` and `Result.when()`

## Decisions Made

- **runtimeType in DomainError.toString():** Kept and documented with a
  `// ignore: no_runtimetype_tostring` block-comment justification. Rationale:
  concrete subtype name is essential for diagnostic scanning of log lines and
  this is dev-only output — release builds do not ship crash reporting.
- **Type annotation on `FlutterError.onError` closure:** Removed
  `FlutterErrorDetails` parameter type per `avoid_types_on_closure_parameters`
  lint (function signature is inferred from `FlutterErrorHandler`).
- **`dart:ui` import removed:** `PlatformDispatcher` re-exports from
  `package:flutter/foundation.dart`; the explicit `dart:ui` import triggered
  `unnecessary_import`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking] Dropped `dart:ui` import; removed closure parameter type annotation**
- **Found during:** Task 4.3 (main.dart verify)
- **Issue:** `flutter analyze --fatal-infos` flagged the plan-provided snippet
  with two `info` diagnostics (`unnecessary_import`, `avoid_types_on_closure_parameters`).
- **Fix:** Dropped `import 'dart:ui';` (functionality remains via
  `package:flutter/foundation.dart`). Removed the `FlutterErrorDetails` type
  annotation on the `onError` closure parameter (still inferred).
- **Files modified:** `lib/main.dart`
- **Verification:** `flutter analyze --fatal-infos` clean; `flutter test` all pass.
- **Committed in:** `3341081`

**2. [Rule 3 — Blocking] Added `// ignore` doc for runtimeType.toString**
- **Found during:** Task 4.2 (errors verify)
- **Issue:** `no_runtimetype_tostring` lint would fail `--fatal-infos`; then
  the required `// ignore:` needed a `document_ignores` justification comment.
- **Fix:** Added a two-line explanation above the `// ignore: no_runtimetype_tostring`
  comment describing why the runtime type is retained for diagnostic log clarity.
- **Files modified:** `lib/core/errors/domain_error.dart`
- **Verification:** analyzer clean.
- **Committed in:** `499b798`

**3. [Rule 3 — Blocking] Removed dangling `lib/core/errors/.gitkeep`**
- **Found during:** Task 4.2 followup
- **Issue:** After creating real files in `lib/core/errors/`, the Plan 01
  `.gitkeep` was redundant and would clutter the tree.
- **Fix:** `git rm` the `.gitkeep`.
- **Files modified:** `lib/core/errors/.gitkeep` (deleted)
- **Committed in:** `4cc7f64`

**4. [Rule 3 — Blocking] Staged three Plan 02 test files needed for verification**
- **Found during:** Task 4.3 (running full `flutter test` suite)
- **Issue:** Plan 02 (Drift, `feat(01-02): add AppDatabase...`, committed as
  `307673b`) landed the AppDatabase library but its associated tests
  (`test/core/db/app_database_open_test.dart`, `test/core/db/migration_test.dart`,
  `test/helpers/test_database.dart`) were left untracked in the working tree.
  These files also had two trivial style lints (`unused_import`,
  `prefer_single_quotes`) which had already been auto-fixed on disk by a
  Plan 02 continuation. Leaving them untracked (or with the lint issues) would
  block the plan-wide `flutter analyze --fatal-infos` success criterion.
- **Fix:** Included these three test files in the Task 4.3 commit
  (`3341081`) so the full analyzer + test suite passes. Style lints were
  already fixed in the working tree; committed as-is.
- **Files affected:**
  - `test/core/db/app_database_open_test.dart`
  - `test/core/db/migration_test.dart`
  - `test/helpers/test_database.dart`
- **Verification:** `flutter analyze --fatal-infos` clean; all 14 tests pass.
- **Committed in:** `3341081`
- **Note:** These files nominally belong to Plan 02's scope. Recommend Plan 02's
  final SUMMARY (or a followup) acknowledge them.

---

**Total deviations:** 4 auto-fixed (all Rule 3 — Blocking / verification unblocking)
**Impact on plan:** No scope creep. Every deviation was needed to satisfy the
plan's own `flutter analyze --fatal-infos` + `flutter test` success criterion
under `very_good_analysis` strictness. The plan-provided snippets were slightly
out of sync with the actual lint profile; changes are semantically equivalent.

## Issues Encountered

- **Widget smoke test appeared broken at start of execution.** On my first
  `flutter test test/widget_test.dart` run the test hit `pumpAndSettle timed
  out` because Plan 03's `SplashScreen` now reads `SharedPreferencesAsync`.
  Investigation confirmed the failure predated my Plan 04 edits (reproduced by
  checking out the pre-Plan-04 `main.dart`). Plan 03's completion commit
  (`0dc3eae test(01-03): widget tests prove splash -> onboarding -> home flow`)
  had already updated `test/widget_test.dart` to install an
  `InMemorySharedPreferencesAsync` platform instance before pumping — the
  filesystem picked up that change while I was mid-execution and the retry
  passed. No action needed from Plan 04.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- `AppLogger`, `DomainError`, and `Result<T>` are the foundations every
  Phase 2+ layer will lean on when reporting failures. Repositories in
  Phase 5 (OSM download) should return `Result<...>` for expected failures
  (offline, 404); unexpected throwables should be wrapped at the boundary.
- `FlutterError.onError` and `PlatformDispatcher.instance.onError` are wired.
  If Phase 10 (diagnostics screen) wants to surface recent errors, add a
  `LogRecord` listener to `Logger.root` that buffers into a ring in memory —
  do NOT introduce a remote crash sink (locked decision).
- No blockers introduced. The temporary `custom_lint` / `riverpod_lint` gap
  from Plan 01 remains — this plan hand-wrote no providers, so no impact.

---
*Phase: 01-scaffolding*
*Plan: 04-error-logging-infra*
*Completed: 2026-07-03*
