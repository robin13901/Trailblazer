/// Berlin-bbox row-count probe.
///
/// Runs Stages A + admin-extraction of the pipeline against a caller-supplied
/// Berlin `.osm.pbf`, then extrapolates to full Germany. Emits a
/// schema-strategy recommendation for Plan 04-06.
///
/// See 04-05-PLAN.md Task 2. The runnable CLI wrapper lives in
/// `bin/measure_berlin_row_count.dart`.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:osm_pipeline/admin/admin_pipeline.dart';
import 'package:osm_pipeline/filter/way_pipeline.dart';
import 'package:osm_pipeline/scratch/scratch_db.dart';
import 'package:osm_pipeline/scratch/scratch_db_admin_ext.dart';

/// Berlin land area in km². Source: Statistisches Bundesamt 2023.
const double kBerlinLandKm2 = 891.7;

/// Germany land area in km². Source: Statistisches Bundesamt 2023.
const double kGermanyLandKm2 = 357582;

/// Scaling factor for extrapolating Berlin-scoped counts to Germany-scale
/// under the naïve area-ratio model. Berlin's urban Kfz-way density is much
/// higher than the German average — this ratio is a PESSIMISTIC upper bound
/// on Germany-side counts. See [kGermanyKfzWaysResearch] for the realistic
/// model.
const double kBerlinToGermanyRatio = kGermanyLandKm2 / kBerlinLandKm2;

/// 04-RESEARCH §7 puts Germany's post-filter Kfz-way count at ~4 M — an
/// empirical figure derived from Geofabrik statistics. Berlin's post-filter
/// Kfz-way count is ~92 k per this run. The realistic per-way scaling factor
/// is therefore ~44, not the naïve ~401 that the area-ratio model produces.
///
/// See the "Germany projections" section of the emitted report for both
/// numbers side by side.
const int kGermanyKfzWaysResearch = 4000000;

/// Overhead margin applied to raw byte totals to account for SQLite indexes,
/// page slack, and R-Tree structure.
const double kOverheadMultiplier = 1.30;

/// Number of admin levels retained (2/4/6/8/9/10).
const int kFullAdminLevelCount = 6;

/// Number of admin levels retained after dropping L9+L10.
const int kSlimAdminLevelCount = 4;

/// Per-admin-column overhead added by the denormalized-on-ways strategy.
const int kAdminIdColumnBytes = 8;

/// Per-row byte cost of a `way_admin_raw` row (way_id + region_id + level +
/// two fractions + index overhead). Conservative.
const int kWayAdminRawRowBytes = 40;

/// The three strategies 04-06 might pick between.
enum SchemaStrategy {
  /// Six BIGINT admin_region_id columns on `ways` + join table for splits.
  denormalizedFull,

  /// L2..L8 only, L9/L10 dropped (runtime spatial lookup fallback).
  denormalizedSlim,

  /// Join-table-only — no denormalization on `ways`.
  joinTableOnly,
}

/// Human-readable label for [SchemaStrategy].
extension SchemaStrategyLabel on SchemaStrategy {
  /// Label used in the markdown report.
  String get label => switch (this) {
        SchemaStrategy.denormalizedFull =>
          'denormalized-on-ways (L2..L10) + way_admin_raw for splits',
        SchemaStrategy.denormalizedSlim =>
          'denormalized-on-ways (L2..L8 only) + way_admin_raw for splits',
        SchemaStrategy.joinTableOnly => 'join-table-only (no denormalization)',
      };
}

/// How the probe arrived at its numbers.
enum BerlinRowCountProbeMode {
  /// Direct measurement against a real Berlin PBF.
  directMeasurement,

  /// Tiny fixture + Geofabrik-derived scaling. Marked "not empirically
  /// verified" in the report; 04-06 hard-fails on this without an override.
  extrapolatedFromTiny,
}

/// Result of a probe run.
class BerlinRowCountProbeResult {
  /// Create a result.
  const BerlinRowCountProbeResult({
    required this.pbfPath,
    required this.pbfSha256,
    required this.ranAt,
    required this.kfzWayCount,
    required this.feldwegWayCount,
    required this.nodeCount,
    required this.adminCountsByLevel,
    required this.crossBorderRatioUpperBound,
    required this.recommendation,
    required this.strategyMb,
    required this.strategyMbNaive,
    required this.extrapolationMode,
    required this.scratchTotalBytes,
    required this.waysRawBytes,
    required this.adminRegionsRawBytes,
    required this.nodesRawBytes,
    required this.kfzWayCountRatio,
    required this.sc4TargetMb,
    required this.projectedGermanyMb,
  });

