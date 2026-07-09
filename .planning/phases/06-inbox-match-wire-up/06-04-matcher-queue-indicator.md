---
plan: 06-04
phase: 6
wave: 1
depends_on: []
type: execute
autonomous: true
files_owned:
  - lib/features/trips/presentation/providers/inbox_providers.dart
  - lib/features/trips/presentation/widgets/matching_queue_pill.dart
  - test/features/trips/inbox_providers_test.dart
  - test/features/trips/matching_queue_pill_test.dart
files_modified:
  - lib/features/trips/presentation/providers/inbox_providers.dart
  - lib/features/trips/presentation/widgets/matching_queue_pill.dart
  - test/features/trips/inbox_providers_test.dart
  - test/features/trips/matching_queue_pill_test.dart
must_haves:
  truths:
    - "inboxTripsProvider yields StreamProvider<List<TripListItem>> sourced from TripsInboxRepository.watchInboxItems (Q8)"
    - "historyTripsProvider yields StreamProvider<List<TripListItem>> sourced from watchHistoryItems (Q8)"
    - "inFlightCountProvider yields StreamProvider<int> sourced from watchInFlightCount (Q8)"
    - "MatchingQueuePill renders 'N trips matching…' when count > 0 and nothing when count == 0 (CONTEXT post-Keep UX)"
    - "MatchingQueuePill uses Liquid Glass aesthetic with withValues(alpha:) — never withOpacity"
  artifacts:
    - path: "lib/features/trips/presentation/providers/inbox_providers.dart"
      provides: "inboxTripsProvider, historyTripsProvider, inFlightCountProvider"
    - path: "lib/features/trips/presentation/widgets/matching_queue_pill.dart"
      provides: "MatchingQueuePill widget consumed by TripsScreen (in 06-05)"
  key_links:
    - from: "inbox_providers.dart"
      to: "tripsInboxRepositoryProvider (from 06-02)"
      via: "ref.watch(...).watchInboxItems() etc."
      pattern: "tripsInboxRepositoryProvider"
verification:
  analyzer: "flutter analyze passes"
  tests:
    - test/features/trips/inbox_providers_test.dart
    - test/features/trips/matching_queue_pill_test.dart
---

<objective>
Presentation-layer providers exposing inbox/history/in-flight streams from 06-02's repository, plus the Liquid Glass "N trips matching…" pill widget consumed by TripsScreen in 06-05.
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
@CLAUDE.md

# Sibling plan APIs referenced (defined in 06-02 — the plans run in parallel; this plan REFERENCES the future provider)
# tripsInboxRepositoryProvider: Provider<TripsInboxRepository>
#   TripsInboxRepository.watchInboxItems() → Stream<List<TripListItem>>
#   TripsInboxRepository.watchHistoryItems() → Stream<List<TripListItem>>
#   TripsInboxRepository.watchInFlightCount() → Stream<int>
</context>

<invariants>
- Riverpod codegen OFF — plain `StreamProvider<T>`.
- Package imports only.
- `withValues(alpha:)` never `withOpacity()`.
- No drive checkpoint.
- **DO NOT touch files owned by 06-01, 06-02, 06-03** (parallel-wave metadata hygiene).
- IMPORT paths from 06-02: `package:auto_explore/features/trips/data/trips_repository_inbox_extensions.dart` (tripsInboxRepositoryProvider) and `package:auto_explore/features/trips/domain/trip_list_item.dart` (TripListItem). These are declared in 06-02's files_owned; this plan only READS them, doesn't own them.
</invariants>

<tasks>

<task id="1" type="auto">
  <title>Task 1: Inbox / History / In-Flight presentation providers</title>
  <files>
    lib/features/trips/presentation/providers/inbox_providers.dart
    test/features/trips/inbox_providers_test.dart
  </files>
  <action>
