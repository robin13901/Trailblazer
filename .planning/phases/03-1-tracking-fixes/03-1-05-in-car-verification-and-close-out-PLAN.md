---
id: 03-1-05
phase: 03-1-tracking-fixes
plan: 05
type: execute
wave: 3
depends_on: [03-1-02, 03-1-03, 03-1-04]
files_modified:
  - .planning/phases/03-1-tracking-fixes/03-1-DRIVE-VERIFICATION-<date>.md
  - .planning/phases/03-tracking-mvp/03-VERIFICATION.md
  - .planning/REQUIREMENTS.md
  - .planning/ROADMAP.md
  - .planning/STATE.md
autonomous: false
requirements: []

must_haves:
  truths:
    - "User completes an in-car drive (manual + auto legs) with HUD open and produces a passing drive-verification report at .planning/phases/03-1-tracking-fixes/03-1-DRIVE-VERIFICATION-<date>.md"
    - "The drive-verification report confirms all 6 Phase 3.1 SC empirically: HUD renders every field live (SC1), manual trip fixes arrive within 3s and distance/speed update ≤5s (SC2), auto trip enters pending within 60s of in_vehicle and terminates after 2min dwell (SC3), persistent notification is visible and text updates at 30s cadence (SC4), map camera follows during recording and releases on stop/pan (SC5), and the drive itself passes (SC6)"
    - "Phase 3 (parent) VERIFICATION.md is updated: SC1..SC5 flip from 'code-complete, drive-deferred' to 'verified' with evidence from this drive; TRK-01..11 + QUA-06 in REQUIREMENTS.md flip to Complete"
    - "ROADMAP.md marks Phase 3.1 complete + Phase 3 close-out finalized; STATE.md pending-todo for 'Phase 3 close-out (batched in-car drive)' resolved and replaced with a Phase 3.1 close-out block"
    - "Phase 5 unblocks — the STATE.md Blockers/Concerns entry 'PHASE 3 DRIVE VERIFICATION FAILED (2026-07-06)' is resolved and removed"
  artifacts:
    - path: ".planning/phases/03-1-tracking-fixes/03-1-DRIVE-VERIFICATION-<date>.md"
      provides: "Empirical evidence document — HUD screenshots (if capturable), per-SC observations from the drive, and pass/fail per criterion"
    - path: ".planning/phases/03-tracking-mvp/03-VERIFICATION.md"
      provides: "Updated Phase 3 verification status — SC1..SC5 evidence rows now filled in from the Phase 3.1 drive"
    - path: ".planning/REQUIREMENTS.md"
      provides: "TRK-01..11 + QUA-06 rows flipped to Complete"
    - path: ".planning/ROADMAP.md"
      provides: "Phase 3.1 row marked complete; Phase 3 close-out finalized"
    - path: ".planning/STATE.md"
      provides: "Pending-todo for in-car drive resolved; Blockers entry for 2026-07-06 drive failure removed; Phase 3.1 close-out decisions block appended"
  key_links:
    - from: ".planning/ROADMAP.md"
      to: ".planning/phases/03-1-tracking-fixes/03-1-DRIVE-VERIFICATION-<date>.md"
      via: "Phase 3.1 status row links to the drive-verification report for evidence trail"
      pattern: "03-1-DRIVE-VERIFICATION"
    - from: ".planning/phases/03-tracking-mvp/03-VERIFICATION.md"
      to: ".planning/phases/03-1-tracking-fixes/03-1-DRIVE-VERIFICATION-<date>.md"
      via: "Phase 3 VERIFICATION cross-links to Phase 3.1's drive report as the source of SC1..SC5 empirical evidence"
      pattern: "03-1-DRIVE-VERIFICATION"
---

## Goal

Close Phase 3.1 with an on-device drive that empirically verifies all 6 SC via the debug HUD from 03-1-01 and the fixes from 03-1-02 / 03-1-03. Update parent Phase 3 verification + REQUIREMENTS + ROADMAP + STATE to reflect a fully closed tracking MVP. This checkpoint plan is `autonomous: false` — the executor cannot run the drive for the user.

