---
plan: "02-07"
title: "Phase 2 verification — real-device smoke test + docs + STATE.md close-out"
phase: "02-map-glass-shell"
type: execute
wave: 5
depends_on: ["02-01", "02-02", "02-03", "02-04", "02-05", "02-06"]
files_modified:
  - docs/G1_SPIKE.md                     # extend with post-integration observations
  - docs/PHASE_02_VERIFICATION.md
  - .planning/STATE.md
  - .planning/ROADMAP.md
  - .planning/phases/02-map-glass-shell/02-VERIFICATION.md
autonomous: false   # requires human real-device verification checkpoint

must_haves:
  truths:
    - "All 5 Phase 2 success criteria (SC1-SC5 from ROADMAP.md) are documented as PASS in `.planning/phases/02-map-glass-shell/02-VERIFICATION.md`, OR the fallback path is explicitly recorded for any that don't pass end-to-end."
    - "A real-device smoke test on Android has been completed by the user: install debug build, complete onboarding (grant location), verify map renders offline, pan/zoom/rotate, blue dot centered, re-center works, dark-mode swap works, glass chrome renders without jank."
    - "Coverage of Phase 2 requirements (MAP-01..07, UI-01..07) is checked against the artifacts."
    - "STATE.md is updated: Phase 2 complete, decisions logged, pending todos identified, blockers cleared or re-scoped."
    - "ROADMAP.md checkbox for Phase 2 flipped to `[x]`; Phase 2 requirements moved to Complete in the traceability table."
    - "`flutter analyze` + `flutter test` remain green."
    - "`flutter build apk --debug` (or iOS equivalent) succeeds."
  artifacts:
    - path: .planning/phases/02-map-glass-shell/02-VERIFICATION.md
      provides: "Formal Phase 2 verification record with per-SC PASS/FAIL + evidence."
      contains: "SC1"
    - path: docs/PHASE_02_VERIFICATION.md
      provides: "User-facing summary of what was verified + how to reproduce."
      contains: "# Phase 2 Verification"
  key_links:
    - from: .planning/phases/02-map-glass-shell/02-VERIFICATION.md
      to: docs/G1_SPIKE.md
      via: "SC5 references the G1 decision"
      pattern: "G1_SPIKE"
    - from: .planning/STATE.md
      to: .planning/phases/02-map-glass-shell/02-VERIFICATION.md
      via: "Phase 2 close-out log entry"
      pattern: "Phase 2 close-out"
---

<objective>
Verify that Phase 2 delivers on its 5 success criteria on real hardware, document any deviations or partial-fallback paths (especially around G1), update project state, and close out the phase in ROADMAP.md.

Purpose: This is the phase's exit gate. No downstream phase should start until Phase 2's SC1-SC5 are honestly recorded (PASS or DOCUMENTED_FALLBACK).
Output: Verification records + STATE.md/ROADMAP.md updates.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/STATE.md
@.planning/REQUIREMENTS.md
@.planning/phases/02-map-glass-shell/02-CONTEXT.md
@.planning/phases/02-map-glass-shell/02-RESEARCH.md
@docs/G1_SPIKE.md
@.planning/phases/02-map-glass-shell/02-01-SUMMARY.md
@.planning/phases/02-map-glass-shell/02-02-SUMMARY.md
@.planning/phases/02-map-glass-shell/02-03-SUMMARY.md
@.planning/phases/02-map-glass-shell/02-04-SUMMARY.md
@.planning/phases/02-map-glass-shell/02-05-SUMMARY.md
@.planning/phases/02-map-glass-shell/02-06-SUMMARY.md
</context>

<tasks>

