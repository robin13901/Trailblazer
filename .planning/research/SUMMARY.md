# Trailblazer — Research Summary

**Synthesized:** 2026-07-02
**Sources:** STACK.md, FEATURES.md, ARCHITECTURE.md, PITFALLS.md
**Overall confidence:** MEDIUM-HIGH — map/DB/state/rendering paths well-trodden; on-device HMM matching and Liquid-Glass-over-platform-view are the two research-flagged risks.

---

## TL;DR

- **Stack shape:** `maplibre_gl` (PMTiles + native feature-state) + `drift` (two databases) + `flutter_riverpod` 3.x + `flutter_background_geolocation` + hand-rolled Dart HMM matcher. Liquid Glass stays as chosen (dev version, Impeller-only).
- **Two-database split is the single most important architectural decision.** App DB (mutable, migrated) and OSM DB (read-only, versioned artifact, swap-in-place). Never merge.
- **Map-matching is its own core module** (`core/map_matching/`) running in a **single long-lived isolate**, not `compute()`-per-trip. HMM (Newson-Krumm) with R-Tree candidate search over a precomputed graph.
- **OSM pipeline is a separate deliverable** (`tool/osm_pipeline/`), not app code — must be built before mobile matching. Ships a slim SQLite/PMTiles artifact (<150 MB target) with pre-built R-Tree and admin joins; downloaded on first run, not embedded in the APK/IPA.
- **Driven-road coloring uses MapLibre `feature-state`**, not GeoJSON re-uploads. Zero re-tessellation. Verify plugin exposes it in P2 spike.
- **Three show-stopper risks:** (1) Liquid Glass `BackdropFilter` over the MapLibre platform view is historically broken — spike on device before committing to the aesthetic; (2) HMM false-positives paint parallel autobahn/Bundesstraße unless Viterbi is delayed and re-matched at trip end; (3) `flutter_background_geolocation` Android release build requires a paid one-time license (~USD 400-1200) — surface to user before P3 ships.
- **MVP scope is generous but well-defined.** Table stakes: manual + auto tracking, offline matching, inbox review, coverage overlay, focus-area pill, admin regions, multi-vehicle, local backup. Anti-features: social, gamification streaks/badges, cloud sync, realtime coloring, turn-by-turn nav.
- **Skip immediately:** `flutter_map` + `vector_map_tiles` (stale, no feature-state), Google/Mapbox maps (cloud/cost), Valhalla/GraphHopper via FFI, `provider`, `mockito`, `flutter_lints`, `geodesy`, `flutter_bluetooth_serial`, `background_locator_2`.

---

## Stack

| Layer | Library | Version | Confidence | Note |
|---|---|---|---|---|
| Map render | `maplibre_gl` | ^0.26.2 | HIGH | Official, PMTiles + feature-state |
| Offline tiles | `pmtiles` | ^2.2.0 | HIGH | Ship thin base in-app, download detail on Wi-Fi |
| State | `flutter_riverpod` + `riverpod_generator` | ^3.3.2 / ^4.0.4 | HIGH | Replaces XFin's Provider |
| DB | `drift` + `sqlite3_flutter_libs` | ^2.34.0 / ^0.5.24 | HIGH | Drop `sqflite`/`drift_sqflite` |
| Background GPS/motion | `flutter_background_geolocation` | ^5.3.0 | HIGH (license caveat) | Motion classifier included |
| Permissions | `permission_handler` | ^12.0.3 | HIGH | |
| OSM PBF preprocessing | `geo_route_finder` + custom Dart CLI | ^1.0.3 | MEDIUM | Build-time only; audit code |
| Spatial index (runtime) | `r_tree` | ^3.0.2 | HIGH | |
| Map matcher | hand-rolled HMM (Newson-Krumm) | n/a | MEDIUM | No turnkey Dart lib exists |
| Geodesy | `geobase` + `turf` | ^1.5.0 / ^0.0.12 | HIGH / MEDIUM | Pin `turf` (pre-1.0) |
| Triangulation | `dart_earcut` | ^1.2.0 | HIGH | Admin-region fills |
| Immutability | `freezed` + `json_serializable` | ^3.2.5 / ^6.14.0 | HIGH | |
| BLE (optional) | `flutter_blue_plus` | ^2.3.10 | HIGH | BLE only — Classic via Kotlin platform channel |
| Routing | `go_router` | ^17.3.0 | HIGH | |
| Lints | `very_good_analysis` | ^10.3.0 | HIGH | Replaces `flutter_lints` |
| Mocking | `mocktail` | ^1.0.5 | HIGH | |
| E2E | `patrol` | ^4.6.1 | HIGH | Handles native permission dialogs |
| Glass UI | `liquid_glass_renderer` + `liquid_navbar` | 0.2.0-dev.4 / ^2.0.7 | MEDIUM | Impeller-only; pin exact dev version |

