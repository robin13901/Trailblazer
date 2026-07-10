---
phase: 07-coverage-rendering
plan: 06
subsystem: map-rendering
tags: [flutter, riverpod, maplibre, coverage, overlay, geojson, bridge, widget-test]

# Dependency graph
requires:
  - phase: 07-03
    provides: coverageOverlayDataProvider StreamProvider + DrivenWayGeometryResolver
  - phase: 07-04
    provides: CoverageOverlayApplier + coverageOverlayApplierProvider + coverageLinePaintExpressions
  - phase: 07-05
    provides: coveragePresetValueProvider (sync amber fallback) + CoveragePresetNotifier
provides:
  - mapStyleLoadedTickProvider (StyleTickNotifier with bump()) — style-load signal
  - CoverageOverlayBridge ConsumerStatefulWidget — tick-driven, headless overlay coordinator
  - MapWidget._onStyleLoaded bumps mapStyleLoadedTickProvider on every style load
  - CoverageOverlayBridge mounted in MapScreen outside isMapTab guard (tab-persistent)
  - bridge_test with recording-fake applier (4 scenarios: tick->apply, data re-emit->apply, preset->updateColors, SizedBox.shrink)
affects:
  - 07-07-stress-harness (stress test will drive the bridge end-to-end)
  - Phase 8+ (any future map overlay work should follow the tick-driven bridge pattern)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Tick-driven bridge pattern: NotifierProvider<int> bumped by host widget's onStyleLoaded;
       headless ConsumerStatefulWidget watches the tick (no public callback method)"
    - "Null-controller passthrough: bridge passes controller to applier regardless of null;
       production applier early-returns, test fakes record always"
    - "Tab-persistent headless widget: zero-size Positioned outside isMapTab guard, mirrors TrackingCameraSync"
    - "Test provider chain isolation: MapScreen tests need coverage provider overrides to avoid DB chain"

key-files:
  created:
    - lib/features/map/presentation/providers/map_style_loaded_provider.dart
    - lib/features/coverage/presentation/coverage_overlay_bridge.dart
    - test/features/coverage/presentation/coverage_overlay_bridge_test.dart
    - .planning/phases/07-coverage-rendering/07-MANUAL-TESTS-DEFERRED.md
  modified:
    - lib/features/map/presentation/widgets/map_widget.dart
    - lib/features/map/presentation/map_screen.dart
    - test/features/map/glass_shell_layout_test.dart

key-decisions:
  - "Tick-driven bridge (no public callback): CoverageOverlayBridge watches mapStyleLoadedTickProvider tick rather than exposing onStyleLoaded() — tick is the only interface between MapWidget and the bridge"
  - "Null-controller passthrough to applier: bridge does NOT guard controller==null itself; production applier handles null with early-return; test fakes record regardless — matches TripOverlayApplier pattern"
  - "Task 4 on-device checkpoint deferred: cataloged in 07-MANUAL-TESTS-DEFERRED.md per project memory defer-in-car-verification + Phase 6 precedent"

patterns-established:
  - "Style-load tick pattern: MapWidget._onStyleLoaded bumps mapStyleLoadedTickProvider; bridge watches tick in build() for style-reload detection"
  - "Cascade ref.listen in build(): two ref.listen calls chained as ref..listen..listen cascade (very_good_analysis cascade_invocations lint)"
  - "Test isolation for MapScreen: glass_shell_layout_test must override coverage provider chain when CoverageOverlayBridge is mounted"

# Metrics
duration: 21min
completed: 2026-07-10
---

# Phase 7 Plan 06: Map Bridge Summary

**tick-driven CoverageOverlayBridge wires data+preset+styleTick to MapLibreCoverageOverlayApplier, making driven Kfz roads paint on first map open and survive brightness swaps**

## Performance

- **Duration:** 21 min
- **Started:** 2026-07-10T06:04:25Z
- **Completed:** 2026-07-10T06:25:Z
- **Tasks:** 3 executed + 1 deferred checkpoint cataloged
- **Files modified:** 7

## Accomplishments

- `mapStyleLoadedTickProvider` (StyleTickNotifier): plain NotifierProvider that MapWidget bumps on every `onStyleLoaded` — initial load and after every `setStyle()` brightness swap
- `CoverageOverlayBridge`: headless ConsumerStatefulWidget driven purely by the tick (no public callback method); guards `_styleReady` / `_sourceAdded` flags; dispatches full `apply()` on tick change, `updateColors()` on preset change with source present, `apply()` on data re-emit
- All applier throws caught and logged via `logging` package — map never crashes (06-05 lesson)
- MapWidget wired: `_onStyleLoaded` bumps tick before `widget.onStyleLoaded?.call()`
- MapScreen wired: `const CoverageOverlayBridge()` as `Positioned(top:0,left:0,width:0,height:0)` alongside TrackingCameraSync, outside `isMapTab` guard
- 4 bridge unit tests: tick→apply(amber,data); data re-emit→apply again; preset amber→green→updateColors (not 2nd apply); SizedBox.shrink render
- glass_shell_layout_test updated with coverage provider overrides (Rule 3 auto-fix)
- 07-MANUAL-TESTS-DEFERRED.md created with 5-step on-device procedure

