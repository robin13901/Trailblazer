---
phase: 04-osm-pipeline
plan: 17
subsystem: docs
tags: [rescope, close-out, requirements, roadmap, verification, phase-4]

# Dependency graph
requires:
  - phase: 04-osm-pipeline
    provides: Code-complete rescope plans 04-11 (MapTiler provider), 04-12 (style rewrite + TileServer teardown), 04-13 (Overpass client + payload probe), 04-14 (Drift v3 + DAOs), 04-15 (WayCandidateSource + trip coordinator), 04-16 (bundled admin polygons), 04-16-1 (UX polish)
provides:
  - REQUIREMENTS.md OSM-01..OSM-08 rewritten for the rescoped MapTiler + Overpass + bundled-admin-polygons architecture; OSMDB-01..OSMDB-07 deleted with a Phase-5 forward-reference comment; total v1 requirement count 119 → 112
  - ROADMAP.md Phase 4 renamed "OSM Pipeline → Map & Matching Data Sources" with new goal + 5 rescoped SCs + 8-plan list (04-11..04-17 + 04-16-1) marked Complete
  - ROADMAP.md Phase 5 renamed "OSM DB + Matcher → Overpass-Backed Matcher + Golden Corpus" with matcher-consumes-WayCandidateSource framing
  - PROJECT.md Key Decisions structured section with dated 2026-07-08 rescope entry
  - STATE.md Current Position advanced to Phase 4 rescope COMPLETE (code-complete; drive-verify pending); obsolete todos marked resolved; SC4 blocker/concern marked "Superseded by rescope"
  - 04-VERIFICATION.md with `status: human_needed` frontmatter for /gsd:execute-phase orchestrator routing; Human Verification Checklist consolidates combined-drive scenarios
affects: [05-overpass-backed-matcher, phase-4-close-out-drive, phase-5-planning]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Rescope close-out plan pattern: docs-only, autonomous:true, per-file staging discipline, one commit per doc file, VERIFICATION.md with status: human_needed frontmatter"
    - "Rescope decision documentation: PROJECT.md Key Decisions gets a dated dated-heading entry documenting abandoned architecture + adopted architecture + consequences (deleted plans by commit hash, deleted requirements, renamed phases)"

key-files:
  created:
    - .planning/phases/04-osm-pipeline/04-VERIFICATION.md
  modified:
    - .planning/REQUIREMENTS.md
    - .planning/ROADMAP.md
    - .planning/PROJECT.md
    - .planning/STATE.md

key-decisions:
  - "SUPERSEDED-marker step for 04-10-1-05-germany-close-out-PLAN.md SKIPPED — the file was already DELETED at session start (commit e475ad8, alongside 04-10-full-germany-close-out-PLAN.md). PROJECT.md Key Decisions + 04-VERIFICATION.md Legacy Artifacts section note the deletion by commit hash."
  - "04-16-1-ux-polish-PLAN.md slotted into ROADMAP plan list mid-execution (between 04-16 and 04-17); plan count 7 → 8; rescope framing shifted from '7 plans, 4 waves' to '8 plans, 4 waves + one polish plan'."
  - "04-VERIFICATION.md gains a top-of-file `status: human_needed` frontmatter (not sketched in the plan template) so /gsd:execute-phase orchestrator's verify_phase_goal step routes to 'human verification required' rather than 'passed'."
  - "Device-verified vs drive-deferred split annotated per SC: SC1 (04-12 MapTiler smoke) = PASS device-verified 2026-07-08 Samsung Galaxy S24; SC3/SC5/UX-polish drive-verify batched to combined Phase-4 close-out session per user directive."
  - "Requirement count 119 → 112 reflected consistently in REQUIREMENTS.md coverage table, ROADMAP.md overview + coverage table, and PROJECT.md Key Decisions entry."

patterns-established:
  - "Docs-only rescope close-out: 4 task commits (one per source-of-truth file) + 1 metadata commit; per-file staging discipline (no git add -A / git commit -a); verification report authored with orchestrator-routable frontmatter."
  - "Legacy-artifact accounting: when a rescope makes prior plans obsolete, PROJECT.md + VERIFICATION.md distinguish DELETED files (cite commit hash) from RETAINED files (superseded but on disk for archaeology, e.g. tool/osm_pipeline retained as dev-only fixture generator)."

# Metrics
duration: ~35 min
completed: 2026-07-08
---