**Version compatibility flags:**
- `liquid_glass_renderer` runs only on Impeller (default iOS 3.10+, Android 3.24+).
- `flutter_background_geolocation` Android release requires paid license (~USD 400-1200 one-time).
- `freezed` 3.x changed union syntax; check migration guide.

---

## Feature Scope

### MVP (v1 — required for "the app is Trailblazer")

- Offline map (MapLibre + PMTiles), pan/zoom/user-location, dark mode
- Manual start/stop trip recording
- Background auto-trip recording (motion-triggered, dwell-terminated)
- On-device offline HMM map-matching
- Trip inbox: pending / confirmed / rejected + confirm-with-vehicle
- Multi-vehicle profiles (CRUD, default vehicle, assign at confirm)
- Coverage aggregation across confirmed trips
- Driven roads overlay via MapLibre `feature-state`; **Kfz vs Feldweg/Fußweg in distinct colors, Feldweg/Fußweg NOT counted in %**
- Admin boundary dataset + **zoom-aware focus-area pill** (region + %)
- Basic stats: total km, unique-road km, top-region %
- Encrypted local backup + restore
- Settings screen, permission onboarding
- OSM extract update / swap flow

### Deferred (v1.x — after MVP validates)

Custom user-drawn regions; sub-region drill-down; per-vehicle map coloring layer; adjacent-unexplored highlight; recency-glow shading; GPX export; BT-based vehicle auto-detect (Android); Google Timeline import; heatmap layer; coverage timeline scrubber.

### v2+

Poster PDF/PNG export; pattern-based vehicle auto-detect; trip split/trim editor; multi-country extract management; per-segment matcher confidence viz; silent region-completion milestones.

### Anti-features (do NOT build)

Social / friends / leaderboards; XP/streaks/badges; realtime coloring during driving; push notifications for nearby unexplored roads; turn-by-turn navigation; cloud sync; fitness metrics; OAuth / public API; elevation profiles; ads / supporter tier; forced trip commenting; recommendation engine.

---

## Architecture at a Glance

### Module map

```
lib/
├── core/
│   ├── db/           # Drift App DB (mutable, migrated)
│   ├── osm/          # Drift OSM DB (RO artifact, swap-in-place)
│   ├── map_matching/ # HMM engine + orchestrator + isolate
│   ├── background/   # GPS, motion, BT watcher, scheduling
│   ├── logging/  errors/  routing/  theme/
└── features/         # feature-first: data / domain / presentation
    ├── tracking/     # live session, motion UX
    ├── trips/        # inbox, confirm, detail
    ├── map/          # MapLibre widget, camera, focus resolver
    ├── vehicles/     # profiles + BT fingerprint config
    ├── regions/      # admin browser + regional coverage
    ├── coverage/     # aggregation + cache invalidation
    └── settings/     # extract updates, prefs, diagnostics
tool/
└── osm_pipeline/     # dev-machine only; NOT shipped
```

**Why core modules exist as they do:**
- `map_matching/` is core (not in `trips/`) because it has its own runtime concern (isolate, cancellation), is consumed by 3+ features, and has no UI.
- `osm/` is core (not in `map/`) because it is versioned read-only reference data with an independent lifecycle (download / verify / swap).

### Isolate topology

```
UI isolate ─┬─ Riverpod, MapLibre
            ├─► DriftIsolate (App DB, mutable)
            ├─► DriftIsolate (OSM DB, read-only)
            └─► Matcher Isolate (long-lived, on-demand)
                    │ holds warm handles to OSM DB + R-Tree
                    ▼
                emits driven_intervals → App DB → coverage cache invalidation
Native GPS/BT plugin ── method/event channels ──► UI isolate ──► Matcher isolate
```

