---
id: 04-10-1-05
phase: 04-osm-pipeline
plan: 10-1-05
type: execute
wave: 5
depends_on: [04-10-1-04]
files_modified:
  - assets/tiles/germany-base.pmtiles
  - assets/osm/osm.sqlite
  - .planning/STATE.md
  - .planning/REQUIREMENTS.md
  - .planning/ROADMAP.md
  - .planning/phases/04-osm-pipeline/04-VERIFICATION.md
  - .planning/phases/04-osm-pipeline/04-05-BERLIN-MEASUREMENT.md
  - tool/osm_pipeline/README.md
  - .gitignore
autonomous: false
requirements: [OSM-01, OSM-02, OSM-03, OSM-04, OSM-05, OSM-06, OSM-07, OSM-08]

must_haves:
  truths:
    - "Full-Germany pipeline runs end-to-end under the new Option E stack (Feldweg drop + perWay R-Tree + Stage D isolates + progress logging) — projected wall-clock 30-90 min."
    - "osm.sqlite full-Germany < 2.5 GB (SC4 target proposed by this plan: 2.5 GB — buffer for future admin/road growth per research §7.1 estimate of ~1.9-2.5 GB after E.1+E.2)."
    - "germany-base.pmtiles size unchanged from pre-Wave-1 baseline (Feldweg still in the roads layer)."
    - "assets/tiles/germany-base.pmtiles replaces the old dev_germany.pmtiles reference chain — Phase 2 style JSONs and pmtiles_source point at the new name (04-10 already spec'd this; verify)."
    - "04-VERIFICATION.md exists documenting wall-clock, sizes, per-stage timing, PRAGMA user_version=2, row counts per table, per-worker Stage D throughput."
    - "Phase 4 close-out: STATE.md pending-todo for dev_germany.pmtiles replacement resolved; ROADMAP marks Phase 4 [x] with all 8 OSM-0X requirements flipped to Complete; REQUIREMENTS.md traceability rows for OSM-01..OSM-08 all Complete."
    - "flutter test + flutter analyze at repo root remain green after asset swap."
  artifacts:
    - path: ".planning/phases/04-osm-pipeline/04-VERIFICATION.md"
      provides: "Phase 4 close-out verification report — SC1..SC5 with post-Option-E numbers"
    - path: "assets/tiles/germany-base.pmtiles"
      provides: "Runtime pmtiles asset (new Option-E build)"
    - path: "assets/osm/osm.sqlite"
      provides: "Runtime SQLite artifact for Phase 5 (v2 schema, Kfz-only, perWay rtree)"
  key_links:
    - from: ".planning/ROADMAP.md"
      to: ".planning/phases/04-osm-pipeline/04-VERIFICATION.md"
      via: "Phase 4 status row links to VERIFICATION for evidence trail"
      pattern: "04-VERIFICATION"
    - from: "assets/tiles/germany-base.pmtiles"
      to: "assets/map_style_light.json"
      via: "MapLibre style JSON sources.trailblazer.url points at germany-base.pmtiles (already wired per 04-08 + 04-10)"
      pattern: "germany-base.pmtiles"
---

## Goal

Run the full-Germany pipeline under the new Option E stack, verify SC4 fits the newly-proposed 2.5 GB budget, replace the app assets, and CLOSE Phase 4 with a verification report. Same close-out shape as the original 04-10 plan, minus the SC4 renegotiation which this plan handles up front.

## Context

- Source: `.planning/phases/04-osm-pipeline/04-10-1-RESEARCH.md` §7 (post-optimization size projection) and §10 (wave breakdown — this plan is "Wave 6" in research, renumbered to Wave 5 per user decision to skip the stretch).
- Parent plan: `04-10-full-germany-close-out-PLAN.md` — SUPERSEDED by this plan. All of its checkpoint / rename / cleanup / close-out semantics carry over here.
- STATE.md line 257: pending todo — replace dev_germany.pmtiles. This plan resolves it (via germany-base.pmtiles).
- STATE.md line 262: pending todo — 04-10 pmtiles budget re-check. This plan captures the number; pmtiles is unchanged by Option E (Feldweg still in roads layer) so pmtiles size will still be the existing 883 MB. Do NOT try to shrink pmtiles in this plan — a follow-up (`04-10-2-pmtiles-slim`) is where that lever pulls, if pursued.
- STATE.md line 290: SC4 target 800 MB was already renegotiated once. This plan proposes 2.5 GB — avoids a third renegotiation by leaving buffer for future admin/road growth. Rationale below.
- **SC4 proposal:** 2.5 GB (not 1.5 GB). Research §7.1 projects 1.9-2.5 GB after E.1+E.2 (this stack, no stretch). Picking 2.5 GB leaves ~500 MB headroom for: (a) future admin-region L11/L12 additions, (b) organic OSM growth (~5%/year), (c) `way_admin` growth as fraction thresholds tighten, (d) tolerance for measurement noise. Picking 1.5 GB would either fail-close on any of the above OR force a third renegotiation. Rationale text goes in the ROADMAP.md SC4 edit.
- **Autonomous: false** — the Germany run takes real time and the user's disk/PBF. Same checkpoint shape as original 04-10 Task 1.

