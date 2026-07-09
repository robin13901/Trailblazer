// Phase 6 (Plan 06-07): UI-facing match-progress state.
//
// Holds a per-trip matching progress fraction (0.0..1.0) streamed from the
// matcher isolate via TripMatchCoordinator's progress sink. History-tab rows
// read this to render a real percentage on the "Matching…" pill instead of an
// indeterminate spinner.
//
// Plain Notifier — no `@Riverpod` codegen (STATE Plan 01-01 decision).

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Notifier holding a `tripId → fraction` map, where `fraction` is the
/// matching completion ratio in `0.0..1.0`.
///
/// A trip appears in the map only while it has reported at least one progress
/// update and has not yet been cleared (on completion/error/cancel or when it
/// transitions to `matched`). Rows treat "absent" as "in-flight but no
/// progress yet" (queued / fetching roads) and fall back to an indeterminate
/// spinner.
class MatchProgressNotifier extends Notifier<Map<int, double>> {
  @override
  Map<int, double> build() => const {};

  /// Record the latest progress [fraction] (clamped to `0.0..1.0`) for
  /// [tripId]. Replaces the whole map so Riverpod emits a new immutable value.
  void update(int tripId, double fraction) {
    final clamped = fraction.clamp(0.0, 1.0);
    state = {...state, tripId: clamped};
  }

  /// Remove [tripId] from the progress map (job completed/errored/cancelled or
  /// trip transitioned to `matched`). No-op when the trip is absent.
  void clear(int tripId) {
    if (!state.containsKey(tripId)) return;
    final next = {...state}..remove(tripId);
    state = next;
  }
}

/// Provider exposing the per-trip matching-progress map. Written by the
/// coordinator's progress sink (wired in `matching_providers.dart`), read by
/// `HistoryRow`.
final matchProgressProvider =
    NotifierProvider<MatchProgressNotifier, Map<int, double>>(
  MatchProgressNotifier.new,
);