### Key patterns

1. **Two-database split** — App DB migrated in-place; OSM DB replaced wholesale on extract update.
2. **Long-lived matcher isolate** — amortizes DB open + R-Tree warm-up; supports cancellation.
3. **Riverpod-only state surface** — `AsyncNotifier` for mutation, `StreamProvider` on Drift `watch()`.
4. **DAO-per-table + Service-per-feature** — thin SQL, testable orchestration.
5. **R-Tree candidate search + Viterbi HMM** — top-5 candidates per point, adaptive radius by HDOP.
6. **Coverage cache with explicit invalidation** — never recompute on map open.
7. **Focus-area resolver as pure function** — `(mapCenter, zoom) → RegionLevel × RegionId`, debounced on camera idle.

---

## Suggested Phase Build Order

Critical dependency chain: `core/db → core/background → tracking → OSM pipeline artifact → core/osm → core/map_matching → trips-confirm-and-match → map render → coverage → regions UI`.

1. **P1 — Scaffolding** — `core/theme`, `routing`, `errors`, `logging`, `core/db` skeleton + migration infra, permission plumbing, CI (very_good_analysis, GitHub Actions, Codecov). *[needs C1/C2 permission checklists day one]*
2. **P2 — Map + Liquid Glass shell** — MapLibre widget, PMTiles base, style JSON, camera, glass shell. **Rendering spike before UI commitment** (R1). *[research flag: feature-state availability in `maplibre_gl` plugin]*
3. **P3 — Background primitives + Tracking MVP** — `core/background` (GPS facade, motion, permissions), state machine, manual + auto trip capture writing raw points to App DB. **License decision for `flutter_background_geolocation` gate.** *[battery HUD baseline required]*
4. **P4 — OSM pipeline (dev-machine deliverable)** — `tool/osm_pipeline/`: PBF → filtered ways → junction split → R-Tree → admin joins → `germany.pmtiles` + `osm.sqlite` artifact. Start with a Berlin-bbox subset. **Own deliverable, not a P5 subtask.**
5. **P5 — core/osm + core/map_matching** — OSM DB loader / verifier / swap; HMM engine (pure), orchestrator, isolate lifecycle; unit-tested against toy OSM DB. *[needs golden test corpus of 20-30 known-hard trips]*
6. **P6 — Trips + inbox + matching wired in** — inbox UI, confirm/reject flow, vehicle assignment stub, `MatchOrchestrator.enqueue` on confirm → intervals written → coverage cache invalidated.
7. **P7 — Coverage rendering** — driven-ways via MapLibre `feature-state` (or sharded GeoJSON fallback); stress-test with 50k faked segments.
8. **P8 — Regions + coverage aggregation UI** — region browser, drill-down, focus-area pill wired to coverage cache, top-region % stats.
9. **P9 — Vehicles + Bluetooth** — full vehicle CRUD, per-vehicle color prefs, Android BT platform-channel fingerprint + iOS motion+audio heuristic.
10. **P10 — Settings, backup, extract updates** — encrypted local backup/restore (App DB only, exclude OSM), extract update UI, permissions inspector, diagnostics.
11. **P11 — Hardening** — iOS `BGTaskScheduler` empirical validation, OEM battery-optimization QA (Samsung + Xiaomi real devices), coverage invalidation edge cases, extract-swap failure recovery, migration schema tests, 60-minute battery baseline gate.

**Phases needing dedicated research spikes (`/gsd:research-phase`):** P2 (glass + platform view), P5 (HMM parameter tuning + golden corpus), P7 (feature-state confirmation), P11 (iOS BG behavior).
**Standard patterns (skip research):** P1, P3 (with plugin), P6, P8, P10.

---

## Critical Risks

