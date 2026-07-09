# 06-05 SUMMARY — Inbox + History UI

**Plan:** 06-05 (Wave 4, `autonomous: false` — human-verify checkpoint)
**Status:** Code-complete; checkpoint FAILED on first on-device run → gap-closure fixes landed (see `06-07-08-GAP-SUMMARY.md`). Behavioral re-verify DEFERRED to user (manual test list at phase close-out).
**Completed:** 2026-07-09

## What shipped

Replaced the Phase-3 `trips_screen.dart` placeholder with the full Inbox + History UI, wired to the real repository:

- **TripsScreen** (`lib/features/trips/presentation/trips_screen.dart`) — Inbox / History sub-tabs (`TabController`), `MatchingQueuePill` above the tabs, landing-tab resolution from the first inbox snapshot. *(The offstage thumbnail map added here was removed in gap-fix 06-07 — it was dead weight and a crash cause.)*
- **TripCard** (`widgets/trip_card.dart`) — place names, date·duration·distance, dormant vehicle chip, Keep (silent confirm) + Discard (confirmation dialog → ordered delete + thumbnail-cache clear). *(Map thumbnail band removed per user request in 06-07 — `529ca08`.)*
- **HistoryRow** (`widgets/history_row.dart`) — status pill: "No roads matched" (fail-matched), "Matching…" (in-flight; later upgraded to a real % in 06-07), no pill (confirmed).
- **DiscardConfirmationDialog**, **InboxEmptyState**, **HistoryEmptyState**.
- **TripDetailScreen** (`trip_detail_screen.dart`) at `/trips/:id` (registered OUTSIDE the bottom-nav ShellRoute) — MapWidget with raw polyline (muted) + matched intervals (accent) via `trip_overlay_layers.dart`, stat strip (duration/distance/matched%), fail-matched + offline-fallback banners, Pitfall-Q1 style-swap re-apply guard, delete action.
- **trip_overlay_layers.dart** — reusable add/remove map-layer helpers, extracted for Phase 7 coverage reuse.

## Commits
- `d14c574` feat(06-05): TripCard + HistoryRow + DiscardConfirmationDialog + empty states
- `51e54a4` feat(06-05): TripsScreen sub-tabs + queue pill + thumbnail overlay
- `09c088e` feat(06-05): TripDetailScreen + trip_overlay_layers + /trips/:id route

## CONTEXT deviations honored
No bulk-select mode; no rejected trips in History (hard-deleted at Discard); no `counts_for_coverage` toggle (P9).

## Checkpoint outcome
The blocking human-verify checkpoint FAILED on first device run (freeze→crash on the Trips tab; map not pivoting to heading; unwanted auto-recording notifications). Root-caused and fixed under gap plans 06-07 (crash + heading + UI) and 06-08 (manual-only recording). Crash fix PROVEN on-device (trip 8, 96 km / 6,295 pts, matched to 814 intervals, app alive). Behavioral re-verify (drive) deferred to the user per `defer-in-car-verification`.

## Tests
All widget tests for the above pass; `test/features/trips/` green. Full suite 524 tests green at gap-fix close.
