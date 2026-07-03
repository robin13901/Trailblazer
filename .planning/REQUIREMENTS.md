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

- [ ] **MAP-01**: MapLibre GL widget renders a Google-Maps-inspired vector base map (cartoon style, not satellite)
- [ ] **MAP-02**: PMTiles archive is the tile source; map works fully offline once the archive is present
- [ ] **MAP-03**: User can pan, zoom, rotate, and tilt the map with standard gestures
- [ ] **MAP-04**: Map shows current device location marker (blue dot) when location permission granted
- [ ] **MAP-05**: Dark mode style switches automatically with system theme
- [ ] **MAP-06**: Map style JSON is a project asset (customisable, not vendor-locked)
- [ ] **MAP-07**: Camera state (last position, zoom) persists across app restarts

### Liquid Glass UI (UI)

- [ ] **UI-01**: Focus-area pill overlays the top of the map showing current admin region + exploration %
- [ ] **UI-02**: Bottom navigation is a Liquid Glass pill (Map, Trips, Regions, Settings)
- [ ] **UI-03**: Floating action button (record trip) is Liquid Glass styled
- [ ] **UI-04**: Panels/sheets overlaying the map use `showLiquidGlassPanel` overlay pattern (keeps map visible behind)
- [ ] **UI-05**: **P2 gate**: Rendering spike on real iOS + Android device before Liquid Glass is committed to for on-map overlays; documented fallback (`FrostedGlassCard` / gradient tint) if BackdropFilter fails on MapLibre platform view
- [ ] **UI-06**: App uses no traditional `AppBar` on the map screen; focus-area pill is the only top-of-screen chrome
- [ ] **UI-07**: Light + dark themes both use the shared `LiquidGlassSettings` singleton pattern from XFin reference

### OSM Data Pipeline (OSM)

- [ ] **OSM-01**: Dev-machine Dart CLI in `tool/osm_pipeline/` converts a Geofabrik `germany-latest.osm.pbf` into a slim artifact
- [ ] **OSM-02**: Pipeline extracts only ways with `highway=motorway|trunk|primary|secondary|tertiary|residential|unclassified|service|living_street|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link` (Kfz-classified) + `highway=track|path|footway|cycleway|pedestrian|bridleway` (Feldweg/Fußweg, stored but tagged as non-counting)
- [ ] **OSM-03**: Pipeline extracts admin boundaries at OSM levels 2, 4, 6, 8, 9, 10 (Land, Bundesland, Landkreis, Gemeinde, Stadtteil, Ortsteil)
- [ ] **OSM-04**: Pipeline pre-computes way ↔ admin region associations (join table `way_admin`) for all Kfz-way ↔ region pairs where the way's geometry intersects the region
- [ ] **OSM-05**: Pipeline produces two output artifacts: (a) `osm.sqlite` (indexed SQLite with R-Tree over Kfz-way geometries) and (b) `germany-base.pmtiles` (rendered vector tiles)
- [ ] **OSM-06**: `osm.sqlite` total size stays under 200 MB; `germany-base.pmtiles` under 200 MB
- [ ] **OSM-07**: Pipeline output has a version stamp (source PBF date + pipeline schema version)
- [ ] **OSM-08**: Pipeline can run on a Berlin bounding box (or arbitrary bbox) for dev/testing without full Germany data

### OSM DB Runtime (OSMDB)

- [ ] **OSMDB-01**: On first launch, app prompts user to download OSM DB over Wi-Fi (~200 MB); download can be resumed if interrupted
- [ ] **OSMDB-02**: OSM DB is stored separately from App DB and treated as read-only
- [ ] **OSMDB-03**: OSM DB is opened in its own Drift isolate with statement caching warm-up
- [ ] **OSMDB-04**: App verifies OSM DB integrity (schema version + row-count sanity check) on open; broken artifact triggers re-download
- [ ] **OSMDB-05**: OSM DB updates are swap-in-place: new artifact downloaded to a temp path, atomically swapped into place, old file deleted
- [ ] **OSMDB-06**: OSM DB updates invalidate the coverage cache; drivenway intervals remain valid (way IDs are stable across Geofabrik snapshots)
- [ ] **OSMDB-07**: R-Tree candidate query (`findWaysNear(lat, lng, radius)`) returns top-N candidates in p95 < 30 ms on target devices

### Vehicles (VEH)

