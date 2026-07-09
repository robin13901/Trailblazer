# Roadmap: Trailblazer

## Overview

Trailblazer is a private Flutter app (iOS + Android) that paints the roads you have driven onto an offline OSM map, aggregated across a 5-level admin hierarchy (Land → Bundesland → Landkreis → Gemeinde → Stadtteil/Ortsteil). The road from empty repo to shipped v1 is a strict dependency chain: build the CI + DB + permission foundation, prove the map + Liquid Glass shell renders on real devices, capture trips in the background, build the OSM pipeline on the dev machine, run on-device HMM map-matching against the resulting artifact, wire trips through an inbox into coverage, render driven roads on the map, then layer in region browser + focus-area pill, vehicles + Bluetooth, settings + backup, and finally harden against OEM battery killers and iOS background-task quirks.

Depth: **comprehensive** — 11 phases, driven by the 112 v1 requirements (FND, MAP, UI, OSM, VEH, TRK, INB, MMT, COV, FOC, REN, REG, SET, QUA). Two spike gates (P2 rendering, P7 feature-state) are called out separately in the Phase Gates section — they can block or divert phase execution. *(Requirement total dropped 119 → 112 in the 2026-07-08 Phase-4 rescope: OSMDB-01..OSMDB-07 deleted; the bundled-osm.sqlite runtime was abandoned. See PROJECT.md Key Decisions.)*

## Phases

**Phase Numbering:**
- Integer phases (1–11): Planned milestone work
- Decimal phases (e.g. 2.1): Urgent insertions if research spikes uncover blockers

- [x] **Phase 1: Scaffolding** — CI, lints, App DB skeleton, routing, error/logging, permission plumbing
- [x] **Phase 2: Map + Glass Shell** — MapLibre + PMTiles + Liquid Glass chrome (rendering spike gate)
- [x] **Phase 3: Tracking MVP** — background GPS + motion state machine + manual/auto trip capture
- [x] **Phase 3.1: Tracking Fixes** — gap-closure phase inserted 2026-07-06 after failed in-car drive verification; closed 2026-07-08 with user-attested drive PASS (H1 facade.start(), H2 camera follow, H5 battery-opt gate). Phase 5 unblocked.
- [x] **Phase 4: Map & Matching Data Sources** — MapTiler-hosted vector tiles + on-demand Overpass road data (cached + retry-safe) + bundled admin polygons (rescoped 2026-07-08 from the original bundled-`osm.sqlite` pipeline; drive-verified 2026-07-09 via 96 km / 1h 40 drive — see `04-VERIFICATION.md`)
- [x] **Phase 5: Overpass-Backed Matcher + Golden Corpus** — HMM matcher consumes `WayCandidateSource` (Phase 4), matches confirmed trip polylines to driven way intervals, CI-verified against a golden corpus
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
**Completed:** 2026-07-04
**Success Criteria** (what must be TRUE):
  1. User sees a Google-Maps-inspired cartoon vector map that pans, zooms, rotates, and tilts smoothly with standard gestures.
  2. Map works fully offline from a bundled PMTiles archive; base map remains available with airplane mode on.
  3. Blue location dot appears on the map when location permission is granted; camera position (last lat/lng/zoom) persists across app restarts.
  4. Dark mode style switches automatically with system theme via the project-owned style JSON asset.
  5. Liquid Glass shell — focus-area pill placeholder, bottom nav pill, FAB, overlay panels — renders on real iOS + Android without release-mode jank, or the documented fallback (per Gate G1) is active.
**Plans:** 7 plans
  - [x] 02-01-g1-rendering-spike-PLAN.md — G1 spike: LiquidGlass over MapLibre on real devices; set platformSupportsBlurOverMap
  - [x] 02-02-pmtiles-base-map-PLAN.md — MapLibre + bundled PMTiles + light/dark style JSONs + MapWidget
  - [x] 02-03-location-and-camera-PLAN.md — permission_handler, blue dot, CameraState/FollowMode (Phase-3-ready), recenter
  - [x] 02-04-dark-mode-style-switch-PLAN.md — brightness observer + setStyle crossfade + ThemeMode.system
  - [x] 02-05-liquid-glass-shell-PLAN.md — GlassPill/Circle branching on G1 flag; focus pill, FAB, settings button, bottom nav
  - [x] 02-06-router-shell-refactor-PLAN.md — StatefulShellRoute.indexedStack with 3 tabs + /settings
  - [x] 02-07-phase-verification-PLAN.md — real-device smoke test + SC1-SC5 verification + STATE/ROADMAP close-out

