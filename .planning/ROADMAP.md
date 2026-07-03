# Roadmap: Trailblazer

## Overview

Trailblazer is a private Flutter app (iOS + Android) that paints the roads you have driven onto an offline OSM map, aggregated across a 5-level admin hierarchy (Land → Bundesland → Landkreis → Gemeinde → Stadtteil/Ortsteil). The road from empty repo to shipped v1 is a strict dependency chain: build the CI + DB + permission foundation, prove the map + Liquid Glass shell renders on real devices, capture trips in the background, build the OSM pipeline on the dev machine, run on-device HMM map-matching against the resulting artifact, wire trips through an inbox into coverage, render driven roads on the map, then layer in region browser + focus-area pill, vehicles + Bluetooth, settings + backup, and finally harden against OEM battery killers and iOS background-task quirks.

Depth: **comprehensive** — 11 phases, driven by the 119 v1 requirements (FND, MAP, UI, OSM, OSMDB, VEH, TRK, INB, MMT, COV, FOC, REN, REG, SET, QUA). Two spike gates (P2 rendering, P7 feature-state) are called out separately in the Phase Gates section — they can block or divert phase execution.

## Phases

**Phase Numbering:**
- Integer phases (1–11): Planned milestone work
- Decimal phases (e.g. 2.1): Urgent insertions if research spikes uncover blockers

- [x] **Phase 1: Scaffolding** — CI, lints, App DB skeleton, routing, error/logging, permission plumbing
- [ ] **Phase 2: Map + Glass Shell** — MapLibre + PMTiles + Liquid Glass chrome (rendering spike gate)
- [ ] **Phase 3: Tracking MVP** — background GPS + motion state machine + manual/auto trip capture
- [ ] **Phase 4: OSM Pipeline** — dev-machine PBF → slim `osm.sqlite` + `germany-base.pmtiles`
- [ ] **Phase 5: OSM DB + Matcher** — OSM DB runtime, HMM engine, matcher isolate, golden corpus
- [ ] **Phase 6: Inbox + Match Wire-Up** — trip inbox, confirm/reject, matching enqueue, coverage cache infra
- [ ] **Phase 7: Coverage Rendering** — driven-ways painted on the map (feature-state fallback gate)
- [ ] **Phase 8: Regions + Focus-Area** — admin region browser, zoom-aware focus pill, coverage aggregation
- [ ] **Phase 9: Vehicles + Bluetooth** — full vehicle CRUD, BT-fingerprint hints, per-vehicle color prefs
- [ ] **Phase 10: Settings + Backup** — encrypted App DB backup/restore, OSM extract updates, diagnostics
- [ ] **Phase 11: Hardening** — patrol E2E, real-device gauntlet, iOS BG behavior, battery regression gate

## Phase Gates

Two research-flagged spike gates can force a fallback or new decimal phase:

### Gate G1 — P2 Rendering Spike (Liquid Glass over MapLibre)
- **Where:** Before P2 commits to the full Liquid Glass aesthetic for on-map overlays (UI-05).
- **Test:** Real iOS + Android device build with `BackdropFilter`/`liquid_glass_renderer` overlaying the MapLibre platform view — verify no blur breakage, no occlusion, no jank in release mode.
- **Pass:** Continue with full Liquid Glass shell for pill + nav + FAB + panels.
- **Fail:** Fall back to `FrostedGlassCard` + gradient tint sampled from map; keep glass to edge panels only. Document decision in PROJECT.md Key Decisions and continue P2 with the fallback.

### Gate G2 — P7 Feature-State Availability (`maplibre_gl` API)
- **Where:** Before P7 commits to `setFeatureState` for driven-way coloring (REN-05).
- **Test:** Confirm `maplibre_gl` ^0.26.2 exposes `setFeatureState` on both platforms with acceptable per-frame cost at 50k features.
- **Pass:** Ship driven-way overlay via `feature-state`.
- **Fail:** Insert Phase 6.1 or 7.1 to build the sharded-GeoJSON-per-5×5-km-tile fallback source; document in PROJECT.md; then continue P7.

Additional research-recommended spikes: HMM parameter tuning + golden corpus recording (P5), iOS BGTaskScheduler empirical wake behavior (P11).

