# Stack Research — Trailblazer

**Domain:** Flutter (iOS + Android) GPS trip-tracker with on-device offline OSM map-matching, vector map with data-driven road coloring, Drift/SQLite persistence, Liquid Glass UI.
**Researched:** 2026-07-02
**Overall confidence:** MEDIUM-HIGH (map/DB/state HIGH; map-matching MEDIUM — no turnkey Dart lib exists, so we assemble it)

---

## TL;DR — The Recommended Stack

| Layer | Choice | Version | Confidence |
|---|---|---|---|
| Map rendering | **maplibre_gl** (official) | ^0.26.2 | HIGH |
| Offline tiles | **PMTiles** via `pmtiles` + MapLibre custom protocol | ^2.2.0 | HIGH |
| State management | **flutter_riverpod** + `riverpod_generator` | ^3.3.2 / ^4.0.4 | HIGH |
| Local DB | **drift** (+ `sqlite3_flutter_libs`) | ^2.34.0 | HIGH |
| Background location + motion | **flutter_background_geolocation** | ^5.3.0 | HIGH (with license caveat) |
| Permissions | **permission_handler** | ^12.0.3 | HIGH |
| OSM PBF preprocessing (build-time CLI) | **`geo_route_finder`** + custom Dart tool | ^1.0.3 | MEDIUM |
| Spatial index (runtime) | **r_tree** | ^3.0.2 | HIGH |
| Map-matching algorithm | **Hand-rolled HMM matcher in Dart** (Newson-Krumm) | n/a | MEDIUM |
| Geometry / geodesy | **geobase** (heavy) + **turf** (turf-style helpers) | ^1.5.0 / ^0.0.12 | HIGH / MEDIUM |
| Polygon triangulation | **dart_earcut** | ^1.2.0 | HIGH |
| JSON codegen | **json_serializable** + `freezed` | ^6.14.0 / ^3.2.5 | HIGH |
| Bluetooth (vehicle fingerprint) | **flutter_blue_plus** (BLE only) — see caveats | ^2.3.10 | HIGH (BLE) / N/A (Classic) |
| Routing / navigation | **go_router** | ^17.3.0 | HIGH |
| Lints | **very_good_analysis** | ^10.3.0 | HIGH |
| Mocking | **mocktail** | ^1.0.5 | HIGH |
| Integration testing | **patrol** | ^4.6.1 | HIGH |
| Glass UI (already chosen) | **liquid_glass_renderer** + **liquid_navbar** | ^0.2.0-dev.4 / ^2.0.7 | MEDIUM (dev version) |

---

## Layer 1 — Map Rendering

### Recommendation: `maplibre_gl` ^0.26.2

**Why (HIGH confidence):**
- Published by `maplibre.org` (verified publisher, official) — last release 12 days ago, actively maintained.
- Uses native MapLibre SDKs (MapLibre Native on Android/iOS) which is the reference vector-map renderer used by MapTiler, Mapbox forks, OpenFreeMap, Protomaps.
- **First-class PMTiles support** via a custom protocol handler (documented, in the example app).
- **Native data-driven styling / feature-state** — the exact primitive needed to paint "driven" road segments a different color from "not driven" without redrawing tiles. This is the killer feature for Trailblazer's core value.
- Vendor-neutral (BSD-3), no API keys, no telemetry, no cost.
- Runs on Impeller — coexists with `liquid_glass_renderer` (which requires Impeller).

**How feature-state coloring will work:**
1. Ship OSM Germany as PMTiles; each road feature has its OSM `way_id` as a feature property.
2. At runtime, after the map-matcher produces a set of driven `way_id`s, call `setFeatureState({source, sourceLayer, id}, {driven: true})`.
3. Style rules use `["case", ["boolean", ["feature-state", "driven"], false], "#ff5500", "#7a7a7a"]`.
4. Zero re-tiling, zero re-download, updates on the fly at 60fps.

### Alternatives Considered