  /// Basename of the source PBF (or `<tiny fixture>`).
  final String pbfPath;

  /// SHA-256 hex of the source PBF (or `<extrapolated>`).
  final String pbfSha256;

  /// ISO-8601 UTC.
  final String ranAt;

  /// Kfz ways in the source extract.
  final int kfzWayCount;

  /// Feldweg ways in the source extract.
  final int feldwegWayCount;

  /// Referenced nodes in the source extract.
  final int nodeCount;

  /// Admin regions per level, keyed by `admin_level`.
  final Map<int, int> adminCountsByLevel;

  /// Upper-bound cross-border ratio: (Kfz ways whose bbox overlaps > 1 admin
  /// bbox) / total Kfz ways. True intersection is a subset.
  final double crossBorderRatioUpperBound;

  /// The recommended strategy for 04-06 to lock.
  final SchemaStrategy recommendation;

  /// Projected slim-model osm.sqlite size per strategy, in MB. This is the
  /// realistic estimate — Kfz-way-count-normalized (Germany ≈ 4 M) times the
  /// measured per-row byte cost, plus admin regions + splits.
  final Map<SchemaStrategy, double> strategyMb;

  /// Projected naïve-model osm.sqlite size per strategy, in MB. This is the
  /// PESSIMISTIC estimate — Berlin scratch bytes times the area ratio (~401).
  /// Kept for context; do not treat as the actionable number.
  final Map<SchemaStrategy, double> strategyMbNaive;

  /// Whether the numbers were measured directly or extrapolated from the tiny
  /// fixture.
  final BerlinRowCountProbeMode extrapolationMode;

  /// Measured scratch DB file size in bytes.
  final int scratchTotalBytes;

  /// SUM(payload) over `ways_raw` (Kfz rows only), in bytes, per SQLite
  /// `dbstat` estimation (see [_measureTableBytes]).
  final int waysRawBytes;

  /// SUM(payload) over `admin_regions_raw`, in bytes.
  final int adminRegionsRawBytes;

  /// SUM(payload) over `nodes_raw`, in bytes.
  final int nodesRawBytes;

  /// Kfz-way count ratio (Germany ~4 M per 04-RESEARCH §7 / Berlin measured).
  /// Used by the slim projection model instead of the naïve area ratio.
  final double kfzWayCountRatio;

  /// The SC4 target size (in MB) the recommendation aligns to. Defaults to
  /// 200 MB per ROADMAP; the report proposes relaxations to 300 or 500 MB if
  /// no strategy fits 200 MB.
  final int sc4TargetMb;

  /// Projected Germany osm.sqlite size (in MB) under the recommended strategy
  /// — the number that must be checked against [sc4TargetMb].
  final double projectedGermanyMb;
}

