// Trailblazer Phase 6, Plan 06-01 (Wave 1 Task 1):
// Pure-Dart sweep-line union over half-open `[startMeters, endMeters)`
// intervals along a way. Drift-free and isolate-safe — no `dart:io`,
// no Riverpod, no generated code. Consumed by the coverage invalidation
// pipeline (this plan) and by the Phase-8 coverage-recompute pass.

import 'dart:math' as math;

import 'package:meta/meta.dart';

/// A single half-open interval `[startMeters, endMeters)` along a way.
///
/// Endpoint equality is deliberately allowed (`endMeters >= startMeters`)
/// so that a zero-length "point" interval survives round-trips through
/// the union pipeline; downstream length arithmetic degenerates to 0 as
/// expected.
@immutable
class Interval {
  const Interval(this.startMeters, this.endMeters)
      : assert(
          endMeters >= startMeters,
          'endMeters must be >= startMeters',
        );

  final double startMeters;
  final double endMeters;

  double get lengthMeters => endMeters - startMeters;

  @override
  bool operator ==(Object other) =>
      other is Interval &&
      other.startMeters == startMeters &&
      other.endMeters == endMeters;

  @override
  int get hashCode => Object.hash(startMeters, endMeters);

  @override
  String toString() => 'Interval($startMeters, $endMeters)';
}

/// Collapse overlapping and adjacent intervals into disjoint unions.
///
/// The returned list is sorted by [Interval.startMeters] ascending. The
/// input iterable is not mutated. Adjacent intervals (a.end == b.start)
/// are merged as a belt-and-suspenders guard against float-precision
/// noise on driven-way-interval sums.
List<Interval> unionIntervals(Iterable<Interval> intervals) {
  final sorted = intervals.toList()
    ..sort((a, b) => a.startMeters.compareTo(b.startMeters));
  if (sorted.isEmpty) return const [];

  final merged = <Interval>[sorted.first];
  for (var i = 1; i < sorted.length; i++) {
    final current = sorted[i];
    final last = merged.last;
    if (current.startMeters > last.endMeters) {
      merged.add(current);
    } else {
      merged[merged.length - 1] = Interval(
        last.startMeters,
        math.max(last.endMeters, current.endMeters),
      );
    }
  }
  return merged;
}

/// Sum of lengths of the disjoint union of [intervals]. Returns 0 for
/// an empty input.
double drivenLengthMeters(Iterable<Interval> intervals) {
  final merged = unionIntervals(intervals);
  var total = 0.0;
  for (final iv in merged) {
    total += iv.lengthMeters;
  }
  return total;
}
