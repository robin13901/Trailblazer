# Requirements: Trailblazer

**Defined:** 2026-07-02
**Core Value:** When I open the map, I immediately see the roads I've already driven, painted onto the world.

## v1 Requirements

### Foundation & CI (FND)

- [x] **FND-01**: Flutter project skeleton (iOS + Android only) with feature-first structure (`lib/features/`, `lib/core/`, `tool/`)
- [x] **FND-02**: `very_good_analysis` lints + `dart format --set-exit-if-changed` enforced in CI
- [x] **FND-03**: GitHub Actions test workflow runs `flutter analyze` + `flutter test --coverage` on push/PR
- [x] **FND-04**: Codecov integration: coverage report uploaded, generated files (`.g.dart`, `l10n/`) stripped before upload
- [x] **FND-05**: GitHub Actions iOS build workflow produces installable `.ipa` (unsigned initially)
- [x] **FND-06**: README with project description, architecture summary, build/test/CI badges
- [x] **FND-07**: Riverpod 3.x set up as sole state-management approach; DI via provider composition, no singleton `.instance`
- [x] **FND-08**: Drift App DB (mutable) scaffolded with migration infrastructure and `SchemaVerifier` tests
- [x] **FND-09**: `go_router` configured for typed navigation between top-level screens
- [x] **FND-10**: Logging, error boundaries, and typed exceptions in `lib/core/`
- [x] **FND-11**: iOS Info.plist purpose strings + Android manifest with `foregroundServiceType="location"` scaffolded from day one

### Map Display (MAP)

- [x] **MAP-01**: MapLibre GL widget renders a Google-Maps-inspired vector base map (cartoon style, not satellite)
- [x] **MAP-02**: PMTiles archive is the tile source; map works fully offline once the archive is present
- [x] **MAP-03**: User can pan, zoom, rotate, and tilt the map with standard gestures
- [x] **MAP-04**: Map shows current device location marker (blue dot) when location permission granted
- [x] **MAP-05**: Dark mode style switches automatically with system theme
- [x] **MAP-06**: Map style JSON is a project asset (customisable, not vendor-locked)
- [x] **MAP-07**: Camera state (last position, zoom) persists across app restarts

### Liquid Glass UI (UI)

- [x] **UI-01**: Focus-area pill overlays the top of the map showing current admin region + exploration %
- [x] **UI-02**: Bottom navigation is a Liquid Glass pill (Map, Trips, Regions, Settings)
- [x] **UI-03**: Floating action button (record trip) is Liquid Glass styled
- [x] **UI-04**: Panels/sheets overlaying the map use `showLiquidGlassPanel` overlay pattern (keeps map visible behind)
- [x] **UI-05**: **P2 gate**: Rendering spike on real iOS + Android device before Liquid Glass is committed to for on-map overlays; documented fallback (`FrostedGlassCard` / gradient tint) if BackdropFilter fails on MapLibre platform view
- [x] **UI-06**: App uses no traditional `AppBar` on the map screen; focus-area pill is the only top-of-screen chrome
- [x] **UI-07**: Light + dark themes both use the shared `LiquidGlassSettings` singleton pattern from XFin reference

### Map & Matching Data Sources (OSM) — rescoped 2026-07-08