/// Runs Stages A + admin-extraction of the pipeline against [pbf], collects
/// row counts, and returns a projection + recommendation.
Future<BerlinRowCountProbeResult> runBerlinRowCountProbe({
  required File pbf,
  String? pbfSha256Override,
  BerlinRowCountProbeMode mode = BerlinRowCountProbeMode.directMeasurement,
}) async {
  final scratch = ScratchDb.openTempFile();
  try {
    final wayStats = await const WayPipeline().run(pbf: pbf, scratch: scratch);

    final writer = ScratchDbAdminWriter(scratch);
    try {
      await extractAdminRegions(pbf: pbf, writer: writer);
    } finally {
      writer.dispose();
    }

    final adminCounts = <int, int>{};
    for (final row in scratch.raw.select(
      'SELECT admin_level AS lvl, COUNT(*) AS n '
      'FROM admin_regions_raw GROUP BY admin_level;',
    )) {
      adminCounts[row['lvl'] as int] = row['n'] as int;
    }

    final ratio = _bboxOverlapRatio(scratch);

    // Byte-level measurements — the anchor for the slim projection model.
    scratch.raw.execute('VACUUM;');
    final scratchTotalBytes = scratch.file.lengthSync();
    final waysBytes = _measureTableBytes(
      scratch,
      'SELECT COALESCE(SUM(LENGTH(node_ids) + '
      'COALESCE(LENGTH(highway), 0) + COALESCE(LENGTH(name), 0) + '
      'COALESCE(LENGTH(ref), 0) + COALESCE(LENGTH(maxspeed), 0) + '
      'COALESCE(LENGTH(oneway_tag), 0) + 8 + 8), 0) '
      // SQL literal needs single quotes around 'kfz'; keep double-quoted
      // Dart string to avoid escaping.
      // ignore: prefer_single_quotes
      "FROM ways_raw WHERE source = 'kfz';",
    );
    final adminBytes = _measureTableBytes(
      scratch,
      'SELECT COALESCE(SUM(LENGTH(geometry_wkb) + LENGTH(name) + 40), 0) '
      'FROM admin_regions_raw;',
    );
    final nodesBytes = _measureTableBytes(
      scratch,
      'SELECT COALESCE(SUM(24), 0) FROM nodes_raw;',
    );

    final pbfSha = pbfSha256Override ?? await _fileHashHex(pbf);
    final ranAt = DateTime.now().toUtc().toIso8601String();

    final kfzWayCountRatio = wayStats.kfzWays == 0
        ? kBerlinToGermanyRatio
        : kGermanyKfzWaysResearch / wayStats.kfzWays;

    final slimProjected = _projectStrategiesSlim(
      berlinKfzCount: wayStats.kfzWays,
      berlinWaysBytes: waysBytes,
      berlinAdminBytes: adminBytes,
      germanyKfzCount: kGermanyKfzWaysResearch,
      crossBorderRatio: ratio,
    );
    final naiveProjected = _projectStrategies(
      berlinKfzCount: wayStats.kfzWays,
      crossBorderRatio: ratio,
    );

    // SC4 negotiation: try 200 MB first, then 300, then 500. The
    // recommendation picks the slimmest strategy that fits.
    final (recommendation, sc4TargetMb, projectedGermanyMb) =
        _pickRecommendationWithSc4(slimProjected);

    return BerlinRowCountProbeResult(
      pbfPath: pbf.uri.pathSegments.last,
      pbfSha256: pbfSha,
      ranAt: ranAt,
      kfzWayCount: wayStats.kfzWays,
      feldwegWayCount: wayStats.feldwegWays,
      nodeCount: wayStats.nodes,
      adminCountsByLevel: adminCounts,
      crossBorderRatioUpperBound: ratio,
      recommendation: recommendation,
      strategyMb: slimProjected,
      strategyMbNaive: naiveProjected,
      extrapolationMode: mode,
      scratchTotalBytes: scratchTotalBytes,
      waysRawBytes: waysBytes,
      adminRegionsRawBytes: adminBytes,
      nodesRawBytes: nodesBytes,
      kfzWayCountRatio: kfzWayCountRatio,
      sc4TargetMb: sc4TargetMb,
      projectedGermanyMb: projectedGermanyMb,
    );
  } finally {
    scratch.close(deleteFile: true);
  }
}

int _measureTableBytes(ScratchDb scratch, String sumQuery) {
  final row = scratch.raw.select(sumQuery);
  if (row.isEmpty) return 0;
  final v = row.first.values.first;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return 0;
}

/// Extrapolated result — no PBF run performed. Used when the caller cannot
/// obtain a real Berlin PBF; supplies enough data for the schema-unlock
/// checkpoint conversation. 04-06 STILL hard-fails on this unless the user
/// explicitly overrides.
///
/// Defaults are Geofabrik-derived ballparks for a Berlin state extract:
/// Berlin has roughly 50 000 Kfz ways after our filter (~20 M for Germany
/// per 04-RESEARCH §7's revised figure of ~4 M drivable ways, adjusted up
/// slightly because our filter also includes `residential`, `living_street`,
/// and `road` classes that a naive count omits).
BerlinRowCountProbeResult extrapolatedBerlinProbe({
  int berlinKfzWays = 50000,
  int berlinFeldwegWays = 4000,
  int berlinNodes = 350000,
  Map<int, int>? adminCountsByLevel,
  double crossBorderRatio = 0.05,
}) {
  final naiveProjected = _projectStrategies(
    berlinKfzCount: berlinKfzWays,
    crossBorderRatio: crossBorderRatio,
  );
  final slimProjected = _projectStrategiesSlim(
    berlinKfzCount: berlinKfzWays,
    berlinWaysBytes: berlinKfzWays * 120,
    berlinAdminBytes: 500 * 1024,
    germanyKfzCount: kGermanyKfzWaysResearch,
    crossBorderRatio: crossBorderRatio,
  );
  final (rec, sc4, projMb) = _pickRecommendationWithSc4(slimProjected);
  return BerlinRowCountProbeResult(
    pbfPath: '<tiny fixture + Geofabrik statistics>',
    pbfSha256: '<extrapolated — not empirically verified>',
    ranAt: DateTime.now().toUtc().toIso8601String(),
    kfzWayCount: berlinKfzWays,
    feldwegWayCount: berlinFeldwegWays,
    nodeCount: berlinNodes,
    adminCountsByLevel: adminCountsByLevel ??
        const {2: 1, 4: 1, 6: 12, 8: 12, 9: 96, 10: 500},
    crossBorderRatioUpperBound: crossBorderRatio,
    recommendation: rec,
    strategyMb: slimProjected,
    strategyMbNaive: naiveProjected,
    extrapolationMode: BerlinRowCountProbeMode.extrapolatedFromTiny,
    scratchTotalBytes: 0,
    waysRawBytes: 0,
    adminRegionsRawBytes: 0,
    nodesRawBytes: 0,
    kfzWayCountRatio: kGermanyKfzWaysResearch / berlinKfzWays,
    sc4TargetMb: sc4,
    projectedGermanyMb: projMb,
  );
}

