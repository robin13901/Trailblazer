---
id: 03-07
phase: 03-tracking-mvp
plan: 07
type: execute
wave: 4
depends_on: [03-06]
files_modified:
  - tool/battery_baseline.dart
  - docs/battery-baseline.md
  - docs/battery-baseline.json
  - .planning/phases/03-tracking-mvp/03-VERIFICATION.md
  - .planning/STATE.md
  - .planning/ROADMAP.md
autonomous: false
requirements_addressed: [QUA-06, TRK-01, TRK-04, TRK-05, TRK-09, TRK-10, TRK-11]

user_setup: []

must_haves:
  truths:
    - "`tool/battery_baseline.dart` is executable via `dart run tool/battery_baseline.dart` — reads adb `dumpsys batterystats`, extracts app UID drain estimate, emits Markdown table row + JSON"
    - "`docs/battery-baseline.md` contains a full baseline entry: device (Samsung Galaxy S24), OS (Android 14), commit SHA, 60 min duration, start/end battery %, drain rate %/hour, mAh estimate, profile, screen state, notification state"
    - "`docs/battery-baseline.json` mirrors the Markdown table as machine-readable data for a future CI regression check"
    - "Regression threshold ( > 20% drain-rate increase ) is documented in the Markdown"
    - "03-VERIFICATION.md follows the Phase 2 template (5 success criteria checked off with evidence lines)"
    - "STATE.md is updated with the Phase 3 close-out decisions; ROADMAP.md flips Phase 3 to `[x] complete` with the completion date"
    - "The 60-min drive is a REAL drive on the S24, not emulator; the artifact reflects a genuine measurement"
  artifacts:
    - path: "tool/battery_baseline.dart"
      provides: "adb-driven measurement CLI"
      contains: "dumpsys"
    - path: "docs/battery-baseline.md"
      provides: "Human-diffable baseline artifact"
      contains: "Samsung Galaxy S24"
    - path: "docs/battery-baseline.json"
      provides: "Machine-diffable baseline artifact"
    - path: ".planning/phases/03-tracking-mvp/03-VERIFICATION.md"
      provides: "Phase 3 success-criteria verification record"
  key_links:
    - from: "docs/battery-baseline.md"
      to: "tool/battery_baseline.dart"
      via: "'## Repro' section referencing the CLI"
      pattern: "battery_baseline.dart"
---

<objective>
Close out Phase 3. Ship the `tool/battery_baseline.dart` CLI, run the 60-minute drive on the Samsung S24, capture the artifact pair (Markdown + JSON), fill in `03-VERIFICATION.md` against ROADMAP.md's 5 success criteria, and update STATE.md + ROADMAP.md.

Purpose: QUA-06 (60-minute baseline artifact committed). Also serves as the phase's on-device sign-off — auto-trip start, 2-min dwell auto-stop, notification live-updating over the drive, and cold-start hydration are all validated in one continuous session.

Output: Two-step plan. Task 1 (autonomous) writes the CLI + placeholder artifact docs. Task 2 (checkpoint:human-action) is the real drive, which the user performs and reports numbers from — Claude cannot drive a car. Task 3 (autonomous) fills in the artifacts + VERIFICATION.md + STATE.md/ROADMAP.md updates using the user-provided numbers.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/STATE.md
@.planning/ROADMAP.md
@.planning/REQUIREMENTS.md
@.planning/phases/03-tracking-mvp/03-CONTEXT.md
@.planning/phases/03-tracking-mvp/03-RESEARCH.md

# Reference: how Phase 2 wrote its verification doc
@.planning/phases/02-map-glass-shell/02-VERIFICATION.md

# Package name is `auto_explore`.
</context>

<tasks>