| # | Risk | Severity | Mitigation | Phase |
|---|---|---|---|---|
| R1 | `BackdropFilter` over MapLibre platform view breaks blur / occludes / janks in release | CRITICAL | Rendering spike on real iOS + Android before committing to full glass; fall back to semi-transparent gradient tinted from map sample; keep glass to edge panels | P2 |
| R2 | HMM false-positives paint parallel autobahn/Bundesstraße, roundabout smearing, parking snap | CRITICAL | Viterbi delay (5-10 emissions); retroactive re-match at trip end; weight emission by `horizontalAccuracy`; min-speed 15 km/h for autobahn matching; 20-30 golden test trips in CI | P5 |
| R3 | Battery drain (15-25% per 45-min drive) — app abandoned | CRITICAL | State machine (`idle→detecting→recording→paused`); `kCLLocationAccuracyBest` not `BestForNavigation`; batch DB writes every ~20 fixes; matcher on isolate; MapLibre pause on background; debug HUD + baseline metric committed to repo | P3 + P11 |
| R4 | iOS auth downgrade — silent `whenInUse → Always` loss | CRITICAL | Two-step ladder (whenInUse first trip, Always on next); poll `CLAuthorizationStatus` on resume; re-prompt UI; `pausesLocationUpdatesAutomatically=false`, `activityType=.automotiveNavigation`, `allowsBackgroundLocationUpdates=true` set AFTER Always | P1 + P3 |
| R5 | Android 14 foreground service type + OEM battery killers | CRITICAL | `foregroundServiceType="location"`, persistent real notification, `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` prompt; real-device QA on Samsung + Xiaomi | P1 + P3 |
| R6 | iOS Classic Bluetooth vehicle fingerprint impossible (Apple API restriction) | HIGH | Documented asymmetry; iOS uses CoreMotion `automotive` + `AVAudioSession` BT-route + CarPlay heuristic; Android uses Kotlin platform channel for `bondedDevices` | P9 |
| R7 | `flutter_background_geolocation` Android release-license cost (~USD 400-1200 one-time) | HIGH | Surface to user before P3 exit; consider `geolocator` + `flutter_background_service` DIY as fallback (4-6 wk OEM work) | P3 |
| R8 | Germany extract too large for APK / R-Tree too slow / DB migrations wipe user trips | HIGH | Slim graph pipeline (<150 MB); ship thin base + Wi-Fi download; R-Tree p95 < 30ms benchmark gate at P5; **two databases** so graph swap can't touch user data; Drift `SchemaVerifier` tests | P4 + P5 |

---

## Open Decisions

| Decision | When | Options |
|---|---|---|
| Background GPS plugin: buy license or DIY | Before P3 ships to Play Store | (a) `flutter_background_geolocation` + Android release license (~USD 400-1200 one-time); (b) `geolocator` + `flutter_background_service` DIY (4-6 wk OEM work) |
| Extract shipping model | Before P4 pipeline design freezes | (a) Slim base PMTiles bundled + detail downloaded on first run (recommended); (b) full extract via Play Asset Delivery; (c) all-download |
| Driven-way rendering primitive | Before P7 starts | (a) MapLibre `feature-state` (preferred; verify plugin API in P2); (b) sharded GeoJSON sources per 5×5 km tile (fallback) |
| Matcher live-vs-final strategy | During P5 design | (a) Single pass at trip finalize (simpler; coverage is post-hoc); (b) Two-pass: provisional online preview + authoritative offline re-match |
| Raw GPS retention after match | Before P6 ships | (a) Delete raw after match; (b) Keep 30 days for re-matching (recommended per PITFALLS M6); (c) Keep forever |
| Map-matching library-vs-hand-rolled | Before P5 starts | (a) Hand-rolled HMM ~800-2000 LOC (recommended); (b) MVP fallback via `route_spatial_index` nearest-snap; (c) FFI Valhalla/GraphHopper (rejected in STACK) |
| Backup encryption + destination | Before P10 | User-picked file path (Nextcloud folder / SD card / iCloud Drive) with app-managed AES key; whether to include OSM DB (default: NO — derivable) |
| Extract source authority | Before P4 | Self-hosted extract CDN vs direct Geofabrik URL vs prebuilt osm-boundaries.com admin GeoJSON |
| iOS Classic BT fallback strategy | Before P9 | Motion+audio heuristic only vs opt-in CarPlay entitlement (bigger review scope) |
| MVP scope of admin levels | Before P8 | L2/4/6/8 only vs also L9/10 (Ortsteile) — depends on OSM data quality per Bundesland |