## Phase Details

### Phase 1: Scaffolding
**Goal:** The project foundation — CI, lints, App DB, routing, permissions — is production-quality and blocks nothing downstream.
**Depends on:** Nothing (first phase)
**Requirements:** FND-01, FND-02, FND-03, FND-04, FND-05, FND-06, FND-07, FND-08, FND-09, FND-10, FND-11, QUA-03, QUA-05
**Success Criteria** (what must be TRUE):
  1. `flutter analyze` (very_good_analysis) and `dart format --set-exit-if-changed` both pass in CI on every push and PR.
  2. GitHub Actions runs `flutter test --coverage`, strips generated files, and uploads to Codecov successfully.
  3. iOS unsigned `.ipa` and Android debug `.apk` build green in CI on the main branch.
  4. App DB opens with Drift migration infrastructure intact and SchemaVerifier tests pass for every defined migration step.
  5. Empty app launches on iOS + Android using declared Info.plist purpose strings and Android manifest `foregroundServiceType="location"` without crashing.
**Plans:** 7 plans
  - [x] 01-flutter-project-bootstrap-PLAN.md — flutter create, pubspec, analysis_options, ProviderScope entry point
  - [x] 02-drift-app-db-schema-PLAN.md — full v1 Drift schema (7 tables) + MigrationStrategy + SchemaVerifier tests
  - [x] 03-go-router-shell-PLAN.md — go_router config + splash/onboarding/placeholder-home flow (first-launch flag)
  - [x] 04-error-logging-infra-PLAN.md — AppLogger + FlutterError/PlatformDispatcher hooks + sealed DomainError + Result<T>
  - [x] 05-platform-permissions-manifest-PLAN.md — iOS Info.plist purpose strings + Android manifest permissions + FGS skeleton
  - [x] 06-github-actions-ci-PLAN.md — ci.yml + ios-build.yml + codecov.yml (autonomous: false — Codecov token human-action)
  - [x] 07-readme-and-docs-PLAN.md — README with badges + docs/ARCHITECTURE.md

### Phase 2: Map + Glass Shell
**Goal:** A map screen with Liquid Glass chrome renders fluidly on both platforms; the rendering spike gate (G1) has been resolved.
**Depends on:** Phase 1
**Requirements:** MAP-01, MAP-02, MAP-03, MAP-04, MAP-05, MAP-06, MAP-07, UI-01, UI-02, UI-03, UI-04, UI-05, UI-06, UI-07
**Success Criteria** (what must be TRUE):
  1. User sees a Google-Maps-inspired cartoon vector map that pans, zooms, rotates, and tilts smoothly with standard gestures.
  2. Map works fully offline from a bundled PMTiles archive; base map remains available with airplane mode on.
  3. Blue location dot appears on the map when location permission is granted; camera position (last lat/lng/zoom) persists across app restarts.
  4. Dark mode style switches automatically with system theme via the project-owned style JSON asset.
  5. Liquid Glass shell — focus-area pill placeholder, bottom nav pill, FAB, overlay panels — renders on real iOS + Android without release-mode jank, or the documented fallback (per Gate G1) is active.
**Plans:** TBD (5–8)

### Phase 3: Tracking MVP
**Goal:** The app records trips automatically and manually, in the background, on both platforms, with battery baseline established.
**Depends on:** Phase 1
**Requirements:** TRK-01, TRK-02, TRK-03, TRK-04, TRK-05, TRK-06, TRK-07, TRK-08, TRK-09, TRK-10, TRK-11, QUA-06
**Success Criteria** (what must be TRUE):
  1. User taps the FAB, drives, then taps Stop — a `pending` trip with GPS polyline, speeds (avg + max), distance, duration, and per-fix motion activity type is written to the App DB.
  2. User closes the app, drives more than 60 s in a car — a `pending` auto-trip is recorded via `flutter_background_geolocation` and auto-terminates after 2 minutes of non-automotive dwell.
  3. Live-tracking overlay is visible on the map during any active trip, showing duration and distance in a glass panel.
  4. iOS whenInUse→Always permission ladder + Android `foregroundServiceType="location"` + persistent notification + battery-optimization prompt are all wired; app never assumes Always is granted.
  5. A 60-minute driving battery-drain baseline is measured on a real device and committed to the repo as the regression reference for major changes.