- [ ] **VEH-01**: On first launch, user is guided through creating their first vehicle (name, model, optional color)
- [ ] **VEH-02**: User can create, edit, delete vehicles from the settings screen
- [ ] **VEH-03**: One vehicle can be marked as default (auto-assigned to manually started trips)
- [ ] **VEH-04**: Each vehicle can optionally be linked to one or more Bluetooth-device fingerprints (paired MAC / device name / stable ID)
- [ ] **VEH-05**: Each vehicle has a `counts_for_coverage` flag (default: true) — only trips with counts=true vehicles contribute to the exploration percentage
- [ ] **VEH-06**: Vehicles can be assigned a display color for future per-vehicle coloring on the map (stored, not yet rendered in v1)

### Trip Tracking (TRK)

- [ ] **TRK-01**: `flutter_background_geolocation` records GPS in the background when motion activity classifier reports `automotive` (>60 s duration) — trip auto-created as `pending`
- [ ] **TRK-02**: User can manually start a trip via FAB on the map screen — trip immediately created as `pending`, assigned to default vehicle, marked as `manually_started`
- [ ] **TRK-03**: Manually-started trips end only when user presses the Stop button (short traffic-light stops do not terminate the trip)
- [ ] **TRK-04**: Auto-started trips end when motion classifier reports non-automotive for > 2 minutes (dwell termination)
- [ ] **TRK-05**: Per-trip captured metadata: start/end timestamp, duration, distance (from GPS integration), avg speed, max speed, raw GPS polyline (lat/lng/accuracy/timestamp/altitude), motion activity type per fix
- [ ] **TRK-06**: Bluetooth device fingerprint at trip start is stored on the trip as a hint (does not gate recording)
- [ ] **TRK-07**: A trip records `manually_started` boolean, `auto_stopped` boolean, and `bluetooth_hint` string (or null)
- [ ] **TRK-08**: Battery-conscious state machine: `idle → detecting → recording → paused` — GPS accuracy switches to `Best` (not `BestForNavigation`) during recording; DB writes batched every ~20 fixes
- [ ] **TRK-09**: Live-tracking indicator visible on the map when a trip is being recorded (glass overlay with duration + distance)
- [ ] **TRK-10**: iOS `whenInUse → Always` two-step permission ladder implemented; app never assumes Always is granted
- [ ] **TRK-11**: Android `foregroundServiceType="location"` with persistent notification; user prompted to disable battery optimization

### Trip Review Inbox (INB)

- [ ] **INB-01**: On app launch (and always available via Trips tab), user sees a list of all `pending` trips
- [ ] **INB-02**: Each pending trip shows: date/time, duration, distance, small static map preview of the route, vehicle-guess badge if Bluetooth matched
- [ ] **INB-03**: User can `keep` a trip: opens vehicle-assignment sheet, then marks trip as `confirmed`, enqueues map-matching
- [ ] **INB-04**: User can `discard` a trip: marks it as `rejected`, raw GPS deleted, no matching runs
- [ ] **INB-05**: User can bulk-confirm all pending trips of a session (with default vehicle) or bulk-discard all
- [ ] **INB-06**: Confirmed and rejected trips are visible in a separate "Trip History" list within the Trips tab
- [ ] **INB-07**: User can retroactively change vehicle assignment on a confirmed trip (triggers coverage-cache invalidation)
- [ ] **INB-08**: User can delete a confirmed trip (removes its contribution to coverage; coverage-cache invalidated)

### Map-Matching (MMT)

- [ ] **MMT-01**: Confirmed trip is enqueued into a long-lived `MatcherIsolate` (single isolate, warm OSM DB handle)
- [ ] **MMT-02**: Matcher uses Hidden Markov Model (Newson-Krumm 2009): emission probability weighted by `horizontalAccuracy`, transition probability weighted by road-network distance
- [ ] **MMT-03**: Matcher performs full retrospective match on trip end (not live during driving) — single authoritative pass
- [ ] **MMT-04**: R-Tree candidate query per GPS point returns top-5 candidates within an adaptive radius (25 m base, expands with HDOP)
- [ ] **MMT-05**: Points that cannot be matched confidently are dropped (not force-snapped) — trips may have gaps
- [ ] **MMT-06**: Matcher output: list of `driven_way_intervals(way_id, start_m, end_m, direction, trip_id, timestamp)` written to App DB
- [ ] **MMT-07**: Autobahn / Bundesstraße parallel-road smearing mitigated by min-speed 15 km/h threshold for high-class ways + Viterbi lookahead of ≥ 5 emissions
- [ ] **MMT-08**: Matcher is cancellable (user deleting an in-flight trip cancels its match job)
- [ ] **MMT-09**: A CI-runnable "golden trip corpus" of ≥ 20 recorded trips (autobahn, Kreisel, tunnel, parking, U-turn, city grid, roundabout, one-way street) with known-correct way-ID sequences; regression on any golden trip fails CI
- [ ] **MMT-10**: Raw GPS retained 30 days after match for re-matching if parameters change; then deleted (user can override retention in settings)

