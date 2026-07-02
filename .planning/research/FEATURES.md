# Feature Research

**Domain:** Personal Route/Street Coverage Tracker (driving-focused)
**Project:** Trailblazer
**Researched:** 2026-07-02
**Confidence:** MEDIUM — driving-focused coverage trackers are rare, most reference apps target cycling/running; features adapted from adjacent categories.

## Adjacent Category Overview

Coverage trackers surveyed:

- **Wandrer.earth** — cycling; syncs Strava/Garmin, points/achievements, monthly challenges, premium tier for device maps and unlimited sync. Web-first, gamified but exploration-focused.
- **CityStrides** — running/walking; per-city street completion, badges, leaderboards, LifeMap poster, integrates with Strava/Garmin/Polar.
- **Squadrats / Squadratinhos** — grid-based coverage (400m/1km squares) rather than roads; adds "square hunting" gamification.
- **StatsHunters** — multi-metric Strava dashboards including tiles/coverage.
- **Every Street projects** — mostly bespoke tooling around GPX + OSM overlays.

**Key adaptation gap for driving:** none of these treat Kfz-Straße vs Feldweg/Fußweg distinctions natively, none default to local-only, and all lean toward social/leaderboard gamification. Trailblazer's positioning inverts that: private, driving-classified, map-first.

## Feature Landscape

### Table Stakes (Users Expect These)

Missing any of these makes the app feel broken for a driving-coverage tracker.

#### Map & Visualization

| Feature | Why Expected | Complexity | Dependencies | Notes |
|---------|--------------|------------|--------------|-------|
| Interactive vector map with pan/zoom | Baseline for any map app | MEDIUM | — | flutter_map or MapLibre GL; OSM tiles |
| Driven roads painted in distinct color | Core value ("roads painted onto the world") | MEDIUM | Map, matched trip storage | Line overlay from matched geometry |
| User location indicator (blue dot + heading) | Universal map convention | LOW | Map, location permission | Standard |
| Map layer toggle (street / satellite / topo) | Users compare terrain vs streets | LOW | Map | 2-3 tile sources sufficient |
| Distinct color for Feldweg/Fußweg segments | Explicit product requirement | MEDIUM | Road classification, styling | Separate GeoJSON layer / style expression |
| Zoom-aware detail level | Painting all roads at country zoom = clutter | MEDIUM | Map, LOD system | Only render Kfz roads above zoom N |

#### Tracking

