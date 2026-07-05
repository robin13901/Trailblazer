---
id: 04-10
phase: 04-osm-pipeline
plan: 10
type: execute
wave: 8
depends_on: [04-09]
files_modified:
  - assets/tiles/dev_germany.pmtiles
  - assets/osm/osm.sqlite
  - .planning/STATE.md
  - .planning/REQUIREMENTS.md
  - .planning/ROADMAP.md
  - .planning/phases/04-osm-pipeline/04-VERIFICATION.md
  - tool/osm_pipeline/README.md
  - .gitignore
autonomous: false
requirements: [OSM-06]

must_haves:
  truths:
    - "Full-Germany pipeline run produces osm.sqlite < 200 MB AND germany-base.pmtiles < 200 MB — SC4 gate is empirically PASS"
    - "assets/tiles/dev_germany.pmtiles is REPLACED with the new germany-base.pmtiles output (or renamed and the app's PMTiles source URL updated); the old Protomaps-derived 371 MB file is removed from the tracked path (still gitignored, still exists as a local file if the user wants to keep it)"
    - "assets/osm/osm.sqlite exists (also gitignored) as the runtime artifact Phase 5 will consume"
    - "Phase 4 close-out: STATE.md pending-todo line for the dev_germany.pmtiles replacement is resolved; ROADMAP marks Phase 4 complete with all 8 OSM-0X requirements verified; REQUIREMENTS.md traceability rows for OSM-01..OSM-08 flip to Complete"
    - "04-VERIFICATION.md exists documenting: full-Germany wall-clock, artifact sizes, PRAGMA user_version, metadata row check, way_admin row count, admin_regions per-level count, tippecanoe warnings count, skipped.log size — one row per success criterion from ROADMAP Phase 4 §Success Criteria"
    - "flutter test at repo root remains green after replacing the pmtiles asset (map still opens both style JSONs against the new Germany pmtiles without runtime errors)"
  artifacts:
    - path: ".planning/phases/04-osm-pipeline/04-VERIFICATION.md"
      provides: "Phase 4 close-out verification report — SC1..SC5 checkboxes with evidence"
    - path: "assets/tiles/dev_germany.pmtiles"
      provides: "Runtime pmtiles asset (replaced with our custom-schema output)"
    - path: "assets/osm/osm.sqlite"
      provides: "Runtime SQLite artifact for Phase 5's matcher isolate"
  key_links:
    - from: ".planning/ROADMAP.md"
      to: ".planning/phases/04-osm-pipeline/04-VERIFICATION.md"
      via: "Phase 4 status row links to VERIFICATION for evidence trail"
      pattern: "04-VERIFICATION"
    - from: "assets/tiles/dev_germany.pmtiles"
      to: "assets/map_style_light.json"
      via: "MapLibre style JSON sources.trailblazer.url points at the pmtiles asset"
      pattern: "pmtiles://asset"
---

## Goal

Run the full-Germany pipeline, verify SC4 (200 MB budget hard constraint), replace the placeholder Protomaps-derived pmtiles in the app, and close Phase 4 with a verification report.

## Context

- 04-CONTEXT locks the 200 MB hard budget per artifact (SC4). "Architectural choices that blow it are wrong, even if theoretically nicer." This plan runs the empirical proof.
- STATE.md line 162 (per planning_context handoff) has a pending todo: replace `assets/tiles/dev_germany.pmtiles` (371 MB Protomaps demo, gitignored). That todo resolves in Task 3.
- 04-RESEARCH §11 expects a full-Germany run of 30–90 min. If it materially exceeds that, the fallback trigger (04-RESEARCH §1) kicks in — escalate to shell-out to `osmium export`. This plan MUST record actual wall-clock so any regression later is caught.
- 04-RESEARCH §12 pitfall #9 (`highway=road` sanity): the pipeline logs this count already (04-03). Task 2's verification report captures the count and comments if > 0.1 % of Kfz ways.
- Phase 4 is a dev-machine deliverable independent of the app's in-car verification. The Ralph-Loop pre-push hook covers the code side; SC1–SC5 are code-level acceptance, no drive-test required (per phase deferrred-in-car-verification memory).
- **This plan is `autonomous: false`** — the full-Germany run takes ~1 hour and the user's dev box; the executor cannot run it without user intervention (need the Germany PBF, need WSL2 tippecanoe, need patience). Same checkpoint shape as 04-09 Task 4.

