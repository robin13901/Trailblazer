---
phase: 10-coverage-recompute-region-totals
verified: 2026-07-17T13:49:02Z
status: human_needed
score: 6/6 must-haves verified (all CODE-COMPLETE; 2 data/device checkpoints deferred)
human_verification:
  - test: "Run germany-latest.osm.pbf through Stage H and commit regenerated assets"
    expected: "assets/admin/region_totals.json.gz produced; L9 count > 0; gzipped size <= 15 MB; verify_bundle_totals_keys exits 0; Landkreis Miltenberg total 0 < x < 6600000 m; Kleinheubach total > 0; both assets committed."
    why_human: "Requires downloading ~4 GB germany-latest.osm.pbf from Geofabrik and running the pipeline (30-90 min). Designed halt in 10-03-PLAN autonomous-safety gate."
  - test: "Tap Regionen neu berechnen on device with 4 existing trips"
    expected: "Confirmation dialog appears. Confirm shows progress. After completion: Bayern (L4), Landkreis Miltenberg (L6), Miltenberg-town (L8), Kleinheubach (L8) appear with correct driven km. Snackbar shows N Regionen aktualisiert."
    why_human: "End-to-end button path requires device with recorded trips. SC1 button confirm + SC6 puck-riding-line confirm both need a physical drive per defer-in-car-verification convention."
---

# Phase 10: Coverage Recompute & Region Totals -- Verification Report

**Phase Goal:** The Regions tab is trustworthy and self-serviceable: driven km per region are correct and re-derivable on demand from already-recorded trips, region-type badges are right, per-region total road length is precomputed offline (zero runtime API calls), and every region the focus pill can name has a matching total-km entry (incl. Ortsteil-level villages).

**Verified:** 2026-07-17T13:49:02Z
**Status:** human_needed
**Re-verification:** No -- initial verification

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Regionen neu berechnen button, confirmation-gated, full rematch+recompute | VERIFIED | recalculate_button.dart line 57-78: AlertDialog; recalculate_coverage_action.dart lines 117-128: rematchAllStoredTrips->recompute; regions_screen.dart line 36: first child |
| 2 | Region-type badge labels correct (L6=Landkreis, L8=Gemeinde/Stadt, L9=Ortsteil, L10=Ortsteil/Stadtteil) | VERIFIED | region_card.dart lines 21-28: corrected switch; coverage_invalidator.dart line 33: kCoverageAdminLevels=[4,6,8,9,10] |
| 3 | Per-region totals from bundled table, zero runtime Overpass | VERIFIED (code-complete; data deferred) | region_totals_lookup.dart wired; coverage_compute_service.dart line 95+173: ensureLoaded+totalFor; region_total_length_service.dart DELETED |
| 4 | Admin bundle contains L9 Ortsteil boundaries | VERIFIED (code-complete; asset deferred) | stage_h_bundle_and_totals.dart emits levels 4/6/8/9/10; current germany_admin.geojson.gz stale (zero L9) |
| 5 | Pill/totals key-set invariant enforced at build time | VERIFIED (code-complete; runs after PBF) | verify_bundle_totals_keys.dart: set equality + exit(1) on mismatch; kfz_parity_test 6/6 passes |
| 6 | Live puck at tip of coverage line; native dot suppressed while recording | VERIFIED (code-complete; device confirm deferred) | live_puck_bridge.dart: ref.listen(liveFixProvider)->addOrUpdate same tick; map_widget.dart lines 188-189: isRecording gate |

**Score:** 6/6 truths verified (all code-complete; 2 deferred checkpoints below)

---

### Required Artifacts

