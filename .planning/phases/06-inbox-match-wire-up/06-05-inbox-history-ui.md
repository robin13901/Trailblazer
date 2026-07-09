---
plan: 06-05
phase: 6
wave: 2
depends_on: [06-01, 06-02, 06-03, 06-04]
type: execute
autonomous: false
files_owned:
  - lib/features/trips/presentation/trips_screen.dart
  - lib/features/trips/presentation/trip_detail_screen.dart
  - lib/features/trips/presentation/widgets/trip_card.dart
  - lib/features/trips/presentation/widgets/history_row.dart
  - lib/features/trips/presentation/widgets/discard_confirmation_dialog.dart
  - lib/features/trips/presentation/widgets/inbox_empty_state.dart
  - lib/features/trips/presentation/widgets/history_empty_state.dart
  - lib/features/trips/presentation/widgets/trip_overlay_layers.dart
  - lib/core/routing/app_router.dart
  - test/features/trips/trips_screen_test.dart
  - test/features/trips/trip_card_test.dart
  - test/features/trips/history_row_test.dart
  - test/features/trips/discard_confirmation_dialog_test.dart
  - test/features/trips/trip_detail_screen_test.dart
files_modified:
  - lib/features/trips/presentation/trips_screen.dart
  - lib/features/trips/presentation/trip_detail_screen.dart
  - lib/features/trips/presentation/widgets/trip_card.dart
  - lib/features/trips/presentation/widgets/history_row.dart
  - lib/features/trips/presentation/widgets/discard_confirmation_dialog.dart
  - lib/features/trips/presentation/widgets/inbox_empty_state.dart
  - lib/features/trips/presentation/widgets/history_empty_state.dart
  - lib/features/trips/presentation/widgets/trip_overlay_layers.dart
  - lib/core/routing/app_router.dart
  - test/features/trips/trips_screen_test.dart
  - test/features/trips/trip_card_test.dart
  - test/features/trips/history_row_test.dart
  - test/features/trips/discard_confirmation_dialog_test.dart
  - test/features/trips/trip_detail_screen_test.dart
must_haves:
  truths:
    - "Opening the Trips tab lands on Inbox when pending trips exist, else on History (CONTEXT)"
    - "Each Inbox card shows: static-map thumbnail, date+time, duration, distance, start→end place names, dormant vehicle chip, Keep + Discard buttons (INB-01, INB-02)"
    - "Tapping Keep flips status matched→confirmed silently (no modal); card leaves Inbox and appears in History (INB-03)"
    - "Tapping Discard shows the confirmation modal; on confirm, invalidator→intervals→trip delete order runs and thumbnail cache is cleared (INB-04)"
    - "MatchingQueuePill appears above both tabs when in-flight count > 0"
    - "History tab shows confirmed trips + in-flight trips (with pill on the row) — NEVER rejected trips (CONTEXT deviation)"
    - "Fail-matched trips (status matched, intervalCount == 0) show a 'No roads matched' chip in warning color (Q10)"
    - "Tapping any row navigates to /trips/:id — full-screen detail with map + raw polyline (gray) + matched intervals (accent) + delete button (INB-06, INB-08)"
    - "Deleting from detail screen triggers same discardTrip repository call as Inbox Discard (INB-08 + COV-06 trigger 2)"
    - "Empty-state widgets show for empty Inbox and empty History"
  artifacts:
    - path: "lib/features/trips/presentation/trips_screen.dart"
      provides: "Replaces placeholder with TabBar (Inbox/History) + MatchingQueuePill + thumbnail overlay entry"
    - path: "lib/features/trips/presentation/trip_detail_screen.dart"
      provides: "Full-screen route at /trips/:id"
    - path: "lib/features/trips/presentation/widgets/trip_overlay_layers.dart"
      provides: "Reusable addRawPolyline + addMatchedIntervalLayers — reused in P7"
    - path: "lib/core/routing/app_router.dart"
      provides: "GoRoute for /trips/:id"
  key_links:
    - from: "TripCard Keep button"
      to: "TripsInboxRepository.confirmTrip"
      via: "ref.read(tripsInboxRepositoryProvider).confirmTrip(tripId)"
      pattern: "confirmTrip"
    - from: "TripCard Discard button"
      to: "DiscardConfirmationDialog → TripsInboxRepository.discardTrip → ThumbnailCache.delete"
      via: "confirm modal, then repo call, then cache.delete(tripId)"
      pattern: "discardTrip"
    - from: "TripDetailScreen"
      to: "trip_overlay_layers.addRawPolyline / addMatchedIntervalLayers"
      via: "invoked from MapWidget onStyleLoaded — MUST re-add on style-swap (Pitfall Q1)"
      pattern: "onStyleLoaded"
    - from: "app_router.dart"
      to: "TripDetailScreen"
      via: "GoRoute('/trips/:id')"
      pattern: "/trips/:id"
