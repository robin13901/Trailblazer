---
phase: 09-settings-backup
plan: 07
subsystem: ui
tags: [flutter, riverpod, settings, backup, permissions, diagnostics, go_router]

# Dependency graph
requires:
  - phase: 09-03
    provides: RawGpsRetentionSection + AppPrefs.getShowDiagnosticsHud/setShowDiagnosticsHud
  - phase: 09-04
    provides: PermissionsSection ConsumerStatefulWidget
  - phase: 09-05
    provides: DataBackupSection ConsumerStatefulWidget
  - phase: 09-06
    provides: DiagnosticsHUD overlay wired to AppPrefs toggle

provides:
  - Single grouped SettingsScreen with 5 sections (Data & Backup, Coverage, Permissions, Diagnostics, About)
  - AboutSection with app version (kAppVersion) + showLicensePage OSS entry + all credits
  - /settings/diagnostics route always registered (release-safe; un-gated from kDebugMode)
  - HUD toggle SwitchListTile in Diagnostics section; DiagnosticsTile visible when ON
  - settings_screen_test.dart: 12/12 integration tests green

affects: [phase-10, future-settings-expansion]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - ConsumerStatefulWidget for settings screen (needs ref + async toggle state)
    - initState + _loadHudPref() + setState pattern for async prefs read
    - if (_showHud) conditional child in ListView for toggle-gated tiles

key-files:
  created:
    - test/features/settings/presentation/settings_screen_test.dart
  modified:
    - lib/features/settings/presentation/settings_screen.dart
    - lib/features/settings/presentation/widgets/about_section.dart
    - lib/core/routing/app_router.dart

key-decisions:
  - "kAppVersion = '0.1.0' hardcoded as const in about_section.dart; no package_info_plus dep"
  - "HUD toggle state loaded via initState+unawaited+setState pattern (not FutureBuilder) for clean rebuild"
  - "DiagnosticsTile shown inline under if (_showHud) — no Navigator pop needed on toggle-off"
  - "/settings/diagnostics un-gated from kDebugMode; stress route stays debug-only"

patterns-established:
  - "showLicensePage(context, applicationName, applicationVersion) for OSS licenses — no extra dep"

# Metrics
duration: 11min
completed: 2026-07-13
---

# Phase 9 Plan 07: Settings Screen Assembly Summary

**Single grouped SettingsScreen assembles all Phase 9 sections — Data & Backup + Coverage + Permissions + Diagnostics (HUD toggle, release-safe) + About (version + OSS licenses + credits) — replacing the Phase 10 placeholder**

## Performance

- **Duration:** ~11 min
- **Started:** 2026-07-13T13:39:21Z
- **Completed:** 2026-07-13T13:50:20Z
- **Tasks:** 4
- **Files modified:** 4

## Accomplishments
- AboutSection gains app version text (`Version 0.1.0`) and `Open-source licenses` ListTile calling `showLicensePage()` — closes SET-09 gap
- SettingsScreen refactored to ConsumerStatefulWidget; 5 CONTEXT-ordered sections assembled; "Full settings arrive in Phase 10" placeholder removed
- `/settings/diagnostics` route un-gated from `kDebugMode` — reachable in release builds when HUD toggle is ON; `/settings/stress-coverage` stays debug-only
- 12/12 integration widget tests green: all section headers, placeholder absent, backup tiles, OSS license entry, HUD toggle + conditional tile

## Task Commits

1. **Task 1: Complete AboutSection** - `9bcf2e5` (feat)
2. **Task 2: Assemble grouped Settings screen** - `e2b9f8a` (feat)
3. **Task 3: Un-gate diagnostics route** - `a1d278b` (feat)
4. **Task 4: Settings screen widget test** - `97a51d4` (test)

## Files Created/Modified
- `lib/features/settings/presentation/widgets/about_section.dart` — added `kAppVersion`, version row, `Open-source licenses` ListTile; all MapTiler/OSM/MapLibre credits retained
- `lib/features/settings/presentation/settings_screen.dart` — converted to ConsumerStatefulWidget; 5 sections in CONTEXT order; HUD SwitchListTile + conditional DiagnosticsTile; StressCoverageTile remains debug-only; placeholder removed
- `lib/core/routing/app_router.dart` — `/settings/diagnostics` GoRoute moved outside `kDebugMode` block; stress route unchanged
- `test/features/settings/presentation/settings_screen_test.dart` — 12 integration widget tests using InMemorySharedPreferencesAsync + service fakes

## Decisions Made
- `kAppVersion = '0.1.0'` hardcoded as a const in `about_section.dart` — no `package_info_plus` dependency added; comment says to bump alongside pubspec
- HUD toggle state loaded via `initState + unawaited(_loadHudPref()) + setState` rather than FutureBuilder — consistent with sibling widgets in this phase; toggle defaults OFF before prefs load
- `DiagnosticsTile` placed inline under `if (_showHud)` in ListView — context.push('/settings/diagnostics') works because the route is always registered in the router
- `/settings/diagnostics` fully un-gated (not just moved): tree-shaking no longer removes the route or TrackingDiagnosticsScreen in release builds

## Deviations from Plan

None — plan executed exactly as written.

## Deferred On-Device Checklist

Batched with 09-05's device checklist for phase close-out / next drive:

- [ ] Diagnostics HUD reachable in a RELEASE build when the toggle is ON (tree-shaking removed the kDebugMode gate correctly).
- [ ] Permissions inspector re-reads after toggling a permission in system Settings and returning to the app.
- [ ] OSS license page renders the aggregated package licenses on-device.

## Issues Encountered
- `unnecessary_ignore` on `// ignore: constant_identifier_names` added to `kAppVersion` — the rule was not applicable; removed the comment and the issue was resolved. (Minor, 1 analyze iteration.)
- Import path for `FakePermissionService` in test was `../../../onboarding/fakes/` but should have been `../../onboarding/fakes/` — fixed on second analyze pass.

## Next Phase Readiness
- Phase 9 code-complete: all plans 09-01 through 09-07 done
- All sections reachable from the single Settings screen
- On-device verification checklist deferred to phase close-out drive (see deferred checklist above)
- Phase 10 (the final phase) can proceed

---
*Phase: 09-settings-backup*
*Completed: 2026-07-13*