| Artifact | Status | Details |
|----------|--------|---------|
| lib/features/regions/presentation/widgets/recalculate_button.dart | VERIFIED | 174 lines; AlertDialog confirmation; spinner+progress label; German copy |
| lib/features/regions/data/recalculate_coverage_action.dart | VERIFIED | 180 lines; sealed RecalculateProgress states; rematch->recompute; DomainError boundary |
| lib/features/regions/presentation/regions_screen.dart | VERIFIED | RecalculateButton first child in Column (line 36) |
| lib/features/matching/data/trip_match_coordinator.dart | VERIFIED | OnIntervalsLandedCallback seam line 46; _recomputeInFlight guard; _triggerAutoRecompute line 239 |
| lib/features/regions/data/coverage_compute_service.dart | VERIFIED | recomputeForTrip() at line 212; totalsLookup.totalFor() at lines 173+314 |
| lib/features/regions/data/region_totals_lookup.dart | VERIFIED | 131 lines; rootBundle.load->compute() off-isolate; graceful missing-file handling |
| lib/features/map/presentation/providers/live_puck_applier.dart | VERIFIED | Abstract seam + MapLibreLivePuckApplier; circle layer above trail |
| lib/features/map/presentation/widgets/live_puck_bridge.dart | VERIFIED | 136 lines; liveFixProvider+trackingStateProvider listen; style-reload re-add |
| tool/osm_pipeline/lib/output/stage_h_bundle_and_totals.dart | VERIFIED | runStageH(); UNION SQL cross_border+denorm_l4/l6/l8; WKB decode+DP simplify; 15 MB budget gate |
| tool/osm_pipeline/bin/verify_bundle_totals_keys.dart | VERIFIED | 178 lines; set equality; exit 0/1/2; symmetric difference output |
| tool/osm_pipeline/test/filter/kfz_allowlist_parity_test.dart | VERIFIED | 6 tests; 14-tag set equality; service exclusion; all pass |
| lib/features/coverage/data/coverage_invalidator.dart | VERIFIED | kCoverageAdminLevels=[4,6,8,9,10] at line 33 |
| lib/features/regions/presentation/widgets/region_card.dart | VERIFIED | Lines 21-28: corrected levelLabel() switch |
| lib/features/regions/data/region_total_length_service.dart | DELETED | Decision 8; file absent; runtime path removed |
| lib/features/regions/domain/region_tiling.dart | DELETED | Decision 8; file absent |
| assets/admin/region_totals.json.gz | DEFERRED | PBF-gated checkpoint |
| assets/admin/germany_admin.geojson.gz | DEFERRED (L9) | Old bundle present (9.3 MB, zero L9); regeneration gated on PBF |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| recalculate_button.dart | RecalculateCoverageAction.run() | confirmation dialog | WIRED | Line 85: await action.run() after confirmed==true |
| recalculate_coverage_action.dart | rematchAllStoredTrips() | run() phase 1 | WIRED | Line 118: await _matchCoordinator.rematchAllStoredTrips() |
| recalculate_coverage_action.dart | CoverageComputeService.recompute() | run() phase 2 | WIRED | Line 127: await _computeService.recompute() |
| coverage_compute_service.dart recompute() | RegionTotalsLookup | bundled totals lookup | WIRED | Line 95: ensureLoaded(); line 173: totalFor(id)->realTotalLengthM |
| trip_match_coordinator _writeIntervals | recomputeForTrip() | auto-recompute seam | WIRED | Line 231: _triggerAutoRecompute; matching_providers.dart line 131: onIntervalsLanded->recomputeForTrip |
| live_puck_bridge.dart | liveFixProvider | ref.listen->addOrUpdate same tick | WIRED | Lines 82-86: ref.listen(liveFixProvider)->_onFix->applier.addOrUpdate |
| map_widget.dart myLocationEnabled | trackingStateProvider | suppress native dot | WIRED | Lines 188-189: isRecording gate; locationEnabled = isGranted && !isRecording |
| stage_h_bundle_and_totals.dart totals | Kfz-filtered ways (source=kfz) | osm.sqlite UNION SQL | WIRED | UNION cross_border+denorm; WHERE admin_level IN (4,6,8,9,10) |
| polygon bundle osm_ids | totals table keys | verify_bundle_totals_keys.dart | CODE-WIRED | CLI exists and correct; runs after PBF regeneration |
| region_browser_provider.dart | coverage_cache real_total_length_m | StreamProvider on .watch() | WIRED | Line 57: StreamProvider; line 101: realTotalLengthM ?? totalLengthM; no spinner |

