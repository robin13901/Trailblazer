import 'package:auto_explore/features/trips/domain/trip_point.dart';

/// Narrow sink interface for persisting batched trip points.
///
/// Implemented by Plan 03-04's adapter which converts TripPoint →
/// `TripPointsCompanion` and calls `TripsRepository.appendPoints`.
/// This interface lives here (not in the data layer) so the batcher has
/// zero imports from `package:auto_explore/features/trips/data/**`.
// ignore: one_member_abstracts
abstract interface class TripPointsSink {
  Future<void> appendPoints(int tripId, List<TripPoint> points);
}

/// Accumulates [TripPoint] values and flushes them to [TripPointsSink] in
/// batches of [batchSize] (default 20) or on explicit [flush].
///
/// Battery-conscious design: avoids a DB write per GPS fix by coalescing
/// ~20 s of 1 Hz fixes into a single transaction (Plan TRK-08).
class TripFixBatcher {
  TripFixBatcher({
    required this.tripId,
    required this.sink,
    this.batchSize = 20,
  });

  final int tripId;
  final TripPointsSink sink;
  final int batchSize;
  final _pending = <TripPoint>[];

  /// Appends [p] to the pending list and triggers an auto-flush when
  /// [pendingCount] reaches [batchSize].
  Future<void> add(TripPoint p) async {
    _pending.add(p);
    if (_pending.length >= batchSize) await flush();
  }

  /// Sends all pending points to [sink] and clears the buffer.
  /// A no-op if the buffer is already empty.
  Future<void> flush() async {
    if (_pending.isEmpty) return;
    final toSend = List<TripPoint>.of(_pending);
    _pending.clear();
    await sink.appendPoints(tripId, toSend);
  }

  /// Number of points waiting to be flushed.
  int get pendingCount => _pending.length;
}