<task type="auto">
  <name>Task 1: `tool/battery_baseline.dart` CLI + placeholder artifact docs</name>
  <files>
    - tool/battery_baseline.dart
    - docs/battery-baseline.md
    - docs/battery-baseline.json
  </files>
  <action>
    1. `tool/battery_baseline.dart` — a Dart CLI runnable via `dart run tool/battery_baseline.dart`:
       - Uses `dart:io` `Process.run('adb', ['shell', 'dumpsys', 'batterystats', '--charged'])`.
       - Accepts CLI flags:
         - `--device <serial>` (optional; if absent, uses the default adb device)
         - `--app-id <id>` (default `de.autoexplore.auto_explore` — STATE.md 01-07 says the Android applicationId is stable)
         - `--duration-min <int>` (metadata for the emitted rows; default 60)
         - `--commit <sha>` (optional; if absent, runs `git rev-parse --short HEAD`)
         - `--reset` (if set, runs `adb shell dumpsys batterystats --reset` and exits, so the user can call it at the START of the drive)
         - `--emit` (default action; parses batterystats and emits Markdown + JSON to stdout)
       - Parsing:
         - Grep for the app's UID line via a regex like `Uid \d+ .* $APP_ID.*: (.*)`
         - Extract `Estimated power use \(mAh\): \d+(\.\d+)?` for that UID
         - Read `start.battery_pct` and `end.battery_pct` — batterystats provides `Battery History Start Power` etc.; if the exact fields prove fragile, fall back to `adb shell dumpsys battery` snapshots at start and end (call CLI twice — once before drive with `--snapshot-start`, once after with `--snapshot-end` — and diff the JSON snapshots).
       - **Recommended simpler UX (implement this):** three sub-commands:
         - `dart run tool/battery_baseline.dart start` → resets batterystats + records `docs/.battery-baseline.tmp.json` with start battery % + timestamp + git sha
         - `dart run tool/battery_baseline.dart stop` → reads current battery %, timestamp, computes drain, reads batterystats for mAh, WRITES the final `docs/battery-baseline.json` and appends a Markdown row to `docs/battery-baseline.md`
         - `dart run tool/battery_baseline.dart status` → prints current battery + elapsed time (for mid-drive sanity check)
       - Error handling: wrap `Process.run` in try/catch; if adb is missing, print a helpful error mentioning the Android SDK Platform Tools install + PATH.
       - Output MAY be shell-diffable — do not print colored output when `stdout.terminal.hasTerminal == false`.

    2. `docs/battery-baseline.md` — placeholder now, filled with real data in Task 3:
       ```markdown
       # Battery baseline — Trailblazer tracking (Phase 3)

       Regression threshold: any change that increases the drain rate by > 20% (relative)
       vs the reference row below must be justified and re-baselined.

       ## Reference measurement — Phase 3 close-out

       | Metric | Value |
       |---|---|
       | Device | Samsung Galaxy S24 (SM-S921B) |
       | OS | Android 14 (build TBD) |
       | App version | 0.1.0+1 |
       | Commit | TBD |
       | Recorded | TBD |
       | Duration | 60 min |
       | Start battery % | TBD |
       | End battery % | TBD |
       | Drain % | TBD |
       | Drain rate | TBD %/hour |
       | Est. mAh (S24 4000 mAh) | TBD |
       | Build mode | debug (Android release-license not procured yet — STATE.md 01-01/01-05) |
       | Screen state | off during the drive |
       | Notification | live-stats visible throughout |
       | Profile | 20 min urban + 20 min Landstraße + 20 min Autobahn |

       ## Repro

       1. Charge the device to 100%; unplug it.
       2. `flutter run --debug --flavor prod` on the device (or `flutter install --debug` and launch by hand).
       3. Grant all permissions in the onboarding ladder (whenInUse + Always + Notification + battery-optimization exemption).
       4. On the map, tap the FAB to start a manual trip (auto-detection also captures if you drive off before tapping).
       5. Drive the 20/20/20 profile above; keep the screen off (Trailblazer's notification will keep the FGS alive).
       6. After ~60 minutes, tap the red Stop FAB to close the trip.
       7. From a laptop with adb access:
          ```
          adb devices           # verify the S24 is listed
          dart run tool/battery_baseline.dart stop
          ```
       8. Review the emitted row; commit `docs/battery-baseline.md` + `docs/battery-baseline.json`.

       ## Regression history

       (Rows will accumulate here in future phases as we re-baseline.)
       ```

    3. `docs/battery-baseline.json` — placeholder:
       ```json
       {
         "reference": {
           "device": "Samsung Galaxy S24 (SM-S921B)",
           "os": "Android 14",
           "app_version": "0.1.0+1",
           "commit": "TBD",
           "recorded": "TBD",
           "duration_min": 60,
           "start_battery_pct": null,
           "end_battery_pct": null,
           "drain_pct": null,
           "drain_rate_pct_per_hour": null,
           "mah_est": null,
           "build_mode": "debug",
           "screen_state": "off",
           "notification": "live-stats",
           "profile": "20 min urban + 20 min Landstraße + 20 min Autobahn"
         },
         "regression_threshold_relative_pct": 20,
         "history": []
       }
       ```

    Anti-patterns to avoid:
    - Do NOT commit `docs/.battery-baseline.tmp.json` — add it to `.gitignore` explicitly.
    - Do NOT run the CLI on macOS-only assumptions; adb is cross-platform.
    - Do NOT parse the entire `dumpsys batterystats` output into a struct — it's massive. Grep specific lines only.
  </action>
  <verify>
    - `dart analyze tool/battery_baseline.dart` clean
    - `dart run tool/battery_baseline.dart status` runs without stack trace (may print "no adb device" — that's fine, that path is exercised via error message check)
    - `flutter analyze` clean across the whole tree
    - Placeholder docs commit cleanly with `TBD` fields
  </verify>
  <done>
    CLI ready; artifact templates in place with the "TBD" fields waiting for the real numbers from Task 2.
  </done>
</task>

<task type="checkpoint:human-action" gate="blocking">
  <name>Task 2: Run the 60-minute real-driving baseline</name>
  <what-built>
    A ready CLI and artifact template. Claude cannot drive; the user runs the drive and reports numbers.
  </what-built>
  <how-to-verify>
    (This is truly manual — no CLI can automate driving a car.)

    Prep:
    1. Confirm you're on a version of `main` that has plans 03-01..03-06 merged and green.
    2. Charge the S24 to 100%; unplug. Note the exact start battery %.
    3. Ensure adb sees the device: `adb devices`.
    4. `flutter install --debug` OR `flutter run --debug` (keep the run alive if you want live logs).
    5. Grant all onboarding permissions (whenInUse, Always, Notification, battery-optimization exemption).
    6. From a laptop:
       ```
       dart run tool/battery_baseline.dart start
       ```
       (This resets batterystats and stamps the start-of-drive metadata.)

    Drive:
    7. Get in the car. Tap the FAB to start a manual trip (or drive off and let auto-detect fire — both paths should work; the baseline records whichever ran).
    8. Drive the profile: 20 min urban → 20 min Landstraße → 20 min Autobahn. Screen off. Do not touch the phone mid-drive.
    9. Watch (before setting the phone down) that the notification says "Recording · MM:SS · X.X km · N km/h" and updates.
    10. At ~60 min elapsed, tap the red Stop FAB.

    Post-drive:
    11. Note the exact end battery %.
    12. From the laptop:
        ```
        dart run tool/battery_baseline.dart stop
        ```
        This should:
        - Read current battery + timestamp
        - Compute drain %, drain rate, elapsed minutes
        - Read `dumpsys batterystats` for the mAh estimate
        - Rewrite `docs/battery-baseline.json` with real values + append the Markdown row
    13. If the CLI errored on any field (RESEARCH.md flagged this parsing as tricky), copy the raw `adb shell dumpsys batterystats --charged` output into `docs/battery-baseline.raw.txt` (gitignored) and hand the numbers off in the resume signal below.

    Also observe (for the VERIFICATION doc in Task 3):
    - Did an auto-trip start on its own (before you tapped FAB)? (TRK-01 SC2)
    - Did the notification stay visible the whole drive? (TRK-11 SC4)
    - After stopping, is there a `pending` trip row in the DB with polyline + summary? (TRK-05 SC1)
    - Did the live-tracking overlay reappear correctly if you toggled to the app during a stop? (TRK-09 SC3)
    - Did any permission prompt re-fire mid-drive? (should be NO — TRK-10)

  </how-to-verify>
  <resume-signal>
    Provide the numbers (start %, end %, elapsed minutes, mAh if CLI parsed it, notes on the observations above) OR type "cli-worked" if the tool wrote the artifacts for you directly.
  </resume-signal>
</task>

<task type="auto">
  <name>Task 3: Finalize artifacts + VERIFICATION.md + STATE.md + ROADMAP.md</name>
  <files>
    - docs/battery-baseline.md
    - docs/battery-baseline.json
    - .planning/phases/03-tracking-mvp/03-VERIFICATION.md
    - .planning/STATE.md
    - .planning/ROADMAP.md
  </files>
  <action>
    1. Using the numbers from Task 2's resume signal, replace all `TBD` fields in `docs/battery-baseline.md` and `docs/battery-baseline.json`. Compute:
       - `drain_pct = start_pct - end_pct`
       - `drain_rate_pct_per_hour = drain_pct / (duration_min / 60)`
       - `mah_est` = if provided by CLI, use verbatim; else compute `drain_pct/100 * 4000` (nominal S24 battery)

    2. Create `.planning/phases/03-tracking-mvp/03-VERIFICATION.md` following the Phase 2 template. Fill in the 5 success criteria from ROADMAP.md Phase 3:
       - **SC1 (manual FAB round-trip → pending trip in DB with polyline + summary)** — evidence: on-device observation from Task 2 step 10; DB inspection via debug print or SQL query.
       - **SC2 (auto-trip runs in background > 60 s and auto-terminates after 2 min non-automotive dwell)** — evidence: Task 2 observation of auto-start; note if dwell auto-termination was observable during the drive (it may only fire post-drive when the car is parked, so document the observed condition — the code path is unit-tested via 03-04 test).
       - **SC3 (live-tracking overlay visible during any active trip)** — evidence: 03-06 checkpoint approval + Task 2 mid-drive glance.
       - **SC4 (whenInUse→Always ladder + Android FGS + persistent notification + battery-opt prompt)** — evidence: 03-05 checkpoint approval + all four permissions granted per Task 2.
       - **SC5 (60-min battery-drain baseline committed)** — evidence: `docs/battery-baseline.md` + `docs/battery-baseline.json` committed with real numbers.
       - Include a G-gate section: no P3 gate was active — G1 was resolved in P2. Note in a "Phase gates" section.
       - Include a "TRK-06 deferred to Phase 9" note (per CONTEXT); bluetooth_hint column exists and is NULL for every P3 write.
       - Include a "Real-device coverage: Android (S24) only; iOS deferred per STATE.md pending todos" note.

    3. Update `.planning/STATE.md`:
       - Bump the header to Phase 3 COMPLETE with today's date
       - Add Phase 3 close-out decisions to the Decisions section (mirror the Phase 2 close-out entries' style):
         - FGB 5.3.0 installed; Phase-1 placeholder `<service>` deleted; iOS UIBackgroundModes gains `fetch`
         - Facade seam (`BackgroundGeolocationFacade`) is the sole FGB import site in the tree
         - Pure-Dart ingestor + batcher + Haversine cover accuracy/gap/split/keeper logic 100%
         - TrackingService owns manual/auto/dwell/resume timers; `TrackingNotifier` is a thin Riverpod adapter
         - Permission ladder (3 pages) replaces P1 single-Continue; capability persisted; yellow banner is the ONLY recovery path
         - FAB morphs Start↔Stop; LiveTrackingPanel above the bottom-nav pill; 30 s notification updater lives in TrackingService
         - Battery baseline: drain rate X %/hour on S24 Android 14 (debug); regression threshold 20% relative
         - iOS blue-bar cannot show custom text — documented; live-stats notification is Android-only
         - Trip keeper thresholds (60 s / 100 m / 50 m bbox diagonal) drop micro-trips silently — raw GPS not retained
         - Manual trips ignore dwell (TRK-03); only Stop FAB ends a manual trip
       - Update the Progress table: Phase 3 → 7/7 plans complete
       - Update the pending todos:
         - iOS device pass still deferred (banner, onboarding pages, panel/FAB morph)
         - Release-mode baseline deferred until Android FGB license procured
         - Golden trip corpus (P5) still open — P3 didn't produce recorded drives yet

    4. Update `.planning/ROADMAP.md`:
       - Phase 3 row: `[ ]` → `[x]`, add completion date
       - Fill the "Plans: TBD (5–8)" line with "7 plans" and the plan filename list, mirroring the Phase 1 / Phase 2 style:
         - `[x] 03-01-drift-v2-trip-repository-PLAN.md — Drift v2 migration + TripsDao/Repository`
         - `[x] 03-02-trip-fix-ingestor-PLAN.md — pure-Dart ingestor + Haversine + batcher`
         - `[x] 03-03-fgb-install-facade-PLAN.md — FGB install + facade seam`
         - `[x] 03-04-tracking-service-notifier-PLAN.md — TrackingService + Riverpod notifier`
         - `[x] 03-05-permission-ladder-banner-PLAN.md — permission ladder + yellow banner`
         - `[x] 03-06-fab-morph-live-panel-PLAN.md — FAB morph + live panel + 30 s notification`
         - `[x] 03-07-phase-verification-battery-baseline-PLAN.md — battery baseline + phase close-out`
       - Update the progress table Phase 3 row: `7/7`, `✓ Complete`, today's date.

    5. `flutter analyze` + `flutter test` full-run — both must be green before committing.

    Anti-patterns to avoid:
    - Do NOT fabricate battery numbers if Task 2's resume signal was ambiguous — go back and ask the user for the specific % values.
    - Do NOT declare SC2 fully verified if the auto-termination path was not observed during the drive — mark it "code-path verified in 03-04 tests; on-device continuous observation deferred to Phase 11 hardening".
    - Do NOT close TRK-06 — it's DEFERRED to Phase 9; VERIFICATION.md must say so.
  </action>
  <verify>
    - `flutter analyze` clean
    - `flutter test` full suite green
    - `03-VERIFICATION.md` has 5 SC entries with evidence
    - STATE.md + ROADMAP.md reflect Phase 3 complete
    - Baseline docs have no `TBD` markers left
  </verify>
  <done>
    Phase 3 signed off with a real battery number, 5 SCs verified (with any caveats explicit), STATE + ROADMAP updated.
  </done>
</task>

</tasks>

<verification>
- `flutter analyze` clean
- `flutter test` full suite green
- `docs/battery-baseline.{md,json}` populated with real data
- `03-VERIFICATION.md` created following Phase 2 template
- STATE.md and ROADMAP.md reflect Phase 3 close-out
- Commit: `docs(03): close out Phase 3 tracking MVP + battery baseline`
</verification>

<success_criteria>
- ROADMAP.md Phase 3 marked `[x]` with 5 success criteria verified
- Battery baseline artifact committed and re-runnable via `tool/battery_baseline.dart`
- STATE.md carries Phase 3's ~10 decisions forward for Phase 4+
- All TRK-01/02/03/04/05/07/08/09/10/11 + QUA-06 requirement checkboxes flippable to `[x]` in REQUIREMENTS.md
- TRK-06 explicitly deferred to Phase 9 (bluetooth_hint column exists, always NULL in P3)
</success_criteria>

<output>
After completion, create `.planning/phases/03-tracking-mvp/03-07-SUMMARY.md`
</output>