## Task Commits

Each task was committed atomically:

1. **Task 1: mapStyleLoadedTickProvider + CoverageOverlayBridge** - `75a6e52` (feat)
2. **Task 2: Tick bump in MapWidget + bridge mount in MapScreen** - `4037d8b` (feat)
3. **Task 3: Bridge unit test with recording-fake applier** - `1f4a972` (test)
4. **Task 4: Deferred checkpoint catalog** — included in final metadata commit (docs)

## Files Created/Modified

- `lib/features/map/presentation/providers/map_style_loaded_provider.dart` — StyleTickNotifier + mapStyleLoadedTickProvider
- `lib/features/coverage/presentation/coverage_overlay_bridge.dart` — CoverageOverlayBridge ConsumerStatefulWidget
- `lib/features/map/presentation/widgets/map_widget.dart` — `_onStyleLoaded` bumps tick; comment updated
- `lib/features/map/presentation/map_screen.dart` — CoverageOverlayBridge mounted alongside TrackingCameraSync
- `test/features/coverage/presentation/coverage_overlay_bridge_test.dart` — 4 bridge unit tests
- `test/features/map/glass_shell_layout_test.dart` — coverage provider overrides added
- `.planning/phases/07-coverage-rendering/07-MANUAL-TESTS-DEFERRED.md` — 5-step on-device procedure

## Decisions Made

- **Tick-driven bridge, no public callback:** The bridge watches `mapStyleLoadedTickProvider` in its `build()` method. There is no `onStyleLoaded()` method on `CoverageOverlayBridge`. MapWidget is the only caller of `bump()`.
- **Null-controller passthrough:** Bridge passes `controller` (nullable) to the applier directly. The production `MapLibreCoverageOverlayApplier` early-returns on null. Test fakes record calls regardless, enabling assertions without a live MapLibre view.
- **Task 4 on-device checkpoint deferred:** Per project memory `defer-in-car-verification` and Phase 6 `MANUAL-TESTS-DEFERRED.md` precedent. The 5-step on-device verify is cataloged and will be batched with the next drive.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] glass_shell_layout_test needed coverage provider overrides**

- **Found during:** Task 2 (MapWidget + MapScreen wiring)
- **Issue:** `CoverageOverlayBridge` mounted in `MapScreen` pulls in `coverageOverlayDataProvider` → `tripsDaoProvider` → `appDatabaseProvider` chain; existing test had no DB override → 3 tests failed with pending timer / DB-not-found errors
- **Fix:** Added `coverageOverlayDataProvider`, `coveragePresetProvider`, and `coveragePresetValueProvider` overrides to `pumpMapScreen()` in `glass_shell_layout_test.dart`; added `_FakeCoveragePresetNotifier` helper class
- **Files modified:** `test/features/map/glass_shell_layout_test.dart`
- **Verification:** All 9 glass_shell_layout tests green; all 237 coverage + map tests green
- **Committed in:** `4037d8b` (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 blocking test fix)
**Impact on plan:** Required to keep existing test suite green after the new bridge was wired. No scope creep.

## Issues Encountered

- `cascade_invocations` lint (very_good_analysis): Two consecutive `ref.listen()` calls in `build()` needed to be written as `ref..listen()..listen()` cascade.
- `comment_references` lint: `[MapWidget]` / `[MapScreen]` in doc comments resolved to unimported types — replaced with backtick code references.
- `unnecessary_lambdas` lint: `mapControllerProvider.overrideWith(() => _NullMapControllerNotifier())` → `mapControllerProvider.overrideWith(_NullMapControllerNotifier.new)`.
- Riverpod stream deduplication in re-emit test: second emit of `CoverageOverlayData.empty` was deduplicated (same content == same hash); fixed with `_distinctEmptyData` (non-const `List<CoverageWay>[]` with different identity).

## Next Phase Readiness

- Phase 7 plan 07-06 complete. Coverage overlay is code-complete and wired to the live map.
- 07-07 (stress harness) already complete (parallel wave). All 7 plans in Phase 7 are now code-complete.
- On-device visual verify (Task 4) remains deferred to next user drive.
- Phase 8 can begin when user is ready.

---
*Phase: 07-coverage-rendering*
*Completed: 2026-07-10*
