// Coverage recompute isolate — sendable payloads (2026-07-22).
//
// Mirrors match_job.dart: every field on every message here must be trivially
// copyable across an isolate boundary via SendPort — primitives, Uint8List,
// value types (LatLonBbox = four doubles), and plain Dart classes containing
// only those. NO closures, NO futures, NO Drift types, NO Flutter imports.
//
// The polygon index is NEVER carried by any of these messages — it is parsed
// ONCE inside the worker from [CoverageLoadBundle.adminBytes] and retained
// there. Only [RegionAccum] (three doubles per region id) crosses back, which
// is what avoids the 2026-07-10 OOM (that crash was a large index copied over
// the SendPort).

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

/// One coverage-attribution job: attribute every driven way to its containing
/// admin region(s) and accumulate driven/total length per region.
///
/// All fields Sendable:
/// - [jobSeq]: int correlation key.
/// - [gzippedTiles]: `List<Uint8List>` raw cached Overpass tiles; the worker
///   gunzips + parses them tile-by-tile (bounded peak memory), never on main.
/// - [tileBboxes]: `List<LatLonBbox>` parallel to [gzippedTiles] (four doubles
///   each) for the post-parse bbox clip.
/// - [intervalsByWayId]: wayId → flattened driven union intervals as
///   `[start0, end0, start1, end1, …]`. Flattened to plain doubles (rather than
///   `Interval` objects) so this file stays free of domain imports; the worker
///   rebuilds `Interval`s locally.
@immutable
class CoverageComputeJob {
  const CoverageComputeJob({
    required this.jobSeq,
    required this.gzippedTiles,
    required this.tileBboxes,
    required this.intervalsByWayId,
  });

  final int jobSeq;
  final List<Uint8List> gzippedTiles;
  final List<LatLonBbox> tileBboxes;
  final Map<int, List<double>> intervalsByWayId;
}

/// Accumulated coverage for one admin region — the ONLY payload that crosses
/// back from the worker (per region id). Three doubles: driven metres, total
/// metres (haversine sum of attributed way lengths), and the bundled real total
/// (from `region_totals.json.gz`, resolved inside the worker; null when absent).
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

/// Terminal reply for one [CoverageComputeJob]. Discriminated union: [result]
/// non-null on success (regionId → [RegionAccum]), [error] non-null on throw.
@immutable
class CoverageComputeReply {
  const CoverageComputeReply({
    required this.jobSeq,
    this.result,
    this.error,
  });

  final int jobSeq;
  final Map<String, RegionAccum>? result;
  final Object? error;
}