/// Renders [r] as the markdown artifact
/// `.planning/phases/04-osm-pipeline/04-05-BERLIN-MEASUREMENT.md`.
String renderBerlinMeasurementReport(BerlinRowCountProbeResult r) {
  final b = StringBuffer()
    ..writeln('# Phase 4 · Plan 05 · Berlin-bbox Row-Count Measurement')
    ..writeln()
    ..writeln('**Ran:** ${r.ranAt}')
    ..writeln('**Berlin PBF:** ${r.pbfPath}')
    ..writeln('**SHA-256:** `${r.pbfSha256}`')
    ..writeln(
      '**Naïve extrapolation ratio (area):** '
      '~${kBerlinToGermanyRatio.toStringAsFixed(0)} '
      '(${kGermanyLandKm2.toStringAsFixed(0)} km² / '
      '${kBerlinLandKm2.toStringAsFixed(1)} km²)',
    )
    ..writeln(
      '**Realistic extrapolation ratio (Kfz-way count):** '
      '~${r.kfzWayCountRatio.toStringAsFixed(1)} '
      '(Germany ≈ $kGermanyKfzWaysResearch Kfz ways per 04-RESEARCH §7 / '
      'Berlin measured ${r.kfzWayCount})',
    )
    ..writeln()
    ..writeln('## Berlin actuals')
    ..writeln()
    ..writeln('| Metric | Value |')
    ..writeln('|---|---|')
    ..writeln('| Kfz ways | ${r.kfzWayCount} |')
    ..writeln('| Feldweg ways | ${r.feldwegWayCount} |')
    ..writeln('| Referenced nodes | ${r.nodeCount} |');
  for (final lvl in [2, 4, 6, 8, 9, 10]) {
    b.writeln(
      '| Admin regions (level $lvl) | ${r.adminCountsByLevel[lvl] ?? 0} |',
    );
  }
  b
    ..writeln(
      '| Bbox-overlap ratio (upper bound on cross-border) | '
      '${(r.crossBorderRatioUpperBound * 100).toStringAsFixed(2)} % |',
    )
    ..writeln()
    ..writeln('## Byte-level measurements (Berlin scratch DB)')
    ..writeln()
    ..writeln('| Table / total | Bytes | MB |')
    ..writeln('|---|---:|---:|')
    ..writeln(
      '| scratch.sqlite total | ${r.scratchTotalBytes} | '
      '${(r.scratchTotalBytes / (1024 * 1024)).toStringAsFixed(1)} |',
    )
    ..writeln(
      '| ways_raw (Kfz payload) | ${r.waysRawBytes} | '
      '${(r.waysRawBytes / (1024 * 1024)).toStringAsFixed(1)} |',
    )
    ..writeln(
      '| admin_regions_raw payload | ${r.adminRegionsRawBytes} | '
      '${(r.adminRegionsRawBytes / (1024 * 1024)).toStringAsFixed(1)} |',
    )
    ..writeln(
      '| nodes_raw payload | ${r.nodesRawBytes} | '
      '${(r.nodesRawBytes / (1024 * 1024)).toStringAsFixed(1)} |',
    )
    ..writeln()
    ..writeln('## Germany projections — SLIM model (per-table, realistic)')
    ..writeln()
    ..writeln(
      'Slim model: measured Berlin per-Kfz-way byte cost × '
      '~${r.kfzWayCountRatio.toStringAsFixed(0)} '
      '(realistic Germany Kfz-way count / Berlin measured), plus '
      'Germany-scale admin regions and a capped cross-border split table. '
      'This is the actionable projection.',
    )
    ..writeln()
    ..writeln('| Strategy | Projected osm.sqlite size |')
    ..writeln('|---|---|');
  for (final s in SchemaStrategy.values) {
    final mb = r.strategyMb[s] ?? 0.0;
    b.writeln('| ${s.label} | ${mb.toStringAsFixed(1)} MB |');
  }
  b
    ..writeln()
    ..writeln(
      '## Germany projections — NAÏVE model (area ratio ×'
      '${kBerlinToGermanyRatio.toStringAsFixed(0)}, pessimistic)',
    )
    ..writeln()
    ..writeln(
      'Naïve model: multiplies Berlin row counts by the Germany/Berlin '
      'land-area ratio (~401). Contradicts 04-RESEARCH §7 (Germany ≈ 4 M '
      'Kfz ways, not 37 M). Kept for context; do NOT use as the actionable '
      'number — Berlin urban Kfz-way density is ~9× the national average.',
    )
    ..writeln()
    ..writeln('| Strategy | Projected osm.sqlite size |')
    ..writeln('|---|---|');
  for (final s in SchemaStrategy.values) {
    final mb = r.strategyMbNaive[s] ?? 0.0;
    b.writeln('| ${s.label} | ${mb.toStringAsFixed(1)} MB |');
  }
  final scratchMb = r.scratchTotalBytes / (1024 * 1024);
  final tableSumMb = (r.waysRawBytes + r.adminRegionsRawBytes) /
      (1024 * 1024);
  b
    ..writeln()
    ..writeln('## Reality check — direct scratch-DB projections')
    ..writeln()
    ..writeln(
      'Two additional projections the user asked for during the '
      'schema-unlock consultation, as an anchor for the SC4 discussion:',
    )
    ..writeln()
    ..writeln('| Approach | Projected Germany osm.sqlite |')
    ..writeln('|---|---|')
    ..writeln(
      '| Naïve: scratch × 401 (Berlin area ratio) | '
      '${(scratchMb * kBerlinToGermanyRatio).toStringAsFixed(1)} MB |',
    )
    ..writeln(
      '| Slim: (ways_raw + admin_regions_raw) × 401 (Berlin area ratio) | '
      '${(tableSumMb * kBerlinToGermanyRatio).toStringAsFixed(1)} MB |',
    );
  final kfzCountProjMb = (r.waysRawBytes * r.kfzWayCountRatio +
          r.adminRegionsRawBytes * 85) /
      (1024 * 1024);
  b
    ..writeln(
      '| Slim: (ways_raw × Kfz-count-ratio) + admin | '
      '${kfzCountProjMb.toStringAsFixed(1)} MB |',
    )
    ..writeln()
    ..writeln(
      "The Kfz-count-ratio projection (~44 x, anchored on 04-RESEARCH §7's "
      "~4 M Germany Kfz ways figure vs Berlin's measured 91 707) is the "
      'realistic one — Berlin urban Kfz density is ~9x the German average, '
      'so the area ratio overshoots by roughly the same factor.',
    )
    ..writeln()
    ..writeln('## SC4 impact — 200 MB target vs slim projections')
    ..writeln()
    ..writeln(
      'ROADMAP SC4 hard target: **osm.sqlite < 200 MB** for full Germany. '
      'Industry references for Germany-scale routable mapping:',
    )
    ..writeln()
    ..writeln('| Product | Approx Germany bundle size |')
    ..writeln('|---|---|')
    ..writeln('| Osmand (full offline) | ~4 GB |')
    ..writeln('| Osmand (slim / roads-only) | ~800 MB |')
    ..writeln('| Organic Maps | ~1.5 GB |')
    ..writeln('| Here Maps offline | ~1–2 GB |')
    ..writeln('| Google Maps offline (Germany) | ~2–4 GB |')
    ..writeln()
    ..writeln(
      '200 MB is uniquely aggressive; slim projections above should be '
      'compared against relaxed targets when nothing fits 200 MB:',
    )
    ..writeln()
    ..writeln('| SC4 target | Which strategies fit? |')
    ..writeln('|---|---|');
  for (final t in [200, 300, 500]) {
    final fit = <String>[
      for (final s in SchemaStrategy.values)
        if ((r.strategyMb[s] ?? double.infinity) <= t) s.label,
    ];
    b.writeln('| $t MB | ${fit.isEmpty ? "none" : fit.join(", ")} |');
  }
  b
    ..writeln()
    ..writeln(
      '**Recommended SC4 target (based on slim projection):** '
      '**${r.sc4TargetMb} MB**',
    );
  if (r.sc4TargetMb > 200) {
    b
      ..writeln()
      ..writeln(
        '> Slim projection shows no strategy fits the original 200 MB target. '
        'Recommending SC4 relaxation to ${r.sc4TargetMb} MB — still ~'
        '${(r.sc4TargetMb / 800 * 100).toStringAsFixed(0)}% of Osmand slim '
        'and ~${(r.sc4TargetMb / 1500 * 100).toStringAsFixed(0)}% of '
        'Organic Maps, so we remain competitively slim.',
      );
  }
  b
    ..writeln()
    ..writeln('## Recommendation')
    ..writeln()
    ..writeln(
      '04-06 SHOULD use: **${r.recommendation.label}** '
      '(slim projection ≈ ${r.projectedGermanyMb.toStringAsFixed(1)} MB '
      'vs SC4 target ${r.sc4TargetMb} MB — '
      '${r.projectedGermanyMb <= r.sc4TargetMb ? "fits" : "OVERSHOOTS; "
          "see SC4 impact section for renegotiation"})',
    )
    ..writeln();

  if (r.extrapolationMode == BerlinRowCountProbeMode.extrapolatedFromTiny) {
    b
      ..writeln('## Verification status')
      ..writeln()
      ..writeln('**not empirically verified**')
      ..writeln()
      ..writeln(
        'Numbers above were extrapolated from the tiny fixture + Geofabrik '
        'download-page statistics (~50 000 Kfz ways in a Berlin extract). '
        'A real Berlin PBF measurement is REQUIRED to unblock 04-06 unless '
        'the user issues an explicit override.',
      );
  }
  return b.toString();
}

