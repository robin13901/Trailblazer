// Trailblazer Phase 7 (07-03), reworked 2026-07-18 (clipped-geometry rework):
// DrivenWayGeometryResolver — builds the app-wide coverage overlay by rendering
// each driven OSM way CLIPPED to the sub-interval(s) actually driven, deduped
// per wayId across ALL trips.
//
// This replaces two earlier approaches:
//   * The original whole-way render (drew a way's ENTIRE geometry the moment it
//     counted as "driven") — caused junction under-draw gaps AND exit-triangle
//     over-draw, patched with a fragile topology heuristic.
//   * The per-trip snapped-GPS-chord line (coverage_path_json) — drew straight
//     chords between snapped fixes (triangles/fans/zigzags at junctions) and one
//     polyline PER TRIP (N drives of a road = N overlapping lines).
//
// The clipped model fixes all of that: the drawn line IS the road's true OSM
// shape (no chord artifacts), clipped to `[start..end]` driven metres (no
// over-draw), unioned per wayId across every trip (drawn ONCE — natural dedup).
//
// Memory (06-05 / trips-tab-oom lesson): the parse + clip runs on a compute()
// isolate over the RAW cached tiles, filtered to just the driven wayId set —
// never the full-bbox way-set on the UI isolate.

import 'dart:convert';
import 'dart:io' show gzip;

import 'package:auto_explore/core/db/daos/coverage_line_cache_dao.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/features/coverage/data/coverage_line_codec.dart';
import 'package:auto_explore/features/coverage/data/coverage_overlay_data.dart';
import 'package:auto_explore/features/coverage/domain/coverage_datum.dart';
import 'package:auto_explore/features/coverage/domain/interval_union.dart';
import 'package:auto_explore/features/coverage/domain/way_subsegment.dart';
import 'package:auto_explore/features/matching/data/overpass_response_parser.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:logging/logging.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng, LatLngBounds;

/// Resolves the app-wide coverage overlay from `driven_way_intervals` + cached
/// OSM way geometry, rendering each way clipped to its driven union interval(s)
/// and deduped per wayId across all trips.
///
/// STATELESS — `resolve` reads fresh on every call. Reactive invalidation is
/// handled by the coverage overlay provider, which re-calls resolve() whenever
/// the Drift `watchUnionBbox()` stream emits (fires on interval writes).
class DrivenWayGeometryResolver {
  DrivenWayGeometryResolver({
    required DrivenWayIntervalsDao intervalsDao,
    required WayCandidateSource waySource,
    CoverageLineCacheDao? lineCacheDao,
    void Function()? onNetworkFetchStart,
    void Function()? onNetworkFetchDone,
    void Function(int done, int total)? onNetworkFetchProgress,
  }) : _intervalsDao = intervalsDao,
       _waySource = waySource,
       _lineCacheDao = lineCacheDao,
       _onNetworkFetchStart = onNetworkFetchStart,
       _onNetworkFetchDone = onNetworkFetchDone,
       _onNetworkFetchProgress = onNetworkFetchProgress;

  final DrivenWayIntervalsDao _intervalsDao;
  final WayCandidateSource _waySource;

  /// Durable clipped-line blob cache (schema v9). Optional so existing tests
  /// that don't exercise the cache need not supply it. When present, [resolve]
  /// reads the blob first (instant, no tile access) and persists freshly
  /// computed lines back to it.
  final CoverageLineCacheDao? _lineCacheDao;

  final void Function()? _onNetworkFetchStart;
  final void Function()? _onNetworkFetchDone;
  final void Function(int done, int total)? _onNetworkFetchProgress;

  /// One-shot guard: Pass B (network tile backfill) runs at most ONCE per
  /// resolver instance (= per app session). Without this, driven ways that can
  /// never be resolved from OSM (deleted ways, permanently-empty tiles, tiles
  /// Overpass keeps failing) would re-trigger a full network re-fetch on EVERY
  /// resolve() call — so every app launch showed the "Kartenlinie wird geladen"
  /// banner again and it got stuck at N/M forever. After one attempt we accept
  /// the cached geometry as final for this session; a genuinely new drive
  /// creates a fresh resolver (provider rebuild) which re-arms the guard.
  bool _networkBackfillAttempted = false;