| Option | Verdict | Why not |
|---|---|---|
| `flutter_map` ^8.3.1 + `vector_map_tiles` ^8.0.0 | REJECT | `vector_map_tiles` last released 22 months ago; no native data-driven styling / feature-state API; runtime style JSON is limited. Would force re-rendering strategies (line overlays) that don't scale to ~1M road segments. |
| `maplibre` ^0.3.5 (community rewrite) | DEFER | Only 2 months old, community rewrite by joscha-eckert.de; not yet feature-complete, no confirmed feature-state API. Revisit in 6-12 months. |
| `mapsforge_flutter` ^4.0.0 | REJECT | Renders raster from vector .map files but lacks a Google-Maps-style vector rendering pipeline and dynamic feature-state coloring. LGPL-3.0 also complicates distribution. |
| `google_maps_flutter` | REJECT | Cloud dependency, cost at scale, no offline vector tiles, no OSM data model. Violates "no server / no ongoing cost". |
| `mapbox_maps_flutter` | REJECT | Requires Mapbox account + token + billing. |

### What NOT to use

- **`vector_map_tiles`** — 22-month-stale, no data-driven feature-state.
- **`flutter_map` alone** — raster-only without plugins; wrong tool for the "paint 400k road segments" job.

---

## Layer 2 — Offline Tiles

### Recommendation: **PMTiles** via `pmtiles` ^2.2.0 (Dart) served through MapLibre's custom protocol handler

**Why (HIGH confidence):**
- Single-file archive → trivially shippable/downloadable/replaceable, no SQLite locking issues.
- HTTP range-request friendly (supports future "download on demand" mode without code change).
- MapLibre GL example ships a `pmtiles.dart` protocol handler — this is a documented, blessed integration path.
- Published by verified publisher, updated 2 days ago (active).

**Sizing (Germany, planning target — verify at build time):**

| Content | Zoom | Approx size |
|---|---|---|
| Germany OpenMapTiles basemap (Protomaps style) | 0–14 | ~2.5–4 GB |
| Trailblazer road-only extract (highway=* only, way_id tagged) | 8–15 | ~600 MB – 1.2 GB |

**Strategy:** ship a **thin base PMTiles** with the app (500-800 MB, zoom 0-12 country overview) and download a **detailed road PMTiles** (zoom 12-15) on first run over Wi-Fi. Store in `path_provider` app-support directory. This keeps initial IPA/APK under 200 MB and delivers full detail after ~5-minute first-run download.

### Alternatives Considered

| Option | Verdict | Why not |
|---|---|---|
| **MBTiles** via `mbtiles` ^0.5.0 (joscha-eckert.de) | Viable fallback | SQLite-based, well-understood, but PMTiles is the modern default for MapLibre and simpler to swap in/out. Choose MBTiles only if you need per-tile writes at runtime. |
| Raw XYZ tile directories | REJECT | Millions of files → filesystem killer on Android. |
| Live tile server (self-hosted) | REJECT | Violates "no server" constraint. |

---

## Layer 3 — On-Device Map-Matching (The Hard Problem)

**No turnkey Dart map-matcher exists.** `pub.dev` search for "map matching" returns only Mapbox API wrappers and unrelated fuzzy-string libs. This is the highest-risk layer and must be built.

### Recommendation: Hand-rolled HMM map matcher in Dart (Newson & Krumm 2009 algorithm)

**Confidence: MEDIUM** — the algorithm is well-documented and has been ported to many languages (Java: Barefoot; Python: leuven-map-matching, fmm; Rust: valhalla-mm). Porting to Dart is ~800-2000 LOC and tractable.

### Concrete Architecture

**Build-time (Dart CLI tool, runs on developer machine):**

```
Germany OSM PBF (osm.pbf, ~4 GB from Geofabrik)
    │
    ├── Parse with `geo_route_finder`'s OsmConverter OR custom `dart_osmpbf` code
    │   (both are pure Dart; `geo_route_finder` already extracts highway networks)
    │
    ├── Filter: keep only ways with highway ∈ {motorway,trunk,primary,secondary,
    │                                           tertiary,unclassified,residential,
    │                                           service,living_street,track}
    │
    ├── Split ways at junctions → road segments (each with stable segment_id + osm_way_id)
    │
    ├── Emit:
    │   - segments.bin  (compact packed: segment_id, way_id, geometry as delta-encoded lat/lon)
    │   - rtree.bin     (serialized R-tree of segment bounding boxes)
    │   - graph.bin     (segment adjacency for HMM transition probabilities)
    │   - germany.pmtiles (vector tiles for MapLibre, with segment_id as feature id)
    │
    └── Ship all with app (or download post-install)
```