## Tasks

<task type="checkpoint:human-verify">
  <name>Task 1: Run full-Germany pipeline + capture measurements</name>
  <gate>blocking</gate>
  <what-built>
    - The complete Phase 4 pipeline (plans 04-01 through 04-09) is code-complete and Berlin-smoked.
    - Ready for the full-Germany run.
  </what-built>
  <how-to-verify>
    1. Download the Germany PBF from Geofabrik if not already present:
       ```powershell
       # ~4 GB download; only do once
       Invoke-WebRequest `
         -Uri "https://download.geofabrik.de/europe/germany-latest.osm.pbf" `
         -OutFile "tool\osm_pipeline\out\germany-latest.osm.pbf"
       ```
       or `curl -L -o tool/osm_pipeline/out/germany-latest.osm.pbf https://download.geofabrik.de/europe/germany-latest.osm.pbf`

    2. Run the pipeline WITHOUT `--bbox` (full extract):
       ```powershell
       $start = Get-Date
       dart run tool/osm_pipeline --pbf="tool\osm_pipeline\out\germany-latest.osm.pbf"
       $elapsed = ((Get-Date) - $start).TotalMinutes
       Write-Host "Wall-clock: $elapsed min"
       ```

    3. Wait 30–90 min. Grab a coffee. If it exceeds 2 hours, cancel and escalate.

    4. Capture and record for the SUMMARY:
       - Wall-clock (target: 30–90 min per 04-RESEARCH §11)
       - `osm.sqlite` size (target: < 200 MB per SC4)
       - `germany-base.pmtiles` size (target: < 200 MB per SC4)
       - `skipped.log` line count (informational — 04-CONTEXT skip-log-continue error handling means non-zero is expected)
       - Any tippecanoe stderr WARN/ERROR lines from the console

    5. Sanity queries on the produced osm.sqlite:
       ```bash
       sqlite3 out/osm.sqlite "PRAGMA user_version;"                  # → 1
       sqlite3 out/osm.sqlite "SELECT * FROM metadata;"               # 7 rows
       sqlite3 out/osm.sqlite "SELECT COUNT(*) FROM ways WHERE source='kfz';"        # ~4M expected
       sqlite3 out/osm.sqlite "SELECT COUNT(*) FROM ways WHERE source='feldweg';"    # anywhere from ~500k to ~2M
       sqlite3 out/osm.sqlite "SELECT admin_level, COUNT(*) FROM admin_regions GROUP BY admin_level;"
       sqlite3 out/osm.sqlite "SELECT COUNT(*) FROM way_admin;"       # cross-border rows
       sqlite3 out/osm.sqlite "SELECT COUNT(*) FROM ways_rtree;"      # per-segment or per-way total
       ```
       Record all counts in the SUMMARY.

    6. Sanity check on pmtiles metadata:
       ```bash
       # Dump first few KB of the file, inspect header + metadata JSON block.
       # 04-08 shipped a metadata dumper; use it:
       dart run tool/osm_pipeline/bin/dump_pmtiles_metadata.dart out/germany-base.pmtiles
       ```
       Verify pbf_date + pipeline_schema_version match osm.sqlite's metadata table.

    7. Report back to the executor.
  </how-to-verify>
  <resume-signal>
    Reply with the captured measurements:
    - Wall-clock: N min
    - osm.sqlite: X MB
    - germany-base.pmtiles: Y MB
    - Kfz ways: A
    - Feldweg ways: B
    - Admin regions per level (2/4/6/8/9/10): [...]
    - way_admin cross-border rows: C
    - ways_rtree rows: D
    - skipped.log lines: E
    - PRAGMA user_version: 1  (or flag if not)
    - pmtiles metadata matches osm.sqlite metadata: yes/no

    Or describe any failure — the executor will iterate on the failing stage.
  </resume-signal>
</task>