  static final _log = Logger('DrivenWayGeometryResolver');

  /// Resolves all driven ways within [unionBounds] and returns their geometry
  /// CLIPPED to the driven union interval(s), one [CoverageWay] per contiguous
  /// driven sub-segment.
  ///
  /// Never throws — degrades to [CoverageOverlayData.empty] on any error.
  Future<CoverageOverlayData> resolve(LatLngBounds unionBounds) async {
    try {
      // 0. DURABLE-CACHE FAST PATH (schema v9): if a stored line blob exists and
      //    was computed against the CURRENT driven_way_intervals revision, decode
      //    and return it — a single DB read, no tile access, no network, immune
      //    to LRU eviction. This is the common path on every app launch. The
      //    blob is only recomputed (steps 1+ below) when a new drive advances the
      //    revision, and the fresh result is persisted back at the end.
      final currentRevision = await _intervalsDao.getRevision();
      if (_lineCacheDao != null) {
        final cached = await _lineCacheDao.getRow();
        if (cached != null && cached.intervalsRevision == currentRevision) {
          final ways = decodeCoverageLine(cached.linesJson);
          if (ways.isNotEmpty) {
            _log.info(
              'resolve: ${ways.length} segments from durable cache '
              '(rev $currentRevision)',
            );
            return CoverageOverlayData(ways);
          }
        }
      }

      // 1. Read all driven intervals (way-centric, across all trips) and group
      //    by wayId, merging overlapping passes into disjoint union intervals.
      //    Unioning across ALL trips is what dedupes a road driven N times into
      //    one drawn line.
      final allIntervals = await _intervalsDao.getAllIntervals();
      if (allIntervals.isEmpty) {
        _log.fine('resolve: no driven intervals — returning empty');
        return CoverageOverlayData.empty;
      }

      final unionByWayId = <int, List<(double, double)>>{};
      {
        final rawByWayId = <int, List<Interval>>{};
        for (final row in allIntervals) {
          rawByWayId
              .putIfAbsent(row.wayId, () => [])
              .add(Interval(row.startMeters, row.endMeters));
        }
        for (final entry in rawByWayId.entries) {
          unionByWayId[entry.key] = [
            for (final iv in unionIntervals(entry.value))
              (iv.startMeters, iv.endMeters),
          ];
        }
      }

      // 2. Fetch RAW gzipped tiles — two-pass strategy:
      //    PASS A (cacheOnly:true): instant, no network. May leave some ways
      //    without geometry if their tiles were LRU-evicted (e.g. after a fresh
      //    install + backup import). We clip whatever we have and return it
      //    immediately so the map shows *something* without waiting for network.
      //    PASS B (cacheOnly:false): if any driven ways were missing from the
      //    cache, re-fetch the union bbox allowing network hits for the missing
      //    tiles, then re-clip and return the complete result.
      //    This two-pass approach keeps the original instant-render behaviour for
      //    the common case (warm cache after a normal drive) while still
      //    recovering after a fresh install without a multi-minute wait before
      //    anything appears.
      final cachedTiles = await _waySource.fetchRawTilesInBbox(
        minLat: unionBounds.southwest.latitude,
        minLon: unionBounds.southwest.longitude,
        maxLat: unionBounds.northeast.latitude,
        maxLon: unionBounds.northeast.longitude,
        throwOnError: false,
        cacheOnly: true,
      );

      // Clip using cached tiles only (may have geometry gaps).
      final payloadCached = _ClipPayload(
        gzippedTiles: [for (final t in cachedTiles) t.payloadGzip],
        unionByWayId: unionByWayId,
      );
      final clippedCached = cachedTiles.isEmpty
          ? <CoverageWay>[]
          : await compute(_clipCoverageIsolate, payloadCached);

      // Count how many driven ways have no geometry from the cache.
      final cachedWayIds = <int>{};
      if (cachedTiles.isNotEmpty) {
        for (final way in clippedCached) {
          cachedWayIds.add(way.wayId);
        }
      }
      final missingCount =
          unionByWayId.keys.where((id) => !cachedWayIds.contains(id)).length;

      if (missingCount == 0 && cachedTiles.isNotEmpty) {
        // All ways resolved from cache — done, no network needed. Persist the
        // clipped line so future launches read it directly (fast path above).
        await _persist(clippedCached, currentRevision);
        _log.info('resolve: ${clippedCached.length} segments (all cached)');
        return CoverageOverlayData(clippedCached);
      }

      // Pass B guard: attempt the network backfill at most ONCE per session.
      // The guard is set AFTER a successful persist (not before the fetch) so
      // that a crash during the fetch (OOM, background kill) does not leave the
      // guard armed for the next launch — the next launch will simply try again.
      if (_networkBackfillAttempted) {
        await _persist(clippedCached, currentRevision);
        _log.info(
          'resolve: ${clippedCached.length} segments (network backfill already '
          'attempted this session — using cached)',
        );
        return CoverageOverlayData(clippedCached);
      }

      // Pass B: some ways had no cached geometry — re-fetch allowing network.
      _log.info(
        'resolve: $missingCount/${unionByWayId.length} ways missing from '
        'cache — re-fetching with network',
      );
      _onNetworkFetchStart?.call();
      final fullTiles = await _waySource.fetchRawTilesInBbox(
        minLat: unionBounds.southwest.latitude,
        minLon: unionBounds.southwest.longitude,
        maxLat: unionBounds.northeast.latitude,
        maxLon: unionBounds.northeast.longitude,
        throwOnError: false,
        onTileProgress: _onNetworkFetchProgress,
        // cacheOnly defaults to false — fetch missing tiles from network.
      );
      if (fullTiles.isEmpty) {
        _onNetworkFetchDone?.call();
        _log.fine('resolve: no tiles after network fetch — returning cached');
        // Persist what we have so the fast path skips the re-fetch next launch.
        await _persist(clippedCached, currentRevision);
        _networkBackfillAttempted = true;
        return cachedTiles.isEmpty
            ? CoverageOverlayData.empty
            : CoverageOverlayData(clippedCached);
      }

      // Clip in one pass using all fetched tiles — same as Pass A but with the
      // now-complete tile set. Peak RAM is bounded by the LRU cache size for
      // warm-cache launches; on a cold-cache first-launch the recompute startup
      // migration fills the cache first (kCurrentCoverageRecomputeVersion bump),
      // so this path should rarely receive more than a handful of miss-tiles.
      final payloadFull = _ClipPayload(
        gzippedTiles: [for (final t in fullTiles) t.payloadGzip],
        unionByWayId: unionByWayId,
      );
      final clipped = await compute(_clipCoverageIsolate, payloadFull);
      _onNetworkFetchDone?.call();

      // Persist the freshly clipped line so subsequent launches read it
      // directly (durable, eviction-proof) instead of re-fetching tiles.
      // Only arm the one-shot guard AFTER a successful persist — a crash
      // during the clip/persist leaves the guard clear so the next launch
      // retries rather than silently skipping the backfill.
      await _persist(clipped, currentRevision);
      _networkBackfillAttempted = true;
      _log.info('resolve: ${clipped.length} clipped driven segments (network)');
      return CoverageOverlayData(clipped);
    } on DomainError catch (e, st) {
      _onNetworkFetchDone?.call(); // ensure banner clears even on error
      _log.warning('resolve: DomainError — degrading to empty', e, st);
      return CoverageOverlayData.empty;
    } on Object catch (e, st) {
      _onNetworkFetchDone?.call(); // ensure banner clears even on error
      _log.warning(
        'resolve: unexpected error — degrading to empty',
        DomainError.wrap(e, st),
        st,
      );
      return CoverageOverlayData.empty;
    }
  }

