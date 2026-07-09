---
phase: 07-coverage-rendering
plan: 07
type: execute
wave: 4
depends_on: ["07-04"]
files_modified:
  - lib/features/coverage/presentation/stress/synthetic_coverage_generator.dart
  - lib/features/coverage/presentation/stress/frame_timing_meter.dart
  - lib/features/coverage/presentation/stress/stress_coverage_screen.dart
  - lib/features/settings/presentation/settings_screen.dart
  - lib/core/routing/app_router.dart
  - test/features/coverage/presentation/stress/synthetic_coverage_generator_test.dart
  - test/features/coverage/presentation/stress/frame_timing_meter_test.dart
autonomous: true

must_haves:
  truths:
    - "A debug-only screen loads 50,000 synthetic driven ways onto a live MapLibre map via the coverage overlay path"
    - "The screen measures P90 frame time from FrameTiming callbacks and displays derived fps"
    - "The 50k FeatureCollection is built off the UI isolate (compute) so generation does not jank the load"
    - "The pass threshold (P90 <= 33.3ms => >= 30fps, REN-04) is shown/evaluated on the banner"
    - "The screen is reachable only in debug builds (kDebugMode-gated, tree-shaken from release)"
  artifacts:
    - path: "lib/features/coverage/presentation/stress/synthetic_coverage_generator.dart"
      provides: "generate 50k CoverageWays (random Germany-bbox polylines) — compute-friendly"
      contains: "syntheticCoverageWays"
    - path: "lib/features/coverage/presentation/stress/frame_timing_meter.dart"
      provides: "P90 frame-time meter over a rolling window"
      contains: "p90FrameMs"
    - path: "lib/features/coverage/presentation/stress/stress_coverage_screen.dart"
      provides: "StressCoverageScreen (debug) with live map + fps banner"
      contains: "class StressCoverageScreen"
  key_links:
    - from: "stress_coverage_screen.dart"
      to: "CoverageOverlayApplier.apply (same render path)"
      via: "loads synthetic data through the production overlay layer"
      pattern: "apply\\("
    - from: "stress_coverage_screen.dart"
      to: "WidgetsBinding.instance.addTimingsCallback"
      via: "frame timing capture"
      pattern: "addTimingsCallback"
    - from: "app_router.dart"
      to: "StressCoverageScreen route"
      via: "debug-only /settings/stress-coverage route"
      pattern: "stress"
---

<objective>
Build the REN-04 stress verification: a debug-only `StressCoverageScreen` that
loads 50,000 synthetic driven ways through the SAME production coverage overlay
path (07-04) onto a live MapLibre map, then measures P90 frame time via
`FrameTiming` and displays derived fps against the >= 30 fps gate. Per project
memory the actual on-device fps read is a deferred manual checkpoint — this plan
delivers the harness code-complete + a cataloged device checkpoint.

Purpose: Proves (on device, later) that the GeoJSON + data-driven-expression
architecture holds >= 30 fps at 50k segments — the hard REN-04 constraint that
drove the flat-recolor / no-glow decisions.
Output: generator + meter + screen + debug route + unit tests for the pure bits.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/phases/07-coverage-rendering/07-RESEARCH.md

# The production render path the harness must reuse (do NOT build a parallel one)
@lib/features/coverage/presentation/coverage_overlay_layers.dart
@lib/features/coverage/presentation/coverage_feature_collection.dart
@lib/features/coverage/data/coverage_overlay_data.dart
@lib/features/coverage/domain/coverage_threshold.dart
@lib/features/coverage/domain/coverage_datum.dart

# Map host to embed + debug-route + dev-tile idioms
@lib/features/map/presentation/widgets/map_widget.dart
@lib/core/routing/app_router.dart
@lib/features/settings/presentation/settings_screen.dart
</context>

<tasks>

<task type="auto">
  <name>Task 1: Synthetic 50k coverage generator (compute-friendly) + test</name>
  <files>lib/features/coverage/presentation/stress/synthetic_coverage_generator.dart, test/features/coverage/presentation/stress/synthetic_coverage_generator_test.dart</files>
  <action>
Pure top-level function `List<CoverageWay> syntheticCoverageWays({int count =
50000, int seed = 42})`:
  - Germany bbox: lat 47.27..55.06, lon 5.87..15.04 (RESEARCH §Stress Harness).
  - Deterministic Random(seed).
  - Each way: 3..8 points; first point random in-bbox, subsequent points a small
    random walk (~0.001..0.005 deg step) so LineStrings look road-like.
  - fraction = random 0..1; classify via classifyCoverage using a synthetic
    wayLength derived from the polyline (or just set datum directly: compute a
    plausible unionLen = fraction * wayLen and call classifyCoverage so the
    is_full/floor logic is exercised, matching production). wayId = index.
  - Signature must be `compute`-friendly: single-argument variant
    `List<CoverageWay> syntheticCoverageWaysArgs(({int count, int seed}) args)`
    OR accept an int record so it can run via `compute`. (CoverageWay/LatLng must
    be sendable across isolates — LatLng is a plain value; fine.)
Also expose `Future<Map<String,dynamic>> buildSyntheticFeatureCollection(int
count)` that runs `syntheticCoverageWays` + `buildCoverageFeatureCollection` on a
`compute` isolate and returns the FeatureCollection map (Pitfall 4 — keep the
50k build off the UI isolate).