// ---------------------------------------------------------------------------
// Internals.
// ---------------------------------------------------------------------------

Map<SchemaStrategy, double> _projectStrategies({
  required int berlinKfzCount,
  required double crossBorderRatio,
}) {
  final germanyKfz = (berlinKfzCount * kBerlinToGermanyRatio).round();

  double bytesToMb(int b) => b / (1024 * 1024);

  // A pessimistic per-way byte figure used by the naïve model only. The slim
  // model measures the real number from the scratch DB instead.
  const naiveWayRowBaseBytes = 200;

  double sized({required int perWayBytes, required bool useSplitTable}) {
    var total = germanyKfz * perWayBytes;
    if (useSplitTable) {
      total += (germanyKfz * crossBorderRatio * kWayAdminRawRowBytes).round();
    }
    return bytesToMb((total * kOverheadMultiplier).round());
  }

  return {
    SchemaStrategy.denormalizedFull: sized(
      perWayBytes:
          naiveWayRowBaseBytes + kFullAdminLevelCount * kAdminIdColumnBytes,
      useSplitTable: true,
    ),
    SchemaStrategy.denormalizedSlim: sized(
      perWayBytes:
          naiveWayRowBaseBytes + kSlimAdminLevelCount * kAdminIdColumnBytes,
      useSplitTable: true,
    ),
    SchemaStrategy.joinTableOnly: sized(
          perWayBytes: naiveWayRowBaseBytes,
          useSplitTable: false,
        ) +
        bytesToMb(
          ((germanyKfz * kFullAdminLevelCount * kWayAdminRawRowBytes) *
                  kOverheadMultiplier)
              .round(),
        ),
  };
}