**Runtime (device, pure Dart, no isolate-crossing native code):**

```
GPS point stream (from flutter_background_geolocation)
    │
    ├── Buffer window (e.g., last 30 seconds of points)
    │
    ├── For each point:
    │   1. Query r_tree for candidate segments within ~50m radius
    │   2. Compute perpendicular distance → emission probability (Gaussian, σ≈15m)
    │   3. For each candidate pair (prev, curr): compute transition probability
    │      based on network distance / GPS distance ratio
    │
    ├── Viterbi decoding over window → most likely sequence of segments
    │
    ├── Emit driven segment_ids → Drift DB (upsert into `driven_segments`)
    │
    └── Update MapLibre feature-state → segment turns colored
```

**Libraries used:**
- **`r_tree` ^3.0.2** (workiva.com, verified, updated 4 months ago) — Dart R-tree for candidate search.
- **`geobase` ^1.5.0** — geodesic distance (Vincenty/haversine), coordinate math.
- **`turf` ^0.0.12** (scalabs.de, verified, 51 days) — point-to-line-segment operations. Used cautiously (0.0.12 = pre-1.0).
- **`dart_osmpbf` ^0.0.1** (joranmulderij) — OSM PBF parser, but only 0.0.1 and 23 months stale → use only in the offline build tool, not on device.
- **`geo_route_finder` ^1.0.3** — offers PBF → routing-graph compilation in pure Dart; use its `OsmConverter` as a starting point; unverified publisher → **audit code before adopting**.

**Fallback simpler approach (Phase 1 MVP):** Use `route_spatial_index` ^1.0.3 for nearest-segment snapping (documented as "snapping a GPS position to the nearest road", 100k points in 20-100ms). Accuracy is lower than HMM at intersections/parallel roads, but ships in a day. Upgrade to HMM in Phase 3.

### Alternatives Considered

| Option | Verdict | Why not |
|---|---|---|
| Valhalla / GraphHopper via FFI | REJECT | ~150-300 MB native binaries, cross-compilation nightmare on iOS (bitcode, static linking), Android NDK setup pain. Overkill: we don't need routing, only matching. |
| Server-side Valhalla | REJECT | Violates "no server / no cost". |
| OSRM `match` endpoint | REJECT | Same as above. |
| Mapbox Map Matching API | REJECT | Cloud, cost, privacy. |
| Barefoot (Java) via Kotlin FFI | REJECT | Two-language build, JVM on-device is not viable. |
| Snap-to-nearest only, no HMM | ACCEPTABLE for MVP | See fallback above. Insufficient for final quality. |

### What NOT to use

- **Do not FFI a C++ map-matcher**. iOS App Store review + Android NDK + Dart FFI + shared road-graph memory = weeks of pain for a solvable pure-Dart problem.
- **Do not depend on `dart_osmpbf` at runtime** — 0.0.1 and stale. Build-time only.

---

## Layer 4 — GPS Recording (Background + Manual)

### Recommendation: `flutter_background_geolocation` ^5.3.0 (transistorsoft.com)

**Why (HIGH confidence):**
- Verified publisher, updated 9 days ago, industry-standard for background GPS on Flutter.
- Handles all of: motion-activity trigger (bundles accelerometer/gyro/magnetometer detection), foreground service, iOS significant-location changes, geofencing, battery-aware duty cycling, activity classification (in-vehicle / on-bicycle / on-foot / still).
- **Replaces** `flutter_activity_recognition` entirely — motion classification is built in.
- Robust across OS-vendor battery-optimization quirks (Samsung, Xiaomi, Huawei), which are the #1 cause of "trips disappear" bugs.

