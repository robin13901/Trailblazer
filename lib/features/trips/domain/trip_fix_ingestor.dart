import 'dart:math' as math;

import 'package:auto_explore/features/trips/domain/haversine.dart';
import 'package:auto_explore/features/trips/domain/trip_fix_input.dart';

// ---------------------------------------------------------------------------
// IngestorOutcome sealed hierarchy
// ---------------------------------------------------------------------------

/// Result of feeding one [FixInput] to [TripFixIngestor.ingest].
sealed class IngestorOutcome {
  const IngestorOutcome();
}

/// The fix was valid and accepted into the running trip.
final class FixAccepted extends IngestorOutcome {
  const FixAccepted({
    required this.lat,
    required this.lon,
    required this.ts,
    required this.speedKmh,
    required this.accuracyMeters,
    this.altitudeMeters,
    this.motionType,
  });

  final double lat;
  final double lon;
  final DateTime ts;
  final double speedKmh;
  final double accuracyMeters;
  final double? altitudeMeters;
  final String? motionType;
}

/// The fix was rejected.
///
/// [reason] is one of: `'accuracy'` (horizontalAccuracy > threshold),
/// `'rate_limit'` (arrived too soon after last accepted), `'duplicate'`
/// (UUID already seen).
final class FixRejected extends IngestorOutcome {
  const FixRejected(this.reason);

  final String reason;
}

/// A recording gap longer than [TripFixIngestor.gap] was detected, but the
/// recovered fix is within [TripFixIngestor.splitDistanceMeters] — the trip
/// continues. The fix that closed the gap has already been accepted into the
/// running totals; subsequent [FixAccepted] will follow on the next calls.
final class GapObserved extends IngestorOutcome {
  const GapObserved(this.gapStart, this.gapEnd);

  final DateTime gapStart;
  final DateTime gapEnd;
}

/// A gap longer than [TripFixIngestor.gap] AND the recovered fix is more
/// than [TripFixIngestor.splitDistanceMeters] away. The caller must end the
/// current trip and start a new one, feeding [recovered] as its first fix.
/// The ingestor's internal state is NOT updated from [recovered] — the
/// caller should instantiate a fresh [TripFixIngestor] and feed it.
final class SplitRequired extends IngestorOutcome {
  const SplitRequired(this.recovered);

  final FixAccepted recovered;
}

// ---------------------------------------------------------------------------
// TripSummaryDraft — finalize() output
// ---------------------------------------------------------------------------

/// Draft summary computed by [TripFixIngestor.finalize].
///
/// This is intentionally NOT the same as Plan 03-01's repository-facing
/// `TripSummary` (which adds `autoStopped` and other persistence fields).
/// Wave 2's tracking service combines [TripSummaryDraft] with the
/// auto/manual flag to construct the repository record.
class TripSummaryDraft {
  const TripSummaryDraft({
    required this.pointCount,
    required this.startedAt,
    required this.endedAt,
    required this.durationSeconds,
    required this.distanceMeters,
    required this.avgSpeedKmh,
    required this.maxSpeedKmh,
    required this.bboxMinLat,
    required this.bboxMinLon,
    required this.bboxMaxLat,
    required this.bboxMaxLon,
    required this.passesKeeperThreshold,
  });

  final int pointCount;
  final DateTime startedAt;
  final DateTime endedAt;
  final int durationSeconds;
  final double distanceMeters;
  final double avgSpeedKmh;
  final double maxSpeedKmh;
  final double bboxMinLat;
  final double bboxMinLon;
  final double bboxMaxLat;
  final double bboxMaxLon;

  /// False when the trip is a micro-trip that should be discarded:
  /// duration < 60 s OR distance < 100 m OR bbox diagonal < 50 m.
  final bool passesKeeperThreshold;
}

// ---------------------------------------------------------------------------
// TripFixIngestor
// ---------------------------------------------------------------------------

/// Pure-Dart fix pipeline: accuracy filter → de-duplication → 1 Hz rate
/// limiter → gap / split detector → running-stat accumulator.
///
/// Has **zero** dependency on FGB types or Drift types. All inputs arrive
/// as [FixInput]; the caller converts from `bg.Location` (Wave 2).
class TripFixIngestor {
  TripFixIngestor({
    this.maxAccuracyMeters = 25,
    this.minFixIntervalMs = 900,
    Duration? gap,
    this.splitDistanceMeters = 500,
    this.keeperMinSeconds = 60,
    this.keeperMinDistanceMeters = 100,
    this.keeperMinBboxDiagonalMeters = 50,
  }) : gap = gap ?? const Duration(minutes: 5);

  /// Fixes with horizontalAccuracy > this value are rejected as 'accuracy'.
  final double maxAccuracyMeters;

  /// Minimum milliseconds between two accepted fixes (1 Hz = 1000 ms, with
  /// 100 ms tolerance → 900 ms).
  final int minFixIntervalMs;

  /// Gaps longer than this trigger gap/split detection.
  final Duration gap;

  /// If a gap-recovered fix is more than this many meters from the last
  /// accepted fix, [SplitRequired] is emitted.
  final double splitDistanceMeters;

  final int keeperMinSeconds;
  final double keeperMinDistanceMeters;
  final double keeperMinBboxDiagonalMeters;

  // Internal state
  FixAccepted? _lastAccepted;
  int _pointCount = 0;
  double _totalDistanceMeters = 0;
  int _gapSecondsAccumulated = 0;
  double _maxSpeedKmh = 0;

  // Bounding box (only valid when _pointCount > 0)
  double _bboxMinLat = double.infinity;
  double _bboxMinLon = double.infinity;
  double _bboxMaxLat = double.negativeInfinity;
  double _bboxMaxLon = double.negativeInfinity;

