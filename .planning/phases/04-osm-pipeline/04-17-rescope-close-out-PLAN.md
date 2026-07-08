---
id: 04-17
phase: 04-osm-pipeline
plan: 17
type: execute
wave: 4
depends_on: [04-16]
files_modified:
  - .planning/REQUIREMENTS.md
  - .planning/ROADMAP.md
  - .planning/PROJECT.md
  - .planning/STATE.md
  - .planning/phases/04-osm-pipeline/04-10-1-05-germany-close-out-PLAN.md
  - .planning/phases/04-osm-pipeline/04-VERIFICATION.md
autonomous: true
requirements: [OSM-01, OSM-02, OSM-03, OSM-04, OSM-05, OSM-06, OSM-07, OSM-08]

must_haves:
  truths:
    - "REQUIREMENTS.md's OSM-01..OSM-08 rows are rewritten for the rescoped architecture (fetched MapTiler tiles, on-demand Overpass fetches, cache, bundled admin polygons, WayCandidateSource, pendingRoadData retry, dev-only fixture generator, attribution)."
    - "REQUIREMENTS.md's OSMDB-01..OSMDB-07 rows are DELETED; a Phase 5 forward-reference comment replaces them explaining that matcher-consumption requirements move to Phase 5's requirements block."
    - "ROADMAP.md Phase 4 block: name → `Map & Matching Data Sources`; goal + SC list rewritten (SC1-5 from planning_context); depends-on unchanged; plan list rewritten with 04-11..04-17."
    - "ROADMAP.md Phase 5 block: name updated to `Overpass-Backed Matcher + Golden Corpus`; SCs updated to reflect that OSM DB no longer exists and matcher consumes WayCandidateSource."
    - "PROJECT.md Key Decisions has a new dated entry (2026-07-08) documenting the abandonment of bundled-osm.sqlite + the fetched-tiles/on-demand-Overpass adoption."
    - "STATE.md is updated: OSM-related pending todos (dev_germany.pmtiles replacement, SC4 renegotiation, full-Germany run) are cleared or marked superseded."
    - "`04-10-1-05-germany-close-out-PLAN.md` gets a `**STATUS: SUPERSEDED by rescope 2026-07-08**` line at the top; the file is NOT deleted."
    - "`04-VERIFICATION.md` documents that all five rescoped SCs (Wave 1-3 outcomes) were met."
  artifacts:
    - path: ".planning/phases/04-osm-pipeline/04-VERIFICATION.md"
      provides: "Written report matching each rescoped SC to its evidence (Wave 1 real-device smoke; Wave 2 online/offline test scenarios; Wave 3 bundled asset + regionAt latency)."
      min_lines: 80
  key_links:
    - from: ".planning/ROADMAP.md"
      to: ".planning/REQUIREMENTS.md"
      via: "Phase 4 block's Requirements: OSM-01..OSM-08 — new phrasing lands in both docs simultaneously"
      pattern: "OSM-0[1-8]"
    - from: ".planning/PROJECT.md"
      to: "rescope decision"
      via: "Key Decisions log entry dated 2026-07-08"
      pattern: "2026-07-08"
---

## Goal

Close out the rescoped Phase 4 in the planning docs: rewrite requirements, roadmap, project decisions, state; mark the old close-out plan as superseded; write `04-VERIFICATION.md`.

## Context

- Locked SCs (from planning_context — use these as the phase goal):
  1. Map screen renders MapTiler tiles seamlessly at all zoom levels; attribution visible in Settings > About; light + dark styles both work.
  2. Loopback `TileServer` and its deps are gone; `flutter analyze` clean.
  3. Trip finished online → fully-cached Overpass response within 30 s; trip finished offline → `pendingRoadData` state, picked up on reconnect.
  4. `WayCandidateSource` interface has two working impls; test suite uses the fixture impl; runtime uses Overpass impl.
  5. Admin polygons L2..L10 bundled at `assets/admin/germany_admin.geojson.gz` (<15 MB), loaded at first-use, `regionAt(lat, lng, level)` correct for 5 known coordinates.
