// One-shot startup recalc progress (2026-07-26).
//
// Surfaces the app-wide progress of the one-time global re-match + coverage
// rebuild migration (see `lib/app.dart` `_runStartupMigrations`). While the
// migration runs, the state is non-null so a banner can render "Neuberechnung
// … Fahrt N/M" (rematching) then "Abdeckung wird neu berechnet …"
// (recomputing). When idle the state is null and the banner disappears.
//
// Plain Notifier — no `@Riverpod` codegen (STATE Plan 01-01 decision).

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The active phase of the one-time global recalc migration.
enum GlobalRecalcPhase {
  /// Re-matching every stored trip against the new matcher.
  rematching,

  /// Rebuilding the coverage cache from the (re-matched) intervals.
  recomputing,
}

/// Immutable snapshot of the global recalc progress.
///
/// [done]/[total] carry a trip count during [GlobalRecalcPhase.rematching]
/// (trip N of M) AND a tile-coarse clip count during
/// [GlobalRecalcPhase.recomputing] (see `CoverageComputeService.recompute`'s
/// `onProgress` — progress cannot cross the isolate boundary per-way, so it
/// counts tiles). When [total] is 0 the banner falls back to an indeterminate
/// indicator with just the phase label; when [total] > 0 it shows a determinate
/// bar at `done/total`.
@immutable
class GlobalRecalcState {
  const GlobalRecalcState({
    required this.phase,
    this.done = 0,
    this.total = 0,
  });

  final GlobalRecalcPhase phase;
  final int done;
  final int total;

  GlobalRecalcState copyWith({
    GlobalRecalcPhase? phase,
    int? done,
    int? total,
  }) {
    return GlobalRecalcState(
      phase: phase ?? this.phase,
      done: done ?? this.done,
      total: total ?? this.total,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GlobalRecalcState &&
      other.phase == phase &&
      other.done == done &&
      other.total == total;

  @override
  int get hashCode => Object.hash(phase, done, total);
}

/// Notifier holding the current [GlobalRecalcState], or null when idle.
///
/// Written by the startup migration in `lib/app.dart`; read by the
/// `GlobalRecalcBanner` on the Map screen.
class GlobalRecalcNotifier extends Notifier<GlobalRecalcState?> {
  @override
  GlobalRecalcState? build() => null;

  /// Enter the re-matching phase with a known trip [total] (done starts at 0).
  void startRematching(int total) {
    state = GlobalRecalcState(
      phase: GlobalRecalcPhase.rematching,
      total: total,
    );
  }

  /// Update the re-matching progress after each trip completes.
  void updateRematching(int done, int total) {
    state = GlobalRecalcState(
      phase: GlobalRecalcPhase.rematching,
      done: done,
      total: total,
    );
  }

  /// Switch to the coverage-recompute phase. Starts indeterminate (total 0);
  /// [updateRecomputing] fills in the tile-coarse done/total as the clip runs.
  void startRecomputing() {
    state = const GlobalRecalcState(phase: GlobalRecalcPhase.recomputing);
  }

  /// Update the coverage-recompute progress as STAGE-1 clips tiles. Ignored if
  /// the phase has since changed (defensive — the migration only calls this
  /// during the recomputing phase). Tile-coarse (see the provider docstring).
  void updateRecomputing(int done, int total) {
    state = GlobalRecalcState(
      phase: GlobalRecalcPhase.recomputing,
      done: done,
      total: total,
    );
  }

  /// Clear the banner — the migration is done (or had nothing to do).
  void clear() {
    state = null;
  }
}

/// Provider exposing the one-time global recalc progress. Null when idle.
final globalRecalcProgressProvider =
    NotifierProvider<GlobalRecalcNotifier, GlobalRecalcState?>(
  GlobalRecalcNotifier.new,
);