### Phase 3: Tracking MVP
**Goal:** The app records trips automatically and manually, in the background, on both platforms, with battery baseline established.
**Depends on:** Phase 1
**Requirements:** TRK-01, TRK-02, TRK-03, TRK-04, TRK-05, TRK-06, TRK-07, TRK-08, TRK-09, TRK-10, TRK-11, QUA-06
**Completed:** 2026-07-05 (code-complete) → SC1..SC4 drive-verified 2026-07-08 via Phase 3.1 (user-attested — see `.planning/phases/03-1-tracking-fixes/03-1-DRIVE-VERIFICATION-2026-07-08.md`). SC5 (QUA-06 60-min battery baseline) verified 2026-07-09 via user-attested 96 km / 1h 40 drive (Plan 04-19 close-out — no battery anomalies observed).
**Success Criteria** (what must be TRUE):
  1. User taps the FAB, drives, then taps Stop — a `pending` trip with GPS polyline, speeds (avg + max), distance, duration, and per-fix motion activity type is written to the App DB.
  2. User closes the app, drives more than 60 s in a car — a `pending` auto-trip is recorded via `flutter_background_geolocation` and auto-terminates after 2 minutes of non-automotive dwell.
  3. Live-tracking overlay is visible on the map during any active trip, showing duration and distance in a glass panel.
  4. iOS whenInUse→Always permission ladder + Android `foregroundServiceType="location"` + persistent notification + battery-optimization prompt are all wired; app never assumes Always is granted.
  5. A 60-minute driving battery-drain baseline is measured on a real device and committed to the repo as the regression reference for major changes.
**Plans:** 7 plans
  - [x] 03-01-drift-v2-trip-repository-PLAN.md — Drift v2 migration + TripsDao/Repository
  - [x] 03-02-trip-fix-ingestor-PLAN.md — pure-Dart ingestor + Haversine + batcher
  - [x] 03-03-fgb-install-facade-PLAN.md — FGB install + facade seam
  - [x] 03-04-tracking-service-notifier-PLAN.md — TrackingService + Riverpod notifier
  - [x] 03-05-permission-ladder-banner-PLAN.md — permission ladder + yellow banner
  - [x] 03-06-fab-morph-live-panel-PLAN.md — FAB morph + live panel + 30 s notification
  - [x] 03-07-phase-verification-battery-baseline-PLAN.md — battery baseline CLI + phase close-out (in-car drive deferred)

### Phase 3.1: Tracking Fixes
**Goal:** The app records trips end-to-end in the real world — manual and auto trips both capture GPS fixes, live stats stream to the UI, the map camera follows the driver, the persistent notification shows, and OEM battery killers don't silently kill the foreground service. Verified by a passing in-car drive.
**Depends on:** Phase 3
**Blocks:** *(RESOLVED 2026-07-08 — Phase 5 unblocked via user-attested drive verification)*
**Requirements:** *(gap closure — no new requirement IDs; makes TRK-01..11 verifiable in the real world)*
**Trigger:** Failed in-car drive verification 2026-07-06 on Samsung Galaxy S24 (Android 14). Full report: `.planning/phases/03-tracking-mvp/03-DRIVE-VERIFICATION-2026-07-06.md`.
**Completed:** 2026-07-08 (user-attested drive PASS — see `.planning/phases/03-1-tracking-fixes/03-1-DRIVE-VERIFICATION-2026-07-08.md`)
**Success Criteria** (what must be TRUE):
  1. In-app debug HUD (dev-only, reachable from Settings) shows live: FGB ready state, last-fix timestamp + lat/lng/speed/accuracy, last activity type + timestamp, ingestor accept/reject counts + last reject reason, persistent-notification state, POST_NOTIFICATIONS + battery-optimization grant status.
  2. Manual trip: tapping the FAB starts fix intake within 3 s; the LiveTrackingPanel's distance and speed fields update at least once every 5 s during the drive; the polyline persists to the App DB on stop with non-zero distance.
  3. Auto trip: driving in a car with the app backgrounded (screen locked) produces a `pending` auto-trip within 60 s of `in_vehicle` motion; auto-terminates after 2 min of non-automotive dwell as designed.
  4. Persistent notification is visible in the notification bar during any active trip on both platforms (Android channel + POST_NOTIFICATIONS grant verified via HUD); notification text updates at the 30 s cadence.
  5. Map camera follows the current location (`MyLocationTrackingMode.trackingCompass`) while a trip is active; releases to free-pan on trip stop or user pan gesture.
  6. **In-car drive verification passes:** re-drive the failed 2026-07-06 route (or equivalent), observe all four fail modes fixed via the HUD, and record a passing verification report at `.planning/phases/03-1-tracking-fixes/03-1-DRIVE-VERIFICATION-<date>.md`.