**Plans:** TBD (5–8)

### Phase 4: OSM Pipeline
**Goal:** A repeatable dev-machine Dart CLI produces the slim OSM artifacts the app runtime consumes.
**Depends on:** Phase 1 (structure); independent of Phases 2/3 (dev-machine deliverable)
**Requirements:** OSM-01, OSM-02, OSM-03, OSM-04, OSM-05, OSM-06, OSM-07, OSM-08
**Success Criteria** (what must be TRUE):
  1. Running `dart run tool/osm_pipeline` against a Berlin-bbox PBF produces `osm.sqlite` (with R-Tree over Kfz-way geometries) and `germany-base.pmtiles` end-to-end on the dev machine.
  2. Output artifacts include exactly the specified Kfz + Feldweg/Fußweg `highway=*` set and admin boundaries at OSM levels 2, 4, 6, 8, 9, 10.
  3. The `way_admin` join table is populated for every Kfz way ↔ region pair whose geometries intersect.
  4. A full-Germany run keeps `osm.sqlite` under 200 MB and `germany-base.pmtiles` under 200 MB, with a version stamp (source PBF date + pipeline schema version) in each.
  5. Pipeline accepts an arbitrary `--bbox` flag for dev/testing without processing the full Germany extract.
**Plans:** TBD (5–8)

### Phase 5: OSM DB + Matcher
**Goal:** The HMM matcher turns a confirmed trip into a correct list of driven way intervals — offline, on-device, and CI-verified against a golden corpus.
**Depends on:** Phases 1, 4
**Requirements:** OSMDB-01, OSMDB-02, OSMDB-03, OSMDB-04, OSMDB-05, OSMDB-06, OSMDB-07, MMT-01, MMT-02, MMT-03, MMT-04, MMT-05, MMT-06, MMT-07, MMT-08, MMT-09, MMT-10, QUA-02
**Success Criteria** (what must be TRUE):
  1. On first launch the app downloads the OSM DB over Wi-Fi with resume support; artifacts that fail schema/row-count integrity checks trigger re-download; OSM DB opens in its own Drift isolate with statement cache warmed up.
  2. `findWaysNear(lat, lng, radius)` returns top-N R-Tree candidates in p95 < 30 ms on target devices; extract updates swap in place atomically without corrupting driven-way intervals.
  3. A CI-runnable golden corpus of ≥ 20 recorded trips (autobahn, Kreisel, tunnel, parking, U-turn, city grid, roundabout, one-way) produces the known-correct way-ID sequences; core matcher module has ≥ 90 % line coverage; regression on any golden trip fails CI.
  4. Confirmed-trip matching runs off the UI isolate in a warm long-lived `MatcherIsolate` with adaptive R-Tree radius, Viterbi lookahead ≥ 5, min-speed 15 km/h for high-class ways, and is cancellable by the user.
  5. Matcher writes `driven_way_intervals(way_id, start_m, end_m, direction, trip_id, timestamp)` to the App DB; unmatched points are dropped (never force-snapped); raw GPS is retained 30 days by default for re-matching.
**Plans:** TBD (7–10)

### Phase 6: Inbox + Match Wire-Up
**Goal:** Confirmed trips flow end-to-end from raw GPS into driven-way intervals and invalidate the coverage cache; rejected trips vanish cleanly.
**Depends on:** Phases 3, 5
**Requirements:** INB-01, INB-02, INB-03, INB-04, INB-05, INB-06, INB-07, INB-08, COV-01, COV-05, COV-06
**Success Criteria** (what must be TRUE):
  1. User opens the Trips tab and sees every pending trip with date/time, duration, distance, static map preview, and vehicle-guess badge if a Bluetooth fingerprint matched.
  2. User can keep + assign a vehicle, discard, bulk-confirm-all, or bulk-discard from the inbox; rejected trips delete their raw GPS and never run through matching.
  3. Confirming a trip enqueues it into the matcher; on completion, merged (overlap-collapsed) driven-way intervals are written to the App DB and the `coverage_by_region` cache is invalidated.
  4. Trip History shows confirmed + rejected trips; the user can retroactively change a confirmed trip's vehicle assignment or delete it, and the coverage cache is invalidated in response.
  5. Explicit invalidation triggers (new intervals, trip deleted, vehicle `counts_for_coverage` toggled, OSM extract updated) all mark the affected region rows in `coverage_by_region` as stale.