# Phase 4 Plan 17: Rescope Close-Out Summary

**Docs-only rescope close-out: REQUIREMENTS.md + ROADMAP.md + PROJECT.md + STATE.md rewritten for the MapTiler + on-demand Overpass + bundled-admin-polygons architecture; 04-VERIFICATION.md authored with `status: human_needed` frontmatter consolidating evidence for all 5 rescoped SCs and a combined-drive Human Verification Checklist.**

## Performance

- **Duration:** ~35 min
- **Started:** 2026-07-08 (session)
- **Completed:** 2026-07-08
- **Tasks:** 4 executed + 1 metadata commit
- **Files modified:** 4 (`.planning/REQUIREMENTS.md`, `.planning/ROADMAP.md`, `.planning/PROJECT.md`, `.planning/STATE.md`)
- **Files created:** 1 (`.planning/phases/04-osm-pipeline/04-VERIFICATION.md`, 194 lines)

## Accomplishments

- **REQUIREMENTS.md rescoped:** OSM-01..OSM-08 rewritten for the rescoped runtime (MapTiler tiles + on-demand Overpass fetches + Drift v3 cache + LRU eviction + bundled admin polygons + `WayCandidateSource` interface + `pendingRoadData` state + `tool/osm_pipeline` as dev-only fixture generator + attribution in Settings > About). OSMDB-01..OSMDB-07 deleted with a forward-reference HTML comment. Total 119 → 112.
- **ROADMAP.md rescoped:** Phase 4 renamed `OSM Pipeline → Map & Matching Data Sources` (new goal, 5 rescoped SCs verbatim from plan §Context, 8-plan list marked Complete, depends on Phase 1 + Phase 3). Phase 5 renamed `OSM DB + Matcher → Overpass-Backed Matcher + Golden Corpus` (matcher consumes `WayCandidateSource`; requirements block loses OSMDB rows; SC1/SC2 rewritten). Coverage table 119 → 112; Progress table Phase 4 Complete 2026-07-08.
- **PROJECT.md structured:** "Key Decisions" now has a dated 2026-07-08 rescope heading documenting the abandoned (bundled-osm.sqlite, 200 → 800 MB → projected 2.5 GB) and adopted (MapTiler + Overpass + admin polygons + WayCandidateSource + pendingRoadData + dev-only fixture) architectures. Original decision table preserved as "Historical Decisions".
- **STATE.md advanced:** Current Position → Phase 4 rescope COMPLETE (code-complete; drive-verify pending combined session). Two 04-17 decision bullets added summarizing REQUIREMENTS/ROADMAP/PROJECT rewrites + 04-VERIFICATION.md authoring. Obsolete todos marked resolved (04-10 pmtiles re-run, dev_germany.pmtiles replacement); SC4 blocker/concern marked "Superseded by rescope 2026-07-08" with historical text preserved. Session Continuity + Last activity + progress bar (56% → 57%) updated.
- **04-VERIFICATION.md authored (194 lines):** top-of-file `status: human_needed` frontmatter; 5 rescoped SCs each with substantive evidence citations from source-of-truth docs (04-11-STYLE-SPIKE.md, 04-13-PAYLOAD-PROBE.md, and 04-11..04-16-1 SUMMARY files); device-verified vs drive-deferred split annotated per SC; UX polish (04-16-1) section with 5 tabulated fixes; Legacy Artifacts On Disk section noting DELETED plans by commit hash `e475ad8`; Human Verification Checklist consolidating combined-drive scenarios (04-15 A/B/C + 04-16 D/E + 04-16-1 toast+chrome+zoom+language + MapTiler smoke + ancillary crash checks); 6 documented Deviations from Original Plan.

## Task Commits

Each task was committed atomically with individual file staging (no `git add -A` / `git commit -a`):

1. **Task 1: Rewrite REQUIREMENTS.md OSM + OSMDB rows** — `43a3e84` (docs)
   - OSM-01..OSM-08 rephrased; OSMDB-01..OSMDB-07 deleted with forward-reference comment; traceability table re-labeled to new phase names; coverage totals 119 → 112.
2. **Task 2: Rewrite ROADMAP.md Phase 4 + Phase 5 blocks; update progress + coverage** — `6f344ed` (docs)
   - Phase 4 renamed + goal/SCs/plan-list rewritten (04-16-1 included); Phase 5 renamed + requirements block updated (OSMDB rows removed); Progress + Coverage tables updated 119 → 112.