**Plans:** 5 plans
  - [x] 03-1-01-debug-hud-diagnostics-PLAN.md — diagnostics DTO + HUD + counters
  - [x] 03-1-02-fgb-start-and-battery-opt-PLAN.md — H1 (`_facade.start()` at three sites) + H5 (battery-opt grant in TrackingCapability) fix
  - [x] 03-1-03-map-camera-follow-PLAN.md — H2 fix (TrackingCameraSync + exhaustive FollowMode mapping)
  - [x] 03-1-04-regression-tests-motion-filter-and-cadence-PLAN.md — H3 + H4 regression tripwires (both invariants REFUTED per research)
  - [x] 03-1-05-in-car-verification-and-close-out-PLAN.md — drive verification + close-out (user-attested PASS 2026-07-08)

### Phase 4: Map & Matching Data Sources
**Goal:** The app renders live MapTiler tiles, fetches on-demand Overpass road data per trip (cached + retry-safe when offline), and answers admin-region name lookups from a bundled polygon asset.
**Depends on:** Phase 1 (foundation), Phase 3 (needs the trip lifecycle so trip completion can trigger the Overpass fetch and the new `pendingRoadData` state)
**Rescoped:** 2026-07-08 (from original bundled-`osm.sqlite` pipeline — see PROJECT.md Key Decisions)
**Requirements:** OSM-01, OSM-02, OSM-03, OSM-04, OSM-05, OSM-06, OSM-07, OSM-08
**Completed:** 2026-07-08 (code-complete) → drive-verified 2026-07-09 via 96 km / 1h 40 drive (Plan 04-19 close-out — see `.planning/phases/04-osm-pipeline/04-VERIFICATION.md` + `04-18-SUMMARY.md`). Item 4 (Deutschland labels) deferred to Phase 11 as MapTiler free-tier limitation.
**Success Criteria** (what must be TRUE):
  1. Map screen renders MapTiler tiles seamlessly at all zoom levels; attribution visible in Settings > About; light + dark styles both work.
  2. Loopback `TileServer` and its deps are gone; `flutter analyze` clean.
  3. Trip finished online → fully-cached Overpass response within 30 s; trip finished offline → `pendingRoadData` state, picked up on reconnect.
  4. `WayCandidateSource` interface has two working impls; test suite uses the fixture impl; runtime uses Overpass impl.
  5. Admin polygons L2..L10 bundled at `assets/admin/germany_admin.geojson.gz` (<15 MB), loaded at first-use, `regionAt(lat, lng, level)` correct for 5 known coordinates.
**Plans:** 8 plans, 4 waves + one polish plan (rescoped 2026-07-08 — original 04-01..04-10 + 04-10-1-* archived on disk under this phase folder as SUMMARY docs only)
  - [x] 04-11-maptiler-provider-and-key-plumbing-PLAN.md — MapTiler API key + TileProviderConfig + attribution + style-ID spike
  - [x] 04-12-style-rewrite-and-tileserver-teardown-PLAN.md — swap MapLibre to MapTiler URL + delete TileServer + real-device smoke checkpoint
  - [x] 04-13-overpass-client-and-payload-probe-PLAN.md — OverpassClient + WayCandidate model + Berlin→Munich payload probe
  - [x] 04-14-drift-migration-v3-and-daos-PLAN.md — App DB v3 + overpass_way_cache + pending_road_fetches + DAOs
  - [x] 04-15-way-candidate-source-and-trip-flow-PLAN.md — WayCandidateSource interface + Overpass impl + trip coordinator + offline checkpoint
  - [x] 04-16-bundled-admin-polygons-and-lookup-PLAN.md — dev CLI + assets/admin/germany_admin.geojson.gz + AdminRegionLookup + Settings refresh
  - [x] 04-16-1-ux-polish-PLAN.md — 5 user-observed UI fixes (FGB toast, off-screen attribution, default zoom 15, German localization, top-chrome margin)
  - [x] 04-17-rescope-close-out-PLAN.md — docs rewrite (REQUIREMENTS/ROADMAP/PROJECT/STATE) + VERIFICATION.md

