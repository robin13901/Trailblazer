// Trailblazer Phase 7, Plan 07-01:
// Immutable per-way coverage value carrying a coverage fraction [0,1] and
// an isFull flag. Isolate-safe — no dart:io, no Riverpod, no generated code.
// Produced by classifyCoverage() in coverage_threshold.dart.

import 'package:meta/meta.dart';

/// Immutable coverage snapshot for a single OSM way.
///
/// [fraction] is clamped to [0.0, 1.0] — the ratio of driven union-length
/// to way total length. [isFull] is true when the union-length meets or
/// exceeds the fully-explored threshold (see `isFullyCovered` in
/// coverage_threshold.dart).
///
/// A [fraction] of exactly 0.0 with [isFull] false means either undriven or
/// below the partial minimum floor — both render as base-map default.
@immutable
class CoverageDatum {
  const CoverageDatum({
    required this.fraction,
    required this.isFull,
  });

  /// Convenience constructor for an undriven or below-floor way.
  const CoverageDatum.undriven()
      : fraction = 0.0,
        isFull = false;

  /// Coverage fraction in [0.0, 1.0].
  final double fraction;

  /// True when the union-length meets the fully-explored threshold.
  final bool isFull;

  @override
  bool operator ==(Object other) =>
      other is CoverageDatum &&
      other.fraction == fraction &&
      other.isFull == isFull;

  @override
  int get hashCode => Object.hash(fraction, isFull);

  @override
  String toString() => 'CoverageDatum(fraction: $fraction, isFull: $isFull)';
}