3. **Task 3: PROJECT.md rescope decision + STATE.md cleanup** — `920455d` (docs)
   - PROJECT.md Key Decisions structured with dated 2026-07-08 rescope entry; STATE.md current position advanced, obsolete todos marked resolved, 04-17 bullets added. (SUPERSEDED-marker step for `04-10-1-05-germany-close-out-PLAN.md` SKIPPED per Deviation 1 — file was already DELETED at session start.)
4. **Task 4: 04-VERIFICATION.md with evidence for all 5 rescoped SCs** — `352cdee` (docs)
   - New 194-line report at `.planning/phases/04-osm-pipeline/04-VERIFICATION.md` with `status: human_needed` frontmatter, 5 SC evidence blocks, UX polish section, Legacy Artifacts, Human Verification Checklist, 6 Deviations documented.

**Plan metadata:** [forthcoming — this commit] (docs: complete rescope-close-out plan)

## Files Created/Modified

- `.planning/REQUIREMENTS.md` — OSM-01..OSM-08 rewritten; OSMDB-01..OSMDB-07 deleted (forward-reference comment inserted); traceability table + coverage totals updated.
- `.planning/ROADMAP.md` — Phase 4 + Phase 5 blocks rewritten; overview + phase list + progress table + coverage table updated 119 → 112.
- `.planning/PROJECT.md` — Key Decisions structured with dated 2026-07-08 rescope entry; original decision table preserved as "Historical Decisions".
- `.planning/STATE.md` — current position, session continuity, decisions log (2 new 04-17 bullets), obsolete todos marked resolved.
- `.planning/phases/04-osm-pipeline/04-VERIFICATION.md` — NEW 194-line verification report with `status: human_needed` frontmatter.

## Cross-references: Rescope Plans (Phase 4)

The 8 rescope plans that Phase 4 delivered code-complete before this close-out:

| Plan | Wave | SUMMARY | Metadata commit |
|------|------|---------|-----------------|
| 04-11-maptiler-provider-and-key-plumbing | 1 (serial) | `.planning/phases/04-osm-pipeline/04-11-SUMMARY.md` | `6ca4d30` |
| 04-12-style-rewrite-and-tileserver-teardown | 1 (serial) | `.planning/phases/04-osm-pipeline/04-12-SUMMARY.md` | `930b3ca` |
| 04-13-overpass-client-and-payload-probe | 2 (serial) | `.planning/phases/04-osm-pipeline/04-13-SUMMARY.md` | `c698f65` |
| 04-14-drift-migration-v3-and-daos | 2 (serial) | `.planning/phases/04-osm-pipeline/04-14-SUMMARY.md` | `65141b1` |
| 04-15-way-candidate-source-and-trip-flow | 2 (serial) | `.planning/phases/04-osm-pipeline/04-15-SUMMARY.md` | `2fe8a1e` |
| 04-16-bundled-admin-polygons-and-lookup | 3 | `.planning/phases/04-osm-pipeline/04-16-SUMMARY.md` | `c8a8d1f` |
| 04-16-1-ux-polish | 4a (polish) | `.planning/phases/04-osm-pipeline/04-16-1-SUMMARY.md` | `5804fae` |
| 04-17-rescope-close-out (this plan) | 4b (docs) | this file | forthcoming |

## Decisions Made