### Phase 5: Overpass-Backed Matcher + Golden Corpus
**Goal:** The HMM matcher consumes `WayCandidateSource` (from Phase 4) to match a confirmed trip's polyline to a correct list of driven way intervals, and a CI-runnable golden corpus verifies it.
**Depends on:** Phase 4
**Completed:** 2026-07-08 (code-complete; 8/8 plans landed; verifier PASS 5/5 must-haves; 383/383 tests green; matcher-domain coverage 93.8 % on QUA-02 gate; 1 synthetic golden fixture shipped + 4 real-drive fixtures deferred to drive-batch follow-up; growing to ≥ 20 total is Phase 6's inherited obligation)
**Requirements:** MMT-01, MMT-02, MMT-03, MMT-04, MMT-05, MMT-06, MMT-07, MMT-08, MMT-09, MMT-10, QUA-02. *(MMT-09 marked Partial in REQUIREMENTS.md — harness + CI gate + 1 seed shipped; 19 fixtures to grow the corpus to ≥ 20 are Phase 6's obligation.)*
**Success Criteria** (what must be TRUE):
  1. The main isolate fetches `WayCandidateSource.fetchWaysInBbox` (cache-first path from 04-15 warm before matching starts); the resulting `List<WayCandidate>` is shipped to the matcher isolate as part of a `MatchJob`; offline `pendingRoadData` trips block matching until the fetch queue drains.
  2. Candidate lookup per GPS point is served by the matcher's own in-memory R-Tree built from the ways returned by the source for the trip's bbox (adaptive radius: 25 m base, expands with HDOP; top-5 candidates).
  3. A CI-runnable golden corpus test harness is code-complete at Phase 5 close-out with **1 synthetic seed fixture shipped and 4 real-drive fixtures deferred to a documented drive-batch follow-up** (bringing the corpus to ≥ 5 seeds); growing to ≥ 20 by Phase 6 close-out (scenario coverage across autobahn, Kreisel, tunnel, parking, U-turn, city grid, roundabout, one-way); core matcher module has ≥ 90 % line coverage; regression on any golden trip fails CI. `tool/osm_pipeline/` (retained as dev-only per OSM-07) is the fixture generator for golden PBFs. **Phase 5 code-complete does NOT block on the 4 real drives** — they land as an out-of-band drive-batch alongside the pending Phase 4 combined close-out drive (2026-07-08 overnight-execution adjustment). **Phase 6 inherits the corpus-expansion obligation** to reach ≥ 20 total (record + fixture-ize the remaining trips alongside inbox integration).
  4. Confirmed-trip matching runs off the UI isolate in a warm long-lived `MatcherIsolate` with adaptive R-Tree radius, Viterbi lookahead ≥ 5, min-speed 15 km/h for high-class ways, and is cancellable by the user.
  5. Matcher writes `driven_way_intervals(way_id, start_m, end_m, direction, trip_id, timestamp)` to the App DB; unmatched points are dropped (never force-snapped); raw GPS is retained 30 days by default for re-matching.
**Plans:** 8 plans in 5 waves
Plans:
- [x] 05-01-driven-way-intervals-dao-and-retention-PLAN.md — DrivenWayIntervalsDao + TripsDao 30-day retention sweep (Wave 1)
- [x] 05-02-hmm-probability-and-geometry-PLAN.md — emission/transition/adaptive-radius + perpendicular-distance primitives (Wave 1)
- [x] 05-03-way-segment-index-PLAN.md — WaySegment value type + rbush-backed R-Tree with top-K (Wave 1)
- [x] 05-04-viterbi-decoder-PLAN.md — pure-Dart Viterbi decoder with beam=5, gap/speed/oneway guards (Wave 2)
- [x] 05-05-hmm-matcher-orchestrator-PLAN.md — HmmMatcher + interval merging + DrivenWayIntervalDraft (Wave 3)
- [x] 05-06-matcher-isolate-PLAN.md — long-lived MatcherIsolate + MatchJob protocol + cancel (Wave 4)
- [x] 05-07-trip-match-coordinator-PLAN.md — pending→matched wiring + app-resume processPending + retention (Wave 5)
- [x] 05-08-golden-corpus-and-coverage-gate-PLAN.md — corpus scaffolding + first 5 seed fixtures + CI ≥90% gate (Wave 4, checkpoint)

**Follow-ups (post-close-out):**
- **Phase 5.1 seed (2026-07-09):** road-snap heading hybrid (Layer B of the hybrid heading concept — Layer A `MyLocationTrackingMode.trackingGps` shipped in Plan 04-19 Task 2). Matcher-driven bearing alignment during recording: whenever the live matcher is confident about the current way, override GPS heading with the way's local bearing. Requires a live-matcher variant (Phase 5's matcher runs post-stop only). To be authored when Phase 7 needs live-matcher output for coverage rendering, or sooner if the user requests. Not blocking Phase 6.
- **Corpus growth to ≥ 20 fixtures** is inherited by Phase 6 (per SC3 amendment 2026-07-08). The 4 real-drive fixtures that take the corpus from 1 → 5 seeds can be recorded during any Phase-6 drive; they no longer need a separate drive-batch follow-up now that Phase 4 is drive-verified.

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
**Plans:** 6 plans in 3 waves (planned 2026-07-09; see `phases/06-inbox-match-wire-up/06-CONTEXT.md` for 3 explicit deviations from SC above — no bulk ops, no rejected in History, no counts_for_coverage toggle)

Plans:
- [ ] 06-01-coverage-cache-and-invalidator.md — Wave 1: CoverageCacheDao + CoverageInvalidator (3 triggers) + pure-Dart interval union (COV-01, COV-05, COV-06)
- [ ] 06-02-reverse-geocoding-and-trip-metadata.md — Wave 1: TripPlaceLookup + TripsInboxDao (watch inbox/history/in-flight, transitionToConfirmed) + TripsInboxRepository with correct delete order (INB-03, INB-04, INB-06, INB-08, Q10)
- [ ] 06-03-trip-thumbnail-renderer.md — Wave 1: ThumbnailRenderer (MapLibre takeSnapshot + CustomPainter fallback) + disk cache + TripThumbnail widget (INB-02)
- [ ] 06-04-matcher-queue-indicator.md — Wave 1: inbox/history/inFlightCount StreamProviders + MatchingQueuePill (Liquid Glass) (INB-06 support)
- [ ] 06-05-inbox-history-ui.md — Wave 2: TripsScreen sub-tabs + TripCard/HistoryRow/DiscardDialog + TripDetailScreen + /trips/:id route + trip_overlay_layers (INB-01..08 UI, human-verify checkpoint)
- [ ] 06-06-golden-corpus-expansion.md — Wave 3: GoldenFixtureExporter + kDebugMode export FAB + workflow README (Phase 5 inheritance)

### Phase 7: Coverage Rendering
**Goal:** Driven roads paint onto the map with correct semantics for full/partial/Kfz-vs-Feldweg coverage; feature-state fallback gate (G2) resolved.
**Depends on:** Phases 2, 6
**Requirements:** REN-01, REN-02, REN-03, REN-04, REN-05, REN-06, COV-02, COV-03
**Success Criteria** (what must be TRUE):
  1. Driven Kfz-ways render in the primary "explored" color (default warm green); Feldweg/Fußweg ways render as static base geometry from the pmtiles roads layer in a distinct secondary color (default: dashed blue). Per-way driven-state coloring applies to Kfz ways only (see REN-02 note dated 2026-07-07).
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
| 2. Map + Glass Shell | 7/7 | ✓ Complete | 2026-07-04 |
| 3. Tracking MVP | 7/7 | ✓ Complete (SC1..SC4 drive-verified via Phase 3.1 2026-07-08; SC5 QUA-06 verified via user-attested 96 km drive 2026-07-09 — Plan 04-19) | 2026-07-05 code-complete / 2026-07-09 fully drive-verified |
| 3.1. Tracking Fixes | 5/5 | ✓ Complete | 2026-07-08 |
| 4. Map & Matching Data Sources | 8/8 | ✓ Complete (code-complete 2026-07-08; drive-verified 2026-07-09 via 96 km / 1h 40 drive — see `04-VERIFICATION.md` + `04-18-SUMMARY.md`) — 8 rescoped plans (04-11..04-17 + 04-16-1); original 04-01..04-10 + 04-10-1-* archived on disk | 2026-07-09 |
| 5. Overpass-Backed Matcher + Golden Corpus | 8/8 | ✓ Complete (code-complete; matcher-domain coverage 93.8 %; MMT-09 partial — 1 seed + CI gate shipped, 19 fixtures inherited by Phase 6) | 2026-07-08 |
| 6. Inbox + Match Wire-Up | 0/TBD | Not started | - |
| 7. Coverage Rendering | 0/TBD | Not started | - |
| 8. Regions + Focus-Area | 0/TBD | Not started | - |
| 9. Vehicles + Bluetooth | 0/TBD | Not started | - |
| 10. Settings + Backup | 0/TBD | Not started | - |
| 11. Hardening | 0/TBD | Not started | - |

## Coverage

**v1 requirements mapped:** 112/112 (100 %) — no orphans. *(Was 119 pre-2026-07-08; OSMDB-01..OSMDB-07 deleted as part of the Phase-4 rescope — see PROJECT.md Key Decisions.)*

| Category | Count | Assigned to |
|----------|-------|-------------|
| FND | 11 | P1 |
| MAP | 7 | P2 |
| UI | 7 | P2 |
| OSM | 8 | P4 |
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
