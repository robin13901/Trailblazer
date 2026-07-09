---
phase: 06-inbox-match-wire-up
plan: 06-04
subsystem: trips
tags: [riverpod, stream-provider, liquid-glass, inbox, presentation]

# Dependency graph
requires:
  - phase: 06-inbox-match-wire-up
    provides: TripsInboxRepository + tripsInboxRepositoryProvider + TripListItem DTO (Plan 06-02)
  - phase: 02-map-glass-shell
    provides: GlassPill / GlassPillFallback Liquid Glass shell + LiquidGlassSettings G1 flag (Plan 02-05)
provides:
  - inboxTripsProvider — StreamProvider<List<TripListItem>> (matched trips)
  - historyTripsProvider — StreamProvider<List<TripListItem>> (confirmed + in-flight)
  - inFlightCountProvider — StreamProvider<int> (matcher-queue depth)
  - MatchingQueuePill — Liquid Glass "N trips matching…" indicator widget
affects: [06-05 trips screen (imports all four artifacts)]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Thin StreamProvider<T> wrappers over a repository's stream getters — no logic beyond ref.watch(repo).watchX() (Riverpod codegen OFF)"
    - "MatchingQueuePill composes the shared GlassPill shell instead of a bespoke Container — inherits the G1-flag branch (real LiquidGlass vs tinted fallback) for free"
    - "Widget tests keep G1 flag false + tearDown reset (glass_pill_test pattern) so the pill renders via GlassPillFallback, off the liquid_glass_renderer paint path"
    - "Provider-override with a broadcast-StreamController fake repo (implements + noSuchMethod) to drive AsyncValue transitions in provider unit tests"

key-files:
  created:
    - lib/features/trips/presentation/providers/inbox_providers.dart
    - lib/features/trips/presentation/widgets/matching_queue_pill.dart
    - test/features/trips/inbox_providers_test.dart
    - test/features/trips/matching_queue_pill_test.dart
  modified: []

key-decisions:
  - "MatchingQueuePill wraps the shared GlassPill shell (not a standalone Container as the plan sketch showed) — reuses the established G1 branch + fallback tint/border/shadow, keeping the app-wide glass aesthetic and BackdropFilter-avoidance guarantee"
  - "borderRadius: 999 passed to GlassPill for a full stadium shape (the plan's intent); GlassPill's default 28 is overridable via its borderRadius param"
  - "AsyncValue.value (not valueOrNull) — flutter_riverpod 3.3.2 AsyncValue has no valueOrNull getter; .value returns the data-or-null which is exactly the count fallback needed"
  - "Widget-golden tests deferred to 06-05 (per plan output spec) — this plan ships behavioral widget tests (copy strings, spinner presence, hidden-at-zero, no BackdropFilter) only"

patterns-established:
  - "Post-Keep queue indicator copy: '1 trip matching…' (singular) / '$N trips matching…' (plural)"
  - "Count-driven visibility: count == 0 (and loading, since .value is null) → SizedBox.shrink"

# Metrics
duration: 3min
completed: 2026-07-09
---

# Phase 6 Plan 06-04: Matcher Queue Indicator Summary

**Presentation-layer StreamProviders (inbox / history / in-flight) that forward 06-02's TripsInboxRepository streams, plus the Liquid Glass "N trips matching…" queue-pill widget that reassures the user the matcher is still working after they tap Keep — rendered through the shared GlassPill shell so it inherits the G1 blur-vs-fallback branch.**

## Performance

- **Duration:** ~3 min
- **Started:** 2026-07-09T12:03:17Z
- **Completed:** 2026-07-09T12:06:25Z
- **Tasks:** 2/2
- **Files created:** 4 (2 lib + 2 test); 0 modified

## Accomplishments

- Three plain `StreamProvider<T>` fields in `inbox_providers.dart` forward the exact streams 06-02's repository exposes — no extra logic, matching the codegen-OFF convention (STATE 01-01).
- `MatchingQueuePill` composes the shared `GlassPill` shell (rather than a bespoke `Container`), so it automatically renders real `LiquidGlass` when the G1 flag is true and the tinted `GlassPillFallback` otherwise — same aesthetic + BackdropFilter-avoidance as the rest of the chrome. Count-driven copy, spinner, hides at zero.
- 10 tests total (5 + 5): provider re-emission, error propagation, `0 → 1 → 2 → 0` sequence, broadcast caching; pill copy for count 0/1/5, spinner presence, no `BackdropFilter`.

## Task Commits

Each task committed atomically with only files_owned staged:

1. **Task 1: Inbox / History / In-Flight presentation providers** — `2336a3a` (feat)
2. **Task 2: MatchingQueuePill — Liquid Glass "N trips matching…" widget** — `ee00523` (feat)

Metadata commit follows this SUMMARY + STATE update.

## API Reference (for 06-05 wiring — do not re-read source)