Test: syntheticCoverageWays(count: 100) returns 100 CoverageWays, all points in
the Germany bbox, each geometry length in [3,8], deterministic across two calls
with the same seed. (Do NOT generate 50k in the unit test — use a small count.)
  </action>
  <verify>flutter test synthetic_coverage_generator_test.dart green; flutter analyze clean.</verify>
  <done>syntheticCoverageWays produces deterministic in-bbox road-like ways; buildSyntheticFeatureCollection offloads to compute.</done>
</task>

<task type="auto">
  <name>Task 2: FrameTimingMeter (P90 over rolling window) + test</name>
  <files>lib/features/coverage/presentation/stress/frame_timing_meter.dart, test/features/coverage/presentation/stress/frame_timing_meter_test.dart</files>
  <action>
`class FrameTimingMeter`:
  - Holds a rolling list of frame times (ms), capped at ~600 (10s @ 60fps).
  - `void addTimings(List<FrameTiming> timings)` — for each, append
    `t.totalSpan.inMicroseconds / 1000.0`, trim to cap (RESEARCH measurement
    snippet).
  - `double get p90FrameMs` — sorted[(len*0.9).floor()], 0 when empty.
  - `double get fps` — p90FrameMs>0 ? 1000/p90FrameMs : 0.
  - `bool get passes` — p90FrameMs>0 && p90FrameMs <= 33.3 (>= 30fps gate).
  - `void reset()`.
Keep it a plain class (no Flutter widget deps beyond `dart:ui` FrameTiming) so
it's unit-testable by feeding synthetic FrameTiming-like data. Since FrameTiming
is hard to construct in tests, add an internal `void addFrameMs(double ms)` used
by addTimings; test drives addFrameMs directly.

Test: feed 100 frames of 16.6ms + 10 frames of 50ms -> p90 reflects the tail;
passes false when p90 > 33.3; empty -> fps 0, passes false; window cap trims.
  </action>
  <verify>flutter test frame_timing_meter_test.dart green; flutter analyze clean.</verify>
  <done>FrameTimingMeter computes P90/fps/passes over a capped rolling window; unit-tested via addFrameMs.</done>
</task>

<task type="auto">
  <name>Task 3: StressCoverageScreen + debug route + Settings dev entry</name>
  <files>lib/features/coverage/presentation/stress/stress_coverage_screen.dart, lib/core/routing/app_router.dart, lib/features/settings/presentation/settings_screen.dart</files>
  <action>
`StressCoverageScreen extends ConsumerStatefulWidget` (debug tool):
  - Body: a Positioned.fill MapWidget (reuse the production widget — it already
    reads MAPTILER_KEY; the harness inherits the blank-map-without-key caveat)
    + an overlay banner (top) showing: loaded feature count, P90 ms, fps,
    PASS/FAIL vs 33.3ms.
  - initState: `WidgetsBinding.instance.addTimingsCallback(_onFrameTimings)`;
    dispose: remove it. `_onFrameTimings` feeds a FrameTimingMeter then
    `setState`.
  - On map style loaded (via the MapWidget onStyleLoaded callback), kick off the
    load: `await buildSyntheticFeatureCollection(50000)` on compute, then call
    the SAME production applier path — construct CoverageOverlayData from
    syntheticCoverageWays and call
    `ref.read(coverageOverlayApplierProvider).apply(controller, data: data,
    preset: amber, brightness: current)`. (Reusing the production applier is the
    point — it validates the real render path, not a bespoke one.) Guard so the
    heavy load runs once.
  - A small instruction line: "Pan/zoom for 10s; read P90/fps."
  - Everything gated so it's debug-only.

Route (app_router.dart): register `/settings/stress-coverage` INSIDE the same
`if (kDebugMode)` block that guards the diagnostics route (the file already has
one — mirror it). Import StressCoverageScreen.

Settings (settings_screen.dart): under the existing `if (kDebugMode)` Developer
section, add a `_StressCoverageTile` ListTile ("Coverage stress test",
subtitle "50k segments · fps meter", onTap ->
context.push('/settings/stress-coverage')) next to the diagnostics tile.

No unit test for the screen itself (live-map + FrameTiming — device territory);
the pure generator + meter are covered by Tasks 1-2. Add a cataloged deferred
device checkpoint note in the SUMMARY (below).

Run `flutter analyze`; run `flutter test test/features/coverage/presentation/stress/`.
  </action>
  <verify>flutter analyze clean; stress tests green; the screen + debug route compile and are kDebugMode-gated.</verify>
  <done>Debug-only StressCoverageScreen loads 50k synthetic ways through the production applier and shows a P90/fps/PASS banner; reachable via Settings > Developer in debug builds only.</done>
</task>

</tasks>

<verification>
- `flutter analyze` clean.
- `flutter test test/features/coverage/presentation/stress/` green.
- Stress screen + route are behind `kDebugMode` (tree-shaken from release).
- The harness uses the production CoverageOverlayApplier, not a parallel path.
</verification>

<success_criteria>
REN-04 harness is code-complete: a debug-only screen loads 50,000 synthetic
driven ways via the production GeoJSON+expression overlay and reports P90 frame
time + fps against the >= 30 fps gate. The actual on-device fps measurement is
cataloged as a deferred manual checkpoint (batched to the next device session
per project memory).
</success_criteria>

<output>
After completion, create `.planning/phases/07-coverage-rendering/07-07-SUMMARY.md`
(note the deferred on-device 50k-fps read as a manual checkpoint).
</output>
