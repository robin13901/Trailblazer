# Phase 10: Coverage Recompute & Region Totals — Context

**Gathered:** 2026-07-17
**Status:** Ready for planning
**Replaces:** the former Phase 10 "Hardening" (dropped at user request 2026-07-17 — see ROADMAP + PROJECT Key Decisions).

<domain>
## Phase Boundary

Triggered by on-device observation (2026-07-17, production iPhone, 4 recorded trips:
1× Kleinheubach→Miltenberg, 3× within Kleinheubach). The user found the **Regions
tab is wrong and stale** while the map coverage line is perfect. This phase makes the
region browser trustworthy and self-serviceable, and makes per-region totals correct,
fast, and offline.

Five deliverables (all confirmed in-scope, all shipped together — nothing lands
piecemeal per user decision 2026-07-17):

1. **Recalculate button** — a user-triggered "Regionen neu berechnen" action in the
   **Regions tab (top)**, behind a **confirmation dialog** (it's a heavy operation).
   Does a **full re-match + recompute**: re-runs the matcher over all stored trips,
   rebuilds `coverage_cache` driven-km per region, then (re)computes any missing
   per-region real totals. Fixes "driven km frozen / regions missing" without a fresh
   drive and without deleting existing trips.

2. **Region-type badge fix** — the level→label mapping is shifted by one and shows
   wrong German region types. Fix so L4=Bundesland, L6=Landkreis, L8=Gemeinde/Stadt,
   L9=Ortsteil, L10=Ortsteil/Stadtteil.

3. **Offline per-region total road length** — replace the runtime tiled-Overpass total
   with a **dev-machine precomputed, bundled table** keyed by `osm_id`. Zero runtime
   Overpass calls, instant, 100% complete, no per-region spinners ever.

4. **Ortsteil (L9) granularity** — regenerate the bundled admin polygon asset so it
   actually contains the `admin_level=9` Ortsteil boundaries (Linsengericht's villages
   etc.) that OSM has but the current stale bundle is missing.

5. **Live puck sync to the coverage line** — during an active recording the blue location
   puck lags behind the live coverage line and jumps forward late. Draw our own puck from
   the SAME `liveFixSample` feed the line uses so it sits at the tip of the line and
   updates in the same tick. (Added 2026-07-17 from on-device feedback.)

</domain>

<root-cause-findings>
## Root-cause findings (verified 2026-07-17, this session)

### F1 — driven km frozen + coarse regions missing: recompute is never re-triggered
`CoverageComputeService.recompute()` is the ONLY writer of `coverage_cache`
driven-km + region rows. It is invoked from exactly two places:
1. `TripsInboxRepository.confirmTrip()` — i.e. the **"Behalten"/Keep** button on an
   inbox `TripCard`.
2. A one-shot, **version-gated** startup migration (`_runCoverageRecomputeMigrationIfNeeded`
   in `app.dart`, `kCurrentCoverageRecomputeVersion = 1`) — already ran once, never again.

The app is now **manual-only / history-only** (auto-recording + the Inbox/Keep flow
were removed — see `auto-recording-removed-2026-07-09`, `p10-ux-rework-complete-2026-07-13`).
Trips go straight to `matched`/`confirmed`; the `TripCard` Keep button is **not rendered
anywhere** in the current UI. So after the single startup backfill, **nothing ever calls
`recompute()` again.** New drives update matcher intervals + the coverage line (which is
why the map pill's 24.1% is live and correct), but region `driven_length_m` is never
refreshed → the 6.8 km is stuck, and Bayern / Landkreis Miltenberg / Miltenberg-town
rows were never created.

**This is exactly what the recalculate button fixes**, and it's why the button (not a
new auto-trigger) is the right primary deliverable. The button should ALSO be wired so
recompute re-fires whenever new intervals land — see open question OQ1.

### F2 — attribution itself is correct; the data is present
Verified by replicating the point-in-polygon logic against the bundled asset for a
Kleinheubach coordinate (49.7228, 9.1806) and a Miltenberg one (49.7045, 9.2593):
```
Kleinheubach → L4 Bayern(2145268), L6 Landkreis Miltenberg(62404), L8 Kleinheubach(393501)
Miltenberg   → L4 Bayern(2145268), L6 Landkreis Miltenberg(62404), L8 Miltenberg(393538), L10 Miltenberg(9459595)
```
So once recompute runs, Bayern + Landkreis Miltenberg + Miltenberg-town appear. No
attribution bug. `CoverageComputeService.kComputeAdminLevels = [4,6,8,9,10]` is correct;
note `CoverageInvalidator.kCoverageAdminLevels = [4,6,8,10]` is MISSING 9 — align it.

### F3 — badge labels are shifted one level
`region_card.dart levelLabel()` maps: 4→Bundesland, 6→Regierungsbezirk, 8→Landkreis,
9→Gemeindeverband, 10→Gemeinde/Ortsteil. In the German OSM hierarchy this is wrong by
one: **L6 = Landkreis, L8 = Gemeinde/Stadt**. So Kleinheubach (L8) shows "Landkreis"
(user's exact complaint) and Landkreis Miltenberg (L6) would show "Regierungsbezirk".
Confirmed in the bundle: `Landkreis Miltenberg` is L6, `Kleinheubach` and `Miltenberg`
(town) are L8, `Miltenberg` (9459595) is also L10.

Correct mapping (Bavaria/most states — L6 is Landkreis; the rare Regierungsbezirk is L5,
not in scope):
| L | Label |
|---|-------|
| 4 | Bundesland |
| 6 | Landkreis |
| 8 | Gemeinde / Stadt |
| 9 | Ortsteil |
| 10 | Ortsteil / Stadtteil |

### F4 — Kleinheubach has no Ortsteil; Linsengericht does (as L9)
`Kleinheubach` exists ONLY as L8 in both the bundle and OSM (it's L8-terminal — no
child boundaries). So the user's suspicion of "a village-level Kleinheubach separate
from a Landkreis" is a badge bug (F3), not a missing sub-region.

Linsengericht IS subdivided. Live Overpass probe (2026-07-17) of area 3600535929
returned 5 `admin_level=9` boundary relations:
`Lützelhausen(3316284)`, `Altenhaßlau(3316323)`, `Eidengesäß(3316324)`,
`Geislitz(3316325)`, `Großenhausen(3316326)`.

BUT the shipped bundle (`assets/admin/germany_admin.geojson.gz`, committed 2026-07-10)
contains levels **{4:17, 6:400, 8:10836, 10:9284}** and **ZERO L9**. The bundle
generator query (`admin_polygon_downloader.dart kAdminOverpassQuery`) already requests
`admin_level~"^(2|4|6|8|9|10)$"`, and the simplifier tolerance map already includes 9.
So L9 is missing because the shipped asset is **stale** (predates the L9 request, or was
built from an older extract). The fix is **regenerate the bundle** via
`tool/osm_pipeline/bin/fetch_admin_polygons.dart` and verify L9 survives assembly +
simplification, then include L9 in `CoverageInvalidator` (F2). This is overseeable — no
new architecture.

### F5 — live puck lags the coverage line (two independent feeds)
While recording, the live coverage line is drawn by `LiveTrailBridge._onFix` from
`TrackingService.liveFixStream` → `liveFixProvider` — it appends each accepted fix and
updates the polyline in the SAME tick, so it's perfectly live. The blue location puck is
MapLibre's NATIVE location layer (`map_widget.dart`: `myLocationEnabled: isGranted` +
`myLocationRenderMode`), driven by the platform location plugin on its OWN slower cadence
with its own smoothing. Two separate feeds rendering independently → the puck trails the
line and snaps forward late. This is a rendering-source mismatch, not a data problem.

**Fix (clean, low-risk, reuses existing seam):** draw our OWN puck as a MapLibre
symbol/circle layer from the SAME `LiveFixSample` the line consumes, updated in
`LiveTrailBridge._onFix` (or a sibling bridge) so it lands at the newest trail point every
time a segment is drawn; suppress the native dot DURING recording
(`myLocationEnabled:false` / `myLocationRenderMode:none` while `trackingStateProvider` is
active), restore it when idle. `LiveFixSample.heading` is already available for a
directional puck. Model the layer seam on `LiveTrailApplier` / `CoverageOverlayBridge`.
Keep the native puck for the non-recording map (unchanged). See
[[live-nav-heading-and-trail-2026-07-11]] (the liveFixStream seam this builds on).

</root-cause-findings>

<research>
## Efficiency research (empirical, 2026-07-17)

### Overpass free-tier rate limits (live `/api/status`)
- **overpass-api.de = 2 slots per IP.** `RegionTotalLengthService.kRegionCellConcurrency`
  is already 2 — we are ALREADY MAXED on the primary. Raising it → 429 throttling.
  "More concurrent calls to go faster" is NOT available on free public Overpass.
- `maps.mail.ru` mirror advertises no slot cap BUT **504'd / timed out on the heavy
  area-clipped length query** — unreliable for totals.
- Conclusion: on free tier the only lever is **fewer calls**, which the offline decision
  (below) eliminates entirely.

### The current runtime tiler is ~30× too chatty (measured, overpass-api.de)
| Query | Result |
|-------|--------|
| Whole **Landkreis Miltenberg** area-clip `sum(length())`, ONE query | ✅ **17.0 s → 6,596,798 m** |
| One 0.1° area-clipped cell | ✅ ~1.0 s |
| One 0.1° bbox-only cell (no clip) | ✅ 854,417 m in ~1 s |
| Whole **Bayern** (Bundesland) area-clip, ONE query | ❌ OOM / >120 s timeout |

The current `RegionTotalLengthService` tiles **every** region into 0.1° cells
(~30 for a Landkreis, ~1600 for Bayern). But a whole Landkreis answers in ONE 17 s
query. Only **Bundesländer** actually need tiling. The tiler is doing ~30 queries where
1 works, and grinding Bayern through ~1600 cells at concurrency 2 = the "takes hours"
symptom (compounded historically by the HTTP-200-error-body bug, already fixed —
`overpass-http-200-error-bodies`).

### Decision → offline precompute, bundled (user-chosen, "best on all stated priorities")
Compute per-region total Kfz road length for ALL German regions ONCE on the dev machine
from a **Geofabrik Germany `.osm.pbf` extract** using an offline tool (osmium/pyosmium
or a Dart PBF reader). Ship a small bundled table keyed by `osm_id`
(`osm_id → total_length_m`, ~20K rows, est. ~150–300 KB gzipped). Runtime:
- **Zero Overpass calls** for totals.
- **Instant** (table lookup by osm_id — same key `coverage_cache.region_id` already uses).
- **100% complete + correct** at every level incl. Bundesländer (no OOM, no free-tier throttling).
- **No per-region spinner** ever — the pending/spinner UI (`totalPending`, `progressCellsDone`,
  `region_tiling.dart`) can be retired for the bundled path.

This makes `RegionTotalLengthService` + its Overpass length query + the resumable
`real_total_progress_json` accumulator **obsolete** for the shipping path. Keep the
column `coverage_cache.real_total_length_m` but populate it from the bundled table
instead of the network. (Planner: decide whether to delete the service or keep it as a
dev-only fallback.)

### Roll-up insight (the user's "compute nested regions from the big region" idea)
The user's instinct — drive Miltenberg→Gelnhausen crosses Bayern+Hessen, and the smaller
regions are "inside" the big fetch — does NOT apply to the runtime Overpass model,
because the server computes each area-clipped sum independently and transfers NO geometry
to the device (that's what keeps it from OOMing the phone). BUT it DOES apply to the
offline pipeline: a single pass over the PBF can attribute each way to ALL its containing
regions (L4/L6/L8/L9/L10) at once and accumulate every region's total in one sweep —
which is exactly how the offline precompute should be built (one read of Germany, every
region totalled). So the idea is honored, just at dev-time not runtime.

</research>

<invariant>
## Pill/totals consistency invariant (LOCKED — user requirement 2026-07-17)

**Every region the focus pill can name MUST have a total-km entry in the bundled
totals table.** The user's explicit want: hover Kleinheubach → pill says "Gemeinde
Kleinheubach" AND a Kleinheubach total-km row exists; hover each Linsengericht village →
pill names the village AND each village has its own total-km row.

**How it's guaranteed — single source of truth:** the bundled admin-polygon asset
(`AdminRegionLookup`, which the pill resolves against) and the bundled totals table are
BOTH generated from the SAME OSM extract in the SAME pipeline run, keyed by the SAME
`osm_id`, at the SAME level set (4/6/8/9/10). Therefore:
`{regions the pill can resolve} == {regions in the polygon bundle} == {osm_ids in the totals table}`.
The planner MUST NOT let these drift (e.g. don't simplify-drop a polygon that keeps its
totals row, or vice-versa). A build-time assertion that the two asset key-sets are equal
is cheap insurance — add it.

**Intentional nuance (NOT a gap):** two related sets differ by design —
- **Totals table** = ALL regions in the extract (drives the pill denominator + list totals).
- **Regions-tab card list** = only regions with driven coverage > 0 (Phase-8 coverage-gating, unchanged).
So the pill can NAME any region; it shows a `%` only for driven regions (else "—%"),
but the total-km entry exists regardless. `pill-nameable ⊆ totals-table`, guaranteed.

**Consequence for Ortsteil (L9):** the pill can only show Linsengericht's villages once
the bundle is regenerated WITH L9 (F4) — today it has zero L9 so the pill cannot resolve
a village there at all. The same regeneration that adds the L9 polygons also creates
their totals rows, so pill-visibility and totals-availability land together atomically.

</invariant>

<decisions>
## Locked decisions (user, 2026-07-17)

1. **Totals source = offline precompute, bundled table.** No runtime Overpass for totals.
   (User: chose this explicitly over adaptive-runtime and hybrid.)
2. **Everything ships together in this phase** — recalculate button, badge fix, offline
   totals, Ortsteil L9. Nothing lands on-device today / piecemeal.
3. **This phase REPLACES the former Phase 10 "Hardening"** — user dropped Hardening
   ("i do not like it anyways"). This becomes Phase 10. See ROADMAP + orphaned-reqs note.
4. **Recalculate button:** Regions-tab top, **confirmation dialog required**, does
   **full re-match + recompute**.
5. **Existing trips must NOT be deleted** — the whole point is to recalculate over already-
   recorded trips.
6. **Auto-recompute + button fallback (OQ1 RESOLVED).** Recompute ALSO fires automatically
   when a new trip's intervals land — the manual button is a fallback, not the only path.
   **Auto = recompute only** (`CoverageComputeService.recompute()` rebuilds region rows from
   existing intervals — bounded, cache-first, cheap), NOT a full re-match. The **button**
   remains the heavy `rematchAllStoredTrips()` → `recompute()` → populate totals. Clean auto
   seam: `TripMatchCoordinator` after `transitionToMatched` / `_writeIntervals`.
   **PLUS (user add-on 2026-07-17):** investigate matcher performance thoroughly this phase —
   if the matcher/recompute path can be optimized (e.g. incremental per-trip recompute touching
   only affected regions instead of deleteAll+upsert-all, matcher isolate warm-reuse, R-Tree
   rebuild cost), DO it in this phase. See OQ1-PERF in research notes.
7. **Offline tool = pyosmium / osmium (OQ2 RESOLVED).** Build the bundled totals table (and,
   per specifics, the regenerated admin-polygon bundle) from the Geofabrik Germany `.osm.pbf`
   via osmium/pyosmium (mature, fast, C-backed). Accept the Python-env dependency on the dev
   machine. Output shape: `osm_id → total_length_m`.
8. **Delete `RegionTotalLengthService` fully (OQ4 RESOLVED).** Remove the runtime Overpass
   totals service + 0.1° tiling + `real_total_progress_json` accumulator + per-region spinner
   UI (`totalPending`, `progressCellsDone`, `region_tiling.dart`, "N/M Kacheln" progress). The
   bundled table is the ONLY totals path. A region shows its total-km, or nothing before the
   first bundle load — **no loading/spinner state at all**.
9. **Formally de-scope QUA-01/04/07 (OQ5 RESOLVED).** Mark QUA-01 (widget-test coverage),
   QUA-04 (patrol E2E), QUA-07 (battery regression gate) as **de-scoped** in REQUIREMENTS.md
   with a note tying them to the dropped Hardening phase — clean removal, not silent loss.
   Coverage total stays honest (106 → reflect the de-scope in the mapping table).

</decisions>

<specifics>
## Specific implementation notes for the planner

- **Recalculate button plumbing:** the pieces already exist —
  `TripMatchCoordinator.rematchAllStoredTrips()` (re-runs matcher over every stored trip)
  and `CoverageComputeService.recompute()` (rebuilds region rows via deleteAll+upsert).
  The button = `rematchAllStoredTrips()` → `recompute()` → populate real totals from the
  bundled table. Wrap in a progress affordance (it can take a while for many trips) and
  the confirmation dialog. Reuse the `DataManagementSection` confirm-dialog pattern.
- **Badge fix** is a 5-line `switch` change in `region_card.dart levelLabel()` +
  matching test. Also fix `CoverageInvalidator.kCoverageAdminLevels` to include 9 (F2).
- **Bundle regeneration** uses the existing dev CLI
  `tool/osm_pipeline/bin/fetch_admin_polygons.dart` (Overpass path) — but note that path
  ALSO hits the OOM-prone whole-DE Overpass query. Prefer regenerating admin polygons
  from the Geofabrik PBF too, so the SAME offline extract feeds both the polygon bundle
  and the totals table (one source of truth, one download). Verify L9 count > 0 after.
- **Offline totals table** — new bundled asset (e.g. `assets/admin/region_totals.bin` or
  `.json.gz`), loaded once (mirror `AdminRegionLookup` load posture — off main isolate),
  read by `coverage_cache` population. Keep it keyed by `osm_id` (string) to match
  `coverage_cache.region_id`.
- **Kfz allowlist parity:** the offline total MUST use the SAME highway-class allowlist
  the matcher/coverage uses (see `OverpassResponseParser` Kfz allowlist + REQUIREMENTS
  "only Kfz-classified ways count"), or driven/total will be apples-to-oranges. This is
  the single most important correctness detail of the offline pipeline.
- **German UI** throughout (established convention).
- **Schema:** likely no new column (reuse `real_total_length_m`); if a "totals source
  version" stamp is wanted, that's a schema bump → remember to bump
  `drift_backup_service.dart kCurrentSchemaVersion` in lockstep (repeated past trap).

</specifics>

<deferred>
## Resolved open questions + remaining planning constraints

**RESOLVED (now in Locked decisions 6–9):**
- ~~OQ1 auto re-trigger~~ → **decision 6**: auto (recompute-only) + button fallback; plus a
  matcher-performance investigation mandate (OQ1-PERF below).
- ~~OQ2 offline tool~~ → **decision 7**: osmium/pyosmium.
- ~~OQ4 retire service~~ → **decision 8**: delete `RegionTotalLengthService` + spinner fully.
- ~~OQ5 orphaned QUA~~ → **decision 9**: formally de-scope QUA-01/04/07 in REQUIREMENTS.md.

**OQ1-PERF (new investigation mandate, user 2026-07-17):** the current recompute is
deleteAll + upsert-all region rows, and the button re-matches every stored trip serially.
Research whether the hot paths can be optimized *in this phase*:
- **Incremental recompute** — after one new trip matches, recompute only the regions that
  trip's intervals touch, instead of rebuilding the whole `coverage_cache` (the auto path
  fires often, so this is where it pays off).
- **Matcher throughput on the button path** — warm/long-lived `MatcherIsolate` reuse across
  the N trips (avoid per-trip isolate spin-up + R-Tree rebuild where bboxes overlap), and
  whether cached Overpass ways can be shared across trips in the same bbox.
- Land whatever is a clear win; document anything deferred. Don't gold-plate — the goal is
  "recompute after a drive is not annoying" and "the button finishes in reasonable time".

**OQ3 — bundle size budget (still a hard planning constraint, not a decision):** current
admin bundle is under the 15 MB gzipped budget with zero L9. Adding all L9 Ortsteile + the
totals table MUST stay within budget — verify after regeneration; tighten DP tolerance if
needed (`AdminPolygonSimplifier.withStricterL8`). Add the build-time key-set equality
assertion (polygon bundle ⇔ totals table) from the invariant section.

</deferred>

## SC deviations / notes to reconcile
- The former Phase 10 SC (patrol E2E, real-device gauntlet, iOS BG, battery gate) are
  DROPPED with Hardening. QUA-01/04/07 → formally de-scoped in REQUIREMENTS.md (decision 9).

---

*Phase: 10-coverage-recompute-region-totals*
*Context gathered: 2026-07-17*
*Supersedes: former Phase 10 "Hardening"*
