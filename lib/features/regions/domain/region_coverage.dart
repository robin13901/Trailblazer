// Trailblazer Phase 8, Plan 08-01:
// Immutable per-region coverage value type + coverage-percent math (REG-01).
// Isolate-safe — no dart:io, no Riverpod, no generated code.
// Consumed by the focus pill, region browser cards, and detail sheet.

import 'package:meta/meta.dart';

/// Coverage % from driven/total lengths, clamped to [0,100].
/// Matches the pattern at lib/features/coverage/domain/coverage_threshold.dart
/// and RESEARCH.md lines 537-542. Returns 0 when total <= 0.
double coveragePercent(double drivenLengthM, double totalLengthM) {
  if (totalLengthM <= 0) return 0;
  return (drivenLengthM / totalLengthM * 100).clamp(0, 100).toDouble();
}

/// One-decimal display string, e.g. "26.4%". CONTEXT.md line 49: one decimal
/// everywhere (pill, cards, sheet).
String formatPercent(double percent) => '${percent.toStringAsFixed(1)}%';

/// Immutable per-region coverage snapshot. `osmId` is the OSM relation id
/// (coverage_cache.region_id == osmId.toString(); RESEARCH.md line 218,
/// globally unique across admin levels so NO level prefix — line 491).
@immutable
class RegionCoverage {
  const RegionCoverage({
    required this.osmId,
    required this.adminLevel,
    required this.name,
    required this.drivenLengthM,
    required this.totalLengthM,
  });

  final int osmId;
  final int adminLevel;
  final String name;
  final double drivenLengthM;
  final double totalLengthM;

  double get percent => coveragePercent(drivenLengthM, totalLengthM);
  String get percentLabel => formatPercent(percent);

  /// Driven kilometres, one decimal (CONTEXT.md line 50 — driven km + total km).
  double get drivenKm => drivenLengthM / 1000.0;
  double get totalKm => totalLengthM / 1000.0;

  @override
  bool operator ==(Object other) =>
      other is RegionCoverage &&
      other.osmId == osmId &&
      other.drivenLengthM == drivenLengthM &&
      other.totalLengthM == totalLengthM;

  @override
  int get hashCode => Object.hash(osmId, drivenLengthM, totalLengthM);
}