**Plans:** TBD (5–7)

### Phase 7: Coverage Rendering
**Goal:** Driven roads paint onto the map with correct semantics for full/partial/Kfz-vs-Feldweg coverage; feature-state fallback gate (G2) resolved.
**Depends on:** Phases 2, 6
**Requirements:** REN-01, REN-02, REN-03, REN-04, REN-05, REN-06, COV-02, COV-03
**Success Criteria** (what must be TRUE):
  1. Driven Kfz-ways render in the primary "explored" color (default warm green); driven Feldweg/Fußweg ways render in the distinct secondary color (default dashed blue).
  2. A way flips to "fully explored" only when merged intervals cover ≥ (length − 15 m start buffer − 15 m end buffer); partially-driven ways render with proportional gradient or documented reduced-opacity fallback.
  3. Map maintains ≥ 30 fps on target devices with 50 000 driven segments loaded (stress-tested against faked coverage).
  4. Coverage renders via MapLibre `feature-state` — or the sharded-GeoJSON-per-5×5-km-tile fallback (Gate G2) is active and documented.
  5. User can pick coverage colors from a small preset palette in settings; changes apply live without full map reload.
**Plans:** TBD (5–7)

### Phase 8: Regions + Focus-Area
**Goal:** The user can browse coverage by admin region; the focus-area pill tracks their map view; per-region percentages are accurate and cached.
**Depends on:** Phases 6, 7
**Requirements:** FOC-01, FOC-02, FOC-03, FOC-04, FOC-05, FOC-06, FOC-07, REG-01, REG-02, REG-03, REG-04, REG-05, REG-06, REG-07, COV-04, COV-07, COV-08
**Success Criteria** (what must be TRUE):
  1. On camera idle (debounced 200 ms), the focus-area pill updates within one frame to show "{region name} — {coverage %}" (e.g. "Grebenhain · 26%") for the admin level derived from current zoom; over water it falls back to the parent-level region.
  2. Tapping the pill opens the region detail sheet with a full breadcrumb (Land › Bundesland › Landkreis › Gemeinde › Ortsteil) and lists of driven ways + top trips within the region.
  3. Region browser has per-admin-level tabs; default sort is % descending; alternative sorts (alphabetical, driven km, total km, last-driven) and fuzzy search all work; the list is lazy-loaded for Germany-scale thousands of Ortsteile.
  4. "Jump to on map" from any region zooms the map to the region's bounding box.
  5. Coverage percentages are computed via `Σ driven Kfz-length / Σ total Kfz-length` on a compute isolate (Feldweg/Fußweg excluded from both numerator and denominator); total-km and unique-km stats are visible per vehicle and globally.
**Plans:** TBD (6–9)

### Phase 9: Vehicles + Bluetooth
**Goal:** Full vehicle profiles with Bluetooth-fingerprint hints replace the P3/P6 placeholder default vehicle.
**Depends on:** Phase 6
**Requirements:** VEH-01, VEH-02, VEH-03, VEH-04, VEH-05, VEH-06
**Success Criteria** (what must be TRUE):
  1. First-launch onboarding guides the user through creating their first vehicle (name, model, optional color); they can create, edit, delete, and mark default from Settings.
  2. User can link one or more Bluetooth fingerprints (paired MAC / device name / stable ID) to each vehicle; fingerprints stored at trip start surface as the vehicle-guess badge in the inbox.
  3. Toggling a vehicle's `counts_for_coverage` flag invalidates the coverage cache and re-computes region % correctly (trips with `counts=false` do not contribute).
  4. Each vehicle stores a display color for future per-vehicle map layers (not yet rendered in v1).
  5. Every existing trip can be reassigned to any vehicle; retroactive reassignment triggers coverage-cache invalidation from P6.
