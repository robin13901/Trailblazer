---
phase: 09-settings-backup
plan: 05
subsystem: ui
tags: [flutter, riverpod, widget, backup, restore, share-sheet, file-picker, result]

# Dependency graph
requires:
  - phase: 09-01
    provides: BackupService interface + DriftBackupService + FakeBackupService + backupServiceProvider
  - phase: 09-02
    provides: FilePlatform interface + FilePickerPlatformAdapter + FakeFilePlatform + filePlatformProvider
provides:
  - DataBackupSection widget (Export + Restore tiles) wiring BackupService + FilePlatform
  - Widget tests covering all five user-facing flow paths via Fakes
affects: [09-07-settings-screen (mounts DataBackupSection)]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "ScaffoldMessenger captured before awaits to guard against context invalidation"
    - "mounted guard on every setState after await"
    - "Result<T> sealed switch destructuring (Ok(:final value) / Err(:final error))"
    - "Destructive AlertDialog with FilledButton.styleFrom(colorScheme.error)"
    - "ProviderScope.overrideWithValue with Fakes in widget tests"

key-files:
  created:
    - lib/features/settings/presentation/widgets/data_backup_section.dart
    - test/features/settings/presentation/data_backup_section_test.dart
  modified: []

key-decisions:
  - "Inline restoring progress via _restoring bool + spinner in trailing (no separate dialog) — keeps layout stable and avoids nested dialog stacking issues"
  - "Both export and restore tiles disabled while either operation is in flight (cross-lock) — prevents double-tap / concurrent ops"
  - "error.message surfaced directly in SnackBar — BackupService contract guarantees DomainError.message is user-facing"

patterns-established:
  - "DataManagementSection pattern: capture ScaffoldMessenger.of(context) before async gap, check mounted after every await"

# Metrics
duration: 3min
completed: 2026-07-13
---

# Phase 9 Plan 05: DataBackupSection Summary

**ConsumerStatefulWidget with Export (createBackup → OS share sheet) and Restore (pickBackupFile → destructive confirm → progress → restore → provider rebuild) flows, backed by 5 widget tests over FakeBackupService + FakeFilePlatform**

## Performance

- **Duration:** ~3 min
- **Started:** 2026-07-13T13:30:36Z
- **Completed:** 2026-07-13T13:33:06Z
- **Tasks:** 2
- **Files modified:** 2 (both new)

## Accomplishments
- `DataBackupSection` widget with Export + Restore tiles, full async-safety (mounted guards, pre-await messenger capture)
- Destructive restore confirm dialog using `colorScheme.error`-styled FilledButton
- Result/Ok/Err sealed switch destructuring matching project-wide pattern
- 5/5 widget tests green over in-memory Fakes — no platform channels touched

## Task Commits

1. **Task 1: DataBackupSection — Export + Restore flows** - `2d72e94` (feat)
2. **Task 2: Widget tests (export, restore-confirm, invalid-restore)** - `a6c149a` (test)

**Plan metadata:** (docs commit to follow)

## Files Created/Modified
- `lib/features/settings/presentation/widgets/data_backup_section.dart` — ConsumerStatefulWidget; export + restore flows
- `test/features/settings/presentation/data_backup_section_test.dart` — 5-case widget test suite

## Decisions Made
- **Inline spinner (not blocking dialog) for restoring state** — The `_restoring = true` flag disables both tiles and shows a spinner in the restore tile trailing; no separate "Restoring…" progress dialog was used. This keeps the layout stable, avoids nested-dialog complications, and matches the `_refreshing` pattern in `DataManagementSection`.
- **Cross-lock both tiles during either operation** — `onTap` set to `null` when `_exporting || _restoring` to prevent concurrent backup/restore.
- **`error.message` in SnackBar directly** — `DomainError.message` is the user-facing reason per the project contract; no extra wrapping needed.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Added `backup_service.dart` + `file_platform.dart` imports for doc-comment references**
- **Found during:** Task 1 (flutter analyze after initial write)
- **Issue:** `very_good_analysis` `comment_references` lint flagged `BackupService` and `FilePlatform` mentioned in the class-level doc comment as not visible in scope (exit code 1)
- **Fix:** Added imports for `backup_service.dart` and `file_platform.dart` alongside the existing provider imports
- **Files modified:** `lib/features/settings/presentation/widgets/data_backup_section.dart`
- **Verification:** `flutter analyze` clean (No issues found)
- **Committed in:** `2d72e94` (Task 1 commit)

**2. [Rule 3 - Blocking] Fixed relative import path in test file**
- **Found during:** Task 2 (first `flutter test` run)
- **Issue:** Import path `../../fakes/` was wrong; test is in `test/features/settings/presentation/` so fakes are one level up, not two
- **Fix:** Changed `../../fakes/` to `../fakes/`
- **Files modified:** `test/features/settings/presentation/data_backup_section_test.dart`
- **Verification:** `flutter test` 5/5 green
- **Committed in:** `a6c149a` (Task 2 commit)

---

**Total deviations:** 2 auto-fixed (both Rule 3 — blocking analyzer/compiler issues)
**Impact on plan:** Minor path corrections only; no scope change.

## Issues Encountered
None beyond the two auto-fixed blocking issues above.

## Deferred On-Device Checklist

These genuinely need a real device (share sheet + SAF/UIActivityViewController + file picker are platform-channel UI):

- [ ] Export produces a .trailblazer file and the iOS share sheet / Android ACTION_SEND offers iCloud Drive / Drive / Files.
- [ ] Restore picks that file back via the OS picker and the app shows restored trips/coverage after rebuild.
- [ ] Round-trip on a real device: export, wipe (or fresh install), restore, verify trips + coverage return.
- [ ] iOS document picker shows .trailblazer files (Info.plist doc-in-place from 09-02).

## Next Phase Readiness
- `DataBackupSection` is ready to be mounted in the settings screen by Plan 09-07
- No blockers; widget owns its own providers via overrides in tests

---
*Phase: 09-settings-backup*
*Completed: 2026-07-13*
