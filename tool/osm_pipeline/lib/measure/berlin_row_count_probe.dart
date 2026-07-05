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

/// Scaling factor for extrapolating Berlin-scoped counts to Germany-scale.
const double kBerlinToGermanyRatio = kGermanyLandKm2 / kBerlinLandKm2;

/// Conservative per-way byte budget on the `ways` table (existing columns).
/// See 04-RESEARCH §7 + 04-05-PLAN.md Task 2 spec.
const int kWayRowBaseBytes = 200;

/// Per-admin-column overhead added by the denormalized-on-ways strategy.
const int kAdminIdColumnBytes = 8;

/// Number of admin levels retained (2/4/6/8/9/10).
const int kFullAdminLevelCount = 6;

/// Number of admin levels retained after dropping L9+L10.
const int kSlimAdminLevelCount = 4;

/// Per-row byte cost of a `way_admin_raw` row (way_id + region_id + level +
/// two fractions + index overhead). Conservative.
const int kWayAdminRawRowBytes = 40;

/// Overhead margin applied to raw byte totals to account for SQLite indexes,
/// page slack, and R-Tree structure.
const double kOverheadMultiplier = 1.30;

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
    required this.extrapolationMode,
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

  /// Projected osm.sqlite size per strategy, in MB.
  final Map<SchemaStrategy, double> strategyMb;

  /// Whether the numbers were measured directly or extrapolated from the tiny
  /// fixture.
  final BerlinRowCountProbeMode extrapolationMode;
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

    final pbfSha = pbfSha256Override ?? await _fileHashHex(pbf);
    final ranAt = DateTime.now().toUtc().toIso8601String();

    final projected = _projectStrategies(
      berlinKfzCount: wayStats.kfzWays,
      crossBorderRatio: ratio,
    );
    final recommendation = _pickRecommendation(projected);

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
      strategyMb: projected,
      extrapolationMode: mode,
    );
  } finally {
    scratch.close(deleteFile: true);
  }
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
  final projected = _projectStrategies(
    berlinKfzCount: berlinKfzWays,
    crossBorderRatio: crossBorderRatio,
  );
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
    recommendation: _pickRecommendation(projected),
    strategyMb: projected,
    extrapolationMode: BerlinRowCountProbeMode.extrapolatedFromTiny,
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
      '**Extrapolation ratio to Germany:** '
      '~${kBerlinToGermanyRatio.toStringAsFixed(0)} '
      '(${kGermanyLandKm2.toStringAsFixed(0)} km² / '
      '${kBerlinLandKm2.toStringAsFixed(1)} km²)',
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
    ..writeln('## Germany projections + strategy sizing')
    ..writeln()
    ..writeln('| Strategy | Projected osm.sqlite size |')
    ..writeln('|---|---|');
  for (final s in SchemaStrategy.values) {
    final mb = r.strategyMb[s] ?? 0.0;
    b.writeln('| ${s.label} | ${mb.toStringAsFixed(1)} MB |');
  }
  b
    ..writeln()
    ..writeln('## Recommendation')
    ..writeln()
    ..writeln('04-06 SHOULD use: **${r.recommendation.label}**')
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
          kWayRowBaseBytes + kFullAdminLevelCount * kAdminIdColumnBytes,
      useSplitTable: true,
    ),
    SchemaStrategy.denormalizedSlim: sized(
      perWayBytes:
          kWayRowBaseBytes + kSlimAdminLevelCount * kAdminIdColumnBytes,
      useSplitTable: true,
    ),
    SchemaStrategy.joinTableOnly: sized(
          perWayBytes: kWayRowBaseBytes,
          useSplitTable: false,
        ) +
        bytesToMb(
          ((germanyKfz * kFullAdminLevelCount * kWayAdminRawRowBytes) *
                  kOverheadMultiplier)
              .round(),
        ),
  };
}

SchemaStrategy _pickRecommendation(Map<SchemaStrategy, double> sizes) {
  final full = sizes[SchemaStrategy.denormalizedFull]!;
  final slim = sizes[SchemaStrategy.denormalizedSlim]!;
  if (full < 100) return SchemaStrategy.denormalizedFull;
  if (slim < 150) return SchemaStrategy.denormalizedSlim;
  return SchemaStrategy.joinTableOnly;
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