**Plans:** TBD (3–5)

### Phase 10: Settings + Backup
**Goal:** The user can back up their data, restore it, update the OSM extract, and inspect permissions + diagnostics.
**Depends on:** Phases 1, 5, 9
**Requirements:** SET-01, SET-02, SET-03, SET-04, SET-05, SET-06, SET-07, SET-08, SET-09
**Success Criteria** (what must be TRUE):
  1. User can export an encrypted App DB backup to a user-picked destination (iCloud Drive on iOS / SAF picker on Android); the OSM DB is excluded from the archive.
  2. User can restore a backup file: the archive is validated, the App DB is swapped in place, and the OSM DB is untouched.
  3. User can check for OSM updates and swap in a new extract; on success the coverage cache invalidates and driven-way intervals remain valid.
  4. Permissions inspector shows live status for Always/whenInUse location, motion activity, Bluetooth, and background app refresh; raw-GPS retention setting persists and honors 0/30/365/forever options.
  5. Battery-diagnostic HUD toggle exposes fix rate, matcher queue depth, and cache-hit rate; About screen lists app version, OSS licenses, and OSM credits.
**Plans:** TBD (5–7)

### Phase 11: Hardening
**Goal:** The app survives real-world stress on real devices; all quality gates green; release-candidate ready.
**Depends on:** All prior phases
**Requirements:** QUA-01, QUA-04, QUA-07
**Success Criteria** (what must be TRUE):
  1. Every feature module (Map, Tracking, Trips/Inbox, Vehicles, Regions, Focus-Area Pill, Settings) has widget tests covering its key screens; all green in CI.
  2. `patrol` E2E suite covers onboarding → first trip recording → inbox confirmation → matching → coverage update → region browser; runs green on both platforms in CI.
  3. Real-device gauntlet passes on iPhone (current + one older), Samsung, and Xiaomi: auto-trips survive OEM battery killers, foreground service remains alive through screen-off drives, and coverage updates after the drive.
  4. iOS `BGTaskScheduler` empirical wake behavior is documented; extract-swap failure recovery and coverage-cache invalidation edge cases have regression tests.
  5. 60-minute battery-drain gate: no regression vs the P3 baseline on the same reference device.
**Plans:** TBD (4–6)

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11 (with 4 executable in parallel with 2/3 as it is a dev-machine deliverable). Decimal phases inserted between integers if the Phase Gates fire.

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Scaffolding | 7/7 | ✓ Complete | 2026-07-03 |
| 2. Map + Glass Shell | 0/TBD | Not started | - |
| 3. Tracking MVP | 0/TBD | Not started | - |
| 4. OSM Pipeline | 0/TBD | Not started | - |
| 5. OSM DB + Matcher | 0/TBD | Not started | - |
| 6. Inbox + Match Wire-Up | 0/TBD | Not started | - |
| 7. Coverage Rendering | 0/TBD | Not started | - |
| 8. Regions + Focus-Area | 0/TBD | Not started | - |
| 9. Vehicles + Bluetooth | 0/TBD | Not started | - |
| 10. Settings + Backup | 0/TBD | Not started | - |
| 11. Hardening | 0/TBD | Not started | - |

## Coverage

**v1 requirements mapped:** 119/119 (100 %) — no orphans.

| Category | Count | Assigned to |
|----------|-------|-------------|
| FND | 11 | P1 |
| MAP | 7 | P2 |
| UI | 7 | P2 |
| OSM | 8 | P4 |
| OSMDB | 7 | P5 |
| VEH | 6 | P9 |
| TRK | 11 | P3 |
| INB | 8 | P6 |
| MMT | 10 | P5 |
| COV | 8 | P6 (COV-01/05/06), P7 (COV-02/03), P8 (COV-04/07/08) |
| FOC | 7 | P8 |
| REN | 6 | P7 |
| REG | 7 | P8 |
| SET | 9 | P10 |
| QUA | 7 | P1 (QUA-03, QUA-05), P3 (QUA-06), P5 (QUA-02), P11 (QUA-01, QUA-04, QUA-07) |

---
*Roadmap created: 2026-07-02*
*Depth: comprehensive (11 phases)*