---

## Confidence Assessment

| Area | Confidence | Notes |
|---|---|---|
| Stack (map, DB, state, background, testing) | HIGH | Verified publishers, current versions, cross-referenced against XFin |
| Stack (HMM matcher, OSM pipeline libs) | MEDIUM | No turnkey Dart matcher exists; `geo_route_finder` unverified publisher (audit before use); `dart_osmpbf` v0.0.1 build-time only |
| Feature scope MVP | HIGH | Explicit product requirements + cross-verified against Wandrer/CityStrides/Squadrats |
| Anti-features | HIGH | Driving + local-only positioning strongly implies exclusions |
| Architecture (two-DB, isolates, DAO+Service) | HIGH | Drift + Riverpod idioms; MapLibre style-spec confirmed |
| Architecture (iOS `BGTaskScheduler` empirical behavior) | MEDIUM | Device- and OS-version-dependent; validate in P11 |
| Pitfalls (permissions, HMM failure modes, battery) | HIGH | Well-established Apple/Android patterns; Newson-Krumm-documented matcher issues |
| Pitfalls (`BackdropFilter` + platform view in 2026) | MEDIUM | Historical issue is HIGH; current state needs device spike |
| Pitfalls (`maplibre_gl` feature-state API) | MEDIUM | JS parent has it; Flutter plugin coverage not verified this session |

### Gaps to flag for validation

- **P2 rendering spike:** `BackdropFilter` behavior over MapLibre platform view on Impeller (iOS + Android) in 2026.
- **P2/P7:** Confirm `maplibre_gl` ^0.26.2 exposes `setFeatureState` API. If not, plan sharded GeoJSON approach.
- **P4 sizing:** Actual size of Trailblazer-slim road extract for Germany (target <150 MB); Play Asset Delivery + App Store size limits.
- **P5 accuracy:** HMM parameter tuning against Germany autobahn + Bundesstraße parallel scenarios. Requires golden trip corpus recorded in real driving.
- **P9 iOS heuristic quality:** How reliable is CoreMotion `automotive` + `AVAudioSession` BT-route as a vehicle-detection signal in practice.
- **P11 iOS `BGTaskScheduler`:** Empirical wake frequency for coverage-recompute tasks on user devices.

---

## Sources

- **STACK.md** — pub.dev package audit (all versions dated 2026-07-02); Newson & Krumm (2009) HMM reference.
- **FEATURES.md** — Wandrer.earth, CityStrides, Squadrats/Squadratinhos, StatsHunters feature landscape; OSM `highway=*` classification for Kfz vs Feldweg split.
- **ARCHITECTURE.md** — Drift docs (isolates, migrations, `SchemaVerifier`); MapLibre style-spec (data-driven paint + feature-state); Riverpod 2.x/3.x docs; Apple CoreLocation + BGTaskScheduler; Android foreground service + WorkManager.
- **PITFALLS.md** — Flutter issue history (#43902, #71888, #74801 area — platform view + BackdropFilter); Apple CLLocationManager patterns; Android 14 foreground-service-type mandate; Newson-Krumm failure modes; MapLibre feature-state pattern; `dontkillmyapp.com` OEM battery reference.

### Cross-references

- **Two-database split:** ARCHITECTURE §1, §2.4, §4-Pattern1, §7; PITFALLS H4.
- **HMM matcher packaging:** STACK Layer 3; ARCHITECTURE §2.3, §4-Pattern2, §4-Pattern5, §5.2; PITFALLS C4.
- **OSM pipeline as separate deliverable:** STACK Layer 3, Layer 9; ARCHITECTURE §3 (`tool/osm_pipeline/`), §7; PITFALLS H2.
- **`feature-state` driven-road coloring:** STACK Layer 1; ARCHITECTURE §5.3; PITFALLS H5.
- **Battery / background:** STACK Layer 4; ARCHITECTURE §6; PITFALLS C1, C2, C5.
- **Liquid Glass + platform view:** STACK Layer 11; PITFALLS C3.

---

*Research synthesis for: Trailblazer (Flutter GPS trip-tracker with on-device OSM map-matching)*
*Synthesized: 2026-07-02*