**CRITICAL CAVEAT — LICENSING:**
- Free & fully functional in **DEBUG** builds on both platforms.
- **RELEASE builds on Android require a paid license** (one-time HYPPO license, roughly USD 400-500 per app, plus a Pro license USD ~700 for full features). iOS release builds are free.
- **Decision required before Phase 1 ships to Play Store.** For a private app, the license is a one-time cost, not "ongoing" — arguably compatible with the "no ongoing cost" constraint, but call this out to the user.

### Alternatives Considered

| Option | Verdict | Why not |
|---|---|---|
| `geolocator` + custom foreground service | Viable but LOTS of work | Would need to hand-roll the foreground service, motion-triggering, battery duty cycling, and OEM-battery-optimization workarounds. 4-6 weeks of platform engineering. |
| `background_locator_2` ^2.0.6 | REJECT | 3 years stale, unclear Flutter 3.x support. |
| `flutter_activity_recognition` ^4.0.0 | Only as helper | 22 months old, works but redundant if using `flutter_background_geolocation`. |

### What NOT to use

- **Any package published >2 years ago** for background location on Android — battery API changes since Android 12 have broken most.

---

## Layer 5 — Permissions

### Recommendation: `permission_handler` ^12.0.3

**Why (HIGH confidence):**
- Baseflow, verified, updated 31 days ago, 2.91M downloads.
- Covers all needed permissions: `location`, `locationAlways`, `locationWhenInUse`, `activityRecognition`, `bluetooth`, `bluetoothScan`, `bluetoothConnect`, `notification` (Android 13+).
- Already in XFin reference project.

Note: `flutter_background_geolocation` has its own permission flow that wraps `permission_handler` semantics; check its docs first before duplicating.

---

## Layer 6 — State Management (Migration from Provider → Riverpod)

### Recommendation: `flutter_riverpod` ^3.3.2 + `riverpod_generator` ^4.0.4 + `custom_lint` + `riverpod_lint`

**Why (HIGH confidence):**
- Riverpod 3.x is current (^3.3.2 released 22 days ago), published by remi (dash-overflow.net, verified).
- Code-gen (`@riverpod` annotation) is the current idiomatic style, plays nicely with Freezed models and Drift-generated types.
- Feature-first architecture maps cleanly onto Riverpod's provider families and modifiers.

**Companion packages:**
```yaml
dependencies:
  flutter_riverpod: ^3.3.2
  riverpod_annotation: ^3.3.2
dev_dependencies:
  riverpod_generator: ^4.0.4
  riverpod_lint: ^3.3.2
  custom_lint: ^0.7.5
```

### Alternatives Considered

| Option | Verdict | Why not |
|---|---|---|
| `provider` (current XFin choice) | REJECT for new project | User explicitly asked to swap. Less structured for async streams (GPS points, DB watches). |
| `flutter_bloc` | Viable | More boilerplate; Riverpod is simpler for this kind of derived-state UI. |
| `signals` / `mobx` | REJECT | Smaller ecosystems for this domain. |

---

## Layer 7 — Local Database (given: Drift)

### Recommendation: keep `drift` ^2.34.0 (was ^2.19.0 in XFin) + `sqlite3_flutter_libs` ^0.5.24

**Why (HIGH confidence):**
- Verified publisher (simonbinder.eu), updated 21 days ago, actively developed.
- Type-safe Dart-side queries, reactive `watch()` streams that plug perfectly into Riverpod.
- Isolate support built-in — long-running map-matching writes can happen off the UI thread.
- Custom SQL functions supported → we can register a Dart callback for spatial predicates if needed.

**Schema notes for Trailblazer:**
- `trips`, `trip_points` (raw GPS), `driven_segments` (segment_id UNIQUE, first_driven_at, last_driven_at, drive_count), `admin_regions` (id, level, name, geometry_blob), `region_coverage_cache`.
- Use `INTEGER PRIMARY KEY` for segment_id (map straight to OSM way_id where possible).
- Wrap batch inserts of GPS points in transactions; enable WAL mode.

**Consider dropping:** `sqflite` / `drift_sqflite` from XFin's config — they're legacy. `sqlite3_flutter_libs` alone is the modern path.

### What NOT to use

- **Isar / ObjectBox** — user has committed to Drift; also both have had maintenance turbulence.
- **hive** — no relational queries, wrong tool for coverage aggregation.

