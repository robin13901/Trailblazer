// Trailblazer Phase 10, Plan 10-05:
// RecalculateCoverageAction — orchestrates a full re-match + recompute pass
// over all stored trips (the "Regionen neu berechnen" button).
//
// Pipeline: rematchAllStoredTrips() → recompute()
//   - rematchAllStoredTrips: re-runs the Viterbi matcher over EVERY trip that
//     has stored intervals, replacing them in-place. DOES NOT delete trips.
//   - recompute: rebuilds coverage_cache region rows from existing intervals.
//     Bundled totals (real_total_length_m) are populated inside recompute()
//     from RegionTotalsLookup — no extra Overpass call.
//
// Progress signal: [progressNotifier] exposes a [RecalculateProgress] enum
// so the button widget can render a spinner + "N/M Trips" label.
//
// Error posture: run() never throws. Non-DomainError throwables are wrapped
// via DomainError.wrap; always returns Result<int> (rows written).
//
// Riverpod: plain Provider<RecalculateCoverageAction> (no codegen, STATE 01-01).

import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/features/matching/data/matching_providers.dart';
import 'package:auto_explore/features/matching/data/trip_match_coordinator.dart';
import 'package:auto_explore/features/regions/data/coverage_compute_providers.dart';
import 'package:auto_explore/features/regions/data/coverage_compute_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

// ---------------------------------------------------------------------------
// Progress state
// ---------------------------------------------------------------------------

/// Progress state emitted by [RecalculateCoverageAction] during run().
sealed class RecalculateProgress {
  const RecalculateProgress();
}

/// Not running — ready to accept a new [RecalculateCoverageAction.run] call.
final class RecalculateIdle extends RecalculateProgress {
  const RecalculateIdle();
}

/// Re-matching trips: [done] trips processed so far out of [total].
final class RecalculateRematching extends RecalculateProgress {
  const RecalculateRematching({required this.done, required this.total});
  final int done;
  final int total;
}

/// Rebuilding coverage_cache region rows from the matched intervals.
final class RecalculateRecomputing extends RecalculateProgress {
  const RecalculateRecomputing();
}

/// Successfully completed. [rowsWritten] is the number of coverage_cache rows
/// upserted by the recompute pass.
final class RecalculateDone extends RecalculateProgress {
  const RecalculateDone({required this.rowsWritten});
  final int rowsWritten;
}

/// Finished with an error. Progress is reset to idle after the caller reads.
final class RecalculateError extends RecalculateProgress {
  const RecalculateError({required this.error});
  final DomainError error;
}

// ---------------------------------------------------------------------------
// Action class
// ---------------------------------------------------------------------------

/// Orchestrates the full "Regionen neu berechnen" pipeline:
/// rematchAllStoredTrips → recompute.
///
/// Inject via [recalculateCoverageActionProvider].
class RecalculateCoverageAction {
  RecalculateCoverageAction({
    required TripMatchCoordinator matchCoordinator,
    required CoverageComputeService computeService,
  })  : _matchCoordinator = matchCoordinator,
        _computeService = computeService;

  final TripMatchCoordinator _matchCoordinator;
  final CoverageComputeService _computeService;
  final _log = Logger('RecalculateCoverageAction');

  /// Live progress — the button widget watches this notifier.
  ///
  /// Starts idle. Transitions through [RecalculateRematching] →
  /// [RecalculateRecomputing] → [RecalculateDone] / [RecalculateError].
  final progressNotifier =
      ValueNotifier<RecalculateProgress>(const RecalculateIdle());

  bool _running = false;

  /// Whether the action is currently running. Guards against concurrent calls.
  bool get isRunning => _running;

  /// Execute the full re-match + recompute pass.
  ///
  /// Returns [Ok(rowsWritten)] on success, [Err] on failure.
  /// Never throws. Progress is emitted via [progressNotifier].
  Future<Result<int>> run() async {
    if (_running) {
      _log.warning('run() called while already running — ignoring');
      return const Ok(0);
    }
    _running = true;
    _log.info('RecalculateCoverageAction.run() started');

    try {
      // Phase 1: re-match all stored trips.
      // We don't know the total upfront, so publish rematching(0/0) first.
      progressNotifier.value =
          const RecalculateRematching(done: 0, total: 0);

      final rematched = await _matchCoordinator.rematchAllStoredTrips();
      _log.info(
        'RecalculateCoverageAction: $rematched trips re-matched',
      );
      progressNotifier.value =
          RecalculateRematching(done: rematched, total: rematched);

      // Phase 2: rebuild region rows from the freshly-written intervals.
      progressNotifier.value = const RecalculateRecomputing();
      final recomputeResult = await _computeService.recompute();

      return recomputeResult.when(
        ok: (rowsWritten) {
          _log.info(
            'RecalculateCoverageAction: recompute wrote $rowsWritten rows',
          );
          progressNotifier.value =
              RecalculateDone(rowsWritten: rowsWritten);
          return Ok(rowsWritten);
        },
        err: (error) {
          _log.warning('RecalculateCoverageAction: recompute failed: $error');
          progressNotifier.value = RecalculateError(error: error);
          return Err(error);
        },
      );

      // Catches all throwables (Error + Exception) for DomainError.wrap.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      _log.warning('RecalculateCoverageAction: unexpected error: $e', e, st);
      final error = DomainError.wrap(e, st);
      progressNotifier.value = RecalculateError(error: error);
      return Err(error);
    } finally {
      _running = false;
    }
  }

  /// Reset progress to [RecalculateIdle]. Called by the button after the user
  /// acknowledges a [RecalculateDone] or [RecalculateError] state.
  void reset() {
    if (!_running) {
      progressNotifier.value = const RecalculateIdle();
    }
  }
}

// ---------------------------------------------------------------------------
// Riverpod provider
// ---------------------------------------------------------------------------

/// Singleton [RecalculateCoverageAction] provider (plain Provider, no codegen).
///
/// Wires the match coordinator and compute service from their existing providers.
final recalculateCoverageActionProvider =
    Provider<RecalculateCoverageAction>((ref) {
  return RecalculateCoverageAction(
    matchCoordinator: ref.watch(tripMatchCoordinatorProvider),
    computeService: ref.watch(coverageComputeServiceProvider),
  );
});
