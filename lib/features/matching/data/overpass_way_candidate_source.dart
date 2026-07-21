// Phase 4 rescope Wave 2 (Plan 04-15):
// Runtime [WayCandidateSource] implementation combining:
//   * 04-13's `OverpassClient` for on-demand network fetch.
//   * 04-14's `OverpassWayCacheDao` for cache-first reads + LRU/TTL storage.
//   * 04-15's `TileBboxMath` for slippy-tile partitioning.
//
// **Tile-splitting is MANDATORY for v1** (04-13 payload probe verdict —
// see `.planning/phases/04-osm-pipeline/04-13-PAYLOAD-PROBE.md`). Every
// request is partitioned into z12 tiles; each tile is either satisfied from
// the cache or fetched individually. The "coalesce ≤ 4 tiles into a single
// Overpass query" branch sketched in the plan text is NOT implemented — the
// probe measured 294 MiB / 108k ways for a 100 km × 100 km bbox, so
// bundling tile queries would revive the same failure mode.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/daos/overpass_way_cache_dao.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/features/matching/data/overpass_client.dart';
import 'package:auto_explore/features/matching/data/overpass_response_parser.dart';
import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:logging/logging.dart';

/// Cache TTL — mirrors [OverpassWayCacheDao]'s sweep threshold. Fetches
/// whose `fetched_at` is older than this are treated as misses.
const Duration kOverpassCacheTtl = Duration(days: 30);

/// Max concurrent Overpass fetches per source call. Matches the free-tier
/// FOSSGIS slot count (typically 2 concurrent slots per client IP).
const int kOverpassFetchConcurrency = 2;

/// Cache-first, Overpass-backed [WayCandidateSource].
///
/// Flow of `fetchWaysInBbox(...)`:
///   1. Partition the bbox into z12 tiles via [TileBboxMath].
///   2. For each tile, `getByTile(z,x,y)` — filter out TTL-expired rows.
///   3. Collect missing tiles → fetch each via [OverpassClient] with
///      per-tile concurrency clamped to [kOverpassFetchConcurrency].
///   4. For each fetched tile, gzip the raw JSON and `put(...)` into the
///      cache with `wayCount` = number of parsed candidates.
///   5. Decode every cached tile's payload (gunzip → parse) and dedupe by
///      `wayId` (a way that spans two tiles appears twice pre-dedupe).
///   6. Bbox-clip the result to the requested rectangle (a candidate lives
///      in a tile if any point of its geometry is inside the tile; without
///      clip we'd return roads outside the caller's bbox).
class OverpassWayCandidateSource implements WayCandidateSource {
  OverpassWayCandidateSource({
    required OverpassClient client,
    required OverpassWayCacheDao cacheDao,
    TileBboxMath tileMath = const TileBboxMath(),
    OverpassResponseParser parser = const OverpassResponseParser(),
    DateTime Function() now = DateTime.now,
    int fetchConcurrency = kOverpassFetchConcurrency,
  })  : _client = client,
        _cacheDao = cacheDao,
        _tileMath = tileMath,
        _parser = parser,
        _now = now,
        _fetchConcurrency = fetchConcurrency;

  final OverpassClient _client;
  final OverpassWayCacheDao _cacheDao;
  final TileBboxMath _tileMath;
  final OverpassResponseParser _parser;
  final DateTime Function() _now;
  final int _fetchConcurrency;

  final _log = Logger('overpass_way_source');

  /// Per-instance tile cache hit counter.
  ///
  /// Counts z12 tiles served from a fresh DB cache row in
  /// [_collectFreshTiles]. Counters are per-instance and reset when the
  /// provider is rebuilt (e.g. after a restore invalidation). Only the
  /// main-isolate cache-first pre-fetch calls are counted — the matcher
  /// isolate holds its own [OverpassWayCandidateSource] copy whose counters
  /// are not surfaced here.
  int _cacheHits = 0;

  /// Per-instance tile cache miss counter (tile needed a network fetch).
  /// See [_cacheHits] for the documented limitation.
  int _cacheMisses = 0;

  /// Number of tiles served from a fresh DB cache row since this instance
  /// was created.
  int get cacheHits => _cacheHits;

