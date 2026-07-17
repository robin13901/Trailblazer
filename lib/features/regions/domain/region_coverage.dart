// Trailblazer Phase 8, Plan 08-01 / updated Phase 10, Plan 10-04:
// Immutable per-region coverage value type + coverage-percent math (REG-01).
// Isolate-safe — no dart:io, no Riverpod, no generated code.
// Consumed by the focus pill, region browser cards, and detail sheet.
//
// Plan 10-04: Removed totalPending, progressCellsDone, progressCellsPlanned.
// Totals now come from the bundled region_totals.json.gz table (Decision 8).
// A region's total is either present (from the bundle) or absent ("—"); there
// is no loading/pending state.

import 'package:meta/meta.dart';

/// Coverage % from driven/total lengths, clamped to [0,100].
/// Matches the pattern at lib/features/coverage/domain/coverage_threshold.dart
/// and RESEARCH.md lines 537-542. Returns 0 when total <= 0.
double coveragePercent(double drivenLengthM, double totalLengthM) {
  if (totalLengthM <= 0) return 0;
  return (drivenLengthM / totalLengthM * 100).clamp(0, 100).toDouble();
}

/// One-decimal display string in German format, e.g. "26,4 %".
/// CONTEXT.md line 49: one decimal everywhere (pill, cards, sheet).
/// 2026-07-11: user requested German locale "XX,X %" — comma decimal and a
/// space before the percent sign.
String formatPercent(double percent) => '${oneDecimalDe(percent)} %';

/// One-decimal number in German format, e.g. 26.4 -> "26,4". Shared by the
/// percent label and the km stats so the whole region UI reads German-locale.
String oneDecimalDe(double value) => value.toStringAsFixed(1).replaceAll('.', ',');

/// Formats a kilometre value in German locale with a dynamic precision rule
/// (user request 2026-07-17):
///   - `< 1000`: one decimal, comma decimal separator, e.g. 950.3 -> "950,3".
///   - `>= 1000`: no decimals, dot thousands separators, e.g. 148884 -> "148.884".
/// The threshold is evaluated on the raw value; the two branches never mix a
/// decimal with a thousands separator.
String formatKm(double km) {
  if (km < 1000) return oneDecimalDe(km);
  // Round to a whole number, then group thousands with dots. Regex inserts a
  // dot before every run of 3 digits that is followed by another group of 3.
  final whole = km.round().toString();
  return whole.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => '.',
  );
}

/// Formatted "driven / total km" string in German format. Each value uses the
/// dynamic [formatKm] precision rule, e.g. "3,2 / 32,9 km" or "1.234 / 148.884 km".
String formatKmStats(double drivenKm, double totalKm) =>
    '${formatKm(drivenKm)} / ${formatKm(totalKm)} km';

/// Immutable per-region coverage snapshot. `osmId` is the OSM relation id
/// (coverage_cache.region_id == osmId.toString(); RESEARCH.md line 218,
/// globally unique across admin levels so NO level prefix — line 491).
///
/// Totals come from the bundled region_totals.json.gz table (Plan 10-04,
/// Decision 8). A region's [totalLengthM] is either the bundled real total
/// or the haversine fallback; there is no pending/spinner state.
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
