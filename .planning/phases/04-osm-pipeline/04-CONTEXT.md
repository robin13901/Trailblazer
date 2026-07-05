# Phase 4: OSM Pipeline - Context

**Gathered:** 2026-07-05
**Status:** Ready for planning

<domain>
## Phase Boundary

A repeatable dev-machine Dart CLI (`dart run tool/osm_pipeline`) that turns a raw OSM PBF into two slim runtime artifacts the app consumes:

1. `osm.sqlite` — Kfz + Feldweg way geometries, R-Tree spatial index, `way_admin` join table, admin region metadata, version stamp. Consumed by Phase 5 matcher.
2. `germany-base.pmtiles` — offline vector base map (roads, admin_boundaries, water, labels). Consumed by Phase 2 map screen and Phase 7 coverage overlay.

**In scope:** PBF parsing, highway filtering, admin-boundary extraction, way↔admin joining, R-Tree building, pmtiles authoring, `--bbox`-scoped runs for dev/testing.

**Out of scope (belongs elsewhere):**
- App runtime consumption of these files — Phase 5 (matcher isolate), Phase 2 (map rendering).
- OSM extract updates in-app — Phase 10 (Settings + Backup).
- HMM matcher itself — Phase 5.
- Driven-way overlay rendering — Phase 7.

</domain>

<decisions>
## Implementation Decisions

### Pipeline structure & CLI

- **Monolithic single command** — one entry point `dart run tool/osm_pipeline --bbox=… --pbf=…` runs all stages end-to-end. No sub-commands, no user-facing stage boundaries.
- **Ephemeral intermediates** — parsed nodes, filtered ways, admin geometries all live in memory (or in scratch temp files deleted on success). No `build/osm/` persistence between runs. If a run fails, next invocation starts fresh.
- **Minimal CLI flags** — only `--bbox` (required by SC5) and `--pbf` (input path). No `--stages`, no `--out`, no `--clean`. Keep the surface tiny; add flags when a real need appears.
- **Skip-log-continue error handling (default)** — malformed multipolygons, invalid geometries, and orphan tag rows are skipped, written to a `skipped.log` next to the outputs, and the pipeline continues. Full-Germany PBFs always contain edge cases; the pipeline must not die on a handful of them. No `--strict` flag yet — add if CI ever needs one.

### Highway filter & tag retention

- **Kfz allowlist (14 tags — standard drivable set minus `service`):** motorway, motorway_link, trunk, trunk_link, primary, primary_link, secondary, secondary_link, tertiary, tertiary_link, unclassified, residential, living_street, road. Excludes `highway=service` — parking-lot/driveway ways bloat way-count with minimal coverage-experience value.
- **Feldweg/Fußweg allowlist — Claude's Discretion.** Researcher must survey Germany OSM tagging conventions (typical `highway=track/path` usage, `motor_vehicle=*` sub-tagging on tracks) and propose the concrete set. Constraint: it must be *drivable-adjacent* enough that seeing it painted in dashed blue makes sense to a driver — pure `footway`/`cycleway` in urban centers probably does not qualify.
- **Retained tags on ways (beyond `highway` class which is always kept):** `name`, `ref`, `oneway`, `maxspeed`. Skipped: `surface` (no current SC needs it; add later if a feature demands it).
- **Directionality handling — Claude's Discretion.** Pick the representation that gives the smoothest matcher runtime experience. Researcher should evaluate (a) store raw `oneway` tag, (b) precomputed directional segments, (c) tag + normalized `is_directional` boolean handling the `oneway=-1` reversal. Constraint: whatever is chosen must fully cover `oneway=yes`, `oneway=no`, `oneway=-1`, and missing/unknown.

### PMTiles schema & style compatibility

- **Schema choice — Claude's Discretion.** Researcher should evaluate custom Trailblazer schema vs Protomaps v4 vs custom-subset-of-Protomaps-v4. Constraint: outputs must render smoothly under MapLibre GL on both platforms and fit the 200 MB budget (SC4).
- **Layer inventory (4 layers required):** `roads`, `admin_boundaries`, `water` (rivers + lakes), `labels` (places + road names).
- **Maxzoom = 11** — matches the current `dev_germany.pmtiles`, fits 200 MB budget with room to spare. Zoom 12+ tiles are over-scaled but roads stay readable at drive scale.
- **Rewrite Phase 2 style JSONs** — `assets/map_style_light.json` and `assets/map_style_dark.json` will be rewritten to match the new schema. No attempt to keep the old Protomaps-derived styles working; they were placeholder-quality anyway.