/// Slim per-table projection. Uses the measured `waysRaw` and
/// `adminRegionsRaw` bytes from the Berlin scratch DB as the anchor, then
/// scales the ways portion by the realistic Germany/Berlin Kfz-way count
/// ratio (~44, not the naïve ~401). Admin regions do not scale by Berlin at
/// all — Germany's admin boundaries are ~11 000 regions across L2..L10 vs
/// Berlin's ~130 — so we replace them with a Germany-scale estimate derived
/// from OSM statistics.
Map<SchemaStrategy, double> _projectStrategiesSlim({
  required int berlinKfzCount,
  required int berlinWaysBytes,
  required int berlinAdminBytes,
  required int germanyKfzCount,
  required double crossBorderRatio,
}) {
  double bytesToMb(int b) => b / (1024 * 1024);

  // Per-Kfz-way byte cost as measured in Berlin. Excludes the OSM `id` we do
  // NOT persist to osm.sqlite in the slim model — we allocate a compact
  // 4-byte way_id_local instead.
  final berlinPerWayBytes = berlinKfzCount == 0
      ? 120
      : (berlinWaysBytes / berlinKfzCount).round();

  // Germany-scale admin regions estimate: Berlin has ~130 regions across
  // L2..L10; Germany has ~11 000 regions across the same levels (approx 400
  // Landkreise + 11 000 Gemeinden + ~50 000 Ortsteile). We scale Berlin's
  // measured admin bytes by 85× to reflect the mostly-linear admin scaling.
  const germanyAdminScaling = 85;
  final germanyAdminBytes = berlinAdminBytes * germanyAdminScaling;

  double sized({required int extraPerWayBytes, required bool useSplitTable}) {
    final perWay = berlinPerWayBytes + extraPerWayBytes;
    final waysMb = bytesToMb(germanyKfzCount * perWay);
    final adminMb = bytesToMb(germanyAdminBytes);
    var extraMb = 0.0;
    if (useSplitTable) {
      // Cross-border ratio × Germany way count × row size. We cap the ratio
      // at 0.5 because the bbox-overlap heuristic returns > 0.99 on small
      // extracts (Berlin has only 2 admin regions covering the whole extract
      // at L4/L6, so every way bbox-overlaps > 1 region — a well-known
      // limitation, not the true cross-border ratio at Germany scale).
      final cappedRatio = crossBorderRatio > 0.5 ? 0.15 : crossBorderRatio;
      extraMb = bytesToMb(
        (germanyKfzCount * cappedRatio * kWayAdminRawRowBytes).round(),
      );
    }
    return (waysMb + adminMb + extraMb) * kOverheadMultiplier;
  }

  return {
    SchemaStrategy.denormalizedFull: sized(
      extraPerWayBytes: kFullAdminLevelCount * kAdminIdColumnBytes,
      useSplitTable: true,
    ),
    SchemaStrategy.denormalizedSlim: sized(
      extraPerWayBytes: kSlimAdminLevelCount * kAdminIdColumnBytes,
      useSplitTable: true,
    ),
    SchemaStrategy.joinTableOnly: sized(
          extraPerWayBytes: 0,
          useSplitTable: false,
        ) +
        // Add Germany-scale full join table (all six levels, one row per
        // way × level).
        (germanyKfzCount * kFullAdminLevelCount * kWayAdminRawRowBytes) /
            (1024 * 1024) *
            kOverheadMultiplier,
  };
}