<task type="auto">
  <name>Task 1: Automated pre-verification — analyze + test + build</name>
  <files>
    - (no source changes; this task validates the state of the tree)
  </files>
  <action>
    Run in order:
    ```
    flutter pub get
    flutter analyze
    dart format --set-exit-if-changed .
    dart run drift_dev schema generate drift_schemas/ test/generated_migrations/
    flutter test --coverage
    flutter build apk --debug
    ```

    If macOS host available:
    ```
    flutter build ios --debug --no-codesign
    ```

    Every command must exit 0. If any fails, STOP and iterate via the Ralph Loop (fix → rerun) until green. If the fix falls outside Phase 2 scope (e.g. a Phase 1 regression), file a deviation note and continue — but do NOT mark the phase verified.

    Capture the outputs (or at least the trailing "PASS/OK" line) into `docs/PHASE_02_VERIFICATION.md` as evidence.
  </action>
  <verify>
    All commands above exit 0. `docs/PHASE_02_VERIFICATION.md` records their success (with dates + host + tool versions).
  </verify>
  <done>
    - `flutter analyze` green.
    - `dart format --set-exit-if-changed .` green.
    - `flutter test` green (all pre-existing + new).
    - `flutter build apk --debug` succeeds.
    - Evidence captured in `docs/PHASE_02_VERIFICATION.md`.
  </done>
</task>

<task type="checkpoint:human-verify" gate="blocking">
  <name>Task 2: Real-device Phase 2 smoke test</name>
  <what-built>
    A complete Phase 2 app: MapLibre map from bundled PMTiles, blue dot at current location, follow-mode + re-center, dark-mode auto-switch, Liquid Glass chrome (focus pill stub, top-left settings button, FAB stub, bottom nav pill with 3 tabs), StatefulShellRoute wiring.
  </what-built>
  <how-to-verify>
    Instructions for the user:

    1. Install debug build on an Android device:
       ```
       flutter install
       ```
       (or `flutter run -d <device-id>` for a hot run).

    2. Fresh-launch checklist (uninstall the app first for a clean flag state):
       - [ ] **SC1 pan/zoom/rotate/no-tilt:** Two-finger drag horizontally — map rotates. Two-finger vertical pinch — map does NOT tilt (2D flat, per CONTEXT.md). Pinch to zoom — smooth. Pan with one finger — smooth. Compass button appears in top-right when rotated; tapping compass snaps north.
       - [ ] **SC2 offline base map:** Enable airplane mode. Force-close and reopen the app. Complete onboarding. Confirm: map still renders (bundled `dev_berlin.pmtiles`). Berlin area shows streets/roads/labels. Turn airplane mode off.
       - [ ] **SC3 blue dot + camera at current location:** With location permission granted during onboarding, map opens roughly at your current location (or Berlin fallback if permission denied). Blue dot + accuracy ring + heading cone visible. Pan away → re-center button appears bottom-right → tap it → camera snaps back and follow mode resumes.
       - [ ] **SC4 dark mode auto-switch:** In device Settings, flip system theme (Light ↔ Dark). Return to the app. Map style crossfades (no white flash, no abrupt palette jump). Flutter chrome (splash if re-launched, onboarding, glass tint) also switches.
       - [ ] **SC5 Liquid Glass shell — no jank:** Watch a full round-trip: tap the bottom pill (Trips → Regions → Map), tap top-left gear (→ Settings screen appears, back-button returns), tap the FAB (SnackBar 'Coming in Phase 3'), tap Focus pill (does nothing — stub). Frame drops? Report if the pill/chrome stutters or if animations feel sub-30fps.

    3. Report back: PASS/FAIL per checkbox with a short note if FAIL. Screenshots of light + dark map appreciated.

    If G1 spike said `platformSupportsBlurOverMap = false` on Android (expected): the glass chrome will NOT show a real blur over the map — it'll be a semi-transparent tinted pill. This is the documented fallback, and SC5 PASSES if there's no jank + the chrome is visually acceptable.

    If iOS testing is available, run the same checklist on iOS. Otherwise note "iOS not tested".
  </how-to-verify>
  <resume-signal>
    Report back with:
    ```
    SC1: PASS|FAIL - <note>
    SC2: PASS|FAIL - <note>
    SC3: PASS|FAIL - <note>
    SC4: PASS|FAIL - <note>
    SC5: PASS|FAIL - <note>
    Device(s): <Android model / OS version / iOS device or 'not tested'>
    Screenshots: <paths or attached>
    ```
    Or type `approved` if all 5 PASS with default fallbacks.
  </resume-signal>