## Tasks

<task type="checkpoint:human-verify">
  <name>Task 1: Preflight — user supplies Germany PBF path + confirms readiness</name>
  <gate>blocking</gate>
  <what-built>
    - Wave 1-4 code is landed and Berlin-verified.
    - Ready to invoke the full-Germany pipeline.
  </what-built>
  <how-to-verify>
    1. Confirm the Germany PBF is present:
       ```powershell
       Test-Path tool\osm_pipeline\out\germany-latest.osm.pbf
       ```
       If absent:
       ```powershell
       Invoke-WebRequest `
         -Uri "https://download.geofabrik.de/europe/germany-latest.osm.pbf" `
         -OutFile "tool\osm_pipeline\out\germany-latest.osm.pbf"
       ```

    2. Confirm tippecanoe is on PATH in WSL2 (from Plan 04-09 setup).

    3. Confirm disk headroom: ~30 GB free for scratch DB + intermediates.

    4. Reply with the PBF path (absolute) + confirmation to proceed.
  </how-to-verify>
  <resume-signal>Reply with `PBF at <path>; proceed` OR describe any blocker.</resume-signal>
</task>

<task type="checkpoint:human-verify">
  <name>Task 2: Run full-Germany pipeline + capture measurements</name>
  <gate>blocking</gate>
  <what-built>
    - Task 1 confirmed preflight state.
  </what-built>
  <how-to-verify>
    Run from the sub-package:
    ```bash
    cd tool/osm_pipeline
    time dart run bin/osm_pipeline.dart --pbf=out/germany-latest.osm.pbf
    ```

    Expected: --rtree-granularity defaults to perWay, --workers defaults to
    `Platform.numberOfProcessors - 2`. If the executor wants explicit numbers
    (recommended for reproducibility of the VERIFICATION report):
    ```bash
    time dart run bin/osm_pipeline.dart --pbf=out/germany-latest.osm.pbf \
      --rtree-granularity=perWay --workers=8
    ```

    Watch the progress-logger output (Wave 1 machinery) — should see per-stage
    lines every 5s. Stage D should show throughput growing linearly with N
    workers.

    Capture:
    - Wall-clock (target: 30-90 min; escalate if > 3h).
    - Per-stage wall-clock breakdown (from ProgressLogger `finish()` lines).
    - `stat --printf="%s" out/osm.sqlite` — target < 2.5 GB (SC4 proposed).
    - `stat --printf="%s" out/germany-base.pmtiles` — informational (should be ~883 MB baseline).
    - `sqlite3 out/osm.sqlite "PRAGMA user_version;"` → 2.
    - `sqlite3 out/osm.sqlite "SELECT COUNT(*) FROM ways;"` → ~4.07M (Kfz-only).
    - `sqlite3 out/osm.sqlite "SELECT COUNT(*) FROM ways_rtree;"` → ~4.07M (perWay).
    - `sqlite3 out/osm.sqlite "SELECT admin_level, COUNT(*) FROM admin_regions GROUP BY admin_level;"` → per-level breakdown.
    - `sqlite3 out/osm.sqlite "SELECT COUNT(*) FROM way_admin;"` → cross-border rows.
    - `sqlite3 out/osm.sqlite "SELECT * FROM metadata;"` → 7 rows, correct pbf_date + schema_version=2.
    - `wc -l out/skipped.log` → informational.
    - tippecanoe warnings from `[Stage F.2]` prefixed lines.
  </how-to-verify>
  <resume-signal>
    Reply with all captured numbers:
    - Wall-clock: N min
    - Per-stage: B=<t>, C=<t>, D=<t>, E=<t>, F.1=<t>, F.2=<t>
    - osm.sqlite: X GB
    - germany-base.pmtiles: Y MB
    - Kfz ways: A (target ~4.07M)
    - ways_rtree: B (should equal Kfz ways under perWay)
    - Admin per level: [...]
    - way_admin rows: C
    - skipped.log lines: D
    - PRAGMA user_version: 2 (or flag)
    - tippecanoe WARN/ERROR count: N
    Or describe any failure.
  </resume-signal>