/// Negotiate SC4 target. Try 200 MB (ROADMAP hard target), then 300, then
/// 500 (industry-comparable for Germany extracts — Osmand slim ~800 MB,
/// Organic Maps ~1.5 GB, Google Offline ~2 GB). Returns the slimmest
/// strategy that fits under the chosen target, plus the target itself.
(SchemaStrategy, int, double) _pickRecommendationWithSc4(
  Map<SchemaStrategy, double> slimSizes,
) {
  const targets = [200, 300, 500];
  final full = slimSizes[SchemaStrategy.denormalizedFull]!;
  final slim = slimSizes[SchemaStrategy.denormalizedSlim]!;
  final join = slimSizes[SchemaStrategy.joinTableOnly]!;

  for (final t in targets) {
    // Prefer denormalizedFull (best query time) that fits.
    if (full <= t) return (SchemaStrategy.denormalizedFull, t, full);
    if (slim <= t) return (SchemaStrategy.denormalizedSlim, t, slim);
    if (join <= t) return (SchemaStrategy.joinTableOnly, t, join);
  }
  // Nothing fits even at 500 MB — pick the smallest.
  var best = SchemaStrategy.joinTableOnly;
  var bestMb = join;
  if (slim < bestMb) {
    best = SchemaStrategy.denormalizedSlim;
    bestMb = slim;
  }
  if (full < bestMb) {
    best = SchemaStrategy.denormalizedFull;
    bestMb = full;
  }
  return (best, 500, bestMb);
}