### Coverage Aggregation (COV)

- [ ] **COV-01**: `driven_way_intervals` are merged per way: overlapping intervals collapsed into unions
- [ ] **COV-02**: A way counts as fully explored when the merged interval covers ≥ `(length_m − 15 m end buffer − 15 m start buffer)` of the total length
- [ ] **COV-03**: A way is "partially explored" if covered but not fully — surfaces with proportional color in v1.x, in v1 shown as a distinct partial color
- [ ] **COV-04**: Coverage % per region = `Σ driven_length(Kfz-way ∩ region) / Σ length(all Kfz-ways ∈ region)` — Feldweg/Fußweg excluded from both numerator and denominator
- [ ] **COV-05**: Coverage cache table (`coverage_by_region`) stores per-region % + last-computed timestamp; recomputed only on invalidation
- [ ] **COV-06**: Invalidation triggers: new driven intervals written, trip deleted, vehicle `counts_for_coverage` changed, OSM extract updated
- [ ] **COV-07**: Coverage recomputation runs on a compute isolate to keep UI responsive
- [ ] **COV-08**: A "total km driven" and "unique km driven" statistic is maintained per vehicle and globally

### Focus-Area Pill (FOC)

- [ ] **FOC-01**: On map camera idle, a resolver derives the appropriate admin level from the current zoom level (Land at world, Bundesland at country zoom, Landkreis at region zoom, Gemeinde at city zoom, Ortsteil at street zoom)
- [ ] **FOC-02**: The resolver identifies which region the map center falls into at the chosen admin level (point-in-polygon query against admin boundaries)
- [ ] **FOC-03**: Pill displays "{region name} — {coverage %}" e.g. "Grebenhain · 26%"
- [ ] **FOC-04**: If no admin region at the chosen level covers the center (e.g. over water), pill shows the parent-level region
- [ ] **FOC-05**: Tapping the pill opens the region detail sheet
- [ ] **FOC-06**: Region breadcrumb (Land › Bundesland › … › current level) visible when pill expanded
- [ ] **FOC-07**: Resolver is debounced on camera idle (200 ms) and cached per (level, region) tuple

### Coverage Rendering (REN)

- [ ] **REN-01**: Driven Kfz-ways are rendered on the map in a distinctive color (default: warm green) using MapLibre `feature-state` API
- [ ] **REN-02**: Driven Feldweg/Fußweg ways are rendered in a distinct secondary color (default: dashed blue) — clearly not the same "explored" visual language
- [ ] **REN-03**: Partial coverage on a way is rendered with a proportional gradient or reduced opacity (fallback if per-segment coloring impossible)
- [ ] **REN-04**: Rendering scales to ≥ 50 000 driven segments without dropping below 30 fps on target devices (stress test in P7)
- [ ] **REN-05**: **P7 gate**: if `maplibre_gl` `setFeatureState` is unavailable, fall back to sharded GeoJSON sources per 5×5 km tile
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

- [ ] **SET-01**: Vehicle management (list, add, edit, delete, set default)
- [ ] **SET-02**: OSM data status: current version, size, "check for updates" action, update flow
- [ ] **SET-03**: Permissions status inspector (location Always/whenInUse, motion activity, Bluetooth, background app refresh)
- [ ] **SET-04**: Color palette selection for driven / partial / Feldweg overlays
- [ ] **SET-05**: Raw GPS retention setting (default 30 days, options: 0/30/365 days/forever)
- [ ] **SET-06**: Battery-diagnostic HUD toggle (dev/hobbyist users can see fix rate, matcher queue depth, cache-hit rate)
- [ ] **SET-07**: Backup: user picks a destination file path (iCloud Drive on iOS, SAF picker on Android); export writes an encrypted archive of the App DB
- [ ] **SET-08**: Restore: user picks a backup file; app validates and swaps App DB (OSM DB not touched)
- [ ] **SET-09**: About screen with app version, OSS licenses, credits (OSM contributors)

### Quality Gates (QUA)