---

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| coverage_cache_table.dart | 18,28,30 | Stale doc comment refs to RegionTotalLengthService | Info | Doc comment only; runtime path deleted |
| coverage_cache_dao.dart | 63,83,105 | Stale doc comment refs to RegionTotalLengthService | Info | Doc comment only |
| overpass_client.dart | 126 | Stale doc comment ref to RegionTotalLengthService | Info | Doc comment only |
| overpass_query_builder.dart | 46 | Stale doc comment ref to RegionTotalLengthService | Info | Doc comment only |

No blocker or warning anti-patterns. All residue is doc-comment-only.

---

### Test Suite Confirmation

- flutter analyze: No issues found (ran 2026-07-17T13:49:02Z)
- flutter test: 891/891 tests passed
- dart analyze (tool/osm_pipeline): No issues found
- dart test (tool/osm_pipeline): 257/257 tests passed

---

### Deferred Checkpoints (NOT gaps -- documented design decisions)

#### Checkpoint 1: PBF-Gated Asset Regeneration (SC3 data, SC4, SC5)

What is deferred: Physical regeneration of assets/admin/region_totals.json.gz and the updated assets/admin/germany_admin.geojson.gz (with L9 Ortsteil boundaries) from a Geofabrik Germany PBF.

Why deferred: germany-latest.osm.pbf (~4 GB) is absent from the dev machine. The 10-03-PLAN.md contained an explicit autonomous-safety gate specifying HALT when the PBF is absent. The halt was correctly triggered. Same posture as Phase 4 admin-bundle generation (dev-machine deliverable).

What IS complete: Stage H Dart code is fully wired and tested. Kfz parity test 6/6 passes. Key-set assertion CLI ready. RegionTotalsLookup handles missing file gracefully (returns null; UI shows haversine fallback as denominator -- correct lower bound, no crash). Zero code change needed when the asset arrives.

To unblock (run from tool/osm_pipeline/):



Post-run magnitude checks:
- Landkreis Miltenberg (osm_id 62404): 0 < total < 6,600,000 m
- Kleinheubach (osm_id 393501): total > 0
- L9 feature count > 0 (Linsengericht 5 villages present)
- Gzipped bundle size <= 15 MB
- git add assets/admin/germany_admin.geojson.gz assets/admin/region_totals.json.gz

#### Checkpoint 2: On-Device Visual Confirms (SC1 button end-to-end, SC6 puck sync)

What is deferred:
1. SC1 on-device: Tap Regionen neu berechnen with 4 real trips -> Bayern/Landkreis Miltenberg/Kleinheubach appear with correct driven km. Snackbar shows count.
2. SC6 on-device: During recording, blue circle puck tracks live coverage line tip without lag; native dot suppressed while recording, reappears on stop.

Why deferred: Requires physical device and a test drive. Per MEMORY.md defer-in-car-verification convention, on-device confirms are batched to the next drive session.

What IS complete: All code structurally verified. flutter test 891/891 green including 5 button widget tests, 3 coordinator auto-recompute tests, 7 live_puck_bridge tests, 2 map_widget native-dot-suppression tests.

---

### Gaps Summary

No genuine code gaps found. All six success criteria are code-complete:

SC1 (Recalculate button): RecalculateButton + RecalculateCoverageAction (174+180 lines) wired in regions_screen.dart as first Column child. Calls rematchAllStoredTrips()->recompute(). No trip deletion. Confirmation dialog, sealed progress states, snackbar all implemented.

SC2 (Badge labels): levelLabel() switch corrected. kCoverageAdminLevels aligned to [4,6,8,9,10].

SC3/SC4/SC5 (Offline totals + L9 + key-set invariant): Stage H complete and clean. RegionTotalsLookup wired. Runtime tiler deleted. Parity test passes. Key-set CLI ready. Physical .gz assets pending the PBF-gated human checkpoint -- a planned deferral with a clear path, not a code gap.

SC6 (Live puck): LivePuckBridge + LivePuckApplier + native-dot suppression wired, tested, and mounted in map_screen.dart outside the isMapTab guard. Device confirm deferred.

---

_Verified: 2026-07-17T13:49:02Z_
_Verifier: Claude (gsd-verifier)_