  /// Persist [ways] as the durable coverage-line blob keyed to [revision].
  /// No-op when no cache DAO is wired (unit tests). Never throws — a persistence
  /// hiccup must not break the render path; the line still returns to the caller.
  Future<void> _persist(List<CoverageWay> ways, int revision) async {
    final dao = _lineCacheDao;
    if (dao == null) return;
    try {
      await dao.put(
        linesJson: encodeCoverageLine(ways),
        intervalsRevision: revision,
      );
      // A cache-write hiccup must never break rendering.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      _log.warning('resolve: durable line persist failed: $e', e, st);
    }
  }
}

/// Serializable argument bundle for [_clipCoverageIsolate].
class _ClipPayload {
  const _ClipPayload({
    required this.gzippedTiles,
    required this.unionByWayId,
  });

  /// Raw `gzip(utf8(overpassJson))` tile payloads (cross the isolate untouched).
  final List<List<int>> gzippedTiles;

  /// wayId → its disjoint driven union intervals as `(startMeters, endMeters)`.
  final Map<int, List<(double, double)>> unionByWayId;
}

/// Runs on a compute() isolate: gunzip + parse the tiles, keep ONLY the driven
/// wayIds (geometry + OSM node ids), then delegate to [clipDrivenWays] which
/// clips each way to its driven sub-interval(s) with topology-aware thorn-drop,
/// connector-close, and node-id gap-stitch. Returns one [CoverageWay] per drawn
/// segment (solid — every drawn metre was driven).
List<CoverageWay> _clipCoverageIsolate(_ClipPayload p) {
  final wanted = p.unionByWayId.keys.toSet();

  // Parse tiles, keeping geometry + node ids for driven ways (dedupe).
  final geomByWayId = <int, List<LatLng>>{};
  final nodesByWayId = <int, List<int>>{};
  final seen = <int>{};
  const parser = OverpassResponseParser();
  for (final gz in p.gzippedTiles) {
    final rawJson = utf8.decode(gzip.decode(gz));
    for (final w in parser.parseWays(rawJson)) {
      if (!wanted.contains(w.wayId)) continue;
      if (!seen.add(w.wayId)) continue;
      geomByWayId[w.wayId] = w.geometry;
      nodesByWayId[w.wayId] = w.nodeIds;
    }
  }

  return clipDrivenWays(
    unionByWayId: p.unionByWayId,
    geomByWayId: geomByWayId,
    nodesByWayId: nodesByWayId,
  );
}