## Context

- The Phase 3 in-car drive on 2026-07-06 failed on SC1 (distance/speed = 0), SC2 (auto-trip silent), SC3 (map camera did not follow), SC4 (no persistent notification). Full report: `.planning/phases/03-tracking-mvp/03-DRIVE-VERIFICATION-2026-07-06.md`.
- Phase 3.1 exists precisely to fix those failures. Waves 1 (HUD) and 2 (H1+H5, H2, regression tests) are code-complete before this plan runs.
- Ralph-Loop compliance: the execute-plan orchestrator has already run `flutter analyze` + `flutter test` inside the tight loop for each of 03-1-01..03-1-04. This plan doesn't run the analyzer/tests — it's a drive checkpoint.
- CONTEXT non-negotiable: "Widget/unit tests are necessary but not sufficient — Wave 3's drive is authoritative for close." The green test suite from Wave 2 is not enough; only the drive verifies real FGB behavior on Samsung One UI 7.
- Phase 5 (matcher's golden corpus) depends on real captured trips. Phase 3.1 must close before Phase 5 starts.
- STATE Blockers/Concerns line 262 ("PHASE 3 DRIVE VERIFICATION FAILED (2026-07-06)") is resolved by this plan.
- STATE Pending Todos line 236 ("Phase 3 close-out (batched in-car drive)") is superseded by this plan's own drive.

## Tasks

<task type="checkpoint:human-verify">
  <name>Task 1: Run the drive with HUD open + capture observations</name>
  <gate>blocking</gate>
  <what-built>
    - Debug HUD (03-1-01): dev-only screen at Settings → Tracking diagnostics, showing FGB ready outcome, current state (enabled/isMoving), permissions (5 rungs), last accepted/rejected fix, last activity, and 4 counters.
    - H1 fix (03-1-02): FGB.start() now called at three sites; ready() failures are logged severe and surface via HUD's facadeReadyOutcome.
    - H5 fix (03-1-02): TrackingCapability on Android now requires the ignoreBatteryOptimizations grant; Samsung Adaptive-Battery dismissal correctly degrades to manualOnly.
    - H2 fix (03-1-03): TrackingCameraSync widget drives cameraStateProvider on trip start/stop transitions; MyLocationTrackingMode mapping now correctly reaches trackingCompass on locationAndHeading.
    - Regression tests (03-1-04): H3/H4 invariants locked in.
  </what-built>
  <how-to-verify>
    Same route as the 2026-07-06 drive if practical (supermarket-and-back). If not, any 15-30 minute mixed-driving route works — must include both manual and auto-trip legs.

    **Pre-drive setup:**
    1. Install a fresh debug build on the Samsung Galaxy S24 (Android 14). Ensure the app is FRESHLY installed (uninstall old build first) so the permission ladder shows on first launch — required to verify SC1's permission fields and H5's battery-opt grant path.
    2. Walk through onboarding. At the battery-opt dialog, DELIBERATELY GRANT it (contrast with the 2026-07-06 drive where the state was uncertain). Then before starting the drive, revisit the permission-motion-notification page mentally: capability should compute as fullAuto.
    3. Open Settings → Tracking diagnostics. HUD should render. Baseline state:
        - facadeReadyOutcome: pending (until first trip start) OR success (if init() called ready() eagerly — this depends on 03-1-02's implementation choices; either is acceptable).
        - All 5 permission rungs: granted.
        - lastAcceptedFix: — (idle).
        - counters: all 0.

    **Manual-trip leg (SC1, SC2, SC4, SC5):**
    4. Return to map screen. Tap the trip FAB (Start).
    5. Within 3 s, observe on the HUD (second phone or split-screen if possible; otherwise glance-tab):
        - facadeReadyOutcome: **success** (SC1 verification of the ready outcome pathway).
        - counters.accept: increments from 0 → ≥ 1 (SC2 — fix intake).
        - lastAcceptedFix: shows a recent timestamp + coords (SC2).
    6. Drive. Check every ~30 s that:
        - Live panel on the map shows distance ticking up and non-zero speed (SC2 — was BROKEN on 2026-07-06).
        - Map camera stays locked to heading (SC5 — was BROKEN on 2026-07-06).
        - Notification bar shows a Trailblazer notification with the current stats; text updates at ~30 s cadence (SC4 — was BROKEN on 2026-07-06).
    7. Perform a mid-trip user pan on the map. Camera should stay panned (pan-dismiss precedence). Wait ~10 s to confirm the tracking sync does NOT re-arm follow mode.
    8. Tap the FAB (Stop). Trip persists with non-zero distance. Camera releases follow (SC5).

    **Auto-trip leg (SC3):**
    9. Wait 2+ minutes at destination (lock screen off, in car). This should end the manual trip if the manual FAB was tapped; otherwise, transition into a fresh auto-trip window.
    10. Drive back. Within 60 s of driving (motion=true + activity=in_vehicle), the auto-trip should enter pending state (visible via HUD's currentTripId flipping non-null, or the live panel appearing).
    11. Persistent notification appears (SC4 auto-trip case — was BROKEN on 2026-07-06 for auto-trips).
    12. Park. Wait 2 min. Auto-trip auto-terminates via dwell timer (SC3).

    **HUD-specific verification (SC1):**
    - Every field enumerated in 03-1-01's must_haves.truths[3] should have rendered with a real value during the drive: facadeReadyOutcome, facadeCurrentState (enabled/isMoving), lastAcceptedFix, lastRejected reason (if any accuracy filter fired), lastActivityType + lastActivityAt, all 4 counters, currentTripId.

    **After the drive:**
    13. Screenshot the HUD in the following states (or note observations if screenshotting is impractical):
        - During manual trip (counters incrementing, fix arriving, activity=in_vehicle).
        - During auto-trip pending (currentTripId non-null, activity fresh).
        - Idle after auto-trip terminated.
    14. Report back with the observations.
  </how-to-verify>
  <resume-signal>
    Reply with:
    - SC1 (HUD live): PASS / FAIL — describe any field that did not render or updated stale.
    - SC2 (manual trip: fix within 3 s, distance + speed ≤5 s update): PASS / FAIL — attach counters + panel behavior.
    - SC3 (auto trip: pending in ≤60 s, terminate after 2 min dwell): PASS / FAIL — attach approx timing.
    - SC4 (persistent notification, 30 s update cadence): PASS / FAIL — describe manual + auto legs.
    - SC5 (camera follow + pan-release): PASS / FAIL — describe start, mid-trip pan, stop.
    - SC6 (drive itself passes overall): PASS / FAIL.
    - Any other observations (Samsung-specific quirks, HUD polish requests, unexpected reject reasons in HUD).
    - Screenshots if available (or "not captured" — that's fine, textual report is authoritative).

    If any SC fails: describe the failure — the executor either iterates on the failing plan in Wave 2 or opens a Phase 3.2 gap-closure plan.
  </resume-signal>
</task>

<task type="auto">
  <name>Task 2: Write 03-1-DRIVE-VERIFICATION-<date>.md + update Phase 3 VERIFICATION</name>
  <files>
    .planning/phases/03-1-tracking-fixes/03-1-DRIVE-VERIFICATION-<date>.md
    .planning/phases/03-tracking-mvp/03-VERIFICATION.md
  </files>
  <intent>Capture empirical evidence + cross-link into Phase 3's existing VERIFICATION doc.</intent>
  <action>
    **Step 1 — Drive-verification report.** Create `.planning/phases/03-1-tracking-fixes/03-1-DRIVE-VERIFICATION-<yyyy-mm-dd>.md` using this structure (replace `<date>` with the actual drive date, e.g. `2026-07-07`):

    ```markdown
    # Phase 3.1 · Drive Verification — <date>

    **Device:** Samsung Galaxy S24, Android 14, One UI 7
    **Route:** <describe — km, duration, urban/highway mix>
    **Build:** debug, freshly installed (uninstall + install per Task 1 pre-drive step 1)
    **HUD open:** yes (Settings → Tracking diagnostics)

    ## Success Criteria

    ### SC1 — Debug HUD shipped and shows all listed fields live
    Result: **PASS** / FAIL

    Field-by-field observations:
    | Field | Rendered? | Value at peak trip |
    |-------|-----------|-------------------|
    | facadeReadyOutcome | ✓ | success |
    | facadeCurrentState.enabled | ✓ | true |
    | facadeCurrentState.isMoving | ✓ | true |
    | lastAcceptedFix.ts / lat / lon / accuracy / speedKmh | ✓ | 2026-07-07T…, 52.…, 13.…, 5m, 40 km/h |
    | lastRejected.reason (if any) | — / … | — / accuracy_too_low |
    | lastActivityType / lastActivityAt | ✓ | in_vehicle / 2s ago |
    | acceptCount | ✓ | 800+ |
    | rejectCount | ✓ | N |
    | gapCount / splitCount | ✓ | 0 / 0 |
    | currentTripId | ✓ | 42 (manual) |

    ### SC2 — Manual trip: fix intake ≤3 s, distance + speed update ≤5 s
    Result: **PASS** / FAIL
    - Time from FAB tap to first fix: <X> s
    - Distance/speed panel update cadence: <observed>
    - Polyline persistence at stop: non-zero, <D> m over <T> s

    ### SC3 — Auto trip: pending ≤60 s of in_vehicle, auto-terminate after 2 min dwell
    Result: **PASS** / FAIL
    - Time from motion=true + in_vehicle to pending state: <X> s
    - Time from parking to auto-terminate: <Y> min

    ### SC4 — Persistent notification visible during any active trip; text updates at 30 s cadence
    Result: **PASS** / FAIL
    - Manual trip: notification appeared within <X> s of FAB tap
    - Auto trip: notification appeared within <Y> s of pending state
    - Text update cadence: <observed — 30 s ± n>
    - Lock-screen visibility: yes / no

    ### SC5 — Map camera follows during recording; releases on stop or user-pan
    Result: **PASS** / FAIL
    - Trip start: camera activated MyLocationTrackingMode.trackingCompass? yes / no
    - Mid-trip pan: camera stayed panned? yes / no (should be yes — pan-dismiss precedence)
    - Trip stop: camera released to none? yes / no

    ### SC6 — In-car drive passes and produces a passing verification report
    Result: **PASS** / FAIL — <one-line summary>

    ## Observations

    - <Samsung One UI 7 quirks, if any>
    - <HUD polish requests>
    - <Unexpected reject reasons — e.g. rateLimit at what fraction of fixes>

    ## Comparison with 2026-07-06 failed drive

    | Symptom on 2026-07-06 | Fixed in Phase 3.1? |
    |----------------------|---------------------|
    | Distance/speed stuck at 0 | Fixed (H1 — 03-1-02) |
    | No persistent notification | Fixed (H1 — 03-1-02) |
    | Map camera did not follow | Fixed (H2 — 03-1-03) |
    | Auto-trip silent | Fixed (H1 — 03-1-02) |

    ## Follow-ups

    - <If any SC failed>: describe corrective plan.
    - <If HUD needs polish>: file follow-up but do not gate close.
    - <If Samsung Adaptive Battery still kills FGB in Deep Sleep even with grant>: this is device-vendor-specific and out of Phase 3.1 scope (03-1-RESEARCH §9 Risk 7); note as a known limitation.
    ```

    **Step 2 — Update Phase 3 VERIFICATION.** Edit `.planning/phases/03-tracking-mvp/03-VERIFICATION.md`:
    - Flip the "In-car verification checklist (deferred)" section header to "In-car verification (completed via Phase 3.1)".
    - Cross-link the Phase 3.1 drive report: `See .planning/phases/03-1-tracking-fixes/03-1-DRIVE-VERIFICATION-<date>.md for empirical evidence.`
    - Flip SC1..SC4 from "code-complete, drive-deferred" to "verified in Phase 3.1 drive".
    - Leave SC5 (battery baseline) alone — that's a separate deferred item from Plan 03-07 (60-min battery baseline drive); it was NOT run in Phase 3.1 and stays drive-deferred.

    (SC5-battery is different from Phase 3.1's SC5-camera-follow. Do not conflate. Phase 3's SC5 = battery baseline; Phase 3.1's SC5 = map camera follows.)
  </action>
  <verify>
    New file exists at `.planning/phases/03-1-tracking-fixes/03-1-DRIVE-VERIFICATION-<date>.md` with all SC rows filled in.
    `.planning/phases/03-tracking-mvp/03-VERIFICATION.md` cross-links the new file.
    All 6 Phase 3.1 SC show PASS (or the plan escalates to a Phase 3.2 gap-closure plan for failures).
  </verify>
  <done>
    Drive report captured; Phase 3 VERIFICATION updated with cross-link + SC1..SC4 flipped to verified.
  </done>
</task>

<task type="auto">
  <name>Task 3: Update REQUIREMENTS.md + ROADMAP.md + STATE.md to close Phase 3.1</name>
  <files>
    .planning/REQUIREMENTS.md
    .planning/ROADMAP.md
    .planning/STATE.md
  </files>
  <intent>Flip planning docs to Phase 3.1 = Complete + resolve the STATE blocker + resolve pending todos.</intent>
  <action>
    **Step 1 — REQUIREMENTS.md.** Flip these traceability rows from Pending / partial to Complete:
    - TRK-01 (motion filter for auto-trips)
    - TRK-02 (manual trip start/stop via FAB)
    - TRK-03 (dwell timer for auto-trip termination)
    - TRK-04..TRK-11 (all remaining tracking requirements — check each row is empirically covered by the drive; if any is not, leave that specific row alone and note in follow-ups)
    - QUA-06 (persistent notification present and updated)

    Update the last-updated stamp at the bottom of REQUIREMENTS.md.

    **Step 2 — ROADMAP.md.** Add or update the Phase 3.1 row:
    - `[x] **Phase 3.1: Tracking Fixes**` (or matching phase-header pattern used elsewhere).
    - Under Phase 3.1 Success Criteria, add `**Completed:** <date>` line matching Phase 2/3 pattern.
    - Under Plans, list the 5 Phase 3.1 plans with checkboxes:
      ```
      - [x] 03-1-01-debug-hud-diagnostics-PLAN.md — diagnostics DTO + HUD + counters
      - [x] 03-1-02-fgb-start-and-battery-opt-PLAN.md — H1 + H5 fix
      - [x] 03-1-03-map-camera-follow-PLAN.md — H2 fix
      - [x] 03-1-04-regression-tests-motion-filter-and-cadence-PLAN.md — H3 + H4 regression locks
      - [x] 03-1-05-in-car-verification-and-close-out-PLAN.md — drive verification + close-out
      ```
    - Update Progress table row for Phase 3.1 (add row if it doesn't exist): `5/5` `✓ Complete`.

    Also finalize Phase 3 close-out:
    - Update Phase 3 status if it was "code-complete" → now "Complete (drive-verified via Phase 3.1)".
    - Cross-link Phase 3's row to `.planning/phases/03-1-tracking-fixes/03-1-DRIVE-VERIFICATION-<date>.md`.

    **Step 3 — STATE.md.** Multi-edit:
    - **Remove** the pending-todo line: "Phase 3 close-out (batched in-car drive — consolidated)". Superseded by this drive.
    - **Remove** the Blockers/Concerns entry: "PHASE 3 DRIVE VERIFICATION FAILED (2026-07-06)". Resolved.
    - **Append** to Decisions section a Phase 3.1 close-out block:
      ```
      - Phase 3.1 close-out (<date>): drive-verified on Samsung Galaxy S24 / Android 14 / One UI 7.
        - H1 (FGB.start() dead code): FIXED. 03-1-02 added _facade.start() at three sites.
        - H2 (camera-follow decoupled): FIXED. 03-1-03 wired TrackingCameraSync + fixed the FollowMode→MyLocationTrackingMode mapping.
        - H3 (motion filter): REFUTED per 03-1-RESEARCH — code was correct; 03-1-04 locked in regression.
        - H4 (stateStream cadence): REFUTED per 03-1-RESEARCH — code was correct; 03-1-04 locked in regression.
        - H5 (battery-opt grant): FIXED in 03-1-02 — TrackingCapability now considers ignoreBatteryOptimizations on Android.
        - Debug HUD (03-1-01) proved decisive: without on-device introspection, every fix cycle costs a drive.
        - Phase 5 unblocked. Matcher's golden corpus can now record real trips.
      ```
    - Update "Current focus" line + "Session Continuity" section at the bottom of STATE.md to reflect Phase 3.1 close-out.

    Do NOT touch Phase 4 rows — Phase 4 has its own separate close-out track.
  </action>
  <verify>
    `grep 'TRK-0' .planning/REQUIREMENTS.md | grep -i pending` — zero hits (all TRK requirements flipped).
    `grep 'PHASE 3 DRIVE VERIFICATION FAILED' .planning/STATE.md` — zero hits.
    `grep 'Phase 3.1' .planning/ROADMAP.md | grep -c '\[x\]'` — at least 1 (the phase header) + 5 (plan checkboxes) hits.
    `grep '03-1-DRIVE-VERIFICATION' .planning/phases/03-tracking-mvp/03-VERIFICATION.md` — at least 1 hit.
  </verify>
  <done>
    All three planning docs updated. Phase 3.1 = Complete on ROADMAP; STATE blocker + pending todo removed; REQUIREMENTS TRK-01..11 + QUA-06 flipped.
  </done>
</task>

## Verification

- `.planning/phases/03-1-tracking-fixes/03-1-DRIVE-VERIFICATION-<date>.md` exists and shows PASS on all 6 SC.
- Phase 3 VERIFICATION.md cross-links to the Phase 3.1 drive report.
- REQUIREMENTS.md: TRK-01..11 + QUA-06 all Complete.
- ROADMAP.md: Phase 3.1 marked `[x]` with 5 plan checkboxes filled in; Phase 3 close-out finalized.
- STATE.md: Blocker entry for 2026-07-06 drive removed; pending todo for in-car drive removed; Phase 3.1 close-out decisions block appended.
- `flutter analyze` + `flutter test` both green at repo root (should already be from Waves 1–2; sanity-check).

## SC alignment

- **SC1..SC6:** ALL SATISFIED empirically by the drive itself. This plan does not implement fixes — it verifies that Waves 1 + 2 landed correctly on-device.

## Deviation Handling

- If ANY SC fails on the drive: STOP close-out. Open a Phase 3.2 gap-closure plan (or fold the fix back into a Wave 2 plan and re-drive). Do NOT flip REQUIREMENTS.md rows to Complete on a partial pass.
- If the HUD renders but a field shows stale data (e.g. `lastAcceptedFix` doesn't update after each fix), that's a 03-1-01 defect — file a corrective mini-plan targeting the polling frequency or the getter's data staleness.
- If SC3 auto-trip termination is unreliable due to Samsung Adaptive Battery killing the FGS in Deep Sleep (03-1-RESEARCH §9 Risk 7), that's a device-vendor limitation and a KNOWN gap — flag in the drive report but do not block Phase 3.1 close if manual trips (SC2) work reliably. Note: this is different from H5 (battery-opt grant), which we DO fix.
- If the drive doesn't reproduce the 2026-07-06 route exactly, that's fine — any 15-30 min mixed-driving trip suffices. What matters is: at least one manual trip AND at least one auto-trip observed end-to-end.
- If screenshots of the HUD are impractical (single-phone drive), textual reports are authoritative. Do NOT let screenshot-capture logistics block close.
- This plan is autonomous:false — the executor cannot iterate on the drive. Task 1's checkpoint blocks until the user reports back with results. Tasks 2 + 3 iterate up to 3 times on planning-doc edits.
