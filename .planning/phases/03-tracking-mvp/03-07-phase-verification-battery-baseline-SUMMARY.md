---
phase: 03-tracking-mvp
plan: "07"
subsystem: verification
tags: [battery-baseline, cli, verification, phase-close-out, drive-deferred]

# Dependency graph
requires:
  - phase: 03-tracking-mvp
    plans: [01, 02, 03, 04, 05, 06]
    provides: All Phase 3 code deliverables (TrackingService, ingestor, facade, ladder, FAB morph, live panel)
provides:
  - tool/battery_baseline.dart — adb-backed battery drain measurement CLI (start/stop/status sub-commands)
  - docs/battery-baseline.md — placeholder with device spec, methodology, repro, PENDING numeric fields
  - docs/battery-baseline.json — placeholder with null numeric fields + pending_note
  - .planning/phases/03-tracking-mvp/03-VERIFICATION.md — Phase 3 SC1–SC4 code-complete evidence + SC5 drive-blocked
  - .planning/STATE.md — Phase 3 close-out position + decisions
  - .planning/ROADMAP.md — Phase 3 marked code-complete (in-car verification deferred)
  - .planning/REQUIREMENTS.md — TRK-01..11 + QUA-06 marked Code-Complete (drive-deferred)
affects:
  - Phase 11 Hardening (SC5 battery baseline will be the Phase 11 regression reference once filled in)
  - Batched in-car drive session (items in 03-VERIFICATION.md "In-car verification checklist")

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "battery_baseline.dart sub-command pattern: start/stop/status — start resets batterystats + stamps tmp JSON; stop reads end state + writes both artifact files; status prints mid-drive sanity check"
    - "Artifact scaffold with PENDING markers: commit both files immediately with placeholder values; drive fills them in later via the CLI overwrite"

key-files:
  created:
    - tool/battery_baseline.dart
    - docs/battery-baseline.md
    - docs/battery-baseline.json
    - .planning/phases/03-tracking-mvp/03-VERIFICATION.md
    - .planning/phases/03-tracking-mvp/03-07-phase-verification-battery-baseline-SUMMARY.md
  modified:
    - .planning/ROADMAP.md
    - .planning/STATE.md
    - .planning/REQUIREMENTS.md

key-decisions:
  - "Drive deferred: 03-07 Task 2 (60-min battery baseline drive) and 03-06 Task 3 (9 on-device visual checks) deferred to a batched in-car session. SC5 is drive-blocked; SCs 1–4 are code-complete."
  - "Artifact scaffold pattern: create artifact files with PENDING markers so CLI can fill them on the drive without additional git surgery"
  - "Phase 3 declared code-complete 2026-07-05 on the strength of 141 passing widget/unit tests + on-device permission-ladder approval"

# Metrics
duration: partial-close (Task 1 shipped; Task 2 deferred; Task 3 partial)
completed: 2026-07-05
---

# Phase 3 Plan 07: Phase Verification + Battery Baseline Summary

**`tool/battery_baseline.dart` CLI shipped; artifact scaffold committed with PENDING markers for numeric fields; `03-VERIFICATION.md` created with 4/5 SC code-complete and SC5 drive-blocked; Phase 3 declared code-complete 2026-07-05**

## Performance

- **Duration:** Partial close (Task 1 complete; Task 2 deferred; Task 3 partial)
- **Completed:** 2026-07-05
- **Tasks:** 1/3 fully complete (Task 1 CLI + scaffold); Task 3 partially complete (VERIFICATION.md + STATE/ROADMAP updates done; drive-dependent fields left as PENDING)
- **Task 2:** Deferred — 60-min in-car baseline drive batched with other phases' drive-verification needs

## Accomplishments

### Task 1 (complete): Battery baseline CLI + artifact scaffold

- `tool/battery_baseline.dart` — runnable via `dart run tool/battery_baseline.dart <start|stop|status>`
  - `start`: resets `adb shell dumpsys batterystats --reset`, stamps `docs/.battery-baseline.tmp.json` with start battery %, timestamp, git SHA
  - `stop`: reads end battery %, computes drain + rate + mAh estimate (batterystats or `drain_pct/100 * 4000` fallback), overwrites both artifact files with real values
  - `status`: prints elapsed time + current battery + drain so far (mid-drive sanity check)
  - Error handling: wraps `Process.run('adb', ...)` in try/catch; prints helpful install hint if adb is missing
  - Cross-platform: works on Windows (dev box), macOS, Linux
  - `dart analyze tool/battery_baseline.dart` clean (0 issues)