</task>

<task type="auto">
  <name>Task 3: Write 04-VERIFICATION.md close-out report</name>
  <files>
    .planning/phases/04-osm-pipeline/04-VERIFICATION.md
    .planning/phases/04-osm-pipeline/04-05-BERLIN-MEASUREMENT.md
  </files>
  <intent>Document empirical evidence that all 5 Phase 4 success criteria are satisfied under Option E.</intent>
  <action>
    Create `04-VERIFICATION.md` — same shape as the parent plan (04-10 Task 2)
    but with Option-E numbers. Sections:

    - Wall-clock (total + per-stage breakdown from progress logger).
    - SC1 — Berlin bbox end-to-end (reference 04-09 Task 4; add Option E Berlin verify numbers from Wave 4 Task 4).
    - SC2 — Kfz ONLY in osm.sqlite ways (per Wave 2 narrowing); Feldweg in pmtiles roads layer only. Admin levels 2/4/6/8/9/10 counts.
    - SC3 — reconciled wording (from 04-10 parent plan Task 2, copy verbatim — the denormalization / way_admin reconciliation is unchanged).
    - **SC4 — 2.5 GB target (post Option E renegotiation).** Include:
      - Proposed target: 2.5 GB.
      - Rationale: research §7.1 projects 1.9-2.5 GB post-E.1+E.2; picking 2.5 GB leaves headroom for admin/road growth (~500 MB) and avoids a third renegotiation. Prior renegotiation: 200 MB → 800 MB (STATE line 290). This is the second: 800 MB → 2.5 GB.
      - Actual measured: X GB.
      - PASS if X < 2.5 GB.
      - pmtiles unchanged from baseline — separate concern (pending followup 04-10.2 if pursued).
    - SC5 — --bbox flag (Berlin smoke). Referenced.
    - Requirements coverage table: OSM-01..OSM-08 all Complete.
    - Option E deltas vs baseline:
      - Feldweg drop → ~50% ways-table shrink.
      - perWay R-Tree → R-Tree cluster 5.15 GB → ~340 MB (~93% shrink).
      - Stage D isolates → wall-clock reduced from ~14h → ~2h (measured).
    - Skipped-log summary + tippecanoe warnings.
    - Follow-ups (if any).

    **Update `04-05-BERLIN-MEASUREMENT.md`:**
    Add a "Post-Option-E addendum (2026-07-07)" section at the bottom:
    - Berlin baseline under Option E: osm.sqlite < 25 MB; ways_rtree = ways rows (perWay = 1:1).
    - The measurement doc's original perSegment recommendation is superseded by the perWay default set in Plan 04-10-1-03.
    - Historical numbers (perSegment, both Kfz + Feldweg) are preserved above; do not delete.
  </action>
  <verify>
    File exists. All 5 SC sections filled with real numbers from Task 2's
    report. SC4 has explicit renegotiation rationale (2.5 GB target).
  </verify>
</task>

<task type="checkpoint:human-verify">
  <name>Task 4: Approve asset swap (dev_germany.pmtiles → germany-base.pmtiles + osm.sqlite)</name>
  <gate>blocking</gate>
  <what-built>
    - Verified osm.sqlite + germany-base.pmtiles from Task 2.
    - VERIFICATION report from Task 3.
  </what-built>
  <how-to-verify>
    Executor is about to:
    - Rename `tool/osm_pipeline/out/germany-base.pmtiles` → `assets/tiles/germany-base.pmtiles`.
    - Rename `tool/osm_pipeline/out/osm.sqlite` → `assets/osm/osm.sqlite`.
    - Update `.gitignore` if not already.
    - Update `lib/features/map/**` (whichever file reads the pmtiles source) — 04-10 parent plan Task 3 already spec'd this; the executor should verify current state and only touch what's needed.

    User: confirm the swap should proceed. Any concerns about the pmtiles
    size (unchanged from baseline, ~883 MB — separate SC4 concern) should be
    raised here.
  </how-to-verify>
  <resume-signal>Reply `approved` or describe concerns.</resume-signal>
</task>