<task type="auto">
  <name>Task 2: Write 04-VERIFICATION.md close-out report</name>
  <files>
    .planning/phases/04-osm-pipeline/04-VERIFICATION.md
  </files>
  <intent>Document empirical evidence that all 5 Phase 4 success criteria are satisfied.</intent>
  <action>
    Create `04-VERIFICATION.md` with this structure (fill in real numbers from Task 1's report):

    ```markdown
    # Phase 4 · Verification

    **Ran:** <date>
    **Full-Germany PBF:** germany-latest.osm.pbf (<sha256>, <MB>)
    **Wall-clock:** <N> minutes
    **Dev machine:** <host summary — CPU, RAM>

    ## Success Criteria

    ### SC1 — Berlin bbox produces both artifacts end-to-end
    - [x] Verified in 04-09 Task 4 (Berlin smoke) — <wall-clock>, osm.sqlite <X> MB, pmtiles <Y> MB.

    ### SC2 — Kfz + Feldweg + admin levels 2/4/6/8/9/10 present
    - [x] Kfz ways: <count> rows in ways(source='kfz'). Highway class distribution:
      | highway | count |
      | motorway | ... |
      | ... | ... |
    - [x] Feldweg ways: <count> rows in ways(source='feldweg'). Breakdown:
      | highway | count |
      | track | ... |
      | path (motor_vehicle=yes/permissive) | ... |
      | service (driveway/alley) | ... |
    - [x] Admin regions per level:
      | level | count |
      | 2 (country) | ~1 (Germany + border-touch neighbors) |
      | 4 (Bundesland) | 16 (+ city-state dual-writes: Berlin/Hamburg/Bremen also emit at 6) |
      | 6 (Landkreis) | ~400 |
      | 8 (Gemeinde) | ~11 000 |
      | 9 (Stadtteil) | varies |
      | 10 (Ortsteil) | varies |
    - [x] Excluded: highway=service (no rows in ways where highway='service' AND source='kfz').

    ### SC3 — way_admin populated for every Kfz way ↔ region intersection
    - [x] way_admin cross-border rows: <count>
    - [x] Denormalized wholly-contained coverage:
      `SELECT COUNT(*) FROM ways WHERE admin_region_id_l8 IS NOT NULL` → <count>
      (should be ≈ 95 % of Kfz ways per 04-RESEARCH §7 assumption)
    - [x] Point-in-polygon sanity: pick 10 random Kfz ways with admin_region_id_l8 IS NULL, verify each has ≥ 1 way_admin row at level=8 covering its span.

    ### SC4 — 200 MB budget per artifact
    - [x] osm.sqlite: <X> MB (target: < 200 MB) — **PASS** / FAIL / MARGINAL
    - [x] germany-base.pmtiles: <Y> MB (target: < 200 MB) — **PASS** / FAIL / MARGINAL
    - [x] Version stamp present:
      - PRAGMA user_version: 1
      - metadata table: 7 rows with expected keys (see 04-RESEARCH §9)
      - pmtiles metadata JSON: matches osm.sqlite metadata

    ### SC5 — `--bbox` flag works
    - [x] Verified in 04-09 Task 4 (Berlin bbox smoke succeeded).
    - [x] Also verified 04-05 Berlin measurement probe worked with the same flag.

    ## Requirements Coverage

    | Req    | Plan  | Status |
    |--------|-------|--------|
    | OSM-01 | 04-01 | Complete — dev-machine Dart CLI ships |
    | OSM-02 | 04-03 | Complete — 14-tag Kfz + Feldweg carve-out per 04-RESEARCH §4 |
    | OSM-03 | 04-04 | Complete — admin levels 2/4/6/8/9/10 extracted |
    | OSM-04 | 04-05 | Complete — segmented intersection populates way_admin |
    | OSM-05 | 04-06, 04-07, 04-09 | Complete — osm.sqlite + germany-base.pmtiles ship |
    | OSM-06 | 04-10 | Complete — both artifacts under 200 MB (this file) |
    | OSM-07 | 04-06, 04-08 | Complete — version stamp present in both artifacts |
    | OSM-08 | 04-01, 04-09 | Complete — `--bbox` flag exercised |

    ## Skipped-log summary

    <cat out/skipped.log | wc -l> lines total. Breakdown by kind:
    | reason | count |
    | admin ring self-intersect | ... |
    | admin outer/inner assembly failure | ... |
    | deleted-node ref in kfz way | ... |
    | highway=road (informational, not a skip) | ... |
    | ... | ... |

    ## Warnings

    - highway=road count: <N> Kfz ways (<pct>% of total). <  0.1% → OK; > 0.1% → escalate to upstream OSM fix.
    - tippecanoe stderr non-empty lines: <N>.  Notable messages: [...]

    ## Follow-ups

    - [ ] (any deviations from Task 1 that need a corrective mini-plan)
    ```
  </action>
  <verify>
    File exists with all sections filled in from Task 1's captured numbers.
  </verify>
</task>

<task type="auto">
  <name>Task 3: Replace app assets + close Phase 4 in planning docs</name>
  <files>
    assets/tiles/dev_germany.pmtiles
    assets/osm/osm.sqlite
    .planning/STATE.md
    .planning/REQUIREMENTS.md
    .planning/ROADMAP.md
    tool/osm_pipeline/README.md
    .gitignore
  </files>
  <intent>Wire the new artifacts into the app + flip planning docs to Phase 4 = Complete.</intent>
  <action>
    **Step 1: Replace app assets.**

    The app currently reads `assets/tiles/dev_germany.pmtiles` (Protomaps demo, 371 MB, gitignored). Rename decision:
    - **Recommended:** rename the runtime asset from `dev_germany.pmtiles` to `germany-base.pmtiles` (or a similarly Trailblazer-specific name) and update Phase 2's `pmtiles_source.dart` to load the new name. Also update the two style JSONs' `sources.trailblazer.url` field (04-08 wrote them referencing `germany-base.pmtiles` already — verify they match).
    - **Alternative (less churn):** keep the file name `dev_germany.pmtiles` — just copy our output over it. Same tile source URL keeps working. Style JSONs already point at `pmtiles://asset/germany-base.pmtiles` per 04-08 — this alternative would require re-updating them to `dev_germany.pmtiles`.

    Pick option (a) — the naming clarity is worth the small `lib/` diff.

    Copy artifacts:
    ```bash
    mkdir -p assets/tiles assets/osm
    cp tool/osm_pipeline/out/germany-base.pmtiles assets/tiles/germany-base.pmtiles
    cp tool/osm_pipeline/out/osm.sqlite            assets/osm/osm.sqlite
    ```

    Update `pubspec.yaml` assets section (root pubspec):
    - Add `assets/tiles/germany-base.pmtiles` if it wasn't already listed as a glob.
    - Add `assets/osm/osm.sqlite` if the app is going to load it directly. NOTE: Phase 5 (OSMDB-01) says the app DOWNLOADS the OSM DB on first launch — so `assets/osm/osm.sqlite` probably should NOT be bundled. This is Phase 5's concern; for Phase 4 close-out we just ensure the FILE exists on disk so Phase 5 has a source. Leave it out of `pubspec.yaml`.
    - Do NOT delete `assets/tiles/dev_germany.pmtiles` yet — mark it deprecated in a code comment near the source URL and Phase 5/10 will remove it when the download flow ships. Alternatively, delete now and just gitignore the runtime path — up to executor.

    Update `.gitignore`:
    ```
    # Runtime artifacts produced by tool/osm_pipeline
    assets/tiles/germany-base.pmtiles
    assets/osm/osm.sqlite
    ```

    Update `lib/features/map/**` (whichever file reads the pmtiles source): change `dev_germany.pmtiles` → `germany-base.pmtiles`. Run `flutter test` at repo root — everything green.

    **Step 2: Close-out planning docs.**

    `STATE.md`:
    - Under "Pending todos": remove the "replace dev_germany.pmtiles" entry.
    - Under "Phase 4 decisions" (or wherever Phase 4 accumulated notes live): add a Phase 4 close-out block:
      ```
      Phase 4 close-out — <date>
      - Full-Germany pipeline validated: osm.sqlite <X> MB / germany-base.pmtiles <Y> MB (SC4 pass).
      - Berlin smoke wall-clock: <T> s (SC1, SC5 pass).
      - dev_germany.pmtiles → germany-base.pmtiles rename shipped.
      - New pending todo (Phase 5): host germany-base.pmtiles + osm.sqlite at a downloadable URL for the runtime download flow (OSMDB-01).
      ```

    `REQUIREMENTS.md`:
    - Flip OSM-01..OSM-08 traceability rows from "Pending" to "Complete".
    - Update the last-updated line at the bottom.

    `ROADMAP.md`:
    - Change Phase 4 line 18 from `[ ] **Phase 4: OSM Pipeline**` to `[x] **Phase 4: OSM Pipeline**`.
    - Under Phase 4's `Success Criteria`, add a `**Completed:** <date>` line matching the Phase 2/3 pattern.
    - Under `Plans:`, list the 10 plans with checkboxes:
      ```
      - [x] 04-01-reconciliation-and-cli-scaffold-PLAN.md — reconcile OSM-02 + stand up CLI
      - [x] 04-02-pbf-streaming-reader-PLAN.md — pure-Dart streaming PBF parse
      - [x] 04-03-highway-filter-directionality-PLAN.md — Kfz + Feldweg + directionality
      - [x] 04-04-admin-boundary-extraction-PLAN.md — admin relations → multipolygons → WKB
      - [x] 04-05-berlin-measurement-segmented-intersection-PLAN.md — row-count probe + way_admin
      - [x] 04-06-osm-sqlite-finalization-PLAN.md — final osm.sqlite schema + R-Tree + version stamp
      - [x] 04-07-geojson-emit-tippecanoe-pmtiles-PLAN.md — 4-layer GeoJSONSeq + tippecanoe
      - [x] 04-08-pmtiles-metadata-style-rewrite-PLAN.md — pmtiles metadata + light/dark style JSONs
      - [x] 04-09-berlin-smoke-and-wsl-docs-PLAN.md — smoke.sh + smoke.ps1 + WSL2 install guide
      - [x] 04-10-full-germany-close-out-PLAN.md — full-Germany run + 200 MB budget + close-out
      ```
    - Update the Progress table row for Phase 4: `10/10` and `✓ Complete`.

    Update `tool/osm_pipeline/README.md` "Expected timings" section with the actual measured full-Germany wall-clock, so future maintainers have a real baseline.
  </action>
  <verify>
    `flutter analyze` clean.
    `flutter test` at repo root — green.
    `git status` shows the planning doc diffs.
    Manual: open the app on a device (or simulator) — map still renders. Berlin admin regions should now be visible (they weren't in the Protomaps demo — this is the CROSS-CHECK the new pmtiles is loaded).
    `grep '\[ \] \*\*Phase 4:' .planning/ROADMAP.md` returns 0 matches; `grep '\[x\] \*\*Phase 4:' .planning/ROADMAP.md` returns 1 match.
  </verify>
</task>

## Verification

- 04-VERIFICATION.md exists and all 5 SC checkboxes are ticked with evidence.
- OSM-01..OSM-08 flip to Complete in REQUIREMENTS.md.
- ROADMAP.md Phase 4 flipped to `[x]` with 10 plan checkboxes filled in.
- STATE.md pending-todo for dev_germany.pmtiles replacement is resolved.
- `flutter analyze` + `flutter test` at repo root — both green.
- Manual: app opens on a device and the map still renders (with our new schema).

## Deviation Handling

- If osm.sqlite > 200 MB (SC4 fail): the schema is heavier than 04-05 projected. Options:
  1. Drop admin_region_id_l9 and admin_region_id_l10 columns from ways (04-RESEARCH §7 escape hatch). Rerun Stage C only (do NOT redo the whole pipeline — rerun 04-06's writer against the same scratch DB).
  2. Skip Feldweg way storage entirely (they don't contribute to coverage math anyway; keep them in pmtiles for rendering, drop from osm.sqlite). Filed as follow-up if option (1) is insufficient.
  Retry, remeasure, re-verify. If still > 200 MB after option (1), escalate to user with the actual size + a proposal.

- If germany-base.pmtiles > 200 MB (SC4 fail): tippecanoe over-emitted at high zoom. Add `--maximum-tile-bytes=400000 --drop-fraction-as-needed`, rerun 04-07 stage only. Do NOT lower maxzoom below 11 (04-CONTEXT lock).

- If full-Germany pipeline runs > 2 hours: trigger the 04-RESEARCH §1 fallback — shell out to `osmium export` for Stage A (raw filter) and keep Dart for downstream stages. This is a corrective mini-plan (04-10.1), not something we retro-fit into 04-10.

- If tippecanoe emits > 100 warnings: read the top 10 and file a follow-up. Warnings are informational, not blockers.

- If the app's `flutter test` breaks because a widget test hard-codes the old `dev_germany.pmtiles` filename: fix the test to read from the new asset. Not a Phase 4 regression, just a hardcoded string.

- Iterate up to 3 times on non-checkpoint tasks; checkpoint (Task 1) blocks until human confirms.