- New OSM-01..OSM-08 phrasing (from planning_context):
  - OSM-01: App uses MapTiler Cloud for vector tiles (API key via --dart-define, never in source)
  - OSM-02: Trip completion triggers on-demand Overpass fetch for the trip's bbox
  - OSM-03: Overpass responses cached in App DB (Drift v3 table, LRU eviction at 50 MB budget)
  - OSM-04: Admin polygons (L2..L10) bundled as `assets/admin/germany_admin.geojson.gz`, refreshable via Settings
  - OSM-05: `WayCandidateSource` interface abstracts data source for Phase 5 matcher
  - OSM-06: Trip finished offline transitions to `pending_road_data` state, retried on next connectivity
  - OSM-07: `tool/osm_pipeline/` retained as dev-only fixture generator for Phase 5 golden-corpus tests
  - OSM-08: MapTiler + OSM attribution visible in Settings > About
- OSMDB-01..OSMDB-07 are DELETED entirely — the runtime "OSM DB" no longer exists.
- `04-10-1-05-germany-close-out-PLAN.md` is superseded but NOT deleted (archaeology).

## Tasks

<task type="auto">
  <name>Task 1: Rewrite REQUIREMENTS.md OSM + OSMDB rows</name>
  <files>
    .planning/REQUIREMENTS.md
  </files>
  <intent>Land the rescoped OSM-01..OSM-08 phrasing; delete OSMDB-01..OSMDB-07 with a forward-reference comment.</intent>
  <action>
    1. Read `.planning/REQUIREMENTS.md`.
    2. Find the OSM section (rows OSM-01..OSM-08). Replace each row's description with the rescoped phrasing from Context above. Keep any existing verification/status columns intact if the table has them.
    3. Find the OSMDB section (rows OSMDB-01..OSMDB-07). DELETE all 7 rows.
    4. Immediately after the (now-empty) OSMDB slot, add a comment block:
       ```markdown
       <!--
         OSMDB-01..OSMDB-07 were phrased around a bundled-osm.sqlite architecture
         that was abandoned 2026-07-08 (see PROJECT.md Key Decisions). Runtime
         road-data now comes from Overpass via WayCandidateSource (OSM-02, OSM-05).
         Matcher-consumption requirements move to Phase 5's requirements block —
         to be authored during Phase 5 planning.
       -->
       ```
    5. Update any REQUIREMENTS.md summary/counts table if it has one (total requirement count may drop by 7).
  </action>
  <verify>
    ```bash
    grep -E "^OSM-0[1-8]" .planning/REQUIREMENTS.md
    grep -c "OSMDB-" .planning/REQUIREMENTS.md    # should be 0 or only in the comment
    ```
    All 8 OSM rows carry rescoped phrasing; no live OSMDB rows.
  </verify>
</task>