verification:
  analyzer: "flutter analyze passes"
  tests:
    - test/features/trips/trips_screen_test.dart
    - test/features/trips/trip_card_test.dart
    - test/features/trips/history_row_test.dart
    - test/features/trips/discard_confirmation_dialog_test.dart
    - test/features/trips/trip_detail_screen_test.dart
---

<objective>
Ship the Inbox + History UI wave: replaces `trips_screen.dart` placeholder with sub-tabbed screen (Inbox / History), builds TripCard + HistoryRow + DiscardConfirmationDialog + empty states + TripDetailScreen at `/trips/:id`, and extracts reusable trip-overlay-layer helpers for Phase 7.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/STATE.md
@.planning/phases/06-inbox-match-wire-up/06-CONTEXT.md
@.planning/phases/06-inbox-match-wire-up/06-RESEARCH.md
@.planning/phases/06-inbox-match-wire-up/06-01-SUMMARY.md
@.planning/phases/06-inbox-match-wire-up/06-02-SUMMARY.md
@.planning/phases/06-inbox-match-wire-up/06-03-SUMMARY.md
@.planning/phases/06-inbox-match-wire-up/06-04-SUMMARY.md
@CLAUDE.md

# Existing UI infrastructure to reuse
@lib/features/trips/presentation/trips_screen.dart
@lib/features/map/presentation/widgets/map_widget.dart
@lib/features/map/presentation/widgets/bottom_nav_shell.dart
@lib/core/routing/app_router.dart
@lib/features/matching/data/overpass_way_candidate_source.dart
@lib/core/db/daos/driven_way_intervals_dao.dart
</context>

<invariants>
- Riverpod codegen OFF — plain `Provider<T>`, `Notifier<T>`, `ConsumerWidget`.
- Package imports only.
- `withValues(alpha:)` never `withOpacity()`.
- `sort_pub_dependencies` — no new deps expected.
- `DomainError` + `Result<T>` at boundaries; wrap UI-side calls that return Result via `switch (result) { case Ok<T>(): ...; case Err<T>(): ...; }`.
- Ralph Loop tiered: `flutter analyze` per commit; BEHAVIOR-SENSITIVE plan → run `flutter test test/features/trips/` inside the loop too.
- No drive checkpoint in this plan — deferred to phase close-out (memory note `defer-in-car-verification`).
- Pitfall Q1: MapWidget swaps style on brightness change and wipes programmatic layers. `TripDetailScreen` MUST re-add sources+layers inside `onStyleLoaded` — extract the layer-add logic into `trip_overlay_layers.dart` for both P6 and P7 reuse.
</invariants>

<tasks>

<task id="1" type="auto">
  <title>Task 1: TripCard + HistoryRow + DiscardConfirmationDialog + empty states</title>
  <files>
    lib/features/trips/presentation/widgets/trip_card.dart
    lib/features/trips/presentation/widgets/history_row.dart
    lib/features/trips/presentation/widgets/discard_confirmation_dialog.dart
    lib/features/trips/presentation/widgets/inbox_empty_state.dart
    lib/features/trips/presentation/widgets/history_empty_state.dart
    test/features/trips/trip_card_test.dart
    test/features/trips/history_row_test.dart
    test/features/trips/discard_confirmation_dialog_test.dart
  </files>
  <action>
