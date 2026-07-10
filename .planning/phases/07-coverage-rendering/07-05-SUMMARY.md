---
phase: 07-coverage-rendering
plan: 05
subsystem: ui
tags: [flutter, riverpod, shared-preferences, settings, coverage, color-picker]

# Dependency graph
requires:
  - phase: 07-01
    provides: CoverageColorPreset enum + forBrightness + label + fromString
  - phase: 01-03
    provides: AppPrefs SharedPreferencesAsync pattern
provides:
  - AppPrefs.getCoveragePreset() / setCoveragePreset() persistence
  - coveragePresetProvider (AsyncNotifierProvider, amber default)
  - coveragePresetValueProvider (sync convenience with amber fallback)
  - CoverageColorSection widget (5 swatches, pick-then-confirm)
  - Settings screen Coverage section wired between Data and Coming later
affects:
  - 07-06 (bridge reads coveragePresetValueProvider to recolor map)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "AsyncNotifier (plain, no codegen) hydrating from AppPrefs.getCoveragePreset()"
    - "_hexToColor('#RRGGBB') helper — Color(int.parse('FF$clean', radix: 16))"
    - "withValues(alpha:) for translucency on swatch border"
    - "44dp SizedBox tap target wrapping 36dp circle swatch"
    - "Semantics(label:, selected:) on each swatch for accessibility"
    - "ProviderScope.containerOf(element) in widget tests to verify notifier state"

key-files:
  created:
    - lib/features/coverage/presentation/coverage_preset_provider.dart
    - lib/features/settings/presentation/widgets/coverage_color_section.dart
    - test/features/coverage/presentation/coverage_preset_provider_test.dart
    - test/features/settings/coverage_color_section_test.dart
  modified:
    - lib/core/prefs/app_prefs.dart
    - lib/features/settings/presentation/settings_screen.dart

key-decisions:
  - "AsyncValue.value (nullable getter) used instead of .valueOrNull — the latter does not exist in flutter_riverpod 3.3.2"
  - "List<Object> + .cast() for ProviderScope overrides in tests, matching existing data_management_section_test.dart pattern"

patterns-established:
  - "coveragePresetValueProvider: sync Provider<T> watching async provider .value — reuse pattern for 07-06 bridge"

# Metrics
duration: 35min
completed: 2026-07-10
---

# Phase 7 Plan 05: Settings Picker Summary

**Coverage color picker persisted via AppPrefs + AsyncNotifier; Settings screen shows 5 amber-default swatches with pick-then-confirm and accessibility semantics**

## Performance

- **Duration:** ~35 min
- **Started:** 2026-07-10T08:00:00Z
- **Completed:** 2026-07-10T08:35:00Z
- **Tasks:** 3/3
- **Files modified:** 6 (2 modified, 4 created)

## Accomplishments
- `AppPrefs` extended with `getCoveragePreset()` / `setCoveragePreset()` backed by SharedPreferencesAsync
- `CoveragePresetNotifier` (plain `AsyncNotifier`, no codegen) hydrates from AppPrefs; `select()` persists + sets `AsyncData` immediately
- `coveragePresetValueProvider` provides synchronous amber-fallback for map bridge (07-06) and UI
- `CoverageColorSection` widget: 5 tappable 36dp circle swatches, 44dp tap targets, check-icon + border selection indicator, `withValues(alpha:)` translucency
- Settings screen wired: Coverage section between Data and Coming later
- 9 new tests: 5 unit (provider) + 4 widget — all green; `flutter analyze` clean

## Task Commits

1. **Task 1: Persist coverage preset in AppPrefs** - `60f70ca` (feat)
2. **Task 2: coveragePresetProvider (NotifierProvider, no codegen)** - `caae2be` (feat)
3. **Task 3: CoverageColorSection swatches + wire into Settings** - `c5b26b7` (feat)

**Plan metadata:** (docs commit follows)

## Files Created/Modified
- `lib/core/prefs/app_prefs.dart` - Added `kCoveragePreset`, `getCoveragePreset()`, `setCoveragePreset()`
- `lib/features/coverage/presentation/coverage_preset_provider.dart` - New: `CoveragePresetNotifier`, `coveragePresetProvider`, `coveragePresetValueProvider`
- `lib/features/settings/presentation/widgets/coverage_color_section.dart` - New: 5-swatch picker ConsumerWidget
- `lib/features/settings/presentation/settings_screen.dart` - Coverage section wired in
- `test/features/coverage/presentation/coverage_preset_provider_test.dart` - New: 5 unit tests
- `test/features/settings/coverage_color_section_test.dart` - New: 4 widget tests

## Decisions Made
- `AsyncValue.value` (nullable getter) used instead of `.valueOrNull` — the latter is absent in `flutter_riverpod 3.3.2`; the linter auto-corrected this on first analyze.
- `List<Object>` with `.cast()` for `ProviderScope overrides` in tests — matched existing `data_management_section_test.dart` pattern (not `List<Override>`).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] `valueOrNull` does not exist in flutter_riverpod 3.3.2**
- **Found during:** Task 2 (coveragePresetProvider)
- **Issue:** Plan used `.valueOrNull` which does not exist on `AsyncValue` in Riverpod 3.3.2; analyzer reported undefined_getter
- **Fix:** Changed to `.value` (nullable `T?` getter available in Riverpod 3.3.2 on all `AsyncValue` states)
- **Files modified:** `lib/features/coverage/presentation/coverage_preset_provider.dart`
- **Verification:** `flutter analyze` clean
- **Committed in:** `caae2be` (Task 2 commit)

**2. [Rule 1 - Bug] `List<Override>` type not found in widget test**
- **Found during:** Task 3 (coverage_color_section_test.dart)
- **Issue:** `Override` is not a directly importable type via `flutter_riverpod` in this version; test failed to compile
- **Fix:** Changed to `List<Object>` + `.cast()` (matches existing test helper pattern in codebase)
- **Files modified:** `test/features/settings/coverage_color_section_test.dart`
- **Verification:** `flutter test` green
- **Committed in:** `c5b26b7` (Task 3 commit)

---

**Total deviations:** 2 auto-fixed (both Rule 1 - Bug)
**Impact on plan:** Both were minor API naming issues resolvable inline. No scope creep, plan intent fully preserved.

## Issues Encountered
- `very_good_analysis` flagged `_makeContainer` local variable (leading underscore not allowed for locals) and `width: 1` as redundant default for `Border.all`. Both fixed inline before commit.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- `coveragePresetValueProvider` is ready for 07-06 bridge to `watch` — no changes needed to provider API
- `CoveragePresetNotifier.select()` is stable and tested
- Settings screen Coverage section is live

---
*Phase: 07-coverage-rendering*
*Completed: 2026-07-10*