| Feature | Why Expected | Complexity | Dependencies | Notes |
|---------|--------------|------------|--------------|-------|
| Manual start/stop tracking button | Explicit product requirement | LOW | Location service | Foreground button |
| Background trip auto-recording | Explicit product requirement | LARGE | Background location, motion detection | Trip start/end heuristics (speed threshold, dwell time) |
| GPS point capture at meaningful cadence | Baseline tracking | LOW | Location service | Adaptive: 1s driving, 5s slow |
| Pause detection (stops don't create phantom segments) | GPS drift at stops creates noise | MEDIUM | Trip processor | Speed + accuracy heuristic |
| Battery-conscious background operation | Users abandon apps that drain phones | MEDIUM | Platform bg APIs | Doze-mode friendly on Android |

#### Trip Processing

| Feature | Why Expected | Complexity | Dependencies | Notes |
|---------|--------------|------------|--------------|-------|
| Offline map-matching (snap GPS to road graph) | Explicit product requirement; raw GPS is wobbly | LARGE | OSM data, matcher engine | Valhalla-offline / GraphHopper-offline / custom HMM |
| Trip list with basic metadata | Users need to see what was recorded | LOW | Trip storage | Date, duration, distance, vehicle |
| Trip detail view with matched path | Verify what got recorded | MEDIUM | Trip storage, map | Show raw vs matched optionally |
| Delete trip | Bad GPS / wrong vehicle / privacy | LOW | Trip storage | Also recomputes coverage |
| Merge coverage from all confirmed trips | Core aggregation | MEDIUM | Trip storage, road graph | Segment-set union |

#### Review Inbox

| Feature | Why Expected | Complexity | Dependencies | Notes |
|---------|--------------|------------|--------------|-------|
| Inbox listing of auto-recorded pending trips | Explicit product requirement | MEDIUM | Trip storage, states | Pending / confirmed / rejected |
| Confirm trip (adds to coverage) | Explicit product requirement | LOW | Inbox, coverage aggregator | Also assign vehicle |
| Reject trip (excluded from coverage) | Not every drive should count | LOW | Inbox | Kept in db for audit or hard-delete |
| Assign vehicle at confirmation | Explicit product requirement (multi-vehicle) | LOW | Vehicles, inbox | Default = last-used vehicle |
| Split/trim trip at rest stop or bad segment | Auto-detection misses breaks | LARGE | Trip editor UI | Consider deferring to v1.x |

#### Vehicles

| Feature | Why Expected | Complexity | Dependencies | Notes |
|---------|--------------|------------|--------------|-------|
| Create/edit/delete vehicle profiles | Explicit product requirement | LOW | Local storage | Name, color, optional icon |
| Filter map/stats by vehicle | Users bought multi-vehicle for this | MEDIUM | Coverage index per vehicle | Union view = all vehicles |
| Set default vehicle | Reduce friction on confirm | LOW | Preferences | |

#### Regions & Focus Area

| Feature | Why Expected | Complexity | Dependencies | Notes |
|---------|--------------|------------|--------------|-------|
| Zoom-dependent focus-area pill (admin region + %) | Explicit product requirement | LARGE | Admin boundaries, coverage index, spatial query | Nominatim/OSM admin hierarchy; local index |
| Admin hierarchy (Gemeinde / Kreis / Bundesland / Land) | Users want % at multiple granularities | MEDIUM | Admin boundary dataset | OSM admin_level tags |
| Percentage = driven Kfz-Straße length / total Kfz-Straße length in region | Explicit product requirement | MEDIUM | Road graph with class, coverage | Feldwege excluded from denominator |
| Tap pill to see breakdown / detail sheet | Users want context, not just a number | MEDIUM | Regions, stats | Show driven km / total km, sub-regions |

#### Statistics

| Feature | Why Expected | Complexity | Dependencies | Notes |
|---------|--------------|------------|--------------|-------|
| Total km driven (all-time, per vehicle) | Baseline stat | LOW | Trip storage | |
| Total unique road km covered | The point of the app | LOW | Coverage index | Distinct from total km |
| Coverage % per top-level region | Big-picture view | LOW | Regions | |
| Trip count, avg trip length | Standard telemetry | LOW | Trip storage | |

#### Data Management

| Feature | Why Expected | Complexity | Dependencies | Notes |
|---------|--------------|------------|--------------|-------|
| Local persistent storage | Explicit "local-only" requirement | MEDIUM | SQLite/Drift + spatial | Trips, matched geometry, coverage index |
| Offline map tiles for at least user's region | Driving in rural areas = no signal | MEDIUM | MBTiles / PMTiles | Preload user-selected regions |
| Backup / export (encrypted archive) | Users switch phones; local-only ≠ data loss | MEDIUM | Storage, file APIs | ZIP of DB + tiles or DB-only |
| Restore from backup | Symmetric with backup | MEDIUM | Storage | |
| GPX export of individual trips | Universal interop with other tools | LOW | Trip storage | Also enables debugging |

#### UI/UX

| Feature | Why Expected | Complexity | Dependencies | Notes |
|---------|--------------|------------|--------------|-------|
| Dark mode | Driving at night; universal expectation | LOW | Theming | Map style also dark |
| Permission onboarding (location, background, storage) | Android/iOS gate everything on this | MEDIUM | — | Explain "why" per platform |
| Settings screen | Anywhere non-trivial | LOW | Preferences | Units, defaults, thresholds |

---

### Differentiators (Competitive Advantage)

Features that make Trailblazer distinctly better for the target use than any adjacent app.

#### Map & Visualization

| Feature | Value Proposition | Complexity | Dependencies | Notes |
|---------|-------------------|------------|--------------|-------|
| First-render "painted world" on app open | Core value delivered in <2s | MEDIUM | Precomputed coverage tiles/layer | Materialized coverage geometry, not on-the-fly union |
| Kfz vs Feldweg color legend that's actually beautiful | Design taste beats functional parity | LOW | Styling | Distinct hue families, not just red/green |
| Heatmap-style intensity for repeatedly driven roads | Shows favorite routes at a glance | MEDIUM | Coverage index with counts | Optional layer toggle |
| Recency shading (newly discovered roads glow briefly) | Rewards exploration without cheap badges | MEDIUM | Coverage index with timestamps | Fade over 7-30 days |
| Adjacent-unexplored highlight | "One turn away" surfacing for local exploration | MEDIUM | Coverage + graph adjacency | Great for "where should I go next?" |

#### Tracking & Trip Processing

| Feature | Value Proposition | Complexity | Dependencies | Notes |
|---------|-------------------|------------|--------------|-------|
| On-device offline map-matching | Privacy + no-signal reliability | LARGE | Road graph, HMM/Valhalla | Explicit product requirement |
| Auto vehicle detection via Bluetooth device pairing | "It just knew I was in the Golf" | MEDIUM | BT scan, vehicle profile mapping | Optional; needs user to bind |
| Auto vehicle detection via time-of-day / start-location patterns | Reduces confirm-step friction over time | LARGE | Trip history, lightweight ML/heuristic | Later phase |
| Smart trip stitching (short gap = one trip) | Fuel stops shouldn't split trips | MEDIUM | Trip processor | Configurable gap threshold |
| Confidence score on matched geometry | Lets user spot bad matches in inbox | MEDIUM | Matcher | Highlight low-confidence segments |

#### Regions & Coverage

| Feature | Value Proposition | Complexity | Dependencies | Notes |
|---------|-------------------|------------|--------------|-------|
| Custom user-defined regions (draw polygon) | "How much of this specific area?" | MEDIUM | Region storage, spatial query | Named custom areas |
| Region completion targets (silent, no push nagging) | Personal goal, not a leaderboard | LOW | Regions, prefs | Just displayed, never notified aggressively |
| Sub-region drill-down (tap Bundesland -> Kreise list sorted by %) | Discovery of what's next | MEDIUM | Admin hierarchy | |
| "Never driven" road density overlay per region | Plan exploratory trips | MEDIUM | Coverage inverse | Fades where mostly driven |

#### Multi-Vehicle

| Feature | Value Proposition | Complexity | Dependencies | Notes |
|---------|-------------------|------------|--------------|-------|
| Per-vehicle map coloring | See at a glance which car went where | MEDIUM | Coverage per vehicle | Layer per vehicle |
| Combined vs per-vehicle % toggle | Family coverage vs personal coverage | LOW | Coverage aggregation | |
| Vehicle "loaned" mode (record but exclude from stats) | Someone else drove; still logged | LOW | Trip metadata flag | |

#### Statistics & Insights

| Feature | Value Proposition | Complexity | Dependencies | Notes |
|---------|-------------------|------------|--------------|-------|
| Yearly / monthly coverage delta ("new roads this month: 42 km") | Reflection without competition | LOW | Coverage timestamps | |
| "Every road in Gemeinde X" completion milestone (local toast only) | Meaningful achievement, not cheap badge | LOW | Regions, coverage | Silent, appears in stats |
| Coverage timeline scrubber (see what was covered by date) | Personal history browsing | MEDIUM | Coverage with timestamps | |
| Export coverage as styled PNG/PDF poster | Physical print of "your world" | MEDIUM | Renderer | LifeMap-poster equivalent, offline generation |

#### Data & Privacy

| Feature | Value Proposition | Complexity | Dependencies | Notes |
|---------|-------------------|------------|--------------|-------|
| Fully local-only (no account, no server) | Aligns with core positioning | MEDIUM (as constraint) | Storage, backup | Explicit product requirement |
| Optional encrypted backup to user-chosen location (SD card, Nextcloud folder) | Redundancy without SaaS | MEDIUM | File APIs, encryption | User picks path |
| Import from Google Timeline / GPX archive | Bootstrap coverage from years of history | LARGE | Parser + matcher batch mode | Massive first-run value |

---

### Anti-Features (Do NOT Build)

Features that seem good but would corrode the product.

| Anti-Feature | Why Requested | Why Problematic | Alternative |
|--------------|---------------|-----------------|-------------|
| Social sharing / friends / leaderboards (v1) | "Everyone else does it" | Contradicts local-only positioning; forces accounts and servers; changes emotional tone from personal to performative | Optional PNG export the user can share manually |
| Cheap gamification: streaks, XP, coin badges, level-ups | Boosts short-term engagement metrics | Feels condescending; makes personal exploration feel like a slot machine; drives compulsive driving patterns | Silent milestones in stats screen only; recency glow on new roads is enough reward |
| Realtime road coloring during driving | "See the paint fill in as I drive" | Distracts driver; requires realtime matcher (heavy); creates flicker as matches are corrected | Coverage recomputed at trip confirm; app opens showing yesterday's state |
| Push notifications for "nearby unexplored roads" while driving | Nagging exploration prompts | Dangerous while driving; annoying while not | Adjacent-unexplored highlight in-map, on user's terms |
| Turn-by-turn navigation | Feature creep toward "another maps app" | Huge scope; safety liability; Google/Apple/OsmAnd already excellent | Deep-link out to a preferred nav app |
| Cloud sync of trips/coverage | "But what if my phone breaks?" | Breaks local-only promise; server infra to run and secure | User-controlled encrypted backup file |
| Fitness/health metrics (calories, heart rate) | Copy-paste from cycling apps | Meaningless for driving | Omit entirely |
| Public API / OAuth integrations | "Integrate with Strava" | Requires servers/accounts; not a driving-tracker's audience | GPX export/import for local interop |
| Elevation profiles per trip | "It's a standard metric" | Adds compute + noise; irrelevant to driving-coverage story | Skip unless requested |
| In-app ads or "supporter tier" | Common monetization pattern | Personal-use app; no need | It's private; no monetization |
| Trip commenting / titling requiring user input | "Add color to your memories" | Friction on every confirm; most trips are commutes | Auto-title from start/end place names; optional edit |
| Route recommendations engine | "Suggest me a scenic loop" | Massive scope, needs routing engine + preference model | Adjacent-unexplored overlay does 80% of the value |

---

## Feature Dependencies

```
Local Storage (SQLite/Drift + spatial)
   |
   +---> Vehicles CRUD
   |
   +---> Road Graph (OSM extract with class tags)
   |        |
   |        +---> Offline Map-Matching Engine
   |        |         |
   |        |         +---> Trip Processing (matched geometry)
   |        |                    |
   |        |                    +---> Review Inbox
   |        |                    |         |
   |        |                    |         +---> Confirm/Reject
   |        |                    |                    |
   |        |                    |                    +---> Coverage Aggregation
   |        |                    |                                 |
   |        |                    +--> Manual Trip (same path)      |
   |        |                                                       |
   |        +---> Admin Boundaries Dataset                          |
   |                   |                                            |
   |                   +---> Region Index <---------------- Coverage Aggregation
   |                              |
   |                              +---> Focus-Area Pill (zoom-aware)
   |                              +---> Region Stats / Drill-down
   |
   +---> Location Service (fg + bg)
              |
              +---> Manual Start/Stop
              +---> Auto Trip Detection ------+
                                              |
                                       (feeds Trip Processing)

Map Renderer (flutter_map / MapLibre)
   |
   +---> Base tiles (offline PMTiles)
   +---> Coverage Layer (from Coverage Aggregation)
   +---> Kfz vs Feldweg styling
   +---> Focus-Area Pill overlay
```

### Dependency Notes

- **Road graph is the keystone.** Nothing (matching, classification, region % denominators) works without a properly ingested OSM extract with `highway=*` classifications and admin boundaries.
- **Coverage aggregation is downstream of confirmation.** Rejecting a trip must remove its contribution — the aggregator must be recomputable or maintain a reversible index.
- **Region index depends on both admin boundaries and coverage.** Precompute per-region driven-length and total-length; update on trip confirm/reject.
- **Focus-area pill is a UI feature but a heavy backend feature.** It needs an efficient "which admin region is centered on screen at this zoom?" lookup + per-region cached percentages.
- **Manual and auto tracking converge at the same Trip Processing pipeline.** Design the pipeline first, both entry points hook in.
- **Backup depends on final storage schema.** Don't ship backup before the schema stabilizes, or v1 backups become unrestorable in v1.1.

---

## MVP Definition

### Launch With (v1)

The minimum to deliver the core value: "open the map, see roads I've driven, painted."

- [ ] OSM road graph ingestion for one region (e.g., Germany / user's Bundesland) with Kfz vs Feldweg classification
- [ ] Interactive map with offline tiles + user location
- [ ] Manual start/stop trip recording
- [ ] Background auto-trip recording (basic: start-on-motion, stop-on-dwell)
- [ ] Offline map-matching pipeline
- [ ] Trip storage + review inbox (pending / confirmed / rejected)
- [ ] Vehicle profiles (create/edit/delete, assign at confirm)
- [ ] Coverage aggregation across confirmed trips
- [ ] Driven-roads overlay on map, Kfz vs Feldweg distinct colors
- [ ] Admin boundary dataset + zoom-aware focus-area pill (region + %)
- [ ] Basic stats: total km, unique road km, coverage % for top region
- [ ] Local encrypted backup + restore
- [ ] Dark mode
- [ ] Settings screen

### Add After Validation (v1.x)

- [ ] Custom user-defined regions (polygon draw)
- [ ] Sub-region drill-down and sorted lists
- [ ] Per-vehicle map coloring layer
- [ ] Adjacent-unexplored highlight overlay
- [ ] Recency shading for newly discovered roads
- [ ] GPX export per trip
- [ ] Bluetooth-based auto vehicle detection
- [ ] Import from Google Timeline / bulk GPX
- [ ] Coverage timeline scrubber
- [ ] Heatmap layer (drive frequency)

### Future Consideration (v2+)

- [ ] Poster export (PDF/PNG)
- [ ] Pattern-based auto vehicle detection (heuristic/ML)
- [ ] Trip split/trim editor
- [ ] Multi-country road-graph management with switchable extracts
- [ ] Confidence-score visualization for matched segments
- [ ] Region completion "milestones" (silent)

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Driven-roads overlay on map | HIGH | MEDIUM | P1 |
| Offline map-matching | HIGH | HIGH | P1 |
| Focus-area pill | HIGH | HIGH | P1 |
| Review inbox | HIGH | MEDIUM | P1 |
| Manual start/stop | HIGH | LOW | P1 |
| Background auto-recording | HIGH | HIGH | P1 |
| Kfz vs Feldweg coloring | HIGH | MEDIUM | P1 |
| Vehicle profiles | HIGH | LOW | P1 |
| Coverage aggregation | HIGH | MEDIUM | P1 |
| Local backup/restore | MEDIUM | MEDIUM | P1 |
| Offline base tiles | HIGH | MEDIUM | P1 |
| Basic stats | MEDIUM | LOW | P1 |
| Dark mode | MEDIUM | LOW | P1 |
| Custom regions | MEDIUM | MEDIUM | P2 |
| Adjacent-unexplored overlay | HIGH | MEDIUM | P2 |
| Recency shading | MEDIUM | MEDIUM | P2 |
| Per-vehicle map layers | MEDIUM | MEDIUM | P2 |
| GPX export | MEDIUM | LOW | P2 |
| Bluetooth vehicle detection | MEDIUM | MEDIUM | P2 |
| Google Timeline import | HIGH | HIGH | P2 |
| Heatmap layer | LOW | MEDIUM | P3 |
| Poster export | MEDIUM | MEDIUM | P3 |
| Trip split/trim editor | LOW | HIGH | P3 |
| Coverage timeline scrubber | LOW | MEDIUM | P3 |

**Priority key:**
- **P1** Must have for v1 launch — the app is not "Trailblazer" without these.
- **P2** Should have, add in v1.x once P1 is stable in real use.
- **P3** Nice to have, revisit only if driven by actual desire in daily use.

---

## Competitor Feature Analysis

| Feature | Wandrer.earth | CityStrides | Squadrats | Trailblazer Approach |
|---------|---------------|-------------|-----------|-----------------------|
| Coverage unit | road segments | streets (OSM ways) | grid squares | road segments, class-filtered (Kfz vs Feldweg) |
| Data ingestion | Strava/Garmin sync (cloud) | Strava/Garmin sync (cloud) | Strava sync (cloud) | on-device recording only, no cloud |
| Map-matching | server-side | server-side | grid, no matching needed | on-device offline |
| Region % | yes (admin hierarchy) | per-city | per-grid-cell | zoom-aware admin pill (differentiator) |
| Gamification | points, achievements, monthly challenges | badges, leaderboards, challenges | tier ranks | none — silent milestones only |
| Social | forums, leaderboards | leaderboards, comments | leaderboards | none |
| Vehicle types | N/A (cycling) | N/A (walking) | N/A | multi-vehicle profiles (unique) |
| Road classification | all roads equal | all streets equal | not applicable | Kfz vs Feldweg distinction (unique) |
| Offline capable | no (web-based) | no | partial | fully offline (differentiator) |
| Local-only | no (account required) | no | no | yes (positioning) |
| Monetization | freemium | freemium/supporter | freemium | none (personal app) |

---

## Sources

- [Wandrer.earth](https://wandrer.earth/) — feature list from public marketing pages, fetched 2026-07-02, confidence HIGH for stated features, MEDIUM for premium detail nuances.
- [CityStrides](https://citystrides.com/about) — about page feature list, fetched 2026-07-02, confidence HIGH for feature existence.
- Squadrats, StatsHunters — feature knowledge from prior familiarity; confidence MEDIUM (not re-verified this session).
- OpenStreetMap `highway=*` classification (`motorway`, `primary`, `secondary`, `tertiary`, `unclassified`, `residential`, `service`, `track`, `path`, `footway`) — basis for Kfz vs Feldweg/Fußweg split. Confidence HIGH.
- Adjacent-app patterns for offline map-matching: Valhalla, GraphHopper, Mapbox HMM — confidence MEDIUM, revisit in STACK research.

---

## Confidence & Gaps

**HIGH confidence:**
- Table stakes list — cross-verified against multiple adjacent apps.
- Anti-features list — driving-focused local-only positioning strongly implies these exclusions.
- Dependency graph — derived from product requirements themselves.

**MEDIUM confidence:**
- Complexity estimates — depend on final stack choice (flutter_map vs MapLibre; matcher engine).
- Whether Google Timeline import is feasible under current export formats — needs a phase-specific spike.

**LOW confidence / gaps to resolve later:**
- Feasibility and quality of on-device map-matching at road-graph scale on typical Android hardware — hard blocker to validate in a dedicated tech spike before phase planning finalizes.
- Best format for road-graph storage on device (PMTiles + separate topological graph? SpatiaLite? custom?) — resolve in STACK/ARCHITECTURE research.
- Exact German admin-boundary source and update cadence — likely OSM `admin_level=6/7/8`, but boundary quality varies by Bundesland.

---
*Feature research for: personal driving-focused route/street coverage tracker*
*Researched: 2026-07-02*