### osm.sqlite schema & admin joins

- **Segmented intersection for `way_admin`** — each Kfz way is split at admin-region borders into sub-segments; each sub-segment joins to exactly one region per admin level (2, 4, 6, 8, 9, 10). This is the accurate approach for Phase 8's coverage %: `Σ driven Kfz-length / Σ total Kfz-length` per region requires per-region length attribution, which centroid-only cannot deliver correctly for cross-border ways.
- **Admin geometry storage — Claude's Discretion.** Pick whatever gives the smoothest app runtime + most accurate visual experience. Researcher should evaluate: (a) polygons in osm.sqlite only, (b) polygons in pmtiles only + slim regions metadata in DB, (c) both. Constraint: Phase 8 focus-area pill (P8 SC1: 200 ms debounced updates) and region-shape rendering both need fast lookup; whichever storage supports both best wins.
- **R-Tree over per-segment rows** — each two-point segment of every Kfz way gets a row + bbox. Larger index vs way-bbox R-Tree, but the Phase 5 HMM matcher's `findWaysNear(lat, lng, radius)` (P5 SC2: p95 < 30 ms) directly benefits from tight bboxes. A 10 km autobahn as one bbox would flood candidates near the midpoint.
- **Version stamp — Claude's Discretion.** Encode `pbf_date`, `pipeline_schema_version`, `generated_at`, and `bbox` in whatever combination of SQLite `PRAGMA user_version` + `metadata` table is cleanest. Constraint: must be readable by the Phase 5 integrity check (P5 SC1 mentions schema/row-count checks) and future extract-swap logic (Phase 10 SC3).

### Claude's Discretion

- Feldweg/Fußweg exact tag set (see above).
- Directionality representation (see above).
- PMTiles schema choice: custom vs Protomaps v4 vs subset (see above).
- Admin geometry storage location (see above).
- Version-stamp encoding format (see above).
- Memory-vs-streaming implementation strategy for a full-Germany PBF (parsing model, isolate use, RAM budget).
- Progress-reporting UX inside the monolithic run — stage banners, ETA, tile counts.
- `skipped.log` format and rotation.
- SQLite pragmas for the runtime DB (page_size, WAL, synchronous mode) — pick what the matcher's read pattern needs.
- Any external tool wrapping vs pure-Dart implementation (osmium, imposm, tilemaker, tippecanoe) — evaluate license + reproducibility + install burden.

</decisions>

<specifics>
## Specific Ideas

- Pipeline should follow the "one command, quiet on success, loud on failure" ethos — `dart run tool/osm_pipeline --bbox=…` finishes with two artifacts on disk and a one-line summary. No configuration files, no interactive prompts. Should run cleanly on the dev Windows box.
- The 200 MB budget per artifact (SC4) is a hard constraint — architectural choices that blow it are wrong, even if theoretically nicer.
- Downstream Phase 5 uses `findWaysNear` heavily — R-Tree granularity choice directly shapes matcher latency.
- Downstream Phase 8 uses `way_admin` for region coverage % — the segmented-intersection choice makes that math correct on cross-border ways.
- The Berlin-bbox smoke-test path (SC1, SC5) is the primary dev iteration loop — must be fast enough that running it repeatedly during development doesn't cost minutes each time.

</specifics>

<deferred>
## Deferred Ideas

- Incremental / diff-based PBF updates (only re-process changed regions) — future Phase 10 concern, once extract updates ship in-app.
- Web-facing hosted pipeline / CI job that produces artifacts for others — v1 is single-developer, single-machine.
- Per-country / non-Germany extracts — the tool must accept `--bbox` and `--pbf` for arbitrary inputs, but no cross-country feature work in Phase 4.
- Track condition / `surface` tag exposure to UI — retention deferred until a feature demands it.
- Custom Liquid-Glass-styled attribution chip in-app — Phase 8+ concern; unrelated to pipeline.

</deferred>

---

*Phase: 04-osm-pipeline*
*Context gathered: 2026-07-05*
