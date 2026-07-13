---
phase: 09-settings-backup
plan: 03
subsystem: settings
tags: [shared-preferences, retention, persistence, prefs, sweep, flutter, riverpod]

# Dependency graph
requires:
  - phase: 05-trip-matching
    provides: sweepRawGpsRetention in TripsRepository (MMT-10 cleanup hook)
  - phase: 01-scaffolding
    provides: AppPrefs class + appPrefsProvider, InMemorySharedPreferencesAsync test pattern

provides:
  - kRawGpsRetentionDays key + getRawGpsRetentionDays / setRawGpsRetentionDays in AppPrefs
  - kShowDiagnosticsHud key + getShowDiagnosticsHud / setShowDiagnosticsHud in AppPrefs (for Plans 09-06/07)
  - RawGpsRetentionSection widget with 4-option picker and purge-now confirm dialog
  - Resume-lifecycle sweep reads persisted window instead of hardcoded 30 days
  - "forever" path: skips sweep entirely

affects:
  - 09-06 (HUD toggle): consumes kShowDiagnosticsHud getters directly, no app_prefs edit needed
  - 09-07 (HUD overlay): same as 09-06
  - future phases reading retention setting

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "-1 sentinel in SharedPreferences for nullable int (absent→default, -1→null/forever)"
    - "RadioGroup (Flutter 3.44+) replaces deprecated RadioListTile groupValue/onChanged"
    - "Optimistic UI update + revert-on-cancel for settings dialogs"

key-files:
  created:
    - lib/features/settings/presentation/widgets/raw_gps_retention_section.dart
    - test/core/prefs/app_prefs_test.dart
    - test/features/trips/data/trips_repository_retention_test.dart
  modified:
    - lib/core/prefs/app_prefs.dart
    - lib/app.dart

key-decisions:
  - "Sentinel -1 for forever: distinct from absent (→30 default) and explicit 0/30/365"
  - "app_prefs.dart sole owner: both SET-05 retention and SET-06 HUD toggle added in 09-03 to prevent Phase 9 parallel-wave collision"
  - "setShowDiagnosticsHud uses named param {required bool show} to satisfy avoid_positional_boolean_parameters lint"
  - "RadioGroup used instead of RadioListTile.groupValue/onChanged (deprecated in Flutter 3.44)"

patterns-established:
  - "Sentinel-int pattern for nullable int prefs: key absent=default, key=-1=null/forever"
  - "Retention section widget: optimistic setState + revert-on-cancel without double-setState"

# Metrics
duration: 9min
completed: 2026-07-13
---

# Phase 9 Plan 03: Raw-GPS Retention (SET-05) Summary

**Persisted 0/30/365/forever retention window wired end-to-end: AppPrefs keys, resume sweep caller, 4-option picker widget with purge-now confirm, and 16 unit tests.**

## Performance

- **Duration:** 9 min
- **Started:** 2026-07-13T12:55:00Z
- **Completed:** 2026-07-13T13:04:00Z
- **Tasks:** 4/4
- **Files modified:** 5 (2 new lib, 3 new test)

## Accomplishments

- AppPrefs gains `kRawGpsRetentionDays` (sentinel-int, -1=forever) + `kShowDiagnosticsHud` toggle — sole-owner pattern prevents Phase 9 collision on Plans 09-06/07
- Resume lifecycle sweep in `app.dart` now reads the persisted window via `_runRetentionSweepIfNeeded()`; null→skip, days≥0→sweep with `Duration(days: days)`
- `RawGpsRetentionSection` widget: 4 RadioGroup options, shortening triggers confirm dialog, confirm purges via `sweepRawGpsRetention` and shows SnackBar with deleted-trip count
- 16 tests green: 9 AppPrefs round-trip/default/sentinel cases + 7 repository Duration.zero and Duration(days:30) sweep sentinel cases

## Task Commits

1. **Task 1: AppPrefs — retention key + HUD-toggle key** — `cd8ca68` (feat)
2. **Task 2: Thread persisted window into sweep call site** — `7397650` (feat)
3. **Task 3: Retention section widget + purge-now confirm** — `7340893` (feat)
4. **Task 4: Tests — AppPrefs round-trip + sweep sentinels** — `1b379de` (test)

## Files Created/Modified

- `lib/core/prefs/app_prefs.dart` — Added `kRawGpsRetentionDays` + `kShowDiagnosticsHud` keys with getters/setters; sole-owner for all of Phase 9
- `lib/app.dart` — Replaced hardcoded `sweepRawGpsRetention()` call with `_runRetentionSweepIfNeeded()` that reads AppPrefs; forever skips sweep
- `lib/features/settings/presentation/widgets/raw_gps_retention_section.dart` — NEW: 4-option picker widget, confirm dialog on shortening, purge + SnackBar feedback
- `test/core/prefs/app_prefs_test.dart` — NEW: 9 cases for retention defaults, sentinel round-trips, HUD toggle
- `test/features/trips/data/trips_repository_retention_test.dart` — NEW: 7 cases for 30d sentinel, Duration.zero day-0, Ok(count) return, unmatched-trip safety

## Decisions Made

**-1 sentinel for "forever":** Storing -1 in the integer key lets `getRawGpsRetentionDays` distinguish three states — key absent (→30 default), key=0/30/365 (explicit), key=-1 (forever/null). The research's remove-key approach collapses "unset" and "forever" into the same read path.

**app_prefs.dart sole-owner:** Both SET-05 retention and SET-06 HUD toggle keys added here in 09-03 so Plans 09-06 and 09-07 can consume the getters without a merge collision. Matches the file-ownership manifest note in the plan frontmatter.

**RadioGroup instead of RadioListTile.groupValue/onChanged:** Flutter 3.44 deprecates the old imperative radio API. `RadioGroup<int?>` wrapping `RadioListTile<int?>` without value/onChange is the replacement pattern.

**Named bool parameter:** `setShowDiagnosticsHud({required bool show})` avoids the `avoid_positional_boolean_parameters` lint.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 — Missing Critical] RadioListTile deprecated API**

- **Found during:** Task 3 (flutter analyze)
- **Issue:** `groupValue` and `onChanged` on `RadioListTile` are deprecated in Flutter 3.44; `subtitleTextStyle` parameter doesn't exist
- **Fix:** Switched to `RadioGroup<int?>` wrapping `RadioListTile<int?>` (the replacement pattern)
- **Files modified:** `lib/features/settings/presentation/widgets/raw_gps_retention_section.dart`
- **Committed in:** `7340893`

**2. [Rule 2 — Missing Critical] `avoid_positional_boolean_parameters` lint on `setShowDiagnosticsHud`**

- **Found during:** Task 1 (flutter analyze)
- **Issue:** `setShowDiagnosticsHud(bool show)` violates very_good_analysis positional-bool rule
- **Fix:** Changed signature to `setShowDiagnosticsHud({required bool show})`
- **Files modified:** `lib/core/prefs/app_prefs.dart`
- **Committed in:** `cd8ca68`

**3. [Rule 1 — Bug] `avoid_redundant_argument_values` in test file**

- **Found during:** Task 4 (full flutter analyze)
- **Issue:** `retention: const Duration(days: 30)` is the repository default, so passing it explicitly triggers the lint; `count: 3` is seedPoints default
- **Fix:** Removed explicit `retention:` args from tests using 30d default; removed `count: 3` where default suffices
- **Files modified:** `test/features/trips/data/trips_repository_retention_test.dart`
- **Committed in:** `1b379de`
