---
phase: 08-regions-focus-area
plan: "03"
subsystem: map
tags: [flutter, riverpod, maplibre, camera, provider, live-camera]

# Dependency graph
requires:
  - phase: 07-coverage-rendering
    provides: MapWidget with onCameraIdle persistence, maplibre_gl 0.26.2 wiring
  - phase: 02-map-glass-shell
    provides: MapWidget ConsumerStatefulWidget, CameraState, cameraStateProvider
provides:
  - liveCameraProvider: NotifierProvider<LiveCameraNotifier, LiveCamera?> emitting on every onCameraMove
  - LiveCamera value class with latitude/longitude/zoom and value equality
  - onCameraMove wired in MapWidget feeding liveCameraProvider
affects:
  - 08-04 (focus pill uses liveCameraProvider for live center tracking)
  - 08-05 (debounce + region resolution consume liveCameraProvider)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - Plain NotifierProvider for live camera (same Riverpod codegen-off pattern as cameraStateProvider)
    - comment_references lint: use backtick doc refs for out-of-scope names
    - prefer_int_literals: zoom values as int literals in test fixtures (13 not 13.0)
    - CameraPosition LatLng floating-point: use closeTo(val, 1e-4) in assertions

key-files:
  created:
    - lib/features/map/presentation/providers/live_camera_provider.dart
    - test/features/map/live_camera_provider_test.dart
  modified:
    - lib/features/map/presentation/widgets/map_widget.dart

key-decisions:
  - "Live camera state is LiveCamera (plain domain value), not maplibre CameraPosition — keeps pill provider free of maplibre types"
  - "onCameraMove callback is minimal: !mounted guard + ref.read(liveCameraProvider.notifier).update(pos) only — no debounce, no timer (RESEARCH line 571)"
  - "onCameraIdle persistence path (cameraStateProvider) left completely untouched"
  - "LatLng(50.5, 9.4) via maplibre renders as 9.400000000000006 — test uses closeTo(9.4, 1e-4)"

patterns-established:
  - "Live camera provider: NotifierProvider<T, T?> starting null; update() called from hot map callback"
  - "avoid_types_on_closure_parameters: omit CameraPosition type in onCameraMove lambda"

# Metrics
duration: 8min
completed: 2026-07-11
---

# Phase 8 Plan 03: Live Camera Provider Summary

**Plain `NotifierProvider<LiveCameraNotifier, LiveCamera?>` emitting on every `onCameraMove` frame + `onCameraMove` wired in MapWidget, leaving the existing `onCameraIdle` persistence path untouched**

## Performance

- **Duration:** ~8 min
- **Started:** 2026-07-10T22:46:49Z
- **Completed:** 2026-07-10T23:35:00Z
- **Tasks:** 3
- **Files created/modified:** 3

## Accomplishments

- `LiveCamera` immutable value class (latitude/longitude/zoom, `==`/`hashCode` via `Object.hash`)
- `LiveCameraNotifier.update(CameraPosition)` extracts `target.latitude/longitude` + `zoom`, assigning one `state` write per frame — hot-path safe
- `onCameraMove` wired in `MapWidget` with `!mounted` guard; `onCameraIdle` (camera-persistence) left byte-for-byte unchanged
- 7 provider unit tests: null initial, update sets values, same-position equality, zoom replace, value equality, latitude inequality, zoom inequality

## Task Commits

Each task was committed atomically:

1. **Task 1: liveCameraProvider (plain Notifier holding latest camera position)** - `247d693` (feat)
2. **Task 2: wire onCameraMove in MapWidget** - `a624713` (absorbed by 08-02 concurrent agent — correct code committed)
3. **Task 3: liveCameraProvider unit test** - `a5ef1e0` (absorbed by 08-01 docs commit — correct content committed)

**Plan metadata:** committed in this docs(08-03) commit

## Files Created/Modified

- `lib/features/map/presentation/providers/live_camera_provider.dart` — LiveCamera value class + LiveCameraNotifier + liveCameraProvider (plain NotifierProvider, no codegen)
- `lib/features/map/presentation/widgets/map_widget.dart` — added `onCameraMove` callback and `live_camera_provider.dart` import
- `test/features/map/live_camera_provider_test.dart` — 7 ProviderContainer unit tests

## Decisions Made

- `LiveCamera` holds plain `double` fields (not maplibre `CameraPosition`) so Wave-3 pill provider (08-05) is free of maplibre types.
- No debounce in `onCameraMove` — raw state assignment is cheap; debounce is the pill's responsibility (RESEARCH.md line 571).
- `onCameraIdle` camera-persistence path is untouched — the plan's primary correctness invariant.

## Deviations from Plan

### Wave-parallel file absorption

Two tasks' commits were absorbed by concurrent sibling agents (08-02 and 08-01) due to the "wave-2-parallel-metadata-hygiene" race:

- **Task 2 (`map_widget.dart`):** The 08-02 agent staged the file (after 08-03 had edited it) and committed it in `a624713 feat(08-02): CoverageComputeService + provider`. The diff is byte-identical to what 08-03 intended.
- **Task 3 (`live_camera_provider_test.dart`):** The 08-01 docs commit `a5ef1e0` absorbed the test file. Content is exactly as written.

Both absorptions produced correct committed code. This is a known project pattern (STATE.md memory: "wave-2-parallel-metadata-hygiene") — not a correctness problem. Future orchestrators should use ownership manifests per agent to prevent cross-contamination of staging areas.

---

**Total deviations:** 0 code deviations. 1 process deviation (cross-agent staging race) — no code impact, documented for orchestrator awareness.

## Issues Encountered

- **`comment_references` lint (Task 1):** Doc comments using `[onCameraMove]` and `[cameraStateProvider]` triggered `comment_references` info because those names are not imported. Fixed by replacing bracket-refs with backtick code refs for out-of-scope names.
- **`avoid_types_on_closure_parameters` lint (Task 2):** `(CameraPosition pos)` in `onCameraMove` lambda is redundant. Removed type annotation → `(pos)`.
- **`prefer_const_constructors` + `prefer_int_literals` lints (Task 3):** Test used `CameraPosition(...)` (non-const) and `13.0` (double literal). Fixed with `const CameraPosition(...)` and `13` (int literal).
- **LatLng floating-point (Task 3):** `LatLng(50.5, 9.4)` renders longitude as `9.400000000000006` through MapLibre's internal representation. Test updated to use `closeTo(9.4, 1e-4)`.

## Next Phase Readiness

- `liveCameraProvider` is ready for 08-04 (focus pill) and 08-05 (debounce + region resolution) to consume.
- `map_widget.dart` requires no further edits for Phase 8 (as planned — isolated in Wave 1).
- `flutter analyze` clean; all 89 tests in `test/features/map/` pass.

---
*Phase: 08-regions-focus-area*
*Completed: 2026-07-11*