**TripCard** — Consumer widget taking `TripListItem`. Layout:
```
┌──────────────────────────────────────────────┐
│ [ TripThumbnail 320x120 ]                    │
├──────────────────────────────────────────────┤
│ Miltenberg → Aschaffenburg                   │  ← place names from tripPlacesProvider
│ Wed 8 Jul, 14:32 · 42 min · 28.4 km         │  ← date/time · duration · distance
│ [🚗 Vehicle: —]  (dormant chip, P9 populates)│
│                                              │
│ [ Discard ]              [ Keep ]            │
└──────────────────────────────────────────────┘
```

- Watch `tripPlacesProvider((startLat, startLon, endLat, endLon))` for names; show "Location…" while loading.
- Vehicle chip is DORMANT in P6 (CONTEXT decision). Always shows a placeholder chip; do NOT hide it.
- Keep button → `ref.read(tripsInboxRepositoryProvider).confirmTrip(item.id)`. On Ok, no toast (CONTEXT "silent"). On Err, `ScaffoldMessenger.showSnackBar` with the DomainError message.
- Discard button → `showDialog(context, DiscardConfirmationDialog(...))`; if confirmed, sequence:
  1. `await ref.read(tripsInboxRepositoryProvider).discardTrip(item.id)`
  2. On Ok: `await ref.read(thumbnailCacheProvider.notifier).delete(item.id)`
  3. On Err: snackbar with DomainError message; do NOT clear thumbnail.
- Card is tappable (whole surface) → `context.push('/trips/${item.id}')`.

**HistoryRow** — compact row (no thumbnail, or a small 64×48 thumbnail — planner discretion, prefer 64×48 for consistency). Shows:
- Place names ("Miltenberg → Aschaffenburg")
- Date · duration · distance
- Status pill:
  - `TripStatus.matched` && intervalCount == 0 → "No roads matched" chip (warning color)
  - `TripStatus.pending | pendingRoadData` → "Matching…" pill with tiny spinner
  - `TripStatus.confirmed` → no pill
- Tap → `/trips/:id`.

**DiscardConfirmationDialog** — AlertDialog:
```
Title:     "Discard this trip?"
Content:   "Raw GPS will be deleted and coverage recomputed.
           This cannot be undone."
Actions:   [ Cancel ]  [ Discard ]   (Discard styled destructive/red)
```
Returns `Future<bool>` from `showDialog`.

**InboxEmptyState** — SVG-free (avoid new asset deps); use an `Icon` (e.g. `Icons.inbox_outlined`) at 64 px with muted color + centered copy:
```
"No trips waiting"
"Drives you record will show up here for review."
```

**HistoryEmptyState** — similar structure:
```
"No trip history yet"
"Confirmed and matching trips will appear here."
```

Tests (three files, mirroring widget files):

`trip_card_test.dart`:
- Renders place names when `tripPlacesProvider` yields TripPlaces(start: "Miltenberg", end: "Aschaffenburg") → finds "Miltenberg → Aschaffenburg".
- Loop trip (start==end) → finds "Miltenberg" only.
- Vehicle chip rendered even when vehicleId is null (dormant P6 behavior).
- Keep button tap invokes `tripsInboxRepositoryProvider.confirmTrip(tripId)` on a fake repo (verify via call recorder).
- Discard button tap → dialog appears; on confirm, `discardTrip` is invoked then `thumbnailCache.delete(tripId)`.
- Discard cancel → no repo call.
- Whole-card tap → route pushed to `/trips/:id` (fake GoRouter or `MaterialApp.router` with a spy).

`history_row_test.dart`:
- confirmed trip → no status pill.
- matched + 0 intervals → "No roads matched" chip visible with warning color.
- pending trip → "Matching…" text + CircularProgressIndicator.
- pendingRoadData trip → same as pending.
- Row tap → route pushed to `/trips/:id`.