```dart
import 'package:auto_explore/features/trips/data/trips_repository_inbox_extensions.dart';
import 'package:auto_explore/features/trips/domain/trip_list_item.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final inboxTripsProvider = StreamProvider<List<TripListItem>>((ref) {
  return ref.watch(tripsInboxRepositoryProvider).watchInboxItems();
});

final historyTripsProvider = StreamProvider<List<TripListItem>>((ref) {
  return ref.watch(tripsInboxRepositoryProvider).watchHistoryItems();
});

final inFlightCountProvider = StreamProvider<int>((ref) {
  return ref.watch(tripsInboxRepositoryProvider).watchInFlightCount();
});
```

Tests (`test/features/trips/inbox_providers_test.dart`) — override `tripsInboxRepositoryProvider` with a fake repository whose streams emit controlled data via `StreamController`:
- inboxTripsProvider re-emits when fake stream pushes new list.
- historyTripsProvider re-emits.
- inFlightCountProvider emits sequence 0 → 1 → 2 → 0.
- Errors in stream propagate to `AsyncError` state.
- Late subscriber sees latest cached value (broadcast behavior — verify with a `StreamController.broadcast()` fake).

**Fake repo class** for testing lives inline in the test file — no fixture files.
  </action>
  <verify>
`flutter analyze` clean.
`flutter test test/features/trips/inbox_providers_test.dart` green.
  </verify>
  <done>
Three StreamProviders exported; ≥4 test cases pass with provider-override + fake repo.
  </done>
</task>

<task id="2" type="auto">
  <title>Task 2: MatchingQueuePill — Liquid Glass "N trips matching…" widget</title>
  <files>
    lib/features/trips/presentation/widgets/matching_queue_pill.dart
    test/features/trips/matching_queue_pill_test.dart
  </files>
  <action>
```dart
class MatchingQueuePill extends ConsumerWidget {
  const MatchingQueuePill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(inFlightCountProvider).valueOrNull ?? 0;
    if (count == 0) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.7),   // NEVER withOpacity
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.2),
        ),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.shadow.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            count == 1 ? '1 trip matching…' : '$count trips matching…',
            style: theme.textTheme.labelMedium,
          ),
        ],
      ),
    );
  }
}
```

Copy:
- 1 → "1 trip matching…"
- N>1 → "$N trips matching…"

Do NOT wrap in a BackdropFilter (blur is expensive and this pill overlays lists; the alpha-surface + shadow gives the Liquid Glass feel cheaply). If the user later requests a real blur, easy retrofit — this plan ships the shape.

Tests (`test/features/trips/matching_queue_pill_test.dart`) — pumpWidget with `ProviderScope` overriding `inFlightCountProvider`:
- count == 0 → widget tree contains `SizedBox.shrink` and no visible text.
- count == 1 → text "1 trip matching…" found.
- count == 5 → text "5 trips matching…" found.
- CircularProgressIndicator present when count > 0.
- No `withOpacity` in the widget tree (search for `Opacity` widget → not present, this is a static string-search preference; the runtime test just verifies build succeeds).
  </action>
  <verify>
`flutter analyze` clean.
`flutter test test/features/trips/matching_queue_pill_test.dart` green.
  </verify>
  <done>
`MatchingQueuePill` widget with count-driven copy, `withValues(alpha:)` styling, ≥4 test cases pass.
  </done>
</task>

</tasks>

<verification>
Fast-loop: `flutter analyze`.
Loop-tests: `flutter test test/features/trips/inbox_providers_test.dart test/features/trips/matching_queue_pill_test.dart`.
Pre-push covers full suite.
</verification>

<success_criteria>
- Three providers exposed with the exact names in must_haves.artifacts (06-05 imports these).
- MatchingQueuePill renders correctly for count values 0, 1, N.
- Analyzer clean.
- No `withOpacity` used.
- File ownership respected — this plan touches only its 4 owned files.
</success_criteria>

<output>
Create `.planning/phases/06-inbox-match-wire-up/06-04-SUMMARY.md`.
Capture: exact provider names + types, pill copy strings, styling choice (alpha-surface over BackdropFilter), decision that widget-golden tests live in 06-05.
</output>
