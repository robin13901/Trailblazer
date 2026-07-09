// Trailblazer Phase 6, Plan 06-04 Task 1:
// Presentation-layer providers exposing the inbox / history / in-flight
// streams from 06-02's TripsInboxRepository.
//
// Thin StreamProvider wrappers — no logic beyond watching the repository and
// forwarding its Drift-backed streams. Riverpod codegen is OFF (STATE 01-01),
// so these are plain `StreamProvider<T>` fields.

import 'package:auto_explore/features/trips/data/trips_repository_inbox_extensions.dart';
import 'package:auto_explore/features/trips/domain/trip_list_item.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Inbox list stream — matched trips awaiting Keep/Discard (Q8).
final inboxTripsProvider = StreamProvider<List<TripListItem>>((ref) {
  return ref.watch(tripsInboxRepositoryProvider).watchInboxItems();
});

/// History list stream — confirmed + matched + in-flight trips (Q8).
final historyTripsProvider = StreamProvider<List<TripListItem>>((ref) {
  return ref.watch(tripsInboxRepositoryProvider).watchHistoryItems();
});

/// Global in-flight matcher-queue count — pending + pendingRoadData (Q8).
///
/// Consumed by `MatchingQueuePill` to render the "N trips matching…"
/// indicator after Keep (CONTEXT post-Keep UX).
final inFlightCountProvider = StreamProvider<int>((ref) {
  return ref.watch(tripsInboxRepositoryProvider).watchInFlightCount();
});