`discard_confirmation_dialog_test.dart`:
- Cancel returns false.
- Confirm returns true.
- Title + body copy present.
- Destructive button styled with error color from theme.
  </action>
  <verify>
`flutter analyze` clean.
`flutter test test/features/trips/trip_card_test.dart test/features/trips/history_row_test.dart test/features/trips/discard_confirmation_dialog_test.dart` — all green.
  </verify>
  <done>
Five widget files ship; three test files pass with combined ≥15 test cases.
  </done>
</task>

<task id="2" type="auto">
  <title>Task 2: TripsScreen — replace placeholder with sub-tabbed Inbox/History + MatchingQueuePill + thumbnail overlay entry</title>
  <files>
    lib/features/trips/presentation/trips_screen.dart
    test/features/trips/trips_screen_test.dart
  </files>
  <action>
Replace the placeholder body with:

```dart
class TripsScreen extends ConsumerStatefulWidget {
  const TripsScreen({super.key});
  @override
  ConsumerState<TripsScreen> createState() => _TripsScreenState();
}

class _TripsScreenState extends ConsumerState<TripsScreen> with SingleTickerProviderStateMixin {
  late final TabController _tab;
  bool _initialTabResolved = false;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
  }
  ...
}
```

Behavior:
- On first frame after `inboxTripsProvider` yields its first snapshot: if `snapshot.isNotEmpty` → land on Inbox tab; else → land on History. Guard with `_initialTabResolved` so subsequent updates don't force-jump.
- Above TabBar, render `MatchingQueuePill()`.
- Inbox tab body:
  - `ref.watch(inboxTripsProvider).when(data: (items) => items.isEmpty ? InboxEmptyState() : ListView.builder(...TripCard(item)...), loading: shimmer, error: DomainError-aware message)`
- History tab body:
  - Same pattern with `historyTripsProvider` + `HistoryRow` + `HistoryEmptyState`.
- Register a global `Overlay` entry at first build for the thumbnail-renderer's offscreen MapLibreMap (approach C from RESEARCH Q1). Position it `Offstage(offstage: true, child: SizedBox(width: 320, height: 120, child: MapLibreMap(styleString: <fixed>, onMapCreated: (c) => ref.read(thumbnailRendererControllerProvider.notifier).state = c)))`. This is what makes `ThumbnailRenderer.render()` (as opposed to `renderFallback`) work.

Tests (`test/features/trips/trips_screen_test.dart`):
- With `inboxTripsProvider` overridden to yield 2 items → landing tab is Inbox, 2 TripCards visible.
- With `inboxTripsProvider` overridden to yield [] and `historyTripsProvider` yielding 3 → landing tab is History, 3 HistoryRows.
- Both empty → Inbox is default (or History; document + test the exact choice) and correct empty state is shown.
- `inFlightCountProvider` override to 3 → MatchingQueuePill visible with "3 trips matching…".
- Tab switch between Inbox and History works.
- After landing, updates to inbox list DO NOT force a re-jump (verify `_initialTabResolved` guard).

For overriding the thumbnail overlay in tests: skip actual MapLibre instantiation by injecting a `ThumbnailOverlayFactory` provider — override with a no-op in tests.
  </action>
  <verify>
`flutter analyze` clean.
`flutter test test/features/trips/trips_screen_test.dart` green.
  </verify>
  <done>
TripsScreen replaces placeholder; sub-tabs work; MatchingQueuePill wired; ≥6 test cases pass.
  </done>
</task>

<task id="3" type="auto">
  <title>Task 3: TripDetailScreen + trip_overlay_layers + /trips/:id route</title>
  <files>
    lib/features/trips/presentation/trip_detail_screen.dart
    lib/features/trips/presentation/widgets/trip_overlay_layers.dart
    lib/core/routing/app_router.dart
    test/features/trips/trip_detail_screen_test.dart
  </files>
  <action>