  /// Number of tiles that required a network fetch since this instance was
  /// created.
  int get cacheMisses => _cacheMisses;

  /// Cache hit rate in [0, 1], or `null` before any fetch call.
  ///
  /// Returns `null` (not 0) until at least one tile has been classified as
  /// hit or miss, so callers can distinguish "no data yet" from "0 % hit
  /// rate".
  double? get cacheHitRate {
    final total = _cacheHits + _cacheMisses;
    return total == 0 ? null : _cacheHits / total;
  }

  @override
  Future<List<WayCandidate>> fetchWaysInBbox({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    bool throwOnError = true,
    Set<TileId>? restrictTiles,
    bool cacheOnly = false,
    void Function(int done, int total)? onTileProgress,
  }) async {
    final freshCached = await _collectFreshTiles(
      minLat: minLat,
      minLon: minLon,
      maxLat: maxLat,
      maxLon: maxLon,
      throwOnError: throwOnError,
      restrictTiles: restrictTiles,
      cacheOnly: cacheOnly,
      onTileProgress: onTileProgress,
    );

    // Decode every cached tile's payload, dedupe, and bbox-clip.
    //
    // NOTE (Plan 06-07): this decode path runs on the CALLING isolate and is
    // therefore only appropriate for SMALL, single-trip callers (the detail
    // screen overlay + golden-fixture exporter). The matching pipeline uses
    // [fetchRawTilesInBbox] instead and decodes inside the matcher isolate.
    final seenIds = <int>{};
    final results = <WayCandidate>[];
    for (final row in freshCached.values) {
      final rawJson = utf8.decode(gzip.decode(row.payloadGzip));
      final candidates = _parser.parseWays(rawJson);
      for (final c in candidates) {
        if (!seenIds.add(c.wayId)) continue;
        if (!_geometryTouchesBbox(c, minLat, minLon, maxLat, maxLon)) continue;
        results.add(c);
      }
    }
    return results;
  }

  @override
  Future<List<RawTilePayload>> fetchRawTilesInBbox({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    bool throwOnError = true,
    Set<TileId>? restrictTiles,
    bool cacheOnly = false,
    void Function(int done, int total)? onTileProgress,
  }) async {
    final freshCached = await _collectFreshTiles(
      minLat: minLat,
      minLon: minLon,
      maxLat: maxLat,
      maxLon: maxLon,
      throwOnError: throwOnError,
      restrictTiles: restrictTiles,
      cacheOnly: cacheOnly,
      onTileProgress: onTileProgress,
    );
    // Return the raw gzipped payloads + tile bboxes WITHOUT decoding — the
    // matcher isolate does the decode/parse/filter (Plan 06-07). Only the
    // async cache reads + network fetches above ran on this isolate.
    return [
      for (final entry in freshCached.entries)
        RawTilePayload(
          payloadGzip: Uint8List.fromList(entry.value.payloadGzip),
          bbox: _tileMath.tileToBbox(entry.key),
        ),
    ];
  }

