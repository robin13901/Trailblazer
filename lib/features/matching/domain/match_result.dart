// Phase 5 (Plan 05-05): MatchResult — full output of one HmmMatcher run.

import 'package:auto_explore/features/matching/domain/driven_way_interval_draft.dart';
import 'package:auto_explore/features/matching/domain/matched_step.dart';
import 'package:meta/meta.dart';

/// Full result of a single `HmmMatcher.match` call.
///
/// Contains both the per-fix Viterbi decisions ([steps]) for debugging and
/// the collapsed [intervals] ready for the DAO (after the coordinator adds
/// a `tripId`).
@immutable
class MatchResult {
  const MatchResult({
    required this.steps,
    required this.intervals,
    required this.matchedFixCount,
    required this.droppedFixCount,
  });

  /// Per-fix Viterbi decisions. Same length as the input fix list.
  /// `null` entries correspond to fixes that fell below the low-confidence
  /// drop threshold (MMT-05 — unmatched fixes are dropped, not force-snapped).
  final List<MatchedStep?> steps;

  /// Merged driven-way intervals, ready for the DAO once the coordinator
  /// (Plan 05-07) attaches a `tripId`.
  final List<DrivenWayIntervalDraft> intervals;

  /// Number of fixes that received a non-null [MatchedStep].
  final int matchedFixCount;

  /// Number of fixes that yielded `null` (below confidence threshold or
  /// no candidates found within the adaptive search radius).
  final int droppedFixCount;

  /// True when the input fix list was empty.
  bool get isEmpty => steps.isEmpty;

  @override
  String toString() =>
      'MatchResult(matched=$matchedFixCount, dropped=$droppedFixCount, '
      'intervals=${intervals.length})';
}
