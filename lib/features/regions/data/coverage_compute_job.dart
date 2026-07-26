// Coverage recompute isolate — sendable payloads (2026-07-22; reworked
// 2026-07-25 for the durable clip-per-region attribution model).
//
// Mirrors match_job.dart: every field on every message here must be trivially
// copyable across an isolate boundary via SendPort — primitives, Uint8List,
// value types (LatLonBbox = four doubles), and plain Dart classes containing
// only those. NO closures, NO futures, NO Drift types, NO Flutter imports.
//
// The polygon index is NEVER carried by any of these messages — it is parsed
// ONCE inside the worker from [CoverageLoadBundle.adminBytes] and retained
// there. Only [WayRegionAttributionRow]s (five sendable primitives each) cross
// back, which is what avoids the 2026-07-10 OOM (that crash was a large index
// copied over the SendPort).
//
// STAGE SPLIT (2026-07-25): the worker now runs STAGE 1 only — the geometric
// clip of each NEW driven way's polyline against the admin polygons, emitting
// durable per-(way, region, meter-range) attribution rows. The driven-vs-total
// aggregation (STAGE 2) is a pure DB read/sum on the MAIN isolate (see
// CoverageComputeService.recompute), so it is eviction-proof + monotonic and no
// longer depends on this job at all. The job therefore no longer carries driven
// intervals; it carries the set of already-attributed wayIds so the worker only
// clips geometry it has not processed before.

import 'dart:typed_data';

import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:meta/meta.dart';

/// Sent ONCE from the main isolate to the worker right after the port
/// handshake, before any compute job. Carries the raw gzipped asset bytes the
/// worker parses+indexes into its resident admin polygon index + totals map.
///
/// The bytes are read on the MAIN isolate (rootBundle is unreachable from a
/// spawned isolate — "Pitfall 1") and shipped here. [totalsBytes] is null when
/// the deferred `region_totals.json.gz` asset is absent from the build.
@immutable
class CoverageLoadBundle {
  const CoverageLoadBundle({required this.adminBytes, this.totalsBytes});

  /// Raw `gzip(utf8(geojson))` of `assets/admin/germany_admin.geojson.gz`
  /// (or the runtime-refreshed docs-dir override). Parsed inside the worker.
  final Uint8List adminBytes;

  /// Raw `gzip(utf8(json))` of `assets/admin/region_totals.json.gz`, or null
  /// when the asset is absent. `Uint8List` crosses the SendPort untouched.
  ///
  /// Retained for handshake symmetry with the pre-2026-07-25 payload; the
  /// STAGE-1 attribution worker does not use totals (real totals are resolved
  /// on the main side in STAGE 2 via RegionTotalsLookup). Kept so the loader
  /// wiring in coverage_compute_providers.dart is unchanged.
  final Uint8List? totalsBytes;
}

/// Worker → main handshake completion: sent after [CoverageLoadBundle] has been
/// parsed and the polygon index is built, so the main side knows the worker is
/// ready to accept [CoverageComputeJob]s. Two-phase startup: (1) worker sends
/// its SendPort, (2) worker sends this once the index is live.
@immutable
class CoverageReady {
  const CoverageReady();
}

/// One STAGE-1 attribution job: clip every NEW driven way's polyline against
/// the admin polygons and emit the in-region meter-ranges per level.
///
/// All fields Sendable:
/// - [jobSeq]: int correlation key.
/// - [gzippedTiles]: `List<Uint8List>` raw cached Overpass tiles; the worker
///   gunzips + parses them tile-by-tile (bounded peak memory), never on main.
/// - [tileBboxes]: `List<LatLonBbox>` parallel to [gzippedTiles] (four doubles
///   each) for the post-parse bbox clip.
/// - [alreadyAttributedWayIds]: wayIds that already have durable attribution
///   rows in `way_region_attribution` — the worker SKIPS these so it only
///   clips geometry it has not processed before (attribution is static per
///   wayId, so this is a pure cache-fill).
@immutable
class CoverageComputeJob {
  const CoverageComputeJob({
    required this.jobSeq,
    required this.gzippedTiles,
    required this.tileBboxes,
    required this.alreadyAttributedWayIds,
  });

  final int jobSeq;
  final List<Uint8List> gzippedTiles;
  final List<LatLonBbox> tileBboxes;
  final Set<int> alreadyAttributedWayIds;
}

/// One durable attribution row produced by STAGE 1 — a contiguous meter-range
/// `[rangeStartM, rangeEndM]` ALONG a way (offsets from its first node) that
/// lies inside one admin region at one level. The ONLY payload that crosses
/// back from the worker (five sendable primitives per row). Mirrors the columns
/// of the `way_region_attribution` Drift table 1:1; the main isolate maps these
/// straight into `WayRegionAttributionCompanion`s (Drift types stay off-worker).
@immutable
class WayRegionAttributionRow {
  const WayRegionAttributionRow({
    required this.wayId,
    required this.regionId,
    required this.adminLevel,
    required this.rangeStartM,
    required this.rangeEndM,
  });

  /// OSM way id.
  final int wayId;

  /// OSM relation id of the containing admin region, as a string.
  final String regionId;

  /// OSM admin_level of [regionId].
  final int adminLevel;

  /// Start offset in meters along the way where this in-region stretch begins.
  final double rangeStartM;

  /// End offset in meters along the way where this in-region stretch ends.
  final double rangeEndM;
}

/// Terminal reply for one [CoverageComputeJob]. Discriminated union: [rows]
/// non-null on success (the STAGE-1 attribution rows for the new ways),
/// [error] non-null on throw.
@immutable
class CoverageComputeReply {
  const CoverageComputeReply({
    required this.jobSeq,
    this.rows,
    this.error,
  });

  final int jobSeq;
  final List<WayRegionAttributionRow>? rows;
  final Object? error;
}

/// Accumulated coverage for one admin region, built on the MAIN isolate during
/// STAGE 2 (pure DB read/sum). No longer crosses the SendPort — it is the
/// value the recompute aggregation hands to `CoverageCacheDao.upsert`. Three
/// doubles: driven metres (Σ overlap of driven-union with in-region ranges),
/// total metres (Σ clipped in-region range lengths), and the bundled real total
/// (from `RegionTotalsLookup`; null when absent).
@immutable
class RegionAccum {
  const RegionAccum({
    required this.driven,
    required this.total,
    this.realTotal,
  });

  final double driven;
  final double total;
  final double? realTotal;
}