<task type="auto">
  <name>Task 5: Perform asset swap + cleanup</name>
  <files>
    assets/tiles/germany-base.pmtiles
    assets/osm/osm.sqlite
    .gitignore
    tool/osm_pipeline/README.md
  </files>
  <intent>Move artifacts into place; refresh README.</intent>
  <action>
    ```bash
    mkdir -p assets/tiles assets/osm
    cp tool/osm_pipeline/out/germany-base.pmtiles assets/tiles/germany-base.pmtiles
    cp tool/osm_pipeline/out/osm.sqlite            assets/osm/osm.sqlite
    ```

    Update `.gitignore` to cover both artifacts (they should already be
    gitignored per parent plan — verify):
    ```
    assets/tiles/germany-base.pmtiles
    assets/osm/osm.sqlite
    ```

    Update `lib/` map source pointer:
    - Grep: `grep -rn "dev_germany.pmtiles" lib/` — if hits found, change to `germany-base.pmtiles`. Verify style JSONs (`assets/map_style_light.json` and `assets/map_style_dark.json`) already point at `germany-base.pmtiles` (04-08 wrote them this way).
    - Do NOT delete old `assets/tiles/dev_germany.pmtiles` — leave the local file (still gitignored) so re-clones can fall back to `tool/fetch_pmtiles.sh` if the new asset isn't rebuilt yet.

    Update `tool/osm_pipeline/README.md` "Expected timings" section: replace
    the parent plan's projected timings with actual measured post-Option-E
    numbers (wall-clock total + per-stage breakdown). Add a "Option E stack"
    subsection linking to 04-10-1-RESEARCH.md.

    Run `flutter analyze` + `flutter test` at repo root — must remain green.
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test
    ls -la assets/tiles/germany-base.pmtiles assets/osm/osm.sqlite
    ```
    Both files present; both grep as gitignored (`git check-ignore assets/tiles/germany-base.pmtiles assets/osm/osm.sqlite` returns both paths).
  </verify>
</task>

<task type="auto">
  <name>Task 6: Phase 4 close-out — STATE + REQUIREMENTS + ROADMAP</name>
  <files>
    .planning/STATE.md
    .planning/REQUIREMENTS.md
    .planning/ROADMAP.md
  </files>
  <intent>Flip Phase 4 to Complete.</intent>
  <action>
    **`STATE.md`:**
    - Under "Pending todos": strike the `assets/tiles/dev_germany.pmtiles` replacement (line 257) and the 04-10 pmtiles budget recheck (line 262) if resolved; leave the pmtiles-slim follow-up open if pmtiles > 200 MB (which is expected).
    - Add a Phase 4 close-out block near the Phase 4 decisions section:
      ```
      Phase 4 close-out — 2026-07-07 (Option E stack, Plan 04-10.1):
      - Full-Germany run: <T> min wall-clock (Stage D <t_d> min under <N> workers).
      - Artifacts: osm.sqlite <X> GB (SC4 target 2.5 GB — PASS), germany-base.pmtiles <Y> MB (unchanged from baseline; pmtiles SC4 target 200 MB remains an open follow-up).
      - Option E deltas: Feldweg dropped from ways table (Kfz-only), R-Tree perWay default, Stage D N-worker isolates, progress logging.
      - pipelineSchemaVersion = 2.
      - Berlin smoke wall-clock post-E: <T_b> s (SC1 pass); ways_rtree = ways rows (perWay 1:1).
      - SC4 renegotiated (2nd time): 800 MB → 2.5 GB. Rationale in 04-VERIFICATION.md.
      - SC3 reconciliation preserved from parent plan (04-10 Task 2).
      - New pending todo (Phase 5): matcher's findWaysNear must line-clip perWay bbox-hits (see TODO(phase-5) in rtree_builder.dart).
      - Optional followup (Phase 4.2 or later): pmtiles-slim pass — drop Feldweg from pmtiles too if 200 MB SC4 is prioritized. Deferred per user decision to ship at ~2 GB osm.sqlite.
      ```

    **`REQUIREMENTS.md`:**
    - Flip OSM-01..OSM-08 traceability rows from Pending → Complete.
    - Update the last-updated line at bottom to `2026-07-07 (Plan 04-10.1)`.

    **`ROADMAP.md`:**
    - Line 19: `[ ] **Phase 4: OSM Pipeline**` → `[x] **Phase 4: OSM Pipeline**`.
    - Under Phase 4 Success Criteria: change SC4 to reflect the 2.5 GB target (this is the second renegotiation, matches the STATE.md close-out note):
      ```
      4. A full-Germany run keeps `osm.sqlite` under **2.5 GB**, with a version stamp (source PBF date + pipeline_schema_version). The `germany-base.pmtiles` portion of the original SC4 (200 MB) is **explicitly deferred to Plan 04-10.2 (pmtiles-slim)** — Option E did not touch pmtiles, so pmtiles remains at ~883 MB (Feldweg still in the roads layer for base geometry per REN-02). Deferral tracked in STATE.md pending-todos; not a Phase 4 close blocker. *(SC4 osm.sqlite target relaxed 2026-07-07 from 800 MB → 2.5 GB after Option E measured full-Germany at ~<X> GB post-Feldweg-drop + perWay R-Tree. Rationale: leaves ~500 MB headroom for admin/road growth; avoids a third renegotiation. Details in `.planning/phases/04-osm-pipeline/04-VERIFICATION.md` and `.planning/phases/04-osm-pipeline/04-10-1-RESEARCH.md` §7.)*
      ```
    - Add `**Completed:** 2026-07-07` line matching the Phase 2/3 pattern.
    - **Do NOT edit SC3 wording** (per parent plan reconciliation note; unchanged from 04-10).
    - Under `Plans:` for Phase 4, keep the existing 10 rows (add checkmarks) and append the 5 Option E plans:
      ```
      - [x] 04-10-1-01-progress-logging-PLAN.md — ProgressLogger + stage instrumentation
      - [x] 04-10-1-02-feldweg-drop-PLAN.md — Kfz-only osm.sqlite; pipelineSchemaVersion=2
      - [x] 04-10-1-03-perway-rtree-PLAN.md — R-Tree perWay default + CLI flag
      - [x] 04-10-1-04-stage-d-isolates-PLAN.md — Stage D N-worker isolates
      - [x] 04-10-1-05-germany-close-out-PLAN.md — full-Germany rerun + Phase 4 close
      ```
    - Update the Progress table row for Phase 4: `15/15` and `✓ Complete`.
    - Mark the original 04-10 plan as SUPERSEDED by 04-10.1 in its checkbox line comment (or leave it [x] with a note; both fine).
  </action>
  <verify>
    ```bash
    grep -n "\[ \] \*\*Phase 4:" .planning/ROADMAP.md      # 0 matches
    grep -n "\[x\] \*\*Phase 4:" .planning/ROADMAP.md      # 1 match
    grep -n "800 MB → 2.5 GB" .planning/ROADMAP.md         # 1 match
    grep -n "OSM-08" .planning/REQUIREMENTS.md | grep -i "Complete"
    ```
  </verify>
</task>

## Success Criteria

- Full-Germany pipeline runs to completion under the new stack; wall-clock < 3h (target 30-90 min).
- osm.sqlite < 2.5 GB (SC4 proposed target).
- osm.sqlite `PRAGMA user_version` = 2.
- `ways_rtree` rows = `ways` rows (perWay invariant).
- REQUIREMENTS.md OSM-01..OSM-08 all Complete.
- ROADMAP.md Phase 4 flipped to [x]; SC4 wording updated to 2.5 GB with rationale.
- STATE.md pending todos for asset replacement + pmtiles-budget-recheck resolved (or explicitly deferred).
- `flutter analyze` + `flutter test` at repo root green.
- Manual: app opens on a device; map renders (Berlin admin regions visible = cross-check that the new pmtiles loaded).

## Ralph Loop

- Tight loop: `flutter analyze` at repo root after Task 5 asset swap.
- Behavior-sensitive: `flutter test` after Task 5.
- Pre-push covers the boundary.

## Deviations

- If Germany osm.sqlite > 2.5 GB: this is a soft-fail. Options: (a) accept + push SC4 higher (third renegotiation; document rationale); (b) invoke the deferred stretch (varint geometry_wkb, drop L9/L10, drop admin_regions WKB — research §7.1). Prefer (b) if pursuing; escalate to user with actual size + proposal.
- If Germany run > 3h under N=8 workers: something regressed. Compare Berlin (Wave 4 Task 4) → Germany scaling. Likely culprit: Stage F.1 (GeoJSONSeq emit) — not parallelized. If Stage D dominates, check worker balance (round-robin partition may be unlucky; try id-range partition instead).
- If pmtiles size > 200 MB (expected — Feldweg still in): do NOT block Phase 4 close. Document as an open follow-up plan (04-10.2 pmtiles-slim) and mark the pmtiles portion of SC4 as "open follow-up" in the ROADMAP edit.
- If flutter test breaks due to a widget test hard-coding the old `dev_germany.pmtiles` string: fix the test to read the new asset name; not a regression, just a hardcoded string.
- If the user's dev disk lacks ~30 GB for scratch: pause at Task 1; do not force-run.

## Commit Strategy

- Task 3: `docs(04-10-1-05): write 04-VERIFICATION.md + Berlin measurement addendum`
- Task 5: `chore(04-10-1-05): swap in germany-base.pmtiles + osm.sqlite assets; update README`
- Task 6: `docs(04-10-1-05): close Phase 4 — SC4 → 2.5 GB, OSM-01..08 Complete, ROADMAP [x]`
- Final metadata commit at very end: `docs(04-10-1): plan Option E execution — Phase 4 CLOSED`