**trip_overlay_layers.dart** — reusable helpers for map layer add/remove (extracted so P7 can reuse):
```dart
/// Add raw polyline (gray/muted) for a trip's GPS trace.
Future<void> addRawPolyline(
  MapLibreMapController controller, {
  required String sourceId,          // 'trip_raw_${tripId}'
  required String layerId,           // 'trip_raw_layer_${tripId}'
  required List<LatLng> polyline,
  required Color color,              // muted gray from theme
});

/// Add matched intervals as an accent-colored line layer.
Future<void> addMatchedIntervalLayers(
  MapLibreMapController controller, {
  required String sourceId,          // 'trip_matched_${tripId}'
  required String layerId,           // 'trip_matched_layer_${tripId}'
  required List<List<LatLng>> matchedSegments, // reconstructed per-way subsegments
  required Color color,              // accent
});

/// Remove both sources+layers cleanly (idempotent).
Future<void> removeTripOverlay(MapLibreMapController controller, int tripId);
```

**TripDetailScreen** — full-screen route:
```dart
class TripDetailScreen extends ConsumerStatefulWidget {
  const TripDetailScreen({required this.tripId, super.key});
  final int tripId;
  ...
}
```

- App bar: `Trip #${tripId}` + a delete IconButton (opens DiscardConfirmationDialog with the same copy, calls `discardTrip`, then `context.pop()`).
- Body: `MapWidget` with `onStyleLoaded` callback that:
  1. Reads `tripPointsProvider(tripId)` (add a simple `FutureProvider.family` sourced from `TripsDao.listPointsForTrip(tripId)`).
  2. Reads matched intervals via `DrivenWayIntervalsDao.getByTrip(tripId)`.
  3. For each interval, resolves way geometry via `OverpassWayCandidateSource.fetchWaysInBbox(trip.bbox)` (already cache-first — RESEARCH Q6), then extracts the subsegment `[startIndex..endIndex]` from the way's coordinates.
  4. Calls `addRawPolyline` and `addMatchedIntervalLayers`.
  5. Frames camera: `controller.moveCamera(CameraUpdate.newLatLngBounds(bbox, ...))`.
- Below map: a compact stat strip:
  - "Duration: 42 min · Distance: 28.4 km · Matched: 12 ways (87%)"
  - Matched percentage = `driven_length / total_length` for this trip's ways (from intervals + way geometries).
- Fail-matched case (intervalCount == 0): show `MatchedInfoBanner` above map — "No roads matched. GPS may have been indoors or in a parking lot." Delete button still functional; matched-intervals overlay skipped.

**Pitfall Q1 guard**: MapWidget's `onStyleLoaded` fires again on brightness swap. Register the whole add-layer routine as a callback that re-runs on every style-load, not just the first. Track already-added layer IDs in state and remove before re-add (or trust `onStyleLoaded` was preceded by style-swap that wiped them).

**app_router.dart** update — add:
```dart
GoRoute(
  path: '/trips/:id',
  builder: (context, state) => TripDetailScreen(
    tripId: int.parse(state.pathParameters['id']!),
  ),
),
```
Route lives OUTSIDE the bottom-nav ShellRoute (full-screen, not a tab branch).

Tests (`test/features/trips/trip_detail_screen_test.dart`) — use fake DAOs + a `MockMapLibreMapController` (or a controller-abstraction seam). If MapLibre controller isn't easily mockable, test the following without a real map:
- Fail-matched detail: intervalCount == 0 → banner visible, matched-layer add call NOT made (verify via call recorder on a fake overlay-adder injected via provider override).
- Non-fail-matched: banner absent, both raw + matched adders called.
- Delete IconButton tap → DiscardConfirmationDialog → on confirm → `discardTrip(tripId)` called + `context.pop()`.
- Stat strip renders duration/distance/matched% correctly (parameterized).
- Style-swap re-triggers add-layer routine (spy on the callback registered on MapWidget).

**Injection seam**: extract the `addRawPolyline`/`addMatchedIntervalLayers` calls behind a `TripOverlayApplier` provider so tests can override. This is the same pattern used in 06-04's tests.