---

## Layer 8 — Geometry & Geodesy

### Recommendation:

| Package | Version | Role |
|---|---|---|
| `geobase` | ^1.5.0 | Heavy lifting: WKT/WKB/GeoJSON parsing, ellipsoidal distance (Vincenty), Web Mercator projection, tiling schemes. Navibyte, verified, updated 2025-03-11. |
| `turf` | ^0.0.12 | Turf.js-style helpers when needed (bearing, midpoint, along). **Pre-1.0 — pin exact version.** |
| `proj4dart` | ^3.0.0 | Coordinate reference system transforms if we ever need something other than WGS84/Web Mercator (e.g., German ETRS89). Unverified publisher — audit before adopting. |
| `dart_earcut` | ^1.2.0 | Polygon triangulation if we render admin-region fill polygons on the map. |
| `latlong2` | ^0.9.1 | Simple lat/lon type used by geodesy and flutter_map. Optional. |

### What NOT to use

- **`geodesy`** ^0.11.0 — unverified publisher, only spherical model (less accurate than `geobase`'s Vincenty). Skip.

---

## Layer 9 — Admin Boundary Data

**Not a package — a data pipeline. Documented here so roadmap accounts for it.**

**Source:**
- Germany admin boundaries → OSM `boundary=administrative` relations at `admin_level` 4 (Bundesländer), 6 (Landkreise), 8 (Gemeinden).
- Extract at build time from the same Geofabrik Germany PBF using `geo_route_finder` / `dart_osmpbf` OR pre-built downloads from **OSM Boundaries** (osm-boundaries.com) as GeoJSON.

**Runtime storage:**
- Store as `admin_regions(id, parent_id, level, name, geojson_blob)` in Drift.
- Use point-in-polygon (from `turf` or `geobase`) to bucket driven segments into regions.
- Cache aggregate coverage in `region_coverage_cache`.

---

## Layer 10 — Bluetooth (Vehicle Fingerprint)

### Recommendation: `flutter_blue_plus` ^2.3.10 **for BLE only** + platform-channel fallback if needed

**Why (mixed confidence):**
- `flutter_blue_plus` is verified, updated 2 days ago, industry standard for BLE.
- BUT: **it does NOT support Bluetooth Classic** (explicitly documented).

**The problem:** Modern cars typically pair via **Bluetooth Classic** (A2DP/HFP audio profile). Getting a paired-device fingerprint (MAC address / name) of a Classic device is:
- **Android:** possible via `BluetoothAdapter.bondedDevices` — requires a native platform channel (write ~30 lines of Kotlin) OR `flutter_bluetooth_serial` ^0.4.0 (4 years stale, Android-only, unmaintained → not recommended).
- **iOS:** **NOT ALLOWED**. Apple does not expose paired Classic device metadata to non-MFi apps. Ever. Confidence: HIGH — this is a documented App Store restriction.

### iOS workaround for vehicle fingerprint

Since iOS blocks Classic BT enumeration, use **CoreLocation + CarPlay/CarAudioSession** indicators:
- Detect audio route change to a Bluetooth output (`AVAudioSession`).
- Detect CarPlay connection via `CPTemplateApplicationScene`.
- Motion activity type = "automotive" from CoreMotion.

Combined heuristic: BT audio active + automotive motion + speed > 5 km/h → "in a vehicle". This is imperfect but is what everyone else does.

### Recommendation summary

- Ship **Android-only** BT-based vehicle detection via a **thin Kotlin platform channel** (30-50 LOC in `android/app/src/main/kotlin/…/BluetoothPairedPlugin.kt`).
- On **iOS**, use the motion+audio-route heuristic. Document this asymmetry in `PITFALLS.md`.
- Use `flutter_blue_plus` if we later add BLE-only accessories (e.g., OBD-II BLE dongles).

---

## Layer 11 — UI: Liquid Glass (already chosen)

### Keep: `liquid_glass_renderer` ^0.2.0-dev.4 + `liquid_navbar` ^2.0.7

**Confidence: MEDIUM (dev version).**

**Known constraints (from pub.dev):**
- **Only works on Impeller.** Fortunately, Impeller is default on iOS (since Flutter 3.10) and default on Android (since Flutter 3.24). Both platforms of interest are covered.
- **Does not run on web, Windows, or Linux** — irrelevant for iOS+Android target.
- **Animations spike memory** due to a Flutter texture-disposal bug. Document as pitfall; test heavily on low-RAM devices.
- Dev version (0.2.0-dev.4) — pin exact version, watch for a stable 0.2.0 release.

`liquid_navbar` ^2.0.7 already declares `flutter_riverpod: ^3.0.3` as a dep → aligns with our Riverpod choice.

---

## Layer 12 — Codegen, Immutability, Serialization

| Package | Version | Role |
|---|---|---|
| `freezed` | ^3.2.5 | Immutable data classes, unions, `copyWith`, `==`/`hashCode`. Use for domain models (Trip, Segment, Region). |
| `freezed_annotation` | ^3.1.0 | Annotations. |
| `json_serializable` | ^6.14.0 | JSON codegen, integrates with freezed. Use for admin-region GeoJSON and any config files. |
| `json_annotation` | ^4.9.0 | Annotations. |
| `build_runner` | ^2.5.4 | Runs drift_dev + riverpod_generator + freezed + json_serializable. |

**Codegen orchestration:** all four generators share `build_runner`. Add a `build.yaml` to control ordering (drift first, then freezed, then json_serializable, then riverpod_generator).

---

## Layer 13 — Routing (in-app navigation)

### Recommendation: `go_router` ^17.3.0

Flutter Favorite, verified, updated 29 days ago. Declarative, type-safe with codegen, deep-link ready. Only real alternative is `auto_route`, but `go_router` is Flutter team-sponsored and lower-friction.

---

## Layer 14 — Testing

| Package | Version | Role |
|---|---|---|
| `flutter_test` (SDK) | — | Widget tests. |
| `test` | ^1.25.15 | Pure Dart unit tests. |
| `mocktail` | ^1.0.5 | Mocking — preferred over `mockito` (no codegen needed). |
| `patrol` | ^4.6.1 | Native integration/E2E tests — handles native permission dialogs (critical for testing location flows). |
| `sqlite3` | ^2.7.6 | In-memory SQLite for Drift tests. |
| `drift_dev` | ^2.34.0 | Test-side codegen. |
| `remove_from_coverage` | ^2.0.0 | Strip generated files from coverage reports (already in XFin). |
| `integration_test` (SDK) | — | Baseline integration testing (patrol builds on it). |

**Confidence: HIGH.** This is the same stack XFin already uses; just add `patrol` for permission-dialog automation.

---

## Layer 15 — Lints

### Recommendation: `very_good_analysis` ^10.3.0

VGV, verified, updated 14 days ago. Aligns with Riverpod idioms. Replace `flutter_lints: ^3.0.0` from XFin.

---

## Layer 16 — CI/CD

**GitHub Actions + Codecov** — user-specified.

Standard `subosito/flutter-action@v2` (Windows/macOS/Linux runners), matrix over `channel: [stable]`, Flutter version pinned via `.fvmrc` or `flutter-version-file`. Codecov uploader via `codecov/codecov-action@v5`.

**No package dependency needed.** Configure in `.github/workflows/ci.yml`. Add:
- `flutter analyze` (via very_good_analysis)
- `flutter test --coverage`
- Format check (`dart format --set-exit-if-changed .`)
- Build-runner sanity check (`dart run build_runner build --delete-conflicting-outputs`)

**Skip on CI:** integration tests requiring emulators (run locally or via Maestro Cloud if we need cloud device farm later).

---

## Installation (composite `pubspec.yaml`)

```yaml
name: trailblazer
description: "GPS trip tracker with on-device OSM map-matching."
publish_to: 'none'
version: 0.1.0+1

environment:
  sdk: ^3.5.0
  flutter: ">=3.24.0"

dependencies:
  flutter:
    sdk: flutter
  flutter_localizations:
    sdk: flutter

  # State
  flutter_riverpod: ^3.3.2
  riverpod_annotation: ^3.3.2

  # Routing
  go_router: ^17.3.0

  # Immutability / codegen support
  freezed_annotation: ^3.1.0
  json_annotation: ^4.9.0

  # Database
  drift: ^2.34.0
  sqlite3_flutter_libs: ^0.5.24
  path_provider: ^2.1.5
  path: ^1.9.0

  # Map rendering & tiles
  maplibre_gl: ^0.26.2
  pmtiles: ^2.2.0

  # Location & motion
  flutter_background_geolocation: ^5.3.0
  permission_handler: ^12.0.3

  # Geometry
  geobase: ^1.5.0
  turf: ^0.0.12   # Pin: pre-1.0
  dart_earcut: ^1.2.0
  r_tree: ^3.0.2
  proj4dart: ^3.0.0

  # Bluetooth (BLE only — Classic via platform channel)
  flutter_blue_plus: ^2.3.10

  # UI
  liquid_glass_renderer: 0.2.0-dev.4   # Pin exact — dev release
  liquid_navbar: ^2.0.7

  # Misc
  shared_preferences: ^2.3.5
  intl: ^0.20.2
  cupertino_icons: ^1.0.8
  logging: ^1.3.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  integration_test:
    sdk: flutter

  # Codegen
  build_runner: ^2.5.4
  drift_dev: ^2.34.0
  freezed: ^3.2.5
  json_serializable: ^6.14.0
  riverpod_generator: ^4.0.4
  riverpod_lint: ^3.3.2
  custom_lint: ^0.7.5

  # Lints
  very_good_analysis: ^10.3.0

  # Testing
  test: ^1.25.15
  sqlite3: ^2.7.6
  mocktail: ^1.0.5
  patrol: ^4.6.1
  remove_from_coverage: ^2.0.0

  # Build-time OSM preprocessing (used by tools/*, not shipped)
  geo_route_finder: ^1.0.3    # Audit code before use
  dart_osmpbf: ^0.0.1         # Build-time only

flutter:
  uses-material-design: true
  generate: true
```

---

## What NOT to Use (Consolidated)

| Avoid | Why | Use Instead |
|---|---|---|
| `google_maps_flutter` / `mapbox_maps_flutter` | Cloud dep, cost, no offline vector | `maplibre_gl` |
| `flutter_map` + `vector_map_tiles` | `vector_map_tiles` 22 months stale, no feature-state API | `maplibre_gl` (native feature-state) |
| `mapsforge_flutter` | LGPL, no dynamic per-segment coloring | `maplibre_gl` |
| `background_locator_2` | 3 years stale, broken on modern Android | `flutter_background_geolocation` |
| `flutter_bluetooth_serial` | 4 years stale, Android-only, unmaintained | Native Kotlin platform channel |
| `flutter_blue_plus` **for Classic BT** | Explicitly BLE-only | Platform channel |
| `geodesy` | Unverified publisher, spherical only | `geobase` (Vincenty ellipsoidal) |
| `provider` (for new project) | User migrating away | `flutter_riverpod` |
| `mockito` | Requires codegen | `mocktail` |
| `flutter_lints` | Less strict, fewer Riverpod-aware rules | `very_good_analysis` |
| Valhalla / OSRM / GraphHopper via FFI | 100s of MB native, cross-compile pain | Hand-rolled Dart HMM matcher |
| Cloud map-matching APIs (Mapbox, HERE) | Violate "no cloud / no cost" | On-device HMM |

---

## Version Compatibility Notes

| Package A | Compatible With | Notes |
|---|---|---|
| `maplibre_gl` 0.26.2 | Flutter ≥3.19, Impeller | Confirm min SDK; iOS 12+ / Android 21+. |
| `liquid_glass_renderer` 0.2.0-dev.4 | **Impeller only** | Not web/Windows/Linux — fine for our targets. |
| `liquid_navbar` 2.0.7 | `flutter_riverpod ^3.0.3` | Aligns with our Riverpod 3.3.x choice. |
| `drift` 2.34.0 | `sqlite3_flutter_libs ^0.5.24` | Drop `sqflite` / `drift_sqflite` from XFin. |
| `riverpod_generator` 4.x | `flutter_riverpod` 3.x | Major-version bump matched. |
| `freezed` 3.x | `json_serializable` 6.14+ | Freezed 3 changed union syntax; check migration guide. |
| `flutter_background_geolocation` 5.3 | Requires **Android release license** | One-time cost, ~USD 400–1200 depending on features. Not free for prod Android. |

---

## Confidence Ledger

| Recommendation | Confidence | Basis |
|---|---|---|
| `maplibre_gl` for rendering + feature-state | HIGH | Verified publisher pub.dev + docs confirm PMTiles + feature-state |
| PMTiles for offline tiles | HIGH | Documented MapLibre integration path |
| `flutter_background_geolocation` | HIGH | Verified publisher, 9-day-old release, industry standard |
| `drift` + `sqlite3_flutter_libs` | HIGH | Already proven in XFin, current versions |
| `flutter_riverpod` 3.x + generator | HIGH | Verified publisher, current, standard idiom |
| Hand-rolled HMM map matcher | MEDIUM | No turnkey Dart lib; algorithm well-known; need to implement carefully |
| `route_spatial_index` as MVP fallback | MEDIUM | Explicit "snap GPS to route" support, 15-month-old release |
| `geo_route_finder` for build-time PBF processing | MEDIUM | Unverified publisher, only 32 days old — audit code before shipping |
| `dart_osmpbf` for build-time PBF | LOW-MEDIUM | v0.0.1, 23 months stale; use only as fallback / reference |
| iOS Classic-BT vehicle fingerprint | N/A | **Not possible.** Apple API restriction. Use motion+audio heuristic. |
| Android Classic-BT via platform channel | HIGH | Standard `BluetoothAdapter.bondedDevices` API |
| `liquid_glass_renderer` 0.2.0-dev.4 | MEDIUM | Dev release, known memory quirk in animations |
| Codecov + GitHub Actions | HIGH | Well-trodden path |

---

## Sources

- pub.dev/packages/maplibre_gl (v0.26.2, publisher maplibre.org, verified — checked 2026-07-02)
- pub.dev/packages/pmtiles (v2.2.0)
- pub.dev/packages/flutter_map (v8.3.1) and pub.dev/packages/vector_map_tiles (v8.0.0, 22 months stale)
- pub.dev/packages/maplibre (v0.3.5, community rewrite)
- pub.dev/packages/mapsforge_flutter (v4.0.0)
- pub.dev/packages/flutter_background_geolocation (v5.3.0, transistorsoft.com, verified)
- pub.dev/packages/background_locator_2 (v2.0.6, 3 years stale)
- pub.dev/packages/flutter_activity_recognition (v4.0.0)
- pub.dev/packages/permission_handler (v12.0.3)
- pub.dev/packages/flutter_riverpod (v3.3.2) + riverpod_generator (v4.0.4)
- pub.dev/packages/drift (v2.34.0)
- pub.dev/packages/geobase (v1.5.0), turf (v0.0.12), r_tree (v3.0.2), dart_earcut (v1.2.0), proj4dart (v3.0.0)
- pub.dev/packages/dart_osmpbf (v0.0.1), geo_route_finder (v1.0.3), route_spatial_index (v1.0.3)
- pub.dev/packages/mbtiles (v0.5.0)
- pub.dev/packages/flutter_blue_plus (v2.3.10 — explicitly BLE-only)
- pub.dev/packages/flutter_bluetooth_serial (v0.4.0, 4 years stale)
- pub.dev/packages/go_router (v17.3.0)
- pub.dev/packages/freezed (v3.2.5), json_serializable (v6.14.0)
- pub.dev/packages/very_good_analysis (v10.3.0)
- pub.dev/packages/mocktail (v1.0.5), patrol (v4.6.1)
- pub.dev/packages/liquid_glass_renderer (v0.2.0-dev.4, whynotmake.it, verified) and liquid_navbar (v2.0.7)
- Newson, P. & Krumm, J. (2009). *Hidden Markov Map Matching Through Noise and Sparseness.* ACM SIGSPATIAL. (Reference algorithm for the hand-rolled matcher.)

---

*Stack research for: Trailblazer (Flutter GPS trip-tracker with on-device OSM map-matching)*
*Researched: 2026-07-02*