```dart
// inbox_providers.dart
final inboxTripsProvider    = StreamProvider<List<TripListItem>>(...);  // matched
final historyTripsProvider  = StreamProvider<List<TripListItem>>(...);  // confirmed + in-flight
final inFlightCountProvider = StreamProvider<int>(...);                 // matcher-queue depth

// matching_queue_pill.dart
class MatchingQueuePill extends ConsumerWidget { const MatchingQueuePill({super.key}); }
// Watches inFlightCountProvider; renders GlassPill with spinner + "N trips matching…"
// when count > 0, else SizedBox.shrink. Place above the inbox list in 06-05.
```

## Decisions Made

1. **MatchingQueuePill uses the shared `GlassPill` shell.** The plan's action sketch showed a bespoke `Container` with alpha-surface + shadow. Instead the pill composes `GlassPill(borderRadius: 999, …)`, reusing the established G1-flag branch (real `LiquidGlass` wrapped in `LiquidGlassLayer` vs tinted `GlassPillFallback`). This matches the prompt's explicit direction ("follow the established shell pattern") and the `LiveTrackingPanel` precedent, and inherits the fallback's tint/border/shadow + the documented "no BackdropFilter over the map" guarantee for free.
2. **`AsyncValue.value`, not `valueOrNull`.** flutter_riverpod 3.3.2's `AsyncValue<int>` has no `valueOrNull` getter (analyzer error); `.value` returns data-or-null which is exactly the `?? 0` fallback the pill needs — loading and error states both collapse to a hidden pill.
3. **`withValues(alpha:)` for the spinner accent.** The pill's tint/border/shadow all live inside `GlassPillFallback` (already alpha-based); the only local color is the spinner, softened via `theme.colorScheme.primary.withValues(alpha: 0.9)`. No `withOpacity` anywhere.
4. **Widget-golden tests deferred to 06-05** per the plan output spec — 06-04 ships behavioral widget tests only.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `valueOrNull` undefined on AsyncValue (riverpod 3.3.2)**
- **Found during:** Task 2
- **Issue:** The plan's action code used `ref.watch(inFlightCountProvider).valueOrNull` — that getter doesn't exist in flutter_riverpod 3.3.2 (`undefined_getter` analyzer error).
- **Fix:** Switched to `.value ?? 0` (data-or-null with the count fallback).
- **Files modified:** `lib/features/trips/presentation/widgets/matching_queue_pill.dart`
- **Verification:** `flutter analyze` clean; 5 widget tests green.
- **Committed in:** `ee00523` (Task 2 commit)

**2. [Rule 3 - Blocking] Analyzer lint fixes on the provider test**
- **Found during:** Task 1
- **Issue:** `discarded_futures` on `StreamController.close()` calls in a sync `tearDown`, and `unnecessary_underscores` on `(_, __)` listener callbacks.
- **Fix:** Made `tearDown` async + awaited the closes; switched listener callbacks to `(_, _)`.
- **Verification:** `flutter analyze` clean; 5 tests green.
- **Committed in:** `2336a3a` (Task 1 commit)

**3. [Rule 1 - Design fit] GlassPill shell over bespoke Container** — documented as Decision 1 above (not a bug; a deliberate alignment with the project's Liquid Glass shell pattern that the prompt directed).

---

**Total deviations:** 2 auto-fixed (Rule 3 - Blocking) + 1 design-alignment choice (GlassPill shell). No architectural changes, no scope creep.
**Impact on plan:** All fixes mechanical. The pill uses the shared shell instead of a bespoke Container — same visual intent, better consistency.

## Issues Encountered

None beyond the mechanical Ralph-loop lint fixes above.

## Verification

- `flutter analyze` — clean on all 4 owned files.
- `flutter test test/features/trips/inbox_providers_test.dart` — 5/5 green.
- `flutter test test/features/trips/matching_queue_pill_test.dart` — 5/5 green.
- inboxTripsProvider sourced from `TripsInboxRepository.watchInboxItems` (Q8) — confirmed.
- MatchingQueuePill renders via the Liquid Glass shell (GlassPill → GlassPillFallback in tests, real LiquidGlass under the G1 flag).

## Wave Hygiene

Files staged INDIVIDUALLY per the parallel-wave rule (memory: `wave-2-parallel-metadata-hygiene`). No `git add .` / `git add -A`. 06-04 runs in Wave 3 (after 06-02 landed on disk); only READS 06-02's `tripsInboxRepositoryProvider` + `TripListItem` — does not own or modify them.

## Next Phase Readiness

- 06-05 can import all four artifacts: the three list/count providers + `MatchingQueuePill`. Place the pill above the inbox list; wire `inboxTripsProvider` / `historyTripsProvider` to the two sub-tabs.
- Widget-golden tests for the pill's rendered pixels belong to 06-05.
- No blockers.

---
*Phase: 06-inbox-match-wire-up*
*Completed: 2026-07-09*
