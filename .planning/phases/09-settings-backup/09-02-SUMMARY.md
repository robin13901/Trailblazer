---
phase: 09-settings-backup
plan: "02"
subsystem: settings
tags: [flutter, dart, file_picker, share_plus, platform_channel, fake, ios, plist]

# Dependency graph
requires:
  - phase: 09-01
    provides: "BackupService interface + DriftBackupService; file_picker + share_plus in pubspec"
provides:
  - "FilePlatform abstract interface (pickBackupFile / shareFile)"
  - "FilePickerPlatformAdapter: sole importer of file_picker + share_plus"
  - "filePlatformProvider: plain Provider<FilePlatform>"
  - "FakeFilePlatform: channel-free test double"
  - "iOS Info.plist LSSupportsOpeningDocumentsInPlace for .trailblazer document picking"
affects:
  - "09-05 (DataBackupSection widget tests use FakeFilePlatform)"
  - "Any future plan implementing backup/restore UI"

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "FilePlatform interface isolates all platform-channel code to one adapter file (mirrors BackgroundGeolocationFacade)"
    - "FakeFilePlatform test double with configurable pickResult + shareSucceeds + sharedPaths list"

key-files:
  created:
    - lib/features/settings/data/file_platform.dart
    - lib/features/settings/data/file_picker_platform_adapter.dart
    - lib/features/settings/data/file_platform_provider.dart
    - test/features/settings/fakes/fake_file_platform.dart
  modified:
    - ios/Runner/Info.plist

key-decisions:
  - "file_picker 11.x uses FilePicker.pickFiles() static method, NOT FilePicker.platform.pickFiles() (API change from earlier versions)"
  - "share_plus 12.0.2 (installed) uses SharePlus.instance.share(ShareParams(files:[XFile(...)])) — same as 13.x API"
  - "LSSupportsOpeningDocumentsInPlace chosen over UISupportsDocumentBrowser: less UI-invasive, no forced documents-browser root"
  - "Open Question #2 (file_picker iOS plist requirement) resolved: LSSupportsOpeningDocumentsInPlace added, was NOT already present"

patterns-established:
  - "FilePlatform seam: all file_picker + share_plus imports confined to file_picker_platform_adapter.dart; UI code depends only on FilePlatform interface"

# Metrics
duration: 15min
completed: 2026-07-13
---

# Phase 9 Plan 02: FilePlatform Interface + Adapter Summary

**`FilePlatform` abstract interface isolating `file_picker` + `share_plus` platform channels behind a testable seam, with `FilePickerPlatformAdapter` (prod) and `FakeFilePlatform` (tests), plus iOS `LSSupportsOpeningDocumentsInPlace` for `.trailblazer` document picking.**

## Performance

- **Duration:** ~15 min
- **Started:** 2026-07-13T00:00:00Z
- **Completed:** 2026-07-13
- **Tasks:** 3
- **Files modified:** 5

## Accomplishments

- Defined `FilePlatform` abstract interface with `pickBackupFile()` and `shareFile()` — zero platform imports
- Implemented `FilePickerPlatformAdapter` as the single file importing `file_picker` and `share_plus` directly; adapts file_picker 11.x static API and share_plus 12.0.2 `SharePlus.instance` API
- Created `FakeFilePlatform` with `pickResult`, `shareSucceeds`, and `sharedPaths` list for assertion-friendly widget tests in Plan 09-05
- Added `LSSupportsOpeningDocumentsInPlace: true` to iOS `Info.plist`, resolving Open Question #2

## Task Commits

Each task was committed atomically:

1. **Task 1: FilePlatform interface + prod adapter + provider** - `27047e2` (feat)
2. **Task 2: FakeFilePlatform test double** - `c6d5cf4` (feat)
3. **Task 3: iOS Info.plist — document picker support** - `e440915` (feat)

## Files Created/Modified

- `lib/features/settings/data/file_platform.dart` — abstract interface `FilePlatform` (2 methods)
- `lib/features/settings/data/file_picker_platform_adapter.dart` — prod adapter wrapping file_picker 11.x + share_plus 12.x
- `lib/features/settings/data/file_platform_provider.dart` — `filePlatformProvider = Provider<FilePlatform>`
- `test/features/settings/fakes/fake_file_platform.dart` — `FakeFilePlatform` implements `FilePlatform`; configurable pick/share outcome
- `ios/Runner/Info.plist` — added `LSSupportsOpeningDocumentsInPlace: true`

## Decisions Made

- **file_picker 11.x API:** Uses `FilePicker.pickFiles()` static method, NOT `FilePicker.platform.pickFiles()`. The plan sketch used the older `FilePicker.platform` accessor which no longer exists in 11.x. Caught by analyzer (Rule 3 auto-fix).
- **share_plus 12.0.2 API:** `SharePlus.instance.share(ShareParams(files:[XFile(...)]))` confirmed from local pub cache — identical to the 13.x API shape referenced in the plan. No deviation.
- **LSSupportsOpeningDocumentsInPlace chosen over UISupportsDocumentBrowser:** Less UI-invasive (no forced document browser root). Open Question #2 resolved: neither key was present in the plist before this plan.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] file_picker 11.x API: static FilePicker.pickFiles(), not FilePicker.platform.pickFiles()**

- **Found during:** Task 1 (flutter analyze after initial write)
- **Issue:** Plan action said `FilePicker.platform.pickFiles(...)`. In file_picker 11.x, `FilePicker` is `abstract final class` with a static `pickFiles()` method delegating to `FilePickerPlatform.instance`. There is no `platform` getter.
- **Fix:** Changed `FilePicker.platform.pickFiles(...)` to `FilePicker.pickFiles(...)` in adapter.
- **Files modified:** `lib/features/settings/data/file_picker_platform_adapter.dart`
- **Verification:** `flutter analyze` clean
- **Committed in:** `27047e2` (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (1 blocking API mismatch)
**Impact on plan:** Essential correction for compilation; no scope change.

## Issues Encountered

- `comment_references` lint from `very_good_analysis` flagged `[FakeFilePlatform]` and `[BackgroundGeolocationFacade]` in doc comments of the new files (these types aren't imported in those files). Resolved by switching cross-file type references to backtick notation in doc comments.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- `FilePlatform` interface ready for Plan 09-05 (`DataBackupSection` widget) to depend on
- `FakeFilePlatform` ready for Plan 09-05 widget tests via `ProviderScope.overrides`
- iOS document picker enabled — `.trailblazer` file selection will work on device
- No blockers for downstream plans

---
*Phase: 09-settings-backup*
*Completed: 2026-07-13*