**Deferred to phase close-out drive** (per memory `defer-in-car-verification`): on-device visual verification that layers actually render on brightness swap. No drive checkpoint in this plan.
  </action>
  <verify>
`flutter analyze` clean.
`flutter test test/features/trips/trip_detail_screen_test.dart` green.
`flutter test test/core/routing/` — router tests continue to pass; add a router-level test asserting `/trips/1` navigates to `TripDetailScreen` if the app has an existing router test file.
  </verify>
  <done>
TripDetailScreen at `/trips/:id`; trip_overlay_layers helpers extracted; route registered; ≥5 test cases pass; fail-matched banner branch tested.
  </done>
</task>

<task id="4" type="checkpoint:human-verify" gate="blocking">
  <what-built>
Complete Phase 6 Inbox + History + Detail UI, wired to real repository, in the running app.

Automated coverage already green:
- All widget tests pass (TripCard, HistoryRow, DiscardConfirmationDialog, TripsScreen, TripDetailScreen).
- Repository delete-order enforced + tested.
- Thumbnail fallback path proven; MapLibre snapshot path in place but unproven visually.
- Style-swap re-add-layers guard in place; unproven visually.
  </what-built>
  <how-to-verify>
Launch the app on your device:
```
flutter run -d <device>  (--debug or --profile — see memory note fgb-license-and-release-builds)
```

Verify in this order:
1. Open Trips tab. If no pending trips, tap the record button, drive around the block, stop. Otherwise pick an existing matched trip.
2. **Inbox card renders**: thumbnail visible (may show gray shimmer for a moment then the map); place names, date/time, duration, distance shown; dormant vehicle chip present.
3. **Keep flow**: tap Keep → card disappears silently; if in-flight trips exist, MatchingQueuePill visible above tabs.
4. **Discard flow**: on a second pending trip, tap Discard → modal appears with correct copy → confirm → trip vanishes → verify the trip is NOT in History either.
5. **History tab**: switch to History; confirmed trip from step 3 present with no status pill; if any matcher-in-flight trip exists, its row shows "Matching…" with spinner.
6. **Fail-matched case** (if you have one): row shows "No roads matched" warning chip.
7. **Detail screen**: tap any confirmed row → full-screen detail; raw polyline visible in muted gray, matched intervals in accent color; stat strip shows duration/distance/matched-%.
8. **Style-swap regression check**: toggle system dark mode while on Detail screen — polyline+intervals MUST re-appear (Pitfall Q1 sanity).
9. **Delete from detail**: tap delete icon → confirm dialog → trip removed → History updated.
10. **Route stability**: `/trips/999999` (non-existent id) — graceful error message, no crash.

If all 10 items pass, type "approved" to unblock 06-06.
  </how-to-verify>
  <resume-signal>Type "approved" or list issues to fix.</resume-signal>
</task>

</tasks>

<verification>
Fast-loop: `flutter analyze` on every commit (also `flutter analyze --fatal-infos` on final commit before push).
Loop-tests (this plan is heavily behavior-sensitive): `flutter test test/features/trips/`.
Pre-push hook covers the full suite.
Checkpoint gates progression to 06-06.
</verification>

<success_criteria>
- `trips_screen.dart` no longer contains the Phase-3 placeholder.
- All widget tests pass.
- `/trips/:id` route registered outside the bottom-nav ShellRoute.
- `trip_overlay_layers.dart` extracted for Phase 7 reuse.
- Discard flow enforces the delete order from 06-02 (repo test coverage stands).
- MatchingQueuePill visible above tabs when inFlightCount > 0.
- CONTEXT deviations honored: no bulk-select mode; no rejected trips in History; no `counts_for_coverage` toggle.
- Style-swap re-adds layers (Pitfall Q1).
- User has run through the checkpoint and typed "approved".
</success_criteria>

<output>
Create `.planning/phases/06-inbox-match-wire-up/06-05-SUMMARY.md`.
Capture: file inventory, screenshot / video links (if the user attaches any at checkpoint approval), any deviations from plan discovered during execution, list of tests added.
</output>
