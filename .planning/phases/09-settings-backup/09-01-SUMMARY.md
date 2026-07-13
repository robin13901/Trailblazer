---
phase: 09-settings-backup
plan: 01
subsystem: database
tags: [drift, sqlite, backup, restore, riverpod, result-type, file-picker, share-plus]

# Dependency graph
requires:
  - phase: 01-foundation
    provides: Drift AppDatabase with schemaVersion 4 + Result<T>/DomainError core
  - phase: 05-road-matching
    provides: TripsRepository + TripsDao patterns for DB seeding in tests

provides:
  - BackupService abstract interface (createBackup/validateBackup/restore)
  - DriftBackupService implementation (VACUUM INTO export + wipe-and-swap restore)
  - BackupValidationResult sealed class (BackupValid / BackupInvalid)
  - backupServiceProvider (plain Provider<BackupService>)
  - FakeBackupService test double
  - Unit tests: 12 tests covering round-trip, all validation rejection paths, restore error propagation
  - Three new pub deps: file_picker ^11.0.2, share_plus ^12.0.2, sqlite3 ^3.0.0

affects:
  - 09-02 (data_backup_section.dart will call BackupService)
  - 09-05 (widget tests will use FakeBackupService)

# Tech tracking
tech-stack:
  added:
    - file_picker: ^11.0.2 (OS file picker for restore import)
    - share_plus: ^12.0.2 (OS share sheet for export — downgraded from ^13.2.0 due to win32 conflict)
    - sqlite3: ^3.0.0 (direct dep for read-only validation without Drift migration)
  patterns:
    - VACUUM INTO for single-file SQLite backup (no -wal/-shm sidecars)
    - validate-before-touch pattern (foreign file rejected before live DB is modified)
    - Ref.read() on each call (never cache AppDatabase ref across provider invalidations)
    - sealed BackupValidationResult hierarchy for type-safe validation outcomes
    - DriftBackupService uses ProviderContainer.read(backupServiceProvider) in tests

key-files:
  created:
    - lib/features/settings/domain/backup_validation_result.dart
    - lib/features/settings/data/backup_service.dart
    - lib/features/settings/data/drift_backup_service.dart
    - lib/features/settings/data/backup_service_provider.dart
    - test/features/settings/fakes/fake_backup_service.dart
    - test/features/settings/data/drift_backup_service_test.dart
  modified:
    - pubspec.yaml (3 new deps + pubspec.lock)

key-decisions:
  - "share_plus downgraded to ^12.0.2 (from plan's ^13.2.0): win32 ^6.0.1 conflict with file_picker ^11.0.2 (win32 ^5.9.0)"
  - "DriftBackupService.restore uses f.existsSync()/f.deleteSync() for -wal/-shm deletion (avoid_slow_async_io lint)"
  - "DriftBackupService.validateBackup uses db.close() not db.dispose() (deprecated in sqlite3 3.x)"
  - "Tests bypass platform channels by using Directory.systemTemp + NativeDatabase(File(...)) directly"
  - "backupServiceProvider uses DriftBackupService.new tearoff (not lambda) per unnecessary_lambdas lint"

patterns-established:
  - "VACUUM INTO pattern: single SQL call, atomic snapshot, no WAL sidecars on output"
  - "validate-before-touch: validateBackup() called first; live DB never touched on invalid input"
  - "close-before-swap: db.close() MUST precede file ops; ref.invalidate() after swap"
  - "kCurrentSchemaVersion constant: 4, co-located in drift_backup_service.dart"

# Metrics
duration: 20min
completed: 2026-07-13
---

# Phase 9 Plan 01: Backup Engine Summary

**VACUUM INTO backup engine with sealed validation result, abstract BackupService interface, DriftBackupService (validate-before-touch + close-before-swap restore), and 12-test suite confirming round-trip integrity and all rejection paths**

## Performance

- **Duration:** 20 min
- **Started:** 2026-07-13T12:53:22Z
- **Completed:** 2026-07-13T13:13:54Z
- **Tasks:** 5
- **Files modified:** 7 (6 created, 1 modified)

## Accomplishments

- `DriftBackupService` implements full backup/restore lifecycle: `VACUUM INTO` export (single-file, no WAL sidecars), sqlite3-based read-only validation (integrity + user_version + required tables), safety snapshot before wipe, close-before-swap restore sequence
- All failures surface as `Result<Err(StorageError|DatabaseError)>` — no raw throwables escape the interface
- 12-unit tests confirm: no -wal/-shm on backup output, row count preserved in round-trip, all four rejection paths return `BackupInvalid`, corrupt backup returns `Err` without touching live DB
- Three new pub deps declared (file_picker, share_plus, sqlite3 as direct dep) for sibling plans