- [ ] **QUA-01**: All feature modules have widget tests for their key screens (Map, Trip Inbox, Vehicle List, Region List, Focus-Area Pill)
- [ ] **QUA-02**: Core map-matcher has ≥ 90% line coverage; golden-trip regression suite in CI
- [x] **QUA-03**: Drift migration tests use `SchemaVerifier` to validate every migration step
- [ ] **QUA-04**: `patrol` integration tests cover: onboarding flow, first trip recording, inbox confirmation, matching → coverage update, region browser
- [x] **QUA-05**: iOS + Android debug builds succeed in CI
- [ ] **QUA-06**: 60-minute driving battery-drain baseline (measured on real device) committed to repo; regression on major changes flagged
- [ ] **QUA-07**: Real-device QA gauntlet before release: iPhone (current + one older), Samsung, Xiaomi (worst-case battery-killer)

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
- v1 requirements: 119 total
- Mapped to phases: 119 / 119 (100 %)
- Unmapped: 0

Every requirement maps to exactly one phase. Phase Gates in ROADMAP.md carry two open decisions (G1 = UI-05 fallback; G2 = REN-05 fallback) that will resolve when their spike phase runs.

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
| MAP-01 | Phase 2: Map + Glass Shell | Pending |
| MAP-02 | Phase 2: Map + Glass Shell | Pending |
| MAP-03 | Phase 2: Map + Glass Shell | Pending |
| MAP-04 | Phase 2: Map + Glass Shell | Pending |
| MAP-05 | Phase 2: Map + Glass Shell | Pending |
| MAP-06 | Phase 2: Map + Glass Shell | Pending |
| MAP-07 | Phase 2: Map + Glass Shell | Pending |
| UI-01 | Phase 2: Map + Glass Shell | Pending |
| UI-02 | Phase 2: Map + Glass Shell | Pending |
| UI-03 | Phase 2: Map + Glass Shell | Pending |
| UI-04 | Phase 2: Map + Glass Shell | Pending |
| UI-05 | Phase 2: Map + Glass Shell (Gate G1) | Pending |
| UI-06 | Phase 2: Map + Glass Shell | Pending |
| UI-07 | Phase 2: Map + Glass Shell | Pending |
| TRK-01 | Phase 3: Tracking MVP | Pending |
| TRK-02 | Phase 3: Tracking MVP | Pending |
| TRK-03 | Phase 3: Tracking MVP | Pending |
| TRK-04 | Phase 3: Tracking MVP | Pending |
| TRK-05 | Phase 3: Tracking MVP | Pending |
| TRK-06 | Phase 3: Tracking MVP | Pending |
| TRK-07 | Phase 3: Tracking MVP | Pending |
| TRK-08 | Phase 3: Tracking MVP | Pending |
| TRK-09 | Phase 3: Tracking MVP | Pending |
| TRK-10 | Phase 3: Tracking MVP | Pending |
| TRK-11 | Phase 3: Tracking MVP | Pending |
| OSM-01 | Phase 4: OSM Pipeline | Pending |
| OSM-02 | Phase 4: OSM Pipeline | Pending |
| OSM-03 | Phase 4: OSM Pipeline | Pending |
| OSM-04 | Phase 4: OSM Pipeline | Pending |
| OSM-05 | Phase 4: OSM Pipeline | Pending |
| OSM-06 | Phase 4: OSM Pipeline | Pending |
| OSM-07 | Phase 4: OSM Pipeline | Pending |
| OSM-08 | Phase 4: OSM Pipeline | Pending |
| OSMDB-01 | Phase 5: OSM DB + Matcher | Pending |
| OSMDB-02 | Phase 5: OSM DB + Matcher | Pending |
| OSMDB-03 | Phase 5: OSM DB + Matcher | Pending |
| OSMDB-04 | Phase 5: OSM DB + Matcher | Pending |
| OSMDB-05 | Phase 5: OSM DB + Matcher | Pending |
| OSMDB-06 | Phase 5: OSM DB + Matcher | Pending |
| OSMDB-07 | Phase 5: OSM DB + Matcher | Pending |
| MMT-01 | Phase 5: OSM DB + Matcher | Pending |
| MMT-02 | Phase 5: OSM DB + Matcher | Pending |
| MMT-03 | Phase 5: OSM DB + Matcher | Pending |
| MMT-04 | Phase 5: OSM DB + Matcher | Pending |
| MMT-05 | Phase 5: OSM DB + Matcher | Pending |
| MMT-06 | Phase 5: OSM DB + Matcher | Pending |
| MMT-07 | Phase 5: OSM DB + Matcher | Pending |
| MMT-08 | Phase 5: OSM DB + Matcher | Pending |
| MMT-09 | Phase 5: OSM DB + Matcher | Pending |
| MMT-10 | Phase 5: OSM DB + Matcher | Pending |
| INB-01 | Phase 6: Inbox + Match Wire-Up | Pending |
| INB-02 | Phase 6: Inbox + Match Wire-Up | Pending |
| INB-03 | Phase 6: Inbox + Match Wire-Up | Pending |
| INB-04 | Phase 6: Inbox + Match Wire-Up | Pending |
| INB-05 | Phase 6: Inbox + Match Wire-Up | Pending |
| INB-06 | Phase 6: Inbox + Match Wire-Up | Pending |
| INB-07 | Phase 6: Inbox + Match Wire-Up | Pending |
| INB-08 | Phase 6: Inbox + Match Wire-Up | Pending |
| COV-01 | Phase 6: Inbox + Match Wire-Up | Pending |
| COV-05 | Phase 6: Inbox + Match Wire-Up | Pending |
| COV-06 | Phase 6: Inbox + Match Wire-Up | Pending |
| REN-01 | Phase 7: Coverage Rendering | Pending |
| REN-02 | Phase 7: Coverage Rendering | Pending |
| REN-03 | Phase 7: Coverage Rendering | Pending |
| REN-04 | Phase 7: Coverage Rendering | Pending |
| REN-05 | Phase 7: Coverage Rendering (Gate G2) | Pending |
| REN-06 | Phase 7: Coverage Rendering | Pending |
| COV-02 | Phase 7: Coverage Rendering | Pending |
| COV-03 | Phase 7: Coverage Rendering | Pending |
| FOC-01 | Phase 8: Regions + Focus-Area | Pending |
| FOC-02 | Phase 8: Regions + Focus-Area | Pending |
| FOC-03 | Phase 8: Regions + Focus-Area | Pending |
| FOC-04 | Phase 8: Regions + Focus-Area | Pending |
| FOC-05 | Phase 8: Regions + Focus-Area | Pending |
| FOC-06 | Phase 8: Regions + Focus-Area | Pending |
| FOC-07 | Phase 8: Regions + Focus-Area | Pending |
| REG-01 | Phase 8: Regions + Focus-Area | Pending |
| REG-02 | Phase 8: Regions + Focus-Area | Pending |
| REG-03 | Phase 8: Regions + Focus-Area | Pending |
| REG-04 | Phase 8: Regions + Focus-Area | Pending |
| REG-05 | Phase 8: Regions + Focus-Area | Pending |
| REG-06 | Phase 8: Regions + Focus-Area | Pending |
| REG-07 | Phase 8: Regions + Focus-Area | Pending |
| COV-04 | Phase 8: Regions + Focus-Area | Pending |
| COV-07 | Phase 8: Regions + Focus-Area | Pending |
| COV-08 | Phase 8: Regions + Focus-Area | Pending |
| VEH-01 | Phase 9: Vehicles + Bluetooth | Pending |
| VEH-02 | Phase 9: Vehicles + Bluetooth | Pending |
| VEH-03 | Phase 9: Vehicles + Bluetooth | Pending |
| VEH-04 | Phase 9: Vehicles + Bluetooth | Pending |
| VEH-05 | Phase 9: Vehicles + Bluetooth | Pending |
| VEH-06 | Phase 9: Vehicles + Bluetooth | Pending |
| SET-01 | Phase 10: Settings + Backup | Pending |
| SET-02 | Phase 10: Settings + Backup | Pending |
| SET-03 | Phase 10: Settings + Backup | Pending |
| SET-04 | Phase 10: Settings + Backup | Pending |
| SET-05 | Phase 10: Settings + Backup | Pending |
| SET-06 | Phase 10: Settings + Backup | Pending |
| SET-07 | Phase 10: Settings + Backup | Pending |
| SET-08 | Phase 10: Settings + Backup | Pending |
| SET-09 | Phase 10: Settings + Backup | Pending |
| QUA-01 | Phase 11: Hardening | Pending |
| QUA-02 | Phase 5: OSM DB + Matcher | Pending |
| QUA-03 | Phase 1: Scaffolding | Complete |
| QUA-04 | Phase 11: Hardening | Pending |
| QUA-05 | Phase 1: Scaffolding | Complete |
| QUA-06 | Phase 3: Tracking MVP | Pending |
| QUA-07 | Phase 11: Hardening | Pending |

---
*Requirements defined: 2026-07-02*
*Last updated: 2026-07-03 — Phase 1 (Scaffolding) complete; 13 requirements (FND-01..11, QUA-03, QUA-05) moved to Complete*