<task type="auto">
  <name>Task 2: Rewrite ROADMAP.md Phase 4 + Phase 5 blocks; update progress table</name>
  <files>
    .planning/ROADMAP.md
  </files>
  <intent>Roadmap reflects the rescope.</intent>
  <action>
    1. **Phase 4 block:**
       - Rename to `Phase 4: Map & Matching Data Sources`.
       - New goal: "The app renders live MapTiler tiles, fetches on-demand Overpass road data per trip (cached + retry-safe when offline), and answers admin-region name lookups from a bundled polygon asset."
       - Depends on: Phase 1, Phase 3 (needs trip lifecycle for the pendingRoadData state).
       - Requirements: OSM-01..OSM-08.
       - Replace the 5 legacy SCs with the 5 rescoped SCs (verbatim from Context above).
       - Plans list: rewrite as 04-11..04-17 (7 plans, 4 waves). Format:
         ```
         Plans: 7 plans (rescoped 2026-07-08 — original 04-01..04-10 + 04-10-1-* archived on disk)
           - [ ] 04-11-maptiler-provider-and-key-plumbing-PLAN.md — MapTiler API key + TileProviderConfig + attribution + style-ID spike
           - [ ] 04-12-style-rewrite-and-tileserver-teardown-PLAN.md — swap MapLibre to MapTiler URL + delete TileServer + real-device smoke checkpoint
           - [ ] 04-13-overpass-client-and-payload-probe-PLAN.md — OverpassClient + WayCandidate model + Berlin→Munich payload probe
           - [ ] 04-14-drift-migration-v3-and-daos-PLAN.md — App DB v3 + overpass_way_cache + pending_road_fetches + DAOs
           - [ ] 04-15-way-candidate-source-and-trip-flow-PLAN.md — WayCandidateSource interface + Overpass impl + trip coordinator + offline checkpoint
           - [ ] 04-16-bundled-admin-polygons-and-lookup-PLAN.md — dev CLI + assets/admin/germany_admin.geojson.gz + AdminRegionLookup + Settings refresh
           - [ ] 04-17-rescope-close-out-PLAN.md — docs rewrite + VERIFICATION.md + supersede old close-out plan
         ```

    2. **Phase 5 block:**
       - Rename to `Phase 5: Overpass-Backed Matcher + Golden Corpus`.
       - Update goal: "The HMM matcher consumes `WayCandidateSource` (from Phase 4) to match a confirmed trip's polyline to a correct list of driven way intervals, and a CI-runnable golden corpus verifies it."
       - Depends on: Phase 4.
       - Requirements: replace `OSMDB-*` items with a note: `Matcher-facing requirements to be authored during Phase 5 planning (see rescope decision 2026-07-08).` Keep MMT-01..MMT-10, QUA-02.
       - Update SC1: no longer "app downloads OSM DB". Replace with: "Matcher consumes `WayCandidateSource.fetchWaysInBbox` on the matcher isolate; the source's cache-first path is warm before matching starts."
       - Update SC2: `findWaysNear` is now a method on the source (or the matcher builds its own R-Tree from the returned ways for the trip's bbox). Rephrase.
       - Other SCs (SC3 golden corpus, SC4 matcher on isolate, SC5 driven_way_intervals) remain approximately intact — light edits for clarity.

    3. **Coverage section (bottom of ROADMAP.md):**
       - Reduce OSMDB row from 7 to 0 (or delete the row entirely).
       - Update total to 112 (119 - 7).

    4. **Progress table:**
       - Update Phase 4 row: "Plans Complete" → "7 rescoped plans (04-11..04-17); prior 8 plans + 04-10-1-* archived-on-disk-only".
       - Status remains "In progress" until 04-17 lands.
  </action>
  <verify>
    ```bash
    grep -E "^### Phase 4:" .planning/ROADMAP.md      # confirms rename
    grep -E "^### Phase 5:" .planning/ROADMAP.md      # confirms rename
    grep -c "04-11-" .planning/ROADMAP.md             # >0 (in plan list)
    grep -c "OSMDB" .planning/ROADMAP.md              # 0 or only in a note
    ```
    Names updated; plan list current; OSMDB references removed from the roadmap body.
  </verify>
</task>

<task type="auto">
  <name>Task 3: Add PROJECT.md Key Decision + supersede old close-out + clean STATE.md</name>
  <files>
    .planning/PROJECT.md
    .planning/STATE.md
    .planning/phases/04-osm-pipeline/04-10-1-05-germany-close-out-PLAN.md
  </files>
  <intent>Document the rescope decision + prevent execute-phase from re-running the old close-out plan.</intent>
  <action>
    1. **`.planning/PROJECT.md`:** find the "Key Decisions" section (grep). Add a new dated entry:
       ```markdown
       ### 2026-07-08 — Phase 4 rescope: fetched tiles + on-demand Overpass matching

       **Abandoned:** The bundled-`osm.sqlite` architecture from the original Phase 4
       (200 MB → 800 MB → projected 2.5 GB) after user rejected the artifact size
       as unshippable.

       **Adopted:**
       - Map tiles: MapTiler Cloud (free tier, --dart-define API key)
       - Road data: on-demand Overpass fetches per trip's bbox, cached in App DB (Drift v3, LRU 50 MB)
       - Admin polygons: bundled `assets/admin/germany_admin.geojson.gz` (<15 MB), refreshable via Settings
       - `WayCandidateSource` interface with runtime Overpass + test-fixture impls; Phase 5's matcher consumes it
       - Offline trips transition to `pendingRoadData` state and retry on reconnect (`pending_road_fetches` queue)
       - `tool/osm_pipeline/` retained as dev-only fixture generator for Phase 5 golden-corpus tests

       **Consequence:** Original Phase 4 plans 04-01..04-10 + Sub-Phase 04-10.1 Waves 1-4
       are archived on-disk-only (SUMMARY docs preserved for archaeology).
       Wave 5's close-out (`04-10-1-05-germany-close-out-PLAN.md`) is marked SUPERSEDED.
       ```

    2. **`.planning/phases/04-osm-pipeline/04-10-1-05-germany-close-out-PLAN.md`:**
       - Read the first ~10 lines. Add BELOW the frontmatter (or as the very first line if there's no frontmatter):
         ```markdown
         **STATUS: SUPERSEDED by rescope 2026-07-08 — see .planning/PROJECT.md Key Decisions
         and 04-11..04-17-PLAN.md. This file is retained on disk for archaeology only;
         DO NOT execute.**
         ```
       - Do NOT delete the file. Do NOT modify anything else in it.

    3. **`.planning/STATE.md`:**
       - Find pending-todos section. Remove items that are now obsolete:
         - "dev_germany.pmtiles replacement / full-Germany run" — obsolete, tiles come from MapTiler now.
         - "SC4 renegotiation (800 MB → higher?)" — obsolete, no bundled osm.sqlite.
         - Any item referencing `germany-base.pmtiles` production — obsolete.
         - Keep todos that survive the rescope (e.g. "Phase 3.1 gap-closure required before Phase 5" — this is unrelated).
       - Update the "Current position" / "Phase progress" narrative:
         - Phase 4: rescoped 2026-07-08; new plans 04-11..04-17; ready for execute-phase.
       - Add a new decision to the "Accumulated decisions" block if the format warrants:
         - `2026-07-08 — Phase 4 rescoped to fetched-tiles + on-demand Overpass. See PROJECT.md.`
  </action>
  <verify>
    ```bash
    grep "2026-07-08" .planning/PROJECT.md
    head -5 .planning/phases/04-osm-pipeline/04-10-1-05-germany-close-out-PLAN.md
    grep -i "superseded" .planning/phases/04-osm-pipeline/04-10-1-05-germany-close-out-PLAN.md
    grep -iE "germany-base\.pmtiles|dev_germany\.pmtiles" .planning/STATE.md    # should show 0 or only historical
    ```
    PROJECT.md has the dated decision; old close-out plan has SUPERSEDED marker; STATE.md cleared of obsolete todos.
  </verify>
</task>

<task type="auto">
  <name>Task 4: Write 04-VERIFICATION.md matching each rescoped SC to evidence</name>
  <files>
    .planning/phases/04-osm-pipeline/04-VERIFICATION.md
  </files>
  <intent>Closing report — did each SC land?</intent>
  <action>
    **Before writing 04-VERIFICATION.md, read the source-of-truth documents:**

    1. `.planning/phases/04-osm-pipeline/04-11-STYLE-SPIKE.md` — style-ID evidence for SC1 (which MapTiler style IDs were confirmed on the free tier).
    2. `.planning/phases/04-osm-pipeline/04-13-PAYLOAD-PROBE.md` — payload probe result for SC3 (Berlin→Munich response size + tile-split MANDATORY/OPTIONAL verdict).
    3. `04-12-SUMMARY.md` + `04-15-SUMMARY.md` (or the on-disk equivalents produced during execution) — real-device checkpoint results (Wave 1 MapTiler smoke; Wave 2 online/offline/reconnect scenarios).

    **If a checkpoint result is missing** (e.g. real-device drive deferred per user memory `defer-in-car-verification`), leave the corresponding evidence field as `<pending in-car verification>` and note the reason. Do NOT block the docs close-out on a deferred drive — the code-complete gate is what matters for phase progress.

    Create `.planning/phases/04-osm-pipeline/04-VERIFICATION.md`:

    ```markdown
    # Phase 4 (Rescoped): Map & Matching Data Sources — Verification

    **Verified:** {today's date, YYYY-MM-DD}
    **Rescoped:** 2026-07-08
    **Plans:** 04-11..04-17

    ## Rescoped Success Criteria

    ### SC1: MapTiler tiles seamless at all zoom, attribution visible
    - **Evidence:** 04-12 real-device smoke checkpoint (Task 3) — passed on {device model} on {date}.
    - **Attribution:** Settings > About shows clickable `© MapTiler © OpenStreetMap contributors` links. On-map MapLibre attribution button restored at bottom-left.
    - **Style spike:** confirmed style IDs documented in `04-11-STYLE-SPIKE.md`.

    ### SC2: TileServer excised
    - **Evidence:** files `lib/features/map/data/tile_server.dart`, `lib/features/map/data/tile_server_providers.dart`, `tool/fetch_pmtiles.sh`, `tool/fetch_pmtiles.ps1` no longer on disk (git log confirms deletions in 04-12).
    - `pmtiles`, `shelf`, `shelf_router` removed from `pubspec.yaml` (04-12 commit `chore(04-12): swap MapLibre to MapTiler remote style + delete loopback TileServer`).
    - `flutter analyze` clean; `flutter test` green.

    ### SC3: Online trip → Overpass cached within 30 s; offline trip → pendingRoadData + reconnect drain
    - **Evidence:** 04-15 real-device checkpoint (Task 4) — Scenarios A + B + C all passed on {device model} on {date}.
    - **Trip lifecycle:** new `pendingRoadData` state between `active` and `pending`.
    - **Queue:** `pending_road_fetches` table with cascade-delete on trip removal; drainQueue triggered on `AppLifecycleState.resumed`.

    ### SC4: WayCandidateSource with two impls
    - **Evidence:**
      - `lib/features/matching/data/way_candidate_source.dart` — abstract interface.
      - `lib/features/matching/data/overpass_way_candidate_source.dart` — runtime impl (cache-first via OverpassWayCacheDao).
      - `test/helpers/fixture_way_candidate_source.dart` — test impl (gzipped-JSON-backed).
    - **Test coverage:** 04-15 Task 2 tests (cache miss/hit/TTL/dedupe/partial-on-error).

    ### SC5: Admin polygons bundled + regionAt correct + <15 MB gzipped
    - **Evidence:**
      - Bundle: `assets/admin/germany_admin.geojson.gz` at {actual size} MB gzipped (<15 MB budget).
      - Lookup: 5 fixture coordinates (Berlin=Berlin, Kreuzberg, Kleinheubach=Kleinheubach/Miltenberg/Bayern) round-trip correctly (04-16 Task 2 tests).
      - Latency: mean regionAt() < 5 ms (04-16 Task 2 test 7).
      - Refresh: Settings > Data > "Refresh admin regions" wired via `AdminBundleRefresher` (04-16 Task 3).

    ## Payload Probe Results (from 04-13)

    - Berlin→Munich bbox response: {size} MB uncompressed, {parse time} ms.
    - Tile-split verdict: {MANDATORY | OPTIONAL as documented in 04-13-PAYLOAD-PROBE.md}.
    - Consequence for 04-15: {which coalescing path was implemented}.

    ## Not in Phase 4 (deferred to Phase 5)

    - HMM matcher (consumes WayCandidateSource).
    - Golden corpus generation via `tool/osm_pipeline` fixture PBFs.
    - `driven_way_intervals` table.

    ## Legacy Artifacts On Disk (not deleted)

    - `04-01..04-10-*-PLAN.md` + SUMMARYs: original Phase 4 bundled-pipeline architecture. Superseded 2026-07-08.
    - `04-10-1-01..04-10-1-04-*-PLAN.md` + SUMMARYs: Sub-Phase 04-10.1 Waves 1-4 (dev-only pipeline improvements). Retained as `tool/osm_pipeline/` still exists as dev tooling.
    - `04-10-1-05-germany-close-out-PLAN.md`: marked SUPERSEDED at top of file. Do not execute.
    ```

    Fill in the `{placeholder}` fields based on actual results from Wave 1, 2, 3.
  </action>
  <verify>
    ```bash
    cat .planning/phases/04-osm-pipeline/04-VERIFICATION.md | head -60
    ```
    File exists; all 5 SCs have evidence; payload probe result recorded; legacy artifacts noted.
  </verify>
</task>

## Success Criteria

- REQUIREMENTS.md: OSM-01..OSM-08 rewritten; OSMDB-01..OSMDB-07 deleted.
- ROADMAP.md: Phase 4 renamed + rewritten; Phase 5 name updated; plan list current; coverage table updated.
- PROJECT.md: Key Decisions log has 2026-07-08 rescope entry.
- STATE.md: obsolete todos cleared; new decision recorded.
- `04-10-1-05-germany-close-out-PLAN.md`: SUPERSEDED header added; body untouched.
- `04-VERIFICATION.md`: written with evidence for all 5 rescoped SCs.

## Ralph Loop

- This is a docs-only plan — no `flutter analyze` required. Verify via `grep` per task.
- No pre-push code impact.

## Deviations

- If REQUIREMENTS.md table structure has columns beyond description (verification status, source phase, etc.), preserve those columns and only edit the description text.
- If PROJECT.md doesn't have a "Key Decisions" section yet, create one; put the 2026-07-08 entry as the first item.
- If STATE.md format is more structured than plain-text (e.g. YAML frontmatter with fields), respect that structure and only edit the fields specified.

## Commit Strategy

- Task 1 commit: `docs(04-17): rewrite REQUIREMENTS.md OSM-01..OSM-08; delete OSMDB rows`
- Task 2 commit: `docs(04-17): rewrite ROADMAP.md Phase 4 + Phase 5 blocks for rescope`
- Task 3 commit: `docs(04-17): PROJECT.md rescope decision + supersede old close-out + STATE.md cleanup`
- Task 4 commit: `docs(04-17): 04-VERIFICATION.md with evidence for all 5 rescoped SCs`
