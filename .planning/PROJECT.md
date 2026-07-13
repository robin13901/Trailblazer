# Trailblazer

## What This Is

Trailblazer is a private Flutter app (iOS + Android) that tracks which roads the user has driven. Every trip is map-matched against OpenStreetMap on-device; driven road segments are permanently marked as "explored" and shown as colored lines on a Google-Maps-style base map. The app aggregates coverage into a five-level administrative hierarchy (Land → Bundesland → Landkreis → Gemeinde → Ortsteil) with a live "focus area" pill that changes based on map zoom, so the user can see how much of any given town, district, or state they've explored.

The app is being built for personal use (the developer's new company Mercedes gets unlimited kilometers and he enjoys driving new streets), but it is structured to a public-release quality bar in case it ships to the App Store later.

## Core Value

**When I open the map, I immediately see the roads I've already driven, painted onto the world — and that view keeps pulling me back to explore more.**

Everything else in the app exists to make that view accurate, satisfying, and worth returning to.

## Requirements

### Validated

(None yet — ship to validate)

### Active

**Map & Visualization**
- [ ] Google-Maps-like base map (cartoon style, not satellite) using MapLibre + OSM vector tiles
- [ ] Driven Kfz-Straßen (motorways/roads/residential/etc.) rendered in one color, driven Feldwege/Fußwege in a different color
- [ ] Partially-driven ways displayed with partial coloring (interval-based, not binary)
- [ ] Focus-area pill overlay at the top showing the currently-viewed admin region and its exploration percentage — content and admin level change based on map zoom (Land → Bundesland → Landkreis → Gemeinde → Ortsteil)

**Vehicle Management** — ~~removed 2026-07-13~~
- Cut entirely at user request. The app is single-user, single-vehicle in
  practice; coverage counts all trips unconditionally. See Key Decisions.

**Trip Tracking**
- [ ] Automotive motion-activity detection auto-records trips in the background, even when the app is closed
- [ ] Manual start/stop button for explicit "explore trip" mode
- [ ] Per-trip metadata: start/end time, duration, distance, average speed, max speed, raw GPS polyline, elevation profile if available
- [ ] Manual trip end via Stop button when trip was manually started

**Review Inbox**
- [ ] On app open, all unconfirmed background-recorded trips are shown as a list
- [ ] For each unconfirmed trip: date/time, distance, map preview
- [ ] User can keep or discard the trip
- [ ] Only confirmed trips are map-matched and counted

**Map-Matching**
- [ ] Trips are matched to OSM way IDs on-device (offline, no server, no ongoing cost)
- [ ] Matching runs asynchronously after a trip is confirmed (not real-time during driving)
- [ ] Unmatched GPS points (parking lots, GPS drift, off-road) are discarded — not force-snapped
- [ ] Driven ways are stored as intervals (way_id, start_m, end_m) to support partial coverage
- [ ] A way counts as "fully explored" when driven intervals cover ≥ (length − small buffer) to account for GPS imprecision at start/end

**Coverage Aggregation**
- [ ] Every OSM way is pre-associated with its enclosing admin regions (levels 2/4/6/8/9-10)
- [ ] Only Kfz-classified ways (`highway=motorway/trunk/primary/secondary/tertiary/residential/unclassified/service/living_street`) count toward %
- [ ] Coverage % per region = Σ length(driven Kfz-ways ∩ region) / Σ length(all Kfz-ways ∈ region)
- [ ] Focus area on the map is derived from map center + zoom; the correct admin level is selected automatically

**Region List View**
- [ ] Sortable list of regions with their exploration % (default sort: % descending)
- [ ] Search filter on the region list
- [ ] Filter by admin level

**UI / Look & Feel**
- [ ] Liquid Glass elements (via `liquid_glass_renderer`) used for: focus-area pill, bottom navigation, floating action button, "more" pane, panels overlaying the map
- [ ] Cartoonish, modern map style — visually adjacent to Google Maps but not a trademark-infringing clone
- [ ] Reuses proven glass patterns from the XFin reference project (`liquid_glass_widgets.dart`, aurora background, overlay-based glass panels)

**Quality Bar**
- [ ] `very_good_analysis` lints, `dart format` enforced in CI
- [ ] Widget tests + integration tests for all core flows (map render, trip record → match, focus-area pill logic)
- [ ] GitHub Actions: test workflow with Codecov upload, iOS build workflow (unsigned to start, signed later)
- [ ] Feature-first architecture (`lib/features/{map,tracking,trips,vehicles,regions,settings}/{data,domain,presentation}`)
- [ ] Riverpod 2.x for state management (no singleton `.instance` shortcuts)

### Out of Scope

**For v1 / initial release:**

- **Cloud sync / multi-device support** — Local-only via SQLite (Drift). Single-device usage. Backup deferred.
- **Import of historical driving data** (Google Timeline, Mercedes trip history) — Effort not justified for personal use; app starts from zero.
- **Mercedes-Benz API / vehicle-connected APIs** — No public "trip history with GPS polyline" API available for individual customers; phone-based GPS is more reliable, works with any vehicle, and avoids OAuth/ToS friction.
- **Regions outside Germany** — OSM extract size, matching graph size. DACH / Europe extension is a future milestone, not a v1 concern.
- **Real-time coloring during driving** — Map-matching happens after trip confirmation, not while moving. Battery + complexity cost too high for negligible benefit.
- **Social / sharing / leaderboards** — App is personal-use only for now.
- **Web / desktop platforms** — Background GPS is meaningless on those; iOS + Android only.
- **Force-snapping GPS to nearest road** — Unmatched points are dropped, not force-mapped, to avoid false "explored" segments.

## Context

**Domain background:**
- Similar consumer apps exist for cycling/running (Wanderer, Every Street, Rungoal) but few for driving. The "gamified street coverage" niche has proven consumer appeal.
- OSM's `highway=*` tagging is granular enough to differentiate Kfz-usable roads from footpaths/tracks — no external classification needed.
- Map-matching (GPS trace → road network) is a well-understood problem. Newson & Krumm 2009 (Hidden Markov Model matching) is the standard reference. GraphHopper, Valhalla, OSRM all implement variations; embedding a Dart implementation on-device is feasible for a country-sized graph.

**Developer background:**
- Existing Flutter app **XFin** (path: `C:\SAPDevelop\Privat\XFin`) provides a working reference implementation of:
  - `liquid_glass_renderer` integration with a single global `LiquidGlassSettings`
  - Overlay-based glass panels that keep content visible behind them (`showLiquidGlassPanel`, `more_pane.dart`)
  - Aurora animated gradient background
  - Drift + SQLite with per-entity DAOs
  - `flutter-tests.yml` GitHub Actions workflow with Codecov + `remove_from_coverage`
  - Reusable `ios-build.yml` project-type-agnostic iOS build workflow
- Anti-patterns to fix vs. XFin: `provider` + singleton `.instance` → switch to Riverpod 2.x; flat `screens/` → feature-first structure; empty `analysis_options.yaml` → `very_good_analysis`.

**Trigger:**
- Developer is about to receive a new Mercedes company car with unlimited free driving. This is the personal motivation.

## Constraints

- **Tech stack**: Flutter (Dart), iOS + Android only. No web, no desktop. — Background GPS + native platform APIs required.
- **Backend**: None. Local SQLite via Drift. — No hosting costs, no server maintenance, private data stays on device.
- **Ongoing cost**: Zero. — No hosted map tiles, no matching server, no cloud services.
- **Map data**: OpenStreetMap only. — Free, open, contains admin boundaries and detailed road classification.
- **Map-matching**: On-device / offline. — No server dependency, works without internet in the middle of nowhere.
- **Region MVP**: Germany. — OSM extract size manageable (~4 GB source, indexed subset much smaller), covers realistic driving area.
- **Google Maps look**: Inspired-by, not copy of. — Trademark risk if the app is ever published.
- **App must be publishable-quality**: strict lints, CI, tests, Codecov, iOS build pipeline. — Optionality for future App Store release.

## Key Decisions

### 2026-07-13 — Vehicles + Bluetooth removed entirely

**Cut:** The original Phase 9 (full vehicle CRUD, first-launch vehicle
onboarding, Bluetooth-fingerprint hints, per-vehicle display color, and the
`counts_for_coverage` filter) is removed at user request. Trailblazer is a
single-user, single-vehicle app in practice; the entire vehicle aspect was
dormant scaffolding — no CRUD UI, no BT dependency, no fingerprint capture ever
shipped, and `trips.vehicle_id` was a nullable column nothing wrote.

**Removed:**
- Requirements VEH-01..06 withdrawn (v1 total 112 → 106).
- App DB **schema v4** migration: drops the `vehicles` + `bt_fingerprints`
  tables and the `trips.vehicle_id` + `trips.bluetooth_hint` columns
  (`TableMigration(trips)` recreates the table copying only surviving columns;
  all trip/point/coverage data preserved).
- Code: `_DormantVehicleChip` inbox badge, `vehicleId` pass-through in
  `TripsDao`/`TripsRepository`/`TripListItem`/inbox queries, and the
  `TODO(phase-9)` per-vehicle hooks in `CoverageComputeService`.
- Requirement wording: TRK-02 "assigned to default vehicle" and COV-08
  "per vehicle" clauses struck.

**Impact:** `counts_for_coverage` was never read anywhere, so coverage math is
unchanged — every trip contributes unconditionally. Former Phases 10 (Settings
+ Backup) and 11 (Hardening) renumbered to **9** and **10**. Roadmap is now
10 phases.

**V2 backlog unchanged:** VEH-V2-01..03 (pattern-based / BT auto-detect) remain
in REQUIREMENTS.md's out-of-scope section for a possible future milestone.



**Abandoned:** The bundled-`osm.sqlite` architecture from the original Phase 4
(200 MB → 800 MB → projected 2.5 GB for full Germany at Berlin-derived densities)
after the user rejected the artifact size as unshippable.

**Adopted:**
- **Map tiles:** MapTiler Cloud (free tier `dataviz` / `dataviz-dark`; API key delivered via `--dart-define=MAPTILER_KEY=...` or `--dart-define-from-file=env/dev.json`; never in source or logs)
- **Road data:** on-demand Overpass fetches per trip's bbox, cached in App DB (Drift v3 table `overpass_way_cache` — composite PK (tileZ, tileX, tileY), gzipped payload, LRU 50 MB / 40 MB low water, 30-day TTL)
- **Tile granularity:** MANDATORY z12 slippy-tile splitting per the 04-13 payload probe (Nuremberg 100×100 km bbox returned 294.76 MiB / 45.22 MiB gzipped / 3.7 s Dart parse on dev box — both plan thresholds failed by 60×)
- **Admin polygons:** bundled `assets/admin/germany_admin.geojson.gz` (11.90 MB gzipped, 30 819 features across L2..L10; refreshable via Settings > Data > "Refresh admin regions")
- **`WayCandidateSource` interface** with runtime `OverpassWayCandidateSource` (cache-first) + test-only `FixtureWayCandidateSource`; Phase 5's matcher consumes it
- **Offline trips** transition to a new `pendingRoadData` state (between `recording` and `pending`) and retry on `AppLifecycleState.resumed` via a `pending_road_fetches` queue with exponential backoff (5m/30m/2h/12h/24h → abandon at 5 attempts)
- **`tool/osm_pipeline/`** retained as a dev-only fixture generator for Phase 5 golden-corpus tests — NOT invoked at app runtime

**Consequence:** Original Phase 4 plans 04-01..04-10 + Sub-Phase 04-10.1 Waves 1-4
are archived on-disk-only (SUMMARY docs preserved for archaeology under
`.planning/phases/04-osm-pipeline/`). The rescope-plan artifacts are 04-11..04-17 + 04-16-1.

- `04-10-1-05-germany-close-out-PLAN.md`: DELETED at session start (commit `e475ad8` 2026-07-08) — was superseded by the rescope before ever executing.
- `04-10-full-germany-close-out-PLAN.md`: DELETED at the same commit — was the original Phase-4 close-out plan.
- REQUIREMENTS.md OSMDB-01..OSMDB-07 rows deleted (119 → 112 total; a forward-reference HTML comment now stands in their place pointing at Phase 5 planning).
- ROADMAP.md Phase 4 renamed to "Map & Matching Data Sources"; Phase 5 renamed to "Overpass-Backed Matcher + Golden Corpus".

### 2026-07-09 — Phase 7 Gate G2 resolved: GeoJSON data-driven expressions (not feature-state)

`setFeatureState` throws `UnimplementedError` on iOS+Android in maplibre_gl 0.26.2 (web-only; upstream #889 targets 0.27.0). Coverage rendering therefore uses a single runtime GeoJSON source per brightness with data-driven paint expressions:

- **`is_full`** (int 1/0) and **`fraction`** (double 0–1) carried as GeoJSON feature properties; evaluated GPU-side by MapLibre's native rendering pipeline — zero per-feature Dart calls at frame time.
- **`setLayerProperties`** for live color-preset recolor (no source reload needed).
- Sources re-added in `onStyleLoaded` on every style swap (`setStyle()` wipes all programmatic sources).
- The '5×5 km sharded GeoJSON' literal wording in REN-05 is satisfied by this GeoJSON-source path; per-tile sharding is an optional Phase-8+ optimization, not v1-mandatory.

**Consequence for requirements:** REN-01 default color changed from warm green to orange/amber (green retained as one of 5 presets). REN-02 (Feldweg dashed-blue rendering) de-scoped from v1 — Feldweg/Fußweg render as plain Phase-4 base pmtiles geometry only.

### 2026-07-11 — Phase 8 coverage % denominator is fetched-ways-only (KNOWN LIMITATION)

Per-region coverage % is `Σ driven Kfz-length / Σ total Kfz-length`, but **"total" only counts OSM ways already present in `overpass_way_cache`** — i.e. ways near trips the user has actually driven, not the region's full road network. `CoverageComputeService` has no source of the complete per-region Kfz length.

**Consequences (observed on-device 2026-07-11):**
- Coarse regions (Bundesland L4, Landkreis L6) show inflated % — their denominator is only the fetched trip-local ways, not all roads in the region.
- A Bundesland whose only driving is inside one Landkreis shows the **identical** driven/total as that Landkreis (e.g. Bayern == Landkreis Miltenberg: 28.6 / 339.9 km), because every fetched way inside Miltenberg is also inside Bayern and no other Bavarian ways were ever fetched. The more Landkreise a trip spans, the larger (but still incomplete) the coarse denominator.
- Fine levels (Gemeinde L8 / Ortsteil L10) are the most trustworthy, since fetched ways roughly cover the small area actually driven.

**Why not fixed now (user decision 2026-07-11):** a real denominator needs either a bundled precomputed per-region total-Kfz-length table or bulk per-region Overpass area queries — a Phase 9/10-sized effort. The four sibling UI issues (German % format, jump-to-map camera, outside-DE / Deutschland pill fallback) were fixed; this one is logged and deferred.

**Also (same root):** the region browser does not show a **Deutschland (Land / L2) card** — the bundled admin polygon asset has no L2 country polygon to attribute ways against, and a synthetic national total would carry the same inflated-denominator caveat. Deferred with the denominator fix. The focus pill still shows "Deutschland" at country zoom via a level-4 in-Germany probe (no %), and "—" when panned outside Germany.

## Historical Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Flutter (not native) | Cross-platform iOS + Android from one codebase; developer already fluent | — Pending |
| MapLibre GL (not Google Maps SDK) | Google Maps polylines don't scale to thousands of segments; MapLibre supports data-driven styling and OSM vector tiles for free | — Pending |
| On-device offline map-matching | No ongoing cost, no server maintenance, works offline | — Pending |
| Custom HMM matcher (over GraphHopper FFI or Mapbox API) | Avoid Java/C FFI dependencies; keep everything in Dart for testability; async batch matching acceptable for UX; developer prefers full-control approach given "time is not a factor" | — Pending |
| Motion Activity Detection default-on, Bluetooth as hint only | Bluetooth is not always connected; motion detection is universal; manual start button remains as fallback | — Pending |
| Unmatched GPS points → discarded | Force-snapping creates false-positive explored segments (e.g., parallel roads); dropping keeps the "explored" set trustworthy | — Pending |
| Kfz-only ways count towards % | Aligns with user's mental model ("driving a Mercedes"), avoids inflating coverage with unreachable footpaths | — Pending |
| Feldwege/Fußwege still recorded and displayed in different color | Preserves the "look what I've explored" thrill without gaming the % metric | — Pending |
| Local-only SQLite via Drift (no cloud sync in v1) | Simplest, cheapest, matches single-device use case; opens migration path for later sync | — Pending |
| Riverpod 2.x (over `provider` singletons like XFin) | Testability, no static coupling, standard for new Flutter projects | — Pending |
| Feature-first folder structure | `lib/features/{feature}/{data,domain,presentation}` scales better than flat `screens/` | — Pending |
| `very_good_analysis` lints | Strict linting from day 1 raises quality bar | — Pending |
| Reuse XFin's `liquid_glass_widgets.dart` patterns | Working reference implementation, saves weeks of glass-rendering debugging | — Pending |
| Reuse XFin's `flutter-tests.yml` and `ios-build.yml` CI workflows | Battle-tested, project-agnostic, drop-in reusable | — Pending |
| Trip end = explicit Stop button (for manual mode), Motion Activity end (auto mode) | Prevents premature trip termination during traffic-light stops in manual mode; auto mode has 2-minute inactivity timeout | — Pending |

---
*Last updated: 2026-07-02 after initialization*
