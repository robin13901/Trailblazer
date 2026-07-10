# 07 Manual Tests Deferred

This file catalogs on-device visual verification procedures that require a
real device, real trip data, and the MapTiler API key. These checkpoints are
deferred to the next user drive session per project memory
"defer-in-car-verification" and the Phase 6 MANUAL-TESTS-DEFERRED precedent.

---

## Plan 07-06: Coverage Overlay Map Bridge — On-Device Visual Verify

**Checkpoint type:** human-verify (was Task 4 in 07-06-map-bridge-PLAN.md)
**Status:** Deferred — code-complete, all unit tests green as of 2026-07-10
**Prerequisite:** Device with at least one confirmed + matched trip with driven
Kfz roads and a valid MAPTILER_KEY in `env/dev.json`

### Verification Procedure (5 steps)

1. **Launch the app in debug mode with the MapTiler key:**
   ```
   flutter run --dart-define-from-file=env/dev.json
   ```
   Without `--dart-define-from-file=env/dev.json`, the map is blank (no key).

2. **Open the map on a device with confirmed/matched trips:**
   - Explored Kfz roads should appear in **orange** (full coverage) or a
     **lighter orange** (partial coverage) immediately when the map style loads.
   - Verify the overlay appears without any manual interaction.

3. **Toggle system dark mode:**
   - In device Settings, switch between Light and Dark appearance.
   - The map style should swap (brief fade) AND the coverage overlay must
     **stay visible** — it must not vanish after the brightness swap.
   - The overlay should use the dark-mode color variant (slightly lighter orange
     for full, lighter still for partial).

4. **Live preset recolor:**
   - Navigate to Settings → Coverage color → select **Green**.
   - Return to the map.
   - Explored roads should recolor to **green** WITHOUT a full map/tile reload
     flash (no blank-map moment — only the line layer paint updates).

5. **Confirm partial vs full visual distinction:**
   - Roads with partial coverage (fraction < threshold) should be visibly
     **lighter/more transparent** than fully-explored roads.
   - At street level (zoom ~15) the difference should be clear.

### Expected Pass Criteria

- [ ] Driven Kfz roads paint in the active preset color on first map open.
- [ ] Overlay persists after dark-mode swap (does not vanish).
- [ ] Settings → color change recolors live without a tile reload flash.
- [ ] Partial ways are visibly lighter/more transparent than full ways.
- [ ] No crash or blank map during normal exploration.

### Failure Reporting

If any criterion fails, record the failure as a gap-closure issue referencing
this file and the specific step that failed. Common failure modes:
- Overlay vanishes after dark-mode swap → check `mapStyleLoadedTickProvider.bump()`
  is called from `MapWidget._onStyleLoaded` on every style load.
- Recolor causes blank flash → check `updateColors` path (not full `apply`).
- No overlay at all → check `CoverageOverlayBridge` is mounted outside `isMapTab`
  guard in `MapScreen` and the coverage DB has confirmed/matched trips.
- Partial indistinguishable from full → tune `_kPartialOpacityScale` /
  `_kPartialOpacityFloor` in `coverage_overlay_layers.dart`.