- [x] **OSM-01**: App uses MapTiler Cloud for vector tiles (API key delivered via `--dart-define=MAPTILER_KEY=...` or `--dart-define-from-file=env/dev.json`; never checked into source or logs); light + dark styles switch with system theme
- [x] **OSM-02**: Trip completion triggers an on-demand Overpass fetch for the trip's bbox (partitioned by z12 slippy tiles per the 04-13 payload-probe MANDATORY tile-split verdict); Kfz 14-tag allowlist applied at parser boundary
- [x] **OSM-03**: Overpass responses cached in the App DB (Drift v3 table `overpass_way_cache`, composite PK `(tileZ, tileX, tileY)`, gzipped payload, LRU eviction at 50 MB high water / 40 MB low water, 30-day TTL)
- [x] **OSM-04**: Admin polygons (levels 2, 4, 6, 8, 9, 10) bundled as `assets/admin/germany_admin.geojson.gz` (~11.90 MB gzipped, well under the 15 MB budget); refreshable via Settings > Data > "Refresh admin regions" (writes to `<AppDocsDir>/admin/germany_admin.geojson.gz` and takes precedence over the bundled asset)
- [x] **OSM-05**: `WayCandidateSource` abstract interface abstracts the road-data source for the Phase 5 matcher; two working impls — `OverpassWayCandidateSource` (runtime, cache-first via `OverpassWayCacheDao`) and `FixtureWayCandidateSource` (test-only, gzipped-JSON-backed)
- [x] **OSM-06**: Trips completed offline transition to a new `pendingRoadData` state (between `recording` and `pending`); a `pending_road_fetches` queue (FK cascade on trip) is drained on `AppLifecycleState.resumed` with exponential backoff (5m/30m/2h/12h/24h) → abandon at 5 attempts
- [x] **OSM-07**: `tool/osm_pipeline/` is retained as a dev-only fixture generator for Phase 5 golden-corpus tests (NOT invoked at app runtime); the pipeline's outputs (`osm.sqlite`, `germany-base.pmtiles`) are no longer bundled with the app
- [x] **OSM-08**: MapTiler + OpenStreetMap attribution is visible and clickable in Settings > About (links to https://www.maptiler.com/copyright/ and https://www.openstreetmap.org/copyright); MapTiler free-tier TOS + ODbL compliance verified

<!--
  OSMDB-01..OSMDB-07 were phrased around a bundled-osm.sqlite architecture
  that was abandoned 2026-07-08 (see PROJECT.md Key Decisions). Runtime
  road-data now comes from Overpass via WayCandidateSource (OSM-02, OSM-05).
  Matcher-consumption requirements move to Phase 5's requirements block —
  to be authored during Phase 5 planning.
-->

### Vehicles (VEH) — REMOVED 2026-07-13

The Vehicles + Bluetooth feature was cut entirely at user request. VEH-01..06
are withdrawn; the `Vehicles` / `BtFingerprints` tables and the
`trips.vehicle_id` / `trips.bluetooth_hint` columns were removed via App DB
schema v4. Trailblazer is single-user, single-vehicle in practice — coverage
is computed over all trips unconditionally. See PROJECT.md Key Decisions.

### Trip Tracking (TRK)

- [~] **TRK-01**: ~~`flutter_background_geolocation` records GPS in the background when motion activity classifier reports `automotive` (>60 s duration) — trip auto-created as `pending`~~ **SUPERSEDED 2026-07-09** — user requested manual-only recording; automatic background trip-creation removed (Phase 6 gap-plan 06-08). See PROJECT.md Key Decisions / memory `auto-recording-removed-2026-07-09`.
- [x] **TRK-02**: User can manually start a trip via FAB on the map screen — trip immediately created as `pending`, marked as `manually_started` *(2026-07-13: "assigned to default vehicle" clause dropped — Vehicles feature removed)*
- [x] **TRK-03**: Manually-started trips end only when user presses the Stop button (short traffic-light stops do not terminate the trip)
- [~] **TRK-04**: ~~Auto-started trips end when motion classifier reports non-automotive for > 2 minutes (dwell termination)~~ **SUPERSEDED 2026-07-09** — moot with manual-only recording (no auto-trips exist to auto-terminate). Manual trips end only on user Stop (TRK-03).
- [x] **TRK-05**: Per-trip captured metadata: start/end timestamp, duration, distance (from GPS integration), avg speed, max speed, raw GPS polyline (lat/lng/accuracy/timestamp/altitude), motion activity type per fix
- [x] **TRK-06**: Bluetooth device fingerprint at trip start is stored on the trip as a hint (does not gate recording)
- [x] **TRK-07**: A trip records `manually_started` boolean, `auto_stopped` boolean, and `bluetooth_hint` string (or null)
- [x] **TRK-08**: Battery-conscious state machine: `idle → detecting → recording → paused` — GPS accuracy switches to `Best` (not `BestForNavigation`) during recording; DB writes batched every ~20 fixes
- [x] **TRK-09**: Live-tracking indicator visible on the map when a trip is being recorded (glass overlay with duration + distance)
- [x] **TRK-10**: iOS `whenInUse → Always` two-step permission ladder implemented; app never assumes Always is granted
- [x] **TRK-11**: Android `foregroundServiceType="location"` with persistent notification; user prompted to disable battery optimization

### Trip Review Inbox (INB)

- [x] **INB-01**: On app launch (and always available via Trips tab), user sees a list of all `pending` trips
- [x] **INB-02**: Each pending trip shows: date/time, duration, distance, ~~small static map preview of the route~~ *(map preview removed 2026-07-09 per user request)*, vehicle-guess badge if Bluetooth matched *(vehicle chip present, dormant until P9)*
- [x] **INB-03**: User can `keep` a trip: opens vehicle-assignment sheet, then marks trip as `confirmed`, enqueues map-matching *(vehicle-assignment sheet deferred to P9; Keep flips matched→confirmed + enqueues)*
- [x] **INB-04**: User can `discard` a trip: marks it as `rejected`, raw GPS deleted, no matching runs *(hard-delete — no `rejected` tombstone, per CONTEXT deviation)*
- [~] **INB-05**: ~~User can bulk-confirm all pending trips of a session (with default vehicle) or bulk-discard all~~ **DESCOPED** from Phase 6 (06-CONTEXT deviation) — single-trip Keep/Discard only; bulk ops deferred.
- [x] **INB-06**: Confirmed and rejected trips are visible in a separate "Trip History" list within the Trips tab *(confirmed + in-flight only — rejected are hard-deleted, per CONTEXT deviation)*
- [x] **INB-07**: User can retroactively change vehicle assignment on a confirmed trip (triggers coverage-cache invalidation) *(retroactive reassignment UI lands with vehicles in P9; invalidation path in place)*
- [x] **INB-08**: User can delete a confirmed trip (removes its contribution to coverage; coverage-cache invalidated) *(delete-from-detail wired, ordered delete + invalidation)*

### Map-Matching (MMT)

- [x] **MMT-01**: Confirmed trip is enqueued into a long-lived `MatcherIsolate` (single warm worker, ways payload shipped per-job via `WayCandidateSource` on the main isolate)
- [x] **MMT-02**: Matcher uses Hidden Markov Model (Newson-Krumm 2009): emission probability weighted by `horizontalAccuracy`, transition probability weighted by road-network distance
- [x] **MMT-03**: Matcher performs full retrospective match on trip end (not live during driving) — single authoritative pass
- [x] **MMT-04**: R-Tree candidate query per GPS point returns top-5 candidates within an adaptive radius (25 m base, expands with HDOP)
- [x] **MMT-05**: Points that cannot be matched confidently are dropped (not force-snapped) — trips may have gaps
  NOTE (2026-07-07): Feldweg ways are not in osm.sqlite (see OSM-02);
  GPS traces over Feldwege will produce points that the matcher cannot
  snap to a road — these register as trip gaps or "points that cannot be
  matched confidently are dropped" per this requirement. Intended v1
  scope per Plan 04-10.1. If future work restores Feldweg matching,
  this note is deleted.
- [x] **MMT-06**: Matcher output: list of `driven_way_intervals(way_id, start_m, end_m, direction, trip_id, timestamp)` written to App DB
- [x] **MMT-07**: Autobahn / Bundesstraße parallel-road smearing mitigated by min-speed 15 km/h threshold for high-class ways + Viterbi lookahead of ≥ 5 emissions
- [x] **MMT-08**: Matcher is cancellable (user deleting an in-flight trip cancels its match job)
- [ ] **MMT-09**: A CI-runnable "golden trip corpus" of ≥ 20 recorded trips (autobahn, Kreisel, tunnel, parking, U-turn, city grid, roundabout, one-way street) with known-correct way-ID sequences; regression on any golden trip fails CI *(Phase 5 close-out 2026-07-08: harness code-complete + 1 synthetic seed shipped + CI gate wired; 4 real-drive fixtures deferred to drive-batch follow-up; growing to ≥ 20 is Phase 6's inherited obligation per ROADMAP)*
- [x] **MMT-10**: Raw GPS retained 30 days after match for re-matching if parameters change; then deleted (user can override retention in settings)

### Coverage Aggregation (COV)

- [x] **COV-01**: `driven_way_intervals` are merged per way: overlapping intervals collapsed into unions
- [ ] **COV-02**: A way counts as fully explored when the merged interval covers ≥ `(length_m − 15 m end buffer − 15 m start buffer)` of the total length
- [ ] **COV-03**: A way is "partially explored" if covered but not fully — surfaces with proportional color in v1.x, in v1 shown as a distinct partial color
- [ ] **COV-04**: Coverage % per region = `Σ driven_length(Kfz-way ∩ region) / Σ length(all Kfz-ways ∈ region)` — Feldweg/Fußweg excluded from both numerator and denominator
- [x] **COV-05**: Coverage cache table (`coverage_by_region`) stores per-region % + last-computed timestamp; recomputed only on invalidation *(physical table name is `coverage_cache`; `coverage_by_region` is the logical alias)*
- [x] **COV-06**: Invalidation triggers: new driven intervals written, trip deleted, vehicle `counts_for_coverage` changed, OSM extract updated *(3 of 4 triggers wired; `counts_for_coverage` trigger deferred to P9 with vehicles)*
- [ ] **COV-07**: Coverage recomputation runs on a compute isolate to keep UI responsive
- [ ] **COV-08**: A "total km driven" and "unique km driven" statistic is maintained globally *(2026-07-13: "per vehicle" clause dropped — Vehicles feature removed)*

### Focus-Area Pill (FOC)

- [ ] **FOC-01**: On map camera idle, a resolver derives the appropriate admin level from the current zoom level (Land at world, Bundesland at country zoom, Landkreis at region zoom, Gemeinde at city zoom, Ortsteil at street zoom)
- [ ] **FOC-02**: The resolver identifies which region the map center falls into at the chosen admin level (point-in-polygon query against admin boundaries)
- [ ] **FOC-03**: Pill displays "{region name} — {coverage %}" e.g. "Grebenhain · 26%"
- [ ] **FOC-04**: If no admin region at the chosen level covers the center (e.g. over water), pill shows the parent-level region
- [ ] **FOC-05**: Tapping the pill opens the region detail sheet
- [ ] **FOC-06**: Region breadcrumb (Land › Bundesland › … › current level) visible when pill expanded
- [ ] **FOC-07**: Resolver is debounced on camera idle (200 ms) and cached per (level, region) tuple

### Coverage Rendering (REN)

- [ ] **REN-01**: Driven Kfz-ways are rendered on the map in a distinctive color (default: orange/amber; default color deviation locked 2026-07-09 — green remains one of 5 presets) via a runtime GeoJSON source with data-driven paint expressions (feature-state unavailable on mobile — see Gate G2)
- [~] **REN-02**: **DE-SCOPED v1 (2026-07-09):** Feldweg/Fußweg ways receive NO Phase-7 coverage styling — they render as plain Phase-4 base pmtiles geometry only. No dashed-blue, no driven-state color. Intentionally not-in-v1; may revive as a "show trails/tracks" toggle in a later milestone. (Original spec: "Driven Feldweg/Fußweg ways rendered in a distinct secondary color (default: dashed blue).")
- [ ] **REN-03**: Partial coverage on a way is rendered with a proportional gradient or reduced opacity (fallback if per-segment coloring impossible). v1 uses whole-way reduced-opacity scaling (the documented fallback); per-segment/gradient coloring deferred to v1.x.
- [ ] **REN-04**: Rendering scales to ≥ 50 000 driven segments without dropping below 30 fps on target devices (stress test in P7)
- [ ] **REN-05**: **P7 gate — Gate G2 RESOLVED 2026-07-09 = FAIL.** `setFeatureState` throws `UnimplementedError` on iOS+Android in maplibre_gl 0.26.2 (web-only). Resolution: single runtime GeoJSON source per brightness + data-driven paint expressions (`is_full`/`fraction` GeoJSON props evaluated GPU-side); the '5×5 km sharded GeoJSON' literal wording is satisfied by this GeoJSON-source path — per-tile sharding is an optional Phase-8+ optimization, not v1-mandatory.
- [ ] **REN-06**: Coverage colors are customisable per user in settings (from a small preset palette)

### Region List View (REG)

- [ ] **REG-01**: Region browser is a full-screen list, tabbed by admin level (Land / Bundesland / Landkreis / Gemeinde / Ortsteil)
- [ ] **REG-02**: Default sort: exploration % descending
- [ ] **REG-03**: Alternative sorts: alphabetical, driven km, total km, last-driven date
- [ ] **REG-04**: Search filter on region name (fuzzy match)
- [ ] **REG-05**: Tapping a region opens region detail: full name breadcrumb, coverage %, list of driven ways within, top trips within
- [ ] **REG-06**: "Jump to on map" action zooms map to the region's bounding box
- [ ] **REG-07**: Region list is lazy-loaded (thousands of Gemeinden and Ortsteile in Germany)

### Settings (SET)

- [ ] ~~**SET-01**: Vehicle management~~ — DE-SCOPED 2026-07-13 (Vehicles + Bluetooth phase removed)
- [ ] ~~**SET-02**: OSM data status / "check for updates" / update flow~~ — DE-SCOPED (no OSM extract under the Phase-4 MapTiler+Overpass rescope; credits moved to About/SET-09)
- [x] **SET-03**: Permissions status inspector (location Always/whenInUse, motion activity, notifications, battery optimization — Bluetooth dropped with Vehicles) — Phase 9 (read-only v1)
- [x] **SET-04**: Color palette selection for driven / partial / Feldweg overlays — Phase 9 (relocated existing Phase-7 picker into Coverage section)
- [x] **SET-05**: Raw GPS retention setting (default 30 days, options: 0/30/365 days/forever) — Phase 9
- [x] **SET-06**: Battery-diagnostic HUD toggle (fix rate, matcher queue depth, cache-hit rate) — Phase 9
- [x] **SET-07**: Backup: export a shareable `.trailblazer` App DB archive via OS share sheet (SET-07 "encrypted" superseded → plain archive per 09-CONTEXT) — Phase 9
- [x] **SET-08**: Restore: user picks a backup file; app validates and wipe-and-swaps the App DB — Phase 9
- [x] **SET-09**: About screen with app version, OSS licenses, credits (OSM + MapTiler) — Phase 9

### Quality Gates (QUA)

- [ ] **QUA-01**: All feature modules have widget tests for their key screens (Map, Trip Inbox, Vehicle List, Region List, Focus-Area Pill) [DE-SCOPED 2026-07-17 — tied to the dropped Hardening phase; see ROADMAP + 10-CONTEXT decision 9]
- [x] **QUA-02**: Core map-matcher has ≥ 90% line coverage; golden-trip regression suite in CI
- [x] **QUA-03**: Drift migration tests use `SchemaVerifier` to validate every migration step
- [ ] **QUA-04**: `patrol` integration tests cover: onboarding flow, first trip recording, inbox confirmation, matching → coverage update, region browser [DE-SCOPED 2026-07-17 — tied to the dropped Hardening phase; see ROADMAP + 10-CONTEXT decision 9]
- [x] **QUA-05**: iOS + Android debug builds succeed in CI
- [x] **QUA-06**: 60-minute driving battery-drain baseline (measured on real device) committed to repo; regression on major changes flagged  <!-- Complete (user-attested — 96 km/1h40 drive 2026-07-09, no battery anomalies observed) -->
- [ ] **QUA-07**: Real-device QA gauntlet before release: iPhone (current + one older), Samsung, Xiaomi (worst-case battery-killer) [DE-SCOPED 2026-07-17 — tied to the dropped Hardening phase; see ROADMAP + 10-CONTEXT decision 9]

## v2 Requirements

Deferred to future milestone. Tracked but not in v1 roadmap.

### Advanced Rendering

- **REN-V2-01**: Per-vehicle map layer coloring (toggle each vehicle's driven-roads layer independently)
- **REN-V2-02**: Recency-based glow shading (recently driven roads brighter)
- **REN-V2-03**: Adjacent-unexplored highlight (subtle emphasis on ways adjacent to already-driven ways)

### Data & Import

- **IMP-V2-01**: Google Timeline JSON import for retroactive population
- **IMP-V2-02**: GPX export of individual trips
- **IMP-V2-03**: Timeline scrubber to view coverage state at any historical date

### Regions

- **REG-V2-01**: Custom user-drawn regions (draw a polygon on the map, get % coverage for it)
- **REG-V2-02**: Region-completion milestones (silent achievements: "You've fully explored Geisfelds!")

### Vehicles

- **VEH-V2-01**: Pattern-based automatic vehicle detection (driving-style ML — steering rhythm, acceleration profile)
- **VEH-V2-02**: Bluetooth vehicle auto-detect on Android (Kotlin platform-channel enumerating paired Classic BT devices)
- **VEH-V2-03**: iOS CoreMotion + AVAudioSession BT-route heuristic for vehicle detection

### Multi-country

- **CTY-V2-01**: Support switching OSM extract to Austria, Switzerland, or a DACH-combined extract
- **CTY-V2-02**: Per-country coverage stats

### Analytics

- **ANA-V2-01**: Trip split/trim editor (edit start/end points, split a trip in two)
- **ANA-V2-02**: Per-segment matcher confidence visualization (debugging matcher quality)
- **ANA-V2-03**: Heatmap layer (density of times a segment was driven)

### Sharing

- **SHR-V2-01**: Poster PDF/PNG export ("my Germany" as a printable coverage poster)

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| Cloud sync / multi-device | Local-only by design; single-device use case; adding cloud kills the "zero ongoing cost" constraint |
| Mercedes-Benz vehicle API integration | No public "trip history with GPS polyline" API for individual customers; phone GPS more reliable + works with any vehicle |
| Real-time coloring during driving | Matching happens after trip confirmation; realtime adds battery cost + complexity for negligible benefit |
| Social / friends / leaderboards | Personal-use app; excluded regardless of future App Store status |
| XP / streaks / badges / gamification loops | Feels cheap; the coverage map itself is the reward |
| Push notifications for nearby unexplored roads | Nudge-driven, not user-driven; violates the "user comes back because it's satisfying" motive |
| Turn-by-turn navigation | Google Maps / Apple Maps do this; not the product |
| Web / desktop platforms | Background GPS is meaningless there |
| Force-snapping unmatched GPS to nearest road | Would create false-positive explored segments; explicitly rejected |
| Fitness metrics (calories, cadence, HR) | Wrong category — Trailblazer is not a fitness app |
| OAuth / public API / third-party integrations | No integration surface required for local-only single-user app |
| Elevation profiles per trip | Nice-to-have but not core; if it comes free with GPS data it may sneak in |
| Ads / supporter tier / IAP | Personal use; publishable-quality doesn't mean monetized |
| Route recommendation engine | Explicitly against the "explore what you want" philosophy |
| Historical data import from Google Timeline (v1) | Deferred to v2 to keep v1 scope tight |

## Traceability

**Coverage:**
- v1 requirements: 106 total (was 119 pre-rescope; OSMDB-01..OSMDB-07 deleted 2026-07-08; VEH-01..06 deleted 2026-07-13 — see PROJECT.md Key Decisions)
- Mapped to phases: 106 / 106 (100 %)
- Unmapped: 0

Every requirement maps to exactly one phase. Phase Gates in ROADMAP.md: G1 = UI-05 (PASS 2026-07-04); G2 = REN-05 (RESOLVED 2026-07-09 = FAIL → GeoJSON data-driven expressions chosen).

| Requirement | Phase | Status |
|-------------|-------|--------|
| FND-01 | Phase 1: Scaffolding | Complete |
| FND-02 | Phase 1: Scaffolding | Complete |
| FND-03 | Phase 1: Scaffolding | Complete |
| FND-04 | Phase 1: Scaffolding | Complete |
| FND-05 | Phase 1: Scaffolding | Complete |
| FND-06 | Phase 1: Scaffolding | Complete |
| FND-07 | Phase 1: Scaffolding | Complete |
| FND-08 | Phase 1: Scaffolding | Complete |
| FND-09 | Phase 1: Scaffolding | Complete |
| FND-10 | Phase 1: Scaffolding | Complete |
| FND-11 | Phase 1: Scaffolding | Complete |
| MAP-01 | Phase 2: Map + Glass Shell | Complete |
| MAP-02 | Phase 2: Map + Glass Shell | Complete |
| MAP-03 | Phase 2: Map + Glass Shell | Complete (deviated — tilt disabled per 02-CONTEXT.md) |
| MAP-04 | Phase 2: Map + Glass Shell | Complete |
| MAP-05 | Phase 2: Map + Glass Shell | Complete |
| MAP-06 | Phase 2: Map + Glass Shell | Complete |
| MAP-07 | Phase 2: Map + Glass Shell | Complete (deviated — camera opens at current location per 02-CONTEXT.md) |
| UI-01 | Phase 2: Map + Glass Shell | Complete (partial — focus pill stub; real data Phase 8) |
| UI-02 | Phase 2: Map + Glass Shell | Complete |
| UI-03 | Phase 2: Map + Glass Shell | Complete |
| UI-04 | Phase 2: Map + Glass Shell | Complete (partial — panel pattern foundation; full panels Phase 8) |
| UI-05 | Phase 2: Map + Glass Shell (Gate G1) | Complete — G1 unconditional PASS 2026-07-04 |
| UI-06 | Phase 2: Map + Glass Shell | Complete |
| UI-07 | Phase 2: Map + Glass Shell | Complete |
| TRK-01 | Phase 3: Tracking MVP | Superseded 2026-07-09 (manual-only recording — Phase 6 gap 06-08) |
| TRK-02 | Phase 3: Tracking MVP | Complete (verified via Phase 3.1 drive 2026-07-08) |
| TRK-03 | Phase 3: Tracking MVP | Complete (verified via Phase 3.1 drive 2026-07-08) |
| TRK-04 | Phase 3: Tracking MVP | Superseded 2026-07-09 (moot with manual-only recording — Phase 6 gap 06-08) |
| TRK-05 | Phase 3: Tracking MVP | Complete (verified via Phase 3.1 drive 2026-07-08) |
| TRK-06 | Phase 3: Tracking MVP | Complete (verified via Phase 3.1 drive 2026-07-08) — bluetooth_hint column exists, always NULL in P3; wired in Phase 9 |
| TRK-07 | Phase 3: Tracking MVP | Complete (verified via Phase 3.1 drive 2026-07-08) |
| TRK-08 | Phase 3: Tracking MVP | Complete (verified via Phase 3.1 drive 2026-07-08) |
| TRK-09 | Phase 3: Tracking MVP | Complete (verified via Phase 3.1 drive 2026-07-08) |
| TRK-10 | Phase 3: Tracking MVP | Complete (Android ladder verified via Phase 3.1 drive 2026-07-08; iOS real-device test still deferred — Windows dev env) |
| TRK-11 | Phase 3: Tracking MVP | Complete (verified via Phase 3.1 drive 2026-07-08) |
| OSM-01 | Phase 4: Map & Matching Data Sources | Complete (drive-verify pending combined Phase-4 close-out) |
| OSM-02 | Phase 4: Map & Matching Data Sources | Complete (drive-verify pending combined Phase-4 close-out) |
| OSM-03 | Phase 4: Map & Matching Data Sources | Complete (drive-verify pending combined Phase-4 close-out) |
| OSM-04 | Phase 4: Map & Matching Data Sources | Complete (drive-verify pending combined Phase-4 close-out) |
| OSM-05 | Phase 4: Map & Matching Data Sources | Complete (drive-verify pending combined Phase-4 close-out) |
| OSM-06 | Phase 4: Map & Matching Data Sources | Complete (drive-verify pending combined Phase-4 close-out) |
| OSM-07 | Phase 4: Map & Matching Data Sources | Complete (drive-verify pending combined Phase-4 close-out) |
| OSM-08 | Phase 4: Map & Matching Data Sources | Complete |
| MMT-01 | Phase 5: Overpass-Backed Matcher + Golden Corpus | Complete |
| MMT-02 | Phase 5: Overpass-Backed Matcher + Golden Corpus | Complete |
| MMT-03 | Phase 5: Overpass-Backed Matcher + Golden Corpus | Complete |
| MMT-04 | Phase 5: Overpass-Backed Matcher + Golden Corpus | Complete |
| MMT-05 | Phase 5: Overpass-Backed Matcher + Golden Corpus | Complete |
| MMT-06 | Phase 5: Overpass-Backed Matcher + Golden Corpus | Complete |
| MMT-07 | Phase 5: Overpass-Backed Matcher + Golden Corpus | Complete |
| MMT-08 | Phase 5: Overpass-Backed Matcher + Golden Corpus | Complete |
| MMT-09 | Phase 5: Overpass-Backed Matcher + Golden Corpus | Partial (harness + 1 seed + CI gate; 19 fixtures deferred to Phase 6) |
| MMT-10 | Phase 5: Overpass-Backed Matcher + Golden Corpus | Complete |
| INB-01 | Phase 6: Inbox + Match Wire-Up | Complete (code; drive-confirm deferred) |
| INB-02 | Phase 6: Inbox + Match Wire-Up | Complete (map preview removed by user request) |
| INB-03 | Phase 6: Inbox + Match Wire-Up | Complete (vehicle sheet deferred to P9) |
| INB-04 | Phase 6: Inbox + Match Wire-Up | Complete (hard-delete, no tombstone) |
| INB-05 | Phase 6: Inbox + Match Wire-Up | Descoped 2026-07-09 (no bulk ops — CONTEXT deviation) |
| INB-06 | Phase 6: Inbox + Match Wire-Up | Complete (confirmed + in-flight; rejected hard-deleted) |
| INB-07 | Phase 6: Inbox + Match Wire-Up | Complete (reassignment UI lands with P9 vehicles) |
| INB-08 | Phase 6: Inbox + Match Wire-Up | Complete (delete-from-detail + invalidation) |
| COV-01 | Phase 6: Inbox + Match Wire-Up | Complete |
| COV-05 | Phase 6: Inbox + Match Wire-Up | Complete (physical table `coverage_cache`) |
| COV-06 | Phase 6: Inbox + Match Wire-Up | Complete (3/4 triggers; counts_for_coverage → P9) |
| REN-01 | Phase 7: Coverage Rendering | Complete (orange/amber default; 5 presets; on-device first-paint deferred) |
| REN-02 | Phase 7: Coverage Rendering | De-scoped (v1) — 2026-07-09 |
| REN-03 | Phase 7: Coverage Rendering | Complete (whole-way reduced-opacity fallback; per-segment gradient → v1.x) |
| REN-04 | Phase 7: Coverage Rendering | Complete (50k stress harness code-complete; on-device fps read deferred) |
| REN-05 | Phase 7: Coverage Rendering (Gate G2) | Complete (Gate G2 = FAIL; GeoJSON + data-driven expressions) |
| REN-06 | Phase 7: Coverage Rendering | Complete (5-preset picker + AppPrefs persistence; live recolor confirm deferred) |
| COV-02 | Phase 7: Coverage Rendering | Complete (15 m buffer threshold; ≤30 m 80% fallback) |
| COV-03 | Phase 7: Coverage Rendering | Complete (fraction + floor; reduced-opacity render) |
| FOC-01 | Phase 8: Regions + Focus-Area | Complete (zoom→level mapper; live-during-move per 08-CONTEXT, not idle-gated; device confirm deferred) |
| FOC-02 | Phase 8: Regions + Focus-Area | Complete (AdminRegionLookup.regionAt point-in-polygon at chosen level) |
| FOC-03 | Phase 8: Regions + Focus-Area | Complete (two centered lines name-over-%, one-decimal per 08-CONTEXT — not inline "·") |
| FOC-04 | Phase 8: Regions + Focus-Area | Complete (fallbackLevelsFrom parent chain to Deutschland backstop) |
| FOC-05 | Phase 8: Regions + Focus-Area | Complete (pill onTap → showRegionDetailSheet, 08-06) |
| FOC-06 | Phase 8: Regions + Focus-Area | De-scoped (v1) — 2026-07-10 — breadcrumb permanently removed per 08-CONTEXT (detail sheet is stats-only) |
| FOC-07 | Phase 8: Regions + Focus-Area | Complete (softened per 08-CONTEXT: 150 ms trailing debounce + hold-last-value live-track, not strict idle-200ms; per-region cache read) |
| REG-01 | Phase 8: Regions + Focus-Area | Complete (reframed per 08-CONTEXT: one flat coverage-gated mixed-level card list, not per-level tabs) |
| REG-02 | Phase 8: Regions + Focus-Area | Complete (default sort % descending) |
| REG-03 | Phase 8: Regions + Focus-Area | De-scoped (v1) — 2026-07-10 — alternative sorts not requested per 08-CONTEXT; %-desc + search sufficient |
| REG-04 | Phase 8: Regions + Focus-Area | Complete (global fuzzy search, starts-with ranked) |
| REG-05 | Phase 8: Regions + Focus-Area | Complete (stats-only detail per 08-CONTEXT: name+level tag+%+km; breadcrumb/driven-ways/top-trips permanently dropped) |
| REG-06 | Phase 8: Regions + Focus-Area | Complete (Jump-to-on-map → animateCamera newLatLngBounds) |
| REG-07 | Phase 8: Regions + Focus-Area | Complete (lazy ListView.builder) |
| COV-04 | Phase 8: Regions + Focus-Area | Complete (Σ driven Kfz / Σ total Kfz per region, Feldweg/Fußweg excluded; global scope) |
| COV-07 | Phase 8: Regions + Focus-Area | Complete (main-isolate recompute with periodic yielding per plan; separate compute isolate → optimization deferred) |
| COV-08 | Phase 8: Regions + Focus-Area | Complete (global total/driven km; per-vehicle stats dropped 2026-07-13 with Vehicles removal) |
| SET-01 | Phase 9: Settings + Backup | De-scoped (Vehicles removed 2026-07-13) |
| SET-02 | Phase 9: Settings + Backup | De-scoped (no OSM extract post Phase-4 rescope) |
| SET-03 | Phase 9: Settings + Backup | Complete |
| SET-04 | Phase 9: Settings + Backup | Complete |
| SET-05 | Phase 9: Settings + Backup | Complete |
| SET-06 | Phase 9: Settings + Backup | Complete |
| SET-07 | Phase 9: Settings + Backup | Complete |
| SET-08 | Phase 9: Settings + Backup | Complete |
| SET-09 | Phase 9: Settings + Backup | Complete |
| QUA-01 | Phase 10: Hardening | De-scoped (Hardening dropped 2026-07-17) |
| QUA-02 | Phase 5: Overpass-Backed Matcher + Golden Corpus | Complete |
| QUA-03 | Phase 1: Scaffolding | Complete |
| QUA-04 | Phase 10: Hardening | De-scoped (Hardening dropped 2026-07-17) |
| QUA-05 | Phase 1: Scaffolding | Complete |
| QUA-06 | Phase 3: Tracking MVP | Complete (user-attested — 96 km/1h40 drive 2026-07-09, no battery anomalies observed) |
| QUA-07 | Phase 10: Hardening | De-scoped (Hardening dropped 2026-07-17) |

*(VEH-01..06 removed from this table 2026-07-13 — Vehicles + Bluetooth phase cut.)*

---
*Requirements defined: 2026-07-02*
*Last updated: 2026-07-17 (QUA-01/04/07 de-scoped — tied to the dropped Hardening phase, see ROADMAP + 10-CONTEXT decision 9; 2026-07-13: Vehicles + Bluetooth feature removed at user request — VEH-01..06 withdrawn, schema v4 drops Vehicles/BtFingerprints tables + trips.vehicle_id/bluetooth_hint; TRK-02/COV-08 vehicle clauses struck; Phases 10/11 renumbered to 9/10)*