  // Bounded ring-buffer of last 100 UUIDs for de-duplication
  final _seenUuids = <String>[];
  static const _maxSeenUuids = 100;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Process one GPS fix. Returns an [IngestorOutcome] describing what
  /// happened. Rules applied in order:
  ///
  /// 1. De-duplication (UUID)
  /// 2. Accuracy filter
  /// 3. 1 Hz rate limit
  /// 4. Gap / split detection
  /// 5. Accept and update running stats
  IngestorOutcome ingest(FixInput input) {
    // 1. De-duplication
    if (input.uuid != null && _seenUuids.contains(input.uuid)) {
      return const FixRejected('duplicate');
    }

    // 2. Accuracy filter
    if (input.accuracyMeters > maxAccuracyMeters) {
      return const FixRejected('accuracy');
    }

    // 3. Rate limit
    final last = _lastAccepted;
    if (last != null) {
      final dtMs = input.ts.difference(last.ts).inMilliseconds;
      if (dtMs < minFixIntervalMs) {
        return const FixRejected('rate_limit');
      }
    }

    // 4. Gap / split detection
    if (last != null) {
      final dt = input.ts.difference(last.ts);
      if (dt > gap) {
        final distToRecovered =
            haversineMeters(last.lat, last.lon, input.lat, input.lon);

        // Build the FixAccepted for the recovered point (used in both branches)
        final recovered = _buildAccepted(input, last, dt.inSeconds.toDouble());

        if (distToRecovered > splitDistanceMeters) {
          // Do NOT update internal state — caller opens a new trip
          return SplitRequired(recovered);
        }

        // Gap but no split — accept the fix, accumulate gap time
        final gapSecs = dt.inSeconds - 1;
        if (gapSecs > 0) _gapSecondsAccumulated += gapSecs;
        final gapStart = last.ts;
        _acceptFix(input, recovered);
        return GapObserved(gapStart, input.ts);
      }
    }

    // 5. Accept
    final dtSeconds =
        last != null ? input.ts.difference(last.ts).inSeconds.toDouble() : 0.0;
    final accepted = _buildAccepted(input, last, dtSeconds);
    _acceptFix(input, accepted);
    return accepted;
  }

  /// Compute and return the trip summary. Returns `null` if no fixes were
  /// ever accepted.
  TripSummaryDraft? finalize({required DateTime startedAt}) {
    if (_pointCount == 0) return null;
    final last = _lastAccepted!;

    final rawDurationS =
        last.ts.difference(startedAt).inSeconds - _gapSecondsAccumulated;
    final durationSeconds = math.max(0, rawDurationS);

    final avgSpeedKmh =
        _totalDistanceMeters / math.max(durationSeconds, 1) * 3.6;

    final bboxDiagonal = haversineMeters(
      _bboxMinLat,
      _bboxMinLon,
      _bboxMaxLat,
      _bboxMaxLon,
    );

    final passes = !(durationSeconds < keeperMinSeconds ||
        _totalDistanceMeters < keeperMinDistanceMeters ||
        bboxDiagonal < keeperMinBboxDiagonalMeters);

    return TripSummaryDraft(
      pointCount: _pointCount,
      startedAt: startedAt,
      endedAt: last.ts,
      durationSeconds: durationSeconds,
      distanceMeters: _totalDistanceMeters,
      avgSpeedKmh: avgSpeedKmh,
      maxSpeedKmh: _maxSpeedKmh,
      bboxMinLat: _bboxMinLat,
      bboxMinLon: _bboxMinLon,
      bboxMaxLat: _bboxMaxLat,
      bboxMaxLon: _bboxMaxLon,
      passesKeeperThreshold: passes,
    );
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Build a [FixAccepted] without updating internal state.
  FixAccepted _buildAccepted(
    FixInput input,
    FixAccepted? prev,
    double dtSeconds,
  ) {
    double speedKmh;
    if (input.speedMps != null && input.speedMps! >= 0) {
      speedKmh = input.speedMps! * 3.6;
    } else if (prev != null && dtSeconds > 0) {
      final dist = haversineMeters(prev.lat, prev.lon, input.lat, input.lon);
      speedKmh = dist / dtSeconds * 3.6;
    } else {
      speedKmh = 0;
    }
    return FixAccepted(
      lat: input.lat,
      lon: input.lon,
      ts: input.ts,
      speedKmh: speedKmh,
      accuracyMeters: input.accuracyMeters,
      altitudeMeters: input.altitudeMeters,
      motionType: input.activityType,
    );
  }

  /// Update all running-stat fields and advance [_lastAccepted].
  void _acceptFix(FixInput input, FixAccepted accepted) {
    // UUID ring buffer
    if (input.uuid != null) {
      _seenUuids.add(input.uuid!);
      if (_seenUuids.length > _maxSeenUuids) _seenUuids.removeAt(0);
    }

    // Distance from previous
    if (_lastAccepted != null) {
      _totalDistanceMeters += haversineMeters(
        _lastAccepted!.lat,
        _lastAccepted!.lon,
        input.lat,
        input.lon,
      );
    }

    // Bounding box
    _bboxMinLat = math.min(_bboxMinLat, input.lat);
    _bboxMinLon = math.min(_bboxMinLon, input.lon);
    _bboxMaxLat = math.max(_bboxMaxLat, input.lat);
    _bboxMaxLon = math.max(_bboxMaxLon, input.lon);

    // Speed
    if (accepted.speedKmh > _maxSpeedKmh) _maxSpeedKmh = accepted.speedKmh;

    _pointCount++;
    _lastAccepted = accepted;
  }
}
