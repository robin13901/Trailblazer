// Phase 5 (Plan 05-06): Sendable payloads for the matcher isolate.
//
// Every field on MatchJob / MatchJobReply must be trivially copyable
// across an isolate boundary via SendPort — primitives, DateTime, and
// plain Dart classes containing only those (no closures, no futures,
// no Drift types).
//
// WayCandidate uses LatLng from maplibre_gl (plain 2-double class) and
// primitive/enum fields — Sendable.
// GpsFix uses double + DateTime fields — Sendable.

import 'package:auto_explore/features/matching/domain/gps_fix.dart';
import 'package:auto_explore/features/matching/domain/match_result.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:meta/meta.dart';

/// Payload sent from the main isolate to the worker for one matching job.
///
/// All fields are trivially Sendable across the isolate boundary:
/// - [jobSeq]: int correlation key.
/// - [tripId]: int trip identifier (also used as cancel key).
/// - [fixes]: `List<GpsFix>` — each GpsFix holds only `double` + `DateTime`.
/// - [ways]: `List<WayCandidate>` — each WayCandidate holds ints, Strings,
///   enums, and `List<LatLng>` (2 doubles per entry). No closures, no Futures,
///   no Drift objects.
@immutable
class MatchJob {
  const MatchJob({
    required this.jobSeq,
    required this.tripId,
    required this.fixes,
    required this.ways,
  });

  /// Monotonically-increasing sequence number assigned by `MatcherIsolate`.
  /// Correlates this job with its [MatchJobReply] on the main side.
  final int jobSeq;

  /// Trip identifier. Used by `MatcherIsolate.cancel` to cancel in-flight
  /// or pending jobs for a specific trip.
  final int tripId;

  /// GPS observations to match. Each [GpsFix] contains only `double` and
  /// `DateTime` fields — safe to copy across isolate boundaries.
  final List<GpsFix> fixes;

  /// Road candidates in the vicinity of the trip. Each [WayCandidate] holds
  /// ints, Strings, `OnewayDirection` enum, and `List<LatLng>` — all
  /// Sendable.
  final List<WayCandidate> ways;
}

/// Progress update sent back from the worker isolate to the main isolate
/// while a matching job is in flight.
///
/// Flows on the SAME `mainPort` as [MatchJobReply]; the main-side listener
/// discriminates on runtime type. All fields are primitives — trivially
/// Sendable across the isolate boundary (no closures, no Futures, no Drift
/// objects).
///
/// A job may emit zero or more [MatchJobProgress] messages before its single
/// terminal [MatchJobReply]. `processed` is monotonically increasing and
/// `processed <= total`; the final in-flight update satisfies
/// `processed == total`.
@immutable
class MatchJobProgress {
  const MatchJobProgress({
    required this.jobSeq,
    required this.processed,
    required this.total,
  });

  /// Sequence number of the [MatchJob] this progress belongs to. Correlates
  /// the update with the caller-supplied `onProgress` callback on the main
  /// side.
  final int jobSeq;

  /// Number of fixes processed so far (1-based, `<= total`).
  final int processed;

  /// Total number of fixes in the job (`fixes.length`).
  final int total;
}

/// Reply sent back from the worker isolate to the main isolate for one job.
@immutable
class MatchJobReply {
  const MatchJobReply({
    required this.jobSeq,
    this.result,
    this.error,
    this.cancelled = false,
  });

  /// Sequence number echoed from the originating `MatchJob`. Used by
  /// `MatcherIsolate` to find and complete the correct `Completer`.
  final int jobSeq;

  /// Non-null when the job completed successfully.
  final MatchResult? result;

  /// Non-null when the job threw an unexpected error.
  final Object? error;

  /// True when the job was cancelled via `MatcherIsolate.cancel` before the
  /// worker started processing it (v1 pre-job-start cancellation only).
  final bool cancelled;
}

/// Thrown (as the completer error) when a job is cancelled.
///
/// This is NOT a `DomainError` — it is a control-flow signal, not a domain
/// failure. The coordinator (Plan 05-07) may wrap it into a `DomainError`
/// at the `Result<T>` boundary if it decides that a cancelled match is an
/// error from the caller's perspective.
class MatcherCancelledException implements Exception {
  const MatcherCancelledException(this.tripId);

  /// The trip id for which matching was cancelled.
  final int tripId;

  @override
  String toString() => 'MatcherCancelledException(tripId=$tripId)';
}