// ---------------------------------------------------------------------------
// Pure render logic (isolate-safe, unit-testable)
// ---------------------------------------------------------------------------

/// Minimum raw driven-union length (m) below which a NON-bridging way is
/// treated as a junction mis-snap ("thorn") and dropped. A couple of GPS fixes
/// clipping onto a neighbouring road near a junction produce a near-zero-length
/// interval a few metres from a way endpoint; without this floor they render as
/// tiny orange spikes. Bridging connectors (both endpoints pinned to the driven
/// network) are exempt — they close junction gaps.
const double kThornFloorMeters = 25;

/// A bridging way at or below this full length is drawn end-to-end even if the
/// matcher only captured a near-zero span on it (a traversed junction link/arc
/// the decoder collapsed to a point). Over-draw-safe: it is short AND pinned to
/// the driven network at BOTH endpoints, so it cannot be a spurious stub.
const double kConnectorFullDrawMeters = 80;

/// A driven interval end within this distance of a way endpoint that is SHARED
/// with another driven way is snapped exactly to that endpoint node, so two
/// adjacent driven ways meet at the real OSM junction (closes gaps). Node-id
/// gated — stronger and safer than a blanket own-end snap.
const double kStitchToleranceMeters = 25;

/// Clip driven ways to their union interval(s) with topology-aware rules.
///
/// [unionByWayId]: wayId → disjoint driven union intervals `(start, end)` m.
/// [geomByWayId]:  wayId → OSM polyline. [nodesByWayId]: wayId → parallel node
/// ids (empty when the source had none — then this way falls back to the old
/// blanket end-snap and is never thorn-dropped, for fixture back-compat).
///
/// Rules (see [kThornFloorMeters] / [kConnectorFullDrawMeters] /
/// [kStitchToleranceMeters]):
///  - THORN-DROP: a way with node ids that does NOT bridge two driven ways and
///    whose total driven length < floor is dropped.
///  - CONNECTOR-CLOSE: a short way that bridges two driven ways at OPPOSITE
///    endpoints is drawn full-length (closes the junction).
///  - NORMAL-CLIP: otherwise clip to the union interval(s); snap an interval end
///    to a shared endpoint node when within tolerance.
///
/// Pure — no I/O, no Flutter; safe on the matcher/compute isolate.
List<CoverageWay> clipDrivenWays({
  required Map<int, List<(double, double)>> unionByWayId,
  required Map<int, List<LatLng>> geomByWayId,
  required Map<int, List<int>> nodesByWayId,
}) {
  // Driven-way endpoint node graph: nodeId → driven wayIds that start/end there.
  final nodeToWays = <int, Set<int>>{};
  geomByWayId.forEach((wid, g) {
    final n = nodesByWayId[wid];
    if (n == null || n.length != g.length || n.isEmpty) return;
    (nodeToWays[n.first] ??= <int>{}).add(wid);
    (nodeToWays[n.last] ??= <int>{}).add(wid);
  });
  bool sharedWithOther(int node, int self) {
    final s = nodeToWays[node];
    return s != null && s.any((w) => w != self);
  }

  final out = <CoverageWay>[];
  for (final entry in unionByWayId.entries) {
    final wayId = entry.key;
    final geom = geomByWayId[wayId];
    if (geom == null) continue; // geometry not cached (offline gap) — skip
    final intervals = entry.value;
    if (intervals.isEmpty) continue;

    final nodes = nodesByWayId[wayId];
    final hasNodes =
        nodes != null && nodes.length == geom.length && nodes.isNotEmpty;
    final full = polylineLengthMeters(geom);

    var drivenUnionM = 0.0;
    for (final (s, e) in intervals) {
      drivenUnionM += (e - s).abs();
    }

    final firstShared = hasNodes && sharedWithOther(nodes.first, wayId);
    final lastShared = hasNodes && sharedWithOther(nodes.last, wayId);
    final bridges = firstShared && lastShared;

    // THORN-DROP: short, node-known, not bridging → junction mis-snap.
    // Guard with the driven FRACTION: a mostly-driven short through-road pinned
    // to the net at only ONE endpoint (out-and-back turnaround) has a high
    // du/full ratio and must NOT be discarded — dropping it punched 24-40m
    // holes in Miltenberg through-roads (Mainstraße/Jahnstraße/Mainzer Straße).
    // A genuine 2-fix mis-snap has du/full ≈ 0, so the 0.5 cutoff separates them.
    if (hasNodes &&
        !bridges &&
        drivenUnionM < kThornFloorMeters &&
        (full <= 0 || drivenUnionM / full < 0.5)) {
      continue;
    }

    // CONNECTOR-CLOSE: short bridging link the matcher may have collapsed to a
    // point → draw full so the junction closes.
    if (bridges && full <= kConnectorFullDrawMeters) {
      out.add(
        CoverageWay(
          wayId: wayId,
          geometry: List<LatLng>.of(geom),
          datum: const CoverageDatum(fraction: 1, isFull: true),
        ),
      );
      continue;
    }

    // NORMAL-CLIP: clip each union interval; node-id-gated stitch on the
    // outermost interval ends only.
    final sorted = [...intervals]
      ..sort((a, b) {
        final la = a.$1 < a.$2 ? a.$1 : a.$2;
        final lb = b.$1 < b.$2 ? b.$1 : b.$2;
        return la.compareTo(lb);
      });
    for (var i = 0; i < sorted.length; i++) {
      var lo = sorted[i].$1 < sorted[i].$2 ? sorted[i].$1 : sorted[i].$2;
      var hi = sorted[i].$1 > sorted[i].$2 ? sorted[i].$1 : sorted[i].$2;
      if (i == 0 && firstShared && lo <= kStitchToleranceMeters) lo = 0;
      if (i == sorted.length - 1 &&
          lastShared &&
          hi >= full - kStitchToleranceMeters) {
        hi = full;
      }
      // With node ids we do the stitch ourselves (snapMeters:0); without them
      // fall back to the old blanket own-end snap.
      final seg = reconstructWaySubsegment(
        geom,
        lo,
        hi,
        snapMeters: hasNodes ? 0 : kWaySubsegmentSnapMeters,
      );
      if (seg.length < 2) continue;
      out.add(
        CoverageWay(
          wayId: wayId,
          geometry: seg,
          datum: const CoverageDatum(fraction: 1, isFull: true),
        ),
      );
    }
  }
  return out;
}