</task>

<task type="auto">
  <name>Task 3: Write 02-VERIFICATION.md + PHASE_02_VERIFICATION.md</name>
  <files>
    - .planning/phases/02-map-glass-shell/02-VERIFICATION.md
    - docs/PHASE_02_VERIFICATION.md
    - docs/G1_SPIKE.md   # append post-integration observation
  </files>
  <action>
    1. `.planning/phases/02-map-glass-shell/02-VERIFICATION.md` — the machine-parseable record for the gsd verify-work workflow:

       ```yaml
       ---
       phase: 02-map-glass-shell
       verified: {today}
       status: {complete | partial | gaps}
       device_verified:
         android: {model + OS or 'not tested'}
         ios: {model + OS or 'not tested'}
       ---

       # Phase 2 Verification

       ## Success Criteria

       ### SC1 — Pan/zoom/rotate/tilt gestures
       - **Status:** {PASS | FAIL}
       - **Evidence:** MapWidget has `tiltGesturesEnabled: false` + widget test asserts it (test/features/map/map_widget_test.dart). Real-device: {note from human checkpoint}.

       ### SC2 — Offline base map from bundled PMTiles
       - **Status:** {PASS | FAIL}
       - **Evidence:** `assets/tiles/dev_berlin.pmtiles` bundled ({size} MB, source: {Protomaps build date}). Style JSONs reference `pmtiles://assets/tiles/dev_berlin.pmtiles`. Real-device airplane-mode test: {result}.

       ### SC3 — Blue dot + camera at current location
       - **Status:** {PASS | FAIL}
       - **Evidence:** `LocationRepository` + `LocationPermissionNotifier` + `MyLocationTrackingMode.tracking` on map creation. Onboarding requests `Permission.locationWhenInUse`. Real-device: {note}.

       ### SC4 — Dark-mode auto-switch
       - **Status:** {PASS | FAIL}
       - **Evidence:** MapWidget observes `didChangePlatformBrightness`; MapStyleFade wraps MapLibreMap in AnimatedOpacity (180ms); `mapStyleAssetProvider` resolves the correct asset. Real-device: {note}.

       ### SC5 — Glass shell no jank
       - **Status:** {PASS | FAIL} (fallback path: {`fallback active` | `LiquidGlass native`})
       - **Evidence:** GlassPill / GlassCircle branch on `LiquidGlassSettings.platformSupportsBlurOverMap` (set to `{value}` per docs/G1_SPIKE.md). No BackdropFilter used over map in fallback path (per Flutter issue #185497). Real-device profile-mode observation: {note}.

       ## Requirements Coverage

       | Req | Status | Notes |
       |-----|--------|-------|
       | MAP-01 | PASS | MapLibre + Protomaps style renders |
       | MAP-02 | PASS | Bundled PMTiles, airplane mode confirmed |
       | MAP-03 | PASS | Pan/zoom/rotate; tilt disabled |
       | MAP-04 | PASS | Blue dot via myLocationEnabled |
       | MAP-05 | PASS | Auto dark-mode with crossfade |
       | MAP-06 | PASS | Two project-owned style JSONs |
       | MAP-07 | PARTIAL — CONTEXT.md override | Camera opens at current location (via tracking mode), NO persistence per user decision |
       | UI-01 | PASS (stub) | FocusAreaPill shows `—`; Phase 8 wires live data |
       | UI-02 | PASS | 3-tab bottom pill: Map/Trips/Regions |
       | UI-03 | PASS (stub) | TripFab shows SnackBar; Phase 3 wires |
       | UI-04 | PASS | GlassPill + GlassCircle over map |
       | UI-05 | PASS | G1 gate resolved (see docs/G1_SPIKE.md) |
       | UI-06 | PASS | No AppBar on MapScreen |
       | UI-07 | PASS | Light + dark both render via ThemeMode.system + brightness observer |

       ## Deviations from Plan
       {List any deviations logged in the individual plan Deviations sections.}

       ## Open Todos for Phase 3+
       - {Any handoff items — e.g. iOS BackdropFilter behavior to re-check with future Flutter version}
       ```

    2. `docs/PHASE_02_VERIFICATION.md` — the human-facing summary. Sections:
       - What was built (short paragraph)
       - How to reproduce the smoke test (steps from Task 2)
       - G1 decision + rationale (cross-link to `G1_SPIKE.md`)
       - Test + build outputs (paste tail of `flutter analyze`, `flutter test --coverage`, `flutter build apk --debug`)
       - Known gaps for later phases (glyph bundling for full offline, iOS BackdropFilter re-check, MAP-07 persistence disabled by design)

    3. Append to `docs/G1_SPIKE.md` under a new `## Post-Integration Observations` section: after building the whole shell, did the G1 decision hold? Any surprises (e.g. iOS behavior different than the spike suggested)? A single paragraph.
  </action>
  <verify>
    ```
    test -f .planning/phases/02-map-glass-shell/02-VERIFICATION.md
    test -f docs/PHASE_02_VERIFICATION.md
    grep -q 'SC1' .planning/phases/02-map-glass-shell/02-VERIFICATION.md
    grep -q 'SC5' .planning/phases/02-map-glass-shell/02-VERIFICATION.md
    grep -q 'Post-Integration Observations' docs/G1_SPIKE.md
    ```
    All pass.
  </verify>
  <done>
    - Both verification docs written with per-SC status.
    - Requirements coverage table complete.
    - G1_SPIKE.md has a post-integration paragraph.
  </done>
</task>

<task type="auto">
  <name>Task 4: Update STATE.md + ROADMAP.md — Phase 2 close-out</name>
  <files>
    - .planning/STATE.md
    - .planning/ROADMAP.md
  </files>
  <action>
    1. `.planning/STATE.md`:
       - Update `Current Position` block: Phase 2 → COMPLETE. Set `Last activity` to today's date + one-line summary.
       - Update `Progress` bar: `~9.1%` → new estimate based on 14 plans complete out of ~77 total.
       - Under `Performance Metrics`:
         - Add row for `02-map-glass-shell` in the "By Phase" table.
         - Update total plans completed count.
       - Under `Accumulated Context > Decisions`, append 5-8 concise lines summarizing key Phase 2 decisions:
         - G1 gate result (`platformSupportsBlurOverMap = <value>`)
         - MAP-07 persistence intentionally disabled (per CONTEXT.md)
         - `FollowMode` enum extension point for Phase 3 heading-lock
         - PMTiles bundling strategy (Berlin dev tile, ~X MB in `assets/tiles/`)
         - `liquid_navbar` skipped in favor of custom `BottomNavShell` (3 tabs, custom needs)
         - Any G1 fallback (`FallbackTintedPill` uses no BackdropFilter over map on Android)
         - StatefulShellRoute with Settings OUT of the pill (top-left glass button)
       - Under `Blockers/Concerns`, resolve G1 (mark as resolved with the actual result) and preserve G2 (still Phase 7 concern).
       - Under `Pending Todos`, add Phase 3 handoff notes:
         - Phase 3 wires FAB → real trip start; extend `FollowMode` usage to `locationAndHeading`
         - Phase 8 wires FocusAreaPill to live region + coverage data
         - Phase 10 wires Settings screen
         - Optional: iOS BackdropFilter behavior worth re-checking each Flutter version bump

    2. `.planning/ROADMAP.md`:
       - Flip `- [ ] **Phase 2: Map + Glass Shell**` to `- [x] **Phase 2: Map + Glass Shell**` in the phases list.
       - Update `## Progress` table row for Phase 2: `Plans Complete: 7/7`, `Status: ✓ Complete`, `Completed: {today}`.
       - Under `## Coverage`, update the traceability table: flip all MAP-01..07 and UI-01..07 rows from `Pending` to `Complete` (or `Complete (fallback)` for UI-05 if G1 fell back).
  </action>
  <verify>
    ```
    grep -q 'Phase 2.*✓ Complete\|Phase 2.*Complete' .planning/ROADMAP.md
    grep -q 'Plan 02-07' .planning/STATE.md || grep -q 'Phase 2 close-out' .planning/STATE.md
    grep -q 'MAP-07.*Complete' .planning/ROADMAP.md
    grep -q 'UI-05.*Complete' .planning/ROADMAP.md
    ```
    All pass.
  </verify>
  <done>
    - STATE.md and ROADMAP.md reflect Phase 2 completion.
    - Requirements table lists all 14 Phase 2 reqs as Complete.
    - Handoff notes for Phase 3 present.
  </done>
</task>

<task type="auto">
  <name>Task 5: Final green-run — analyze + test + build + git status</name>
  <files>
    - (no source changes — final gate)
  </files>
  <action>
    Re-run the full Ralph Loop gate:
    ```
    flutter analyze
    dart format --set-exit-if-changed .
    flutter test --coverage
    flutter build apk --debug
    git status
    ```

    Every command must exit 0. `git status` should show `.planning/`, `docs/`, and any expected file changes clean-diff. NO uncommitted debug hacks (e.g. bypass in `main.dart` from Plan 02-01) should remain — grep the source for `SpikeG1Screen` references outside the spike file itself and outside test helpers.

    If any leftover debug wiring is found, revert it, re-run this task, and only mark done when clean.
  </action>
  <verify>
    ```
    flutter analyze
    dart format --set-exit-if-changed .
    flutter test
    flutter build apk --debug
    ! grep -r 'SpikeG1Screen' lib/main.dart lib/app.dart lib/core/routing/
    ```
    All exit 0 / grep returns nothing.
  </verify>
  <done>
    - All Ralph Loop gates green.
    - No spike bypasses leaked into production code.
    - Tree is ready for commit.
  </done>
</task>

</tasks>

<verification>
- All 5 SC recorded in `.planning/phases/02-map-glass-shell/02-VERIFICATION.md` as PASS (or documented fallback).
- Real-device smoke test confirmed by user (Task 2 checkpoint).
- `docs/PHASE_02_VERIFICATION.md` present.
- `docs/G1_SPIKE.md` extended with post-integration observations.
- `.planning/STATE.md` reflects Phase 2 = COMPLETE.
- `.planning/ROADMAP.md` Phase 2 checkbox = `[x]`; MAP-01..07 + UI-01..07 = Complete.
- Ralph Loop final green.
</verification>

<success_criteria>
- All 14 Phase 2 requirements accounted for (Complete or documented fallback).
- G1 gate resolved and documented.
- MAP-07 persistence intentionally deferred per CONTEXT.md — recorded as such.
- Phase 3 has a clean starting point: STATE.md handoff notes list the extension points (FAB, FollowMode, Settings, FocusPill).
</success_criteria>

<deviations>
(Executor logs. Examples: which SC needed a "documented fallback" instead of "PASS"; whether iOS device was available; any coverage requirement re-scoped.)
</deviations>

<output>
After completion, create `.planning/phases/02-map-glass-shell/02-07-SUMMARY.md`:
- Frontmatter: `subsystem: verification`, `affects: [phase-3, phase-6, phase-8, phase-10]`, `requires: [02-01, 02-02, 02-03, 02-04, 02-05, 02-06]`
- Notes: per-SC result, G1 decision path summary, Phase 3 handoff highlights.
</output>