- **Skip SUPERSEDED-marker on nonexistent file** — the plan text called for adding a `**STATUS: SUPERSEDED by rescope 2026-07-08**` line at the top of `04-10-1-05-germany-close-out-PLAN.md`, but that file was already deleted at session start (verified: `git show e475ad8 --stat` shows both `04-10-1-05-germany-close-out-PLAN.md` and `04-10-full-germany-close-out-PLAN.md` as `delete`). PROJECT.md Key Decisions + 04-VERIFICATION.md Legacy Artifacts note the deletion by commit hash instead. Task 3 commit accordingly does NOT stage a modification to the nonexistent path.
- **`status: human_needed` frontmatter on 04-VERIFICATION.md** — plan template did not include frontmatter, but /gsd:execute-phase orchestrator's `verify_phase_goal` step routes on a top-of-file `status:` field. Author included the frontmatter (extra guidance from the execute-phase workflow) so the orchestrator routes to "human verification required" rather than "passed" — reflecting that drive-verify is pending.
- **Consolidated Human Verification Checklist** — instead of scattering deferred-drive scenarios across each rescope SUMMARY, 04-VERIFICATION.md consolidates them into ONE actionable checklist covering 04-15 Scenarios A/B/C + 04-16 D/E + 04-16-1 UX visual checks + MapTiler tile smoke + ancillary crash checks. The user gets a single list to work through in the combined drive; matches the memory `phase-4-drives-deferred-to-gym-trip.md`.
- **Device-verified vs drive-deferred annotated per SC** — SC1 (04-12 MapTiler smoke device-verified Samsung Galaxy S24 2026-07-08) marked PASS; SC3/SC5/04-16-1 UX visuals marked CODE-COMPLETE with drive-verify PENDING and inline `<pending combined Phase-4 close-out drive — see memory: phase-4-drives-deferred-to-gym-trip.md>` markers.
- **04-16-1 UX polish tabulated as its own section**, not as a 6th SC. Rationale: the 5 fixes were folded into the rescope after the SCs were locked; keeping them out of the SC block preserves the SC list as-committed at plan-start and gives the UX polish its own visible column of status markers.
- **`sqlite3 ^3.0.0` dependency_override retained as a pending-todo** (documented in 04-VERIFICATION.md SC2 evidence and STATE.md pending todos) — bumping the sub-package pin to ^3.0.0 and removing the override requires re-running the full 233+ sub-package test suite, out of 04-17 scope.

## Deviations from Plan

### 1. [Metadata correction] SUPERSEDED-marker step for `04-10-1-05-germany-close-out-PLAN.md` SKIPPED

- **Found during:** Task 3 (PROJECT.md + STATE.md + SUPERSEDED marker step)
- **Issue:** Plan §Task 3 Step 2 required adding a `**STATUS: SUPERSEDED**` marker at the top of `04-10-1-05-germany-close-out-PLAN.md`. But that file was DELETED at session start in commit `e475ad8` ("chore(04): remove pre-rescope orphan plans 04-10-1-05 + 04-10-full-germany-close-out"), alongside `04-10-full-germany-close-out-PLAN.md`. The user chose "Delete the two orphan PLAN.md files" over "Leave them with SUPERSEDED marker" at a prior orphan-handling AskUserQuestion prompt.
- **Fix:** SKIP the marker step. In PROJECT.md's Key Decisions entry AND in 04-VERIFICATION.md's "Legacy Artifacts On Disk" section, note the deletion by commit hash (`e475ad8` 2026-07-08) instead of a marker on a nonexistent file. The plan frontmatter `files_modified:` listing that path is ignored (file does not exist and should NOT be recreated).
- **Files modified:** None (skipped step); PROJECT.md + 04-VERIFICATION.md updated per adjusted text.
- **Verification:** `git show e475ad8 --stat` shows both files as `delete`; `ls .planning/phases/04-osm-pipeline/04-10-1-05*` returns "No such file or directory".
- **Committed in:** `920455d` (Task 3) — includes the adjusted PROJECT.md text.

### 2. [Metadata addition] `04-16-1-ux-polish-PLAN.md` slotted into ROADMAP plan list

- **Found during:** Task 2 (ROADMAP.md rewrite)
- **Issue:** The plan's Task 2 sketch listed 7 rescope plans (04-11..04-17) and characterized the rescope as "7 plans, 4 waves". During execution (before 04-17), `04-16-1-ux-polish-PLAN.md` was slotted in AFTER 04-16 to fold 5 user-observed UI fixes (FGB toast, off-screen attribution, default zoom 15, German localization, top-chrome margin) — adding an 8th plan.
- **Fix:** ROADMAP.md Phase 4 plan list includes `04-16-1-ux-polish-PLAN.md` between 04-16 and 04-17; the plan-count remark is "8 plans, 4 waves + one polish plan". PROJECT.md Key Decisions entry + 04-VERIFICATION.md's plan cross-references also include 04-16-1. In VERIFICATION.md's "Legacy Artifacts On Disk" section, 04-16-1 is NOT listed as legacy — it's an active rescope plan.
- **Files modified:** `.planning/ROADMAP.md`, `.planning/PROJECT.md`, `.planning/phases/04-osm-pipeline/04-VERIFICATION.md`.
- **Verification:** `grep -c "04-16-1" .planning/ROADMAP.md` shows the entry present in the plan list; UX polish tabulated as its own section in VERIFICATION.md.
- **Committed in:** `6f344ed` (Task 2), `920455d` (Task 3), `352cdee` (Task 4).