  /// Cache-pass + fetch-missing shared by [fetchWaysInBbox] and
  /// [fetchRawTilesInBbox]. Returns the fresh cache rows keyed by tile. No
  /// decoding happens here — only Drift reads and (bounded-concurrency)
  /// network fetches.
  Future<Map<TileId, OverpassWayCacheData>> _collectFreshTiles({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    required bool throwOnError,
    Set<TileId>? restrictTiles,
    bool cacheOnly = false,
    void Function(int done, int total)? onTileProgress,
  }) async {
    var tiles = _tileMath.bboxToZ12Tiles(minLat, minLon, maxLat, maxLon);
    // Corridor restriction (2026-07-21): keep only tiles the trip path touches.
    // Intersection (not replacement) guarantees the result stays ⊆ bbox even if
    // the caller's set was computed at a different zoom or drifted — a safety
    // net, never an expansion. An empty intersection would fetch nothing, so
    // only apply when it leaves at least one tile.
    if (restrictTiles != null) {
      final narrowed = tiles.intersection(restrictTiles);
      if (narrowed.isNotEmpty) tiles = narrowed;
    }
    final cutoff = _now().subtract(kOverpassCacheTtl);

    final total = tiles.length;
    var done = 0;
    // Emit the initial 0/total so the UI shows a determinate bar immediately
    // rather than flashing the indeterminate spinner before the first tile.
    onTileProgress?.call(done, total);

    // 1. Cache pass — figure out which tiles are already fresh in the DB
    //    and which ones need network fetch. Increment [_cacheHits] /
    //    [_cacheMisses] so callers can observe the hit rate on this instance.
    final freshCached = <TileId, OverpassWayCacheData>{};
    final missing = <TileId>[];
    for (final t in tiles) {
      final row = await _cacheDao.getByTile(t.z, t.x, t.y);
      if (row == null || row.fetchedAt.isBefore(cutoff)) {
        _cacheMisses++;
        missing.add(t);
      } else {
        _cacheHits++;
        freshCached[t] = row;
        onTileProgress?.call(++done, total);
      }
    }

    // 2. Fetch missing tiles (bounded concurrency). Any per-tile network
    //    error is either surfaced (throwOnError=true) or swallowed
    //    (throwOnError=false — used by the offline-drain path).
    //
    //    cacheOnly SHORT-CIRCUITS this step: read-only display recomputes
    //    (coverage overlay + region recompute) must never block on network
    //    fetches for off-corridor tiles the matcher never needed — those
    //    uncached tiles are simply omitted (2026-07-21 hang fix). The missing
    //    tiles are still counted in `total` above, so progress ends < total,
    //    which is fine: no consumer of a cacheOnly call reads progress.
    if (missing.isNotEmpty && !cacheOnly) {
      DomainError? firstError;
      final iter = missing.iterator;
      final workers = List.generate(
        _fetchConcurrency.clamp(1, missing.length),
        (_) => _fetchWorker(
          takeNext: () {
            if (iter.moveNext()) return iter.current;
            return null;
          },
          throwOnError: throwOnError,
          onError: (e) => firstError ??= e,
          onFetched: (tile, row) {
            freshCached[tile] = row;
            onTileProgress?.call(++done, total);
          },
        ),
      );
      await Future.wait(workers);
      if (firstError != null && throwOnError) {
        // Propagate the first observed DomainError verbatim — this preserves
        // the underlying NetworkError.statusCode for the retry-scheduler.
        throw firstError!;
      }
    }

    return freshCached;
  }

  Future<void> _fetchWorker({
    required TileId? Function() takeNext,
    required bool throwOnError,
    required void Function(DomainError) onError,
    required void Function(TileId, OverpassWayCacheData) onFetched,
  }) async {
    while (true) {
      final tile = takeNext();
      if (tile == null) return;
      try {
        final bbox = _tileMath.tileToBbox(tile);
        // Fetch raw JSON via a low-level POST that reuses OverpassClient's
        // retry/fallback logic, then persist the raw bytes so cache reads
        // stay format-stable across parser evolution.
        final rawJson = await _client.fetchRawJson(
          minLat: bbox.minLat,
          minLon: bbox.minLon,
          maxLat: bbox.maxLat,
          maxLon: bbox.maxLon,
        );
        final gzipBytes = Uint8List.fromList(gzip.encode(utf8.encode(rawJson)));
        final wayCount = _parser.parseWays(rawJson).length;
        await _cacheDao.put(
          z: tile.z,
          x: tile.x,
          y: tile.y,
          payloadGzip: gzipBytes,
          wayCount: wayCount,
          now: _now(),
        );
        final row = await _cacheDao.getByTile(tile.z, tile.x, tile.y);
        if (row != null) onFetched(tile, row);
      } on DomainError catch (e) {
        _log.warning('tile fetch failed: $tile — ${e.message}');
        onError(e);
        if (!throwOnError) continue;
        return;
      } on Object catch (e, st) {
        _log.warning('tile fetch wrapped: $tile — $e');
        onError(DomainError.wrap(e, st));
        if (!throwOnError) continue;
        return;
      }
    }
  }

  bool _geometryTouchesBbox(
    WayCandidate c,
    double minLat,
    double minLon,
    double maxLat,
    double maxLon,
  ) {
    for (final p in c.geometry) {
      if (p.latitude >= minLat &&
          p.latitude <= maxLat &&
          p.longitude >= minLon &&
          p.longitude <= maxLon) {
        return true;
      }
    }
    return false;
  }
}