- `docs/battery-baseline.md` — scaffold with device spec (Samsung Galaxy S24, SM-S921B), methodology section, FGB config at measurement time, known caveats (debug build ~10–15% CPU overhead vs release), repro steps, regression threshold (> 20% relative drain rate increase)
- `docs/battery-baseline.json` — scaffold with null numeric fields + `pending_note` string

### Task 3 (partial): VERIFICATION.md + STATE/ROADMAP/REQUIREMENTS updates

- `03-VERIFICATION.md` created following Phase 2 `02-VERIFICATION.md` shape:
  - SC1 (manual FAB round-trip): CODE-COMPLETE — evidence: TripsRepository test (4 cases) + TrackingService test (cases 1–4) + TripFab widget test (7 cases)
  - SC2 (auto-trip + 2-min dwell): CODE-COMPLETE — evidence: TrackingService test (cases 5–8) with injected timers; drive verifies real motion classification
  - SC3 (LiveTrackingPanel): CODE-COMPLETE — evidence: live_tracking_panel_test (3 cases) + glass_shell_layout_test update
  - SC4 (permission ladder + FGS + notification + battery-opt): CODE-COMPLETE — evidence: onboarding_ladder_test (9 cases) + permission_denial_banner_test (4 cases) + TrackingService notification case 11; on-device ladder approved 2026-07-05 (S24, Android 14)
  - SC5 (battery baseline): DRIVE-BLOCKED — CLI ready, scaffold in place, awaits real drive
  - Phase gate section: G1 resolved in Phase 2; G2 open for Phase 7; no P3-specific gate
  - TRK-06 deferred to Phase 9 documented
  - iOS device gap documented
  - Full in-car verification checklist (18 items) consolidated from 03-06 Task 3 (9 steps) + 03-07 Task 2

## Task Commits

Bundled into two commits per the close-out instruction:

1. **Commit A (03-07 close-out):** `tool/battery_baseline.dart` + `docs/battery-baseline.md` + `docs/battery-baseline.json` + 03-07 PLAN + 03-07 SUMMARY
2. **Commit B (Phase 3 close-out):** `03-VERIFICATION.md` + `ROADMAP.md` + `STATE.md` + `REQUIREMENTS.md`

## Deferred Verification

**Task 2 (60-min baseline drive) and Task 3 numeric fields are explicitly deferred** to a batched in-car drive session.

The user deferred 03-06 Task 3 (9 on-device visual checks) AND 03-07 Task 2 (60-min battery baseline drive) to be run together with other phases' drive-verification needs. Claude cannot drive a car.

### What the drive still needs to fill in:

| Item | How |
|------|-----|
| SC5 — start battery % | `battery_baseline.dart start` reads it from `adb shell dumpsys battery` |
| SC5 — end battery % | `battery_baseline.dart stop` reads it |
| SC5 — mAh estimate | `battery_baseline.dart stop` parses `dumpsys batterystats` or falls back to `drain_pct/100 * 4000` |
| SC5 — commit SHA + recorded date | `battery_baseline.dart stop` reads from `git rev-parse --short HEAD` + `DateTime.now()` |
| SC1 evidence (real DB row) | Debug log from `TripsRepository.closeTrip` on device |
| SC2 evidence (auto-start observed) | Watch for auto-trip start before FAB tap |
| SC3 evidence (real-time updates) | Observe panel counting up during drive |
| SC4 evidence (notification persists) | Screen off for 60 s; notification visible on unlock |
| 03-06 Task 3 steps 1–9 | FAB morph, panel, notification, distance, stop flow, micro-trip guard |

Full checklist lives in `03-VERIFICATION.md` → "In-car verification checklist (deferred)" section.

### After the drive, update:
1. `docs/battery-baseline.md` — PENDING fields → real values (CLI does this automatically)
2. `docs/battery-baseline.json` — null fields → real values (CLI does this automatically)
3. `03-VERIFICATION.md` — SC5 DRIVE-BLOCKED → PASS with evidence; add drive observations to SC1–SC4
4. `REQUIREMENTS.md` — QUA-06 → Complete (was Code-Complete drive-deferred)
5. `ROADMAP.md` — remove "in-car verification deferred" annotation; mark Phase 3 fully verified

## Issues Encountered

None — Task 1 executed cleanly. `dart analyze tool/battery_baseline.dart` clean on first pass.

## Next Phase Readiness

- Phase 3 code is complete: all 141 tests green, `flutter analyze` 0 issues
- `tool/battery_baseline.dart` ready for the drive
- Phase 4 (OSM Pipeline) can begin — it is a dev-machine deliverable independent of Phases 2/3
- Phase 11 Hardening will use SC5 battery baseline as the regression reference

---
*Phase: 03-tracking-mvp*
*Completed (code): 2026-07-05*
*Drive verification: deferred*