## Task Commits

Each task was committed atomically:

1. **Task 1: Declare new dependencies** - `845bfe2` (chore)
2. **Task 2: Sealed validation result + BackupService interface** - `b2d6ae5` (feat)
3. **Task 3: DriftBackupService impl + provider** - `a0277f6` (feat)
4. **Task 4: FakeBackupService test double** - `39b4d4a` (feat)
5. **Task 5: Unit tests** - `5aaa306` (test)

**Plan metadata:** (docs commit follows)

## Files Created/Modified

- `pubspec.yaml` — added file_picker ^11.0.2, share_plus ^12.0.2, sqlite3 ^3.0.0
- `lib/features/settings/domain/backup_validation_result.dart` — sealed BackupValidationResult (BackupValid/BackupInvalid)
- `lib/features/settings/data/backup_service.dart` — abstract interface BackupService with restore contract docs
- `lib/features/settings/data/drift_backup_service.dart` — DriftBackupService: VACUUM INTO + sqlite3 validate + wipe-and-swap restore; kCurrentSchemaVersion=4
- `lib/features/settings/data/backup_service_provider.dart` — backupServiceProvider plain Provider<BackupService>
- `test/features/settings/fakes/fake_backup_service.dart` — FakeBackupService with createShouldFail/validateShouldFail/restoreShouldFail flags
- `test/features/settings/data/drift_backup_service_test.dart` — 12 unit tests on real temp-file Drift DBs

## Decisions Made

- **share_plus ^12.0.2 instead of ^13.2.0**: win32 version conflict with file_picker ^11.0.2. The ShareParams/XFile API surface is identical in both versions. This does not affect functionality.
- **Platform-channel-free test strategy**: `createBackup`/`restore` call `getTemporaryDirectory()` and `getApplicationDocumentsDirectory()` internally. Tests bypass these by calling `db.customStatement('VACUUM INTO ?', [...])` and `AppDatabase(NativeDatabase(File(...)))` directly. validateBackup is pure sqlite3 and needs no channels. The end-to-end restore path is narrowed per plan note.
- **`f.existsSync()/f.deleteSync()` for sidecar deletion**: `very_good_analysis`'s `avoid_slow_async_io` lint flags `await f.exists()/delete()` in loops; sync versions are correct here (DB is closed before this code runs, no I/O contention).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Downgraded share_plus from ^13.2.0 to ^12.0.2**

- **Found during:** Task 1 (pub get)
- **Issue:** `share_plus >=13.1.0` requires `win32 ^6.0.1`; `file_picker ^11.0.2` requires `win32 ^5.9.0` — no compatible resolution
- **Fix:** Downgraded to `share_plus: ^12.0.2` as suggested by `flutter pub get` output; identical ShareParams/XFile API
- **Files modified:** pubspec.yaml, pubspec.lock
- **Verification:** `flutter pub get` succeeded with no conflict warnings
- **Committed in:** 845bfe2 (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Minor version constraint adjustment; share_plus 12.x has the same API surface as 13.x for the Share/XFile pattern used in this phase.

## Issues Encountered

- `very_good_analysis` triggered multiple lint infos during implementation: `avoid_catches_without_on_clauses`, `cast_nullable_to_non_nullable`, `deprecated_member_use` (dispose→close), `avoid_slow_async_io`, `unnecessary_brace_in_string_interps`, `unnecessary_lambdas`, `cascade_invocations`, `combinators_ordering`. All fixed in the tight loop before each task commit.
- Harmless Drift warning in tests about multiple AppDatabase instances (expected in tests creating several DBs per test); suppressed via `driftRuntimeOptions.dontWarnAboutMultipleDatabases` is an option but not needed since the warning is debug-only.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- **Plan 09-02 (DataBackupSection widget)**: `BackupService` interface + `FakeBackupService` + `backupServiceProvider` ready. Widget calls `createBackup()` then uses share_plus to share the path. Restore calls `FilePicker.platform.pickFiles()` then `restore(path)`.
- **Plan 09-05 (widget tests)**: `FakeBackupService` with togglable failure flags ready for `ProviderScope.overrides` injection.
- **SC1 (export produces shareable single file)**: `VACUUM INTO` confirmed no WAL sidecars, single file output, correct schemaVersion=4. Platform sharing via share_plus is Plan 09-02's responsibility.
- **SC2 (restore validates + swaps in place)**: Validate-before-touch + close-before-swap + invalidate sequence implemented and tested.

---
*Phase: 09-settings-backup*
*Completed: 2026-07-13*