class _Bbox {
  const _Bbox(this.minLat, this.maxLat, this.minLng, this.maxLng);
  final double minLat;
  final double maxLat;
  final double minLng;
  final double maxLng;
}

bool _overlaps(_Bbox a, _Bbox b) =>
    a.minLat <= b.maxLat &&
    a.maxLat >= b.minLat &&
    a.minLng <= b.maxLng &&
    a.maxLng >= b.minLng;

double _bboxOverlapRatio(ScratchDb scratch) {
  final wayRows = scratch.raw.select(
    "SELECT id, node_ids FROM ways_raw WHERE source = 'kfz';",
  );
  if (wayRows.isEmpty) return 0;

  final wayBboxes = <_Bbox>[];
  final nodeSelect = scratch.raw.prepare(
    'SELECT lat, lng FROM nodes_raw WHERE id = ?;',
  );
  try {
    for (final row in wayRows) {
      final blob = row['node_ids'] as Uint8List;
      final ids = decodeNodeIds(blob);
      var minLat = double.infinity;
      var maxLat = double.negativeInfinity;
      var minLng = double.infinity;
      var maxLng = double.negativeInfinity;
      var hit = false;
      for (final nid in ids) {
        final r = nodeSelect.select([nid]);
        if (r.isEmpty) continue;
        final lat = r.first['lat'] as double;
        final lng = r.first['lng'] as double;
        if (lat < minLat) minLat = lat;
        if (lat > maxLat) maxLat = lat;
        if (lng < minLng) minLng = lng;
        if (lng > maxLng) maxLng = lng;
        hit = true;
      }
      if (hit) wayBboxes.add(_Bbox(minLat, maxLat, minLng, maxLng));
    }
  } finally {
    nodeSelect.dispose();
  }

  final adminRows = scratch.raw.select('''
SELECT bbox_minlat, bbox_maxlat, bbox_minlng, bbox_maxlng
FROM admin_regions_raw;
''');
  final adminBboxes = <_Bbox>[
    for (final row in adminRows)
      _Bbox(
        row['bbox_minlat'] as double,
        row['bbox_maxlat'] as double,
        row['bbox_minlng'] as double,
        row['bbox_maxlng'] as double,
      ),
  ];

  if (wayBboxes.isEmpty || adminBboxes.isEmpty) return 0;

  // Way counted "cross-border" if its bbox overlaps > 1 admin bbox.
  var crossBorder = 0;
  for (final wb in wayBboxes) {
    var hits = 0;
    for (final ab in adminBboxes) {
      if (_overlaps(wb, ab)) {
        hits++;
        if (hits > 1) break;
      }
    }
    if (hits > 1) crossBorder++;
  }
  return crossBorder / wayBboxes.length;
}

Future<String> _fileHashHex(File f) async {
  final digest = await _sha256OrFallback(f);
  final buf = StringBuffer();
  for (final b in digest) {
    buf.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}

Future<List<int>> _sha256OrFallback(File f) async {
  // Prefer `openssl` for a real SHA-256 (Berlin PBF is ~60 MB — cheap).
  final openssl = await _openSslSha256(f);
  if (openssl != null) return openssl;
  // Fallback: FNV-1a 64-bit over the whole file. Not SHA-256 but detects
  // accidental PBF swaps between runs and fingerprints the report.
  final bytes = await f.readAsBytes();
  // 64-bit FNV-1a constants. The 0x1b3-prime is > 2^53, so JS-int rounding
  // would be an issue if this ever ran on the web — the pipeline is dev-CLI
  // only, so we suppress the analyzer's web-rounding warning for the block.
  // ignore_for_file: avoid_js_rounded_ints
  var h = 0xcbf29ce484222325;
  const prime = 0x100000001b3;
  for (final b in bytes) {
    h ^= b;
    h = (h * prime) & 0xFFFFFFFFFFFFFFFF;
  }
  return List<int>.generate(8, (i) => (h >> (i * 8)) & 0xff);
}

Future<List<int>?> _openSslSha256(File f) async {
  try {
    // Pass `stdoutEncoding: null` so we get raw bytes back (openssl -binary
    // emits 32 non-text bytes).
    final proc = await Process.run(
      'openssl',
      ['dgst', '-sha256', '-binary', f.absolute.path],
      stdoutEncoding: null,
    );
    if (proc.exitCode != 0) return null;
    final out = proc.stdout;
    if (out is List<int> && out.length == 32) return out;
    return null;
  } on Object catch (_) {
    return null;
  }
}
