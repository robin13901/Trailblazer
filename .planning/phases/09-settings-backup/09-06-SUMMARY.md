---
phase: 09-settings-backup
plan: 06
subsystem: diagnostics
tags: [flutter, riverpod, overpass, drift, diagnostics, hud, release-mode]

# Dependency graph
requires:
  - phase: 09-03
    provides: kShowDiagnosticsHud AppPrefs getter/setter (consumed by HUD screen)
  - phase: 04-15
    provides: OverpassWayCandidateSource cache-first tile pipeline (extended with counters)
  - phase: 05-06
    provides: PendingRoadFetchesDao queue (matcher queue depth source)
provides:
  - OverpassWayCandidateSource.cacheHits/cacheMisses/cacheHitRate counters
  - DiagnosticsMetrics value type + readDiagnosticsMetrics function
  - HUD extended with Matcher/cache section (queue depth + cache hit rate)
  - kDebugMode gate removed from TrackingDiagnosticsScreen (usable in release)
affects:
  - 09-07 (serial tail: settings_screen + app_router toggle-gating that surfaces the HUD)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Per-instance in-memory counters on source objects (cacheHits/cacheMisses), incremented at the classification site in _collectFreshTiles"
    - "readDiagnosticsMetrics(WidgetRef) top-level async function pattern — matches HUD's existing _refreshAsync polling model, avoids Riverpod watch proliferation"
    - "is-check guard for fixture impls: src is OverpassWayCandidateSource ? src.cacheHits : 0"

key-files:
  created:
    - lib/features/settings/data/diagnostics_metrics_provider.dart
    - test/features/matching/data/overpass_cache_counter_test.dart
  modified:
    - lib/features/matching/data/overpass_way_candidate_source.dart
    - lib/features/settings/presentation/tracking_diagnostics_screen.dart

key-decisions:
  - "Cache counters are per-instance; main-isolate only — matcher isolate's OverpassWayCandidateSource copy is not surfaced (documented limitation)"
  - "cacheHitRate returns null (not 0.0) before first call to distinguish no-data from zero-hit-rate"
  - "readDiagnosticsMetrics is a plain async function (not a Provider) — matches the HUD's _refreshAsync polling idiom"
  - "_ReleaseModeShortCircuit class deleted entirely; kDebugMode guard removed from build()"

patterns-established:
  - "Source counters: lightweight in-memory fields incremented at the hit/miss decision point, O(1) per tile"
  - "HUD swallows readDiagnosticsMetrics exceptions to show — on early-startup DB unavailability"

# Metrics
duration: 5min
completed: 2026-07-13
---

# Phase 9 Plan 06: Diagnostics HUD Release Gate + Cache Metrics Summary

**Overpass tile cache hit/miss counters added to OverpassWayCandidateSource; HUD extended with Matcher/cache section (queue depth + hit rate); kDebugMode gate removed so screen renders in release builds**

## Performance

- **Duration:** 5 min
- **Started:** 2026-07-13T13:19:22Z
- **Completed:** 2026-07-13T13:25:14Z
- **Tasks:** 4
- **Files modified:** 4

## Accomplishments
- Added `_cacheHits`/`_cacheMisses` int fields + `cacheHits`, `cacheMisses`, `cacheHitRate` getters to `OverpassWayCandidateSource`; incremented at the tile hit/miss branch in `_collectFreshTiles`
- Created `DiagnosticsMetrics` value type + `readDiagnosticsMetrics(WidgetRef)` function reading queue depth from `PendingRoadFetchesDao` and cache counters from the source (guarded by `is OverpassWayCandidateSource` for fixture impls)
- Extended `TrackingDiagnosticsScreen` with a "Matcher / cache" section (queue depth, cacheHits, cacheMisses, hitRate as `N%` or `—`); removed `if (!kDebugMode) return _ReleaseModeShortCircuit()` gate; deleted now-unused `_ReleaseModeShortCircuit` class and `foundation.dart` import
- 4-scenario unit test suite proving: null rate on fresh instance; all-hit rate=1.0; all-miss rate=0.0; mixed hit+miss rate in (0,1)

## Task Commits

Each task was committed atomically:

1. **Task 1: OverpassWayCandidateSource cache hit/miss counters** - `97027dc` (feat)
2. **Task 2: diagnosticsMetricsProvider** - `1806a49` (feat)
3. **Task 3: Extend HUD + remove kDebugMode build guard** - `1976515` (feat)
4. **Task 4: Cache counter unit test** - `fed56ac` (test)

**Plan metadata:** (docs commit follows)

## Files Created/Modified
- `lib/features/matching/data/overpass_way_candidate_source.dart` - Added _cacheHits/_cacheMisses fields, public getters, cacheHitRate; incremented in _collectFreshTiles
- `lib/features/settings/data/diagnostics_metrics_provider.dart` - NEW: DiagnosticsMetrics DTO + readDiagnosticsMetrics(WidgetRef) function
- `lib/features/settings/presentation/tracking_diagnostics_screen.dart` - DiagnosticsMetrics? _metrics state; _refreshAsync calls readDiagnosticsMetrics; Matcher/cache section; kDebugMode gate + _ReleaseModeShortCircuit removed
- `test/features/matching/data/overpass_cache_counter_test.dart` - NEW: 4-scenario counter unit test

## Decisions Made
- **Counter scope:** Main-isolate only — the matcher isolate's `OverpassWayCandidateSource` copy runs in a separate Dart isolate with no shared memory, so its counters are not accessible from the UI. Documented in the source docstring as a known limitation.
- **null vs 0.0 before first call:** `cacheHitRate` returns `null` (not `0.0`) before any tile has been classified, so the HUD can display `—` rather than `0%`, which would falsely imply a zero hit rate.
- **readDiagnosticsMetrics as function not Provider:** Matches the HUD's existing `_refreshAsync` polling model; adding another `Provider<Future<DiagnosticsMetrics>>` would add a watch cycle with no benefit given the timer-driven refresh pattern.
- **Delete _ReleaseModeShortCircuit:** Class is now dead code with the gate removed; deleted to keep `unused_element` lint clean.

## Deviations from Plan
None — plan executed exactly as written.

## Issues Encountered
- Minor: `comment_references` lint fired on `[wayCandidateSourceProvider]` / `[OverpassWayCandidateSource]` / `[cacheHits]` doc-comment references in `diagnostics_metrics_provider.dart` (the symbols weren't imported in that file's own scope). Fixed by rewriting the affected sentences to prose rather than bracket-references. No behaviour change.

## User Setup Required
None — no external service configuration required.

## Next Phase Readiness
- SC5 satisfied: HUD toggle now exposes fix rate (existing) + matcher queue depth + cache-hit rate
- HUD screen renders in release; the toggle-gated tile in `settings_screen.dart` and route guard in `app_router.dart` are Plan 09-07's job (serial tail)
- No blockers for 09-07

---
*Phase: 09-settings-backup*
*Completed: 2026-07-13*