---

**Total deviations:** 2 (both metadata corrections that reflect real session-state changes; neither introduced code nor scope creep)
**Impact on plan:** Zero scope creep. Both deviations tighten the docs to reflect the actual session state (deleted-file + polish-plan slot-in). The plan's Success Criteria — REQUIREMENTS/ROADMAP/PROJECT/STATE/VERIFICATION all rewritten for the rescope — are all met.

## Issues Encountered

None. Docs-only plan; no code changes; no `flutter analyze` or test runs required per plan §Ralph Loop. Individual file staging discipline held throughout (verified via `git status --porcelain` between commits).

## User Setup Required

None — no external service configuration required. However, the combined Phase-4 close-out drive is required before the phase can flip from `human_needed` → `passed` in the orchestrator's routing. See `.planning/phases/04-osm-pipeline/04-VERIFICATION.md` Human Verification Checklist for the consolidated scenario list.

## Next Phase Readiness

**Ready:**
- Phase 5 planning may begin (Overpass-Backed Matcher + Golden Corpus). Downstream contract: matcher consumes `WayCandidateSource.fetchWaysInBbox` (Phase 4 provides both `OverpassWayCandidateSource` at `lib/features/matching/data/overpass_way_candidate_source.dart` and `FixtureWayCandidateSource` at `test/helpers/fixture_way_candidate_source.dart`). Golden corpus generation uses `tool/osm_pipeline/` fixture PBFs (retained as dev-only per OSM-07).
- Phase 3.1 Wave 3 still open in parallel (in-car drive re-verification of the 03-1-01..03-1-04 fixes) — does not block Phase 5.
- Combined Phase-4 close-out drive-verify pending per user directive 2026-07-08. Memory reference: `phase-4-drives-deferred-to-gym-trip.md`. Single actionable checklist lives in 04-VERIFICATION.md Human Verification Checklist AND in STATE.md Pending Todos "Phase 4 close-out drive (batched)" entry.

**Deferred verification checklist (repeated for convenience):**

| Section | Scenarios | Reference |
|---------|-----------|-----------|
| (a) 04-15 SC3 | A (online → cache row + `pending` in 30 s), B (offline → `pendingRoadData` + queue → drain on resume), C (cache-hit → immediate `pending`) | 04-VERIFICATION.md § Human Verification Checklist |
| (b) 04-16 SC5 | D (bundled admin lookup — Kleinheubach L8/L6/L4 + Berlin L4/L10; asset load < 3 s), E (Refresh admin regions Settings tap → SnackBar → subtitle updates, persists across kill/reopen) | 04-VERIFICATION.md § Human Verification Checklist |
| (c) 04-12 SC1 | Re-verify MapTiler tile smoke (Kleinheubach + Frankfurt/Würzburg in light + dark; attribution off-map; About-link taps) | 04-VERIFICATION.md § Human Verification Checklist |
| (d) 04-16-1 UX polish | Task 1 (FGB toast NOT shown; if it appears fall back to Option B), Task 3 (zoom=15 street labels), Task 4 (German labels — "München"), Task 5 (top-chrome symmetric 12 dp inset) | 04-VERIFICATION.md § Human Verification Checklist |
| (e) Ancillary | Liquid Glass FAB not regressed; no-crash on tab switch during admin-refresh; MapTiler tiles remain visible after backgrounded resume | 04-VERIFICATION.md § Human Verification Checklist |

After the drive, land the deferred `docs(04-1X): ... verified on device` commit(s) — one per plan (04-15, 04-16, 04-16-1) OR one combined `docs(04): Phase 4 rescope verified on device`. Replace the "pending combined Phase-4 close-out drive" markers in 04-VERIFICATION.md with the actual verification date + device + observed results, and flip the top-of-file `status:` from `human_needed` to `passed`.

**Blockers / concerns:**
- None from this plan. The Phase 3.1 drive-verify blocker (STATE Blockers section) is independent of Phase 4. G2 (P7 feature-state availability) is still an open gate for Phase 7.

---
*Phase: 04-osm-pipeline*
*Plan: 17*
*Completed: 2026-07-08*
