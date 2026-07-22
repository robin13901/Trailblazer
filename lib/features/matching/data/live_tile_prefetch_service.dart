// Trailblazer — LiveTilePrefetchService (Idea #6 "Half A", 2026-07-22).
//
// While a trip is being recorded, this service periodically pre-warms the
// Overpass road-tile cache for the ALREADY-DRIVEN portion of the trip, so that
// when the trip stops the final map-match finds every corridor tile cache-hot
// and starts almost immediately — instead of paying the full network cost
// (~dozens of throttled Overpass tiles) all at once at the end.
//
// WHAT THIS DOES NOT DO — and deliberately so:
//   * It does NOT run the map-matcher incrementally. The Viterbi decode stays a
//     single whole-trip batch at trip end (its backward traceback needs the
//     full sequence; chunk boundaries would reintroduce the traceback
//     chain-break class of bug fixed by rematch v7). This service only warms
//     the tile CACHE — the exact same content-addressed z/x/y tiles the final
//     match reads. Warming a tile can never change match correctness.
//   * Because it only touches the cache, a long dwell (e.g. 3 min at a barrier)
//     is harmless: the stacked stationary fixes all map to a tile that is
//     already fetched, so no repeated work and no "garbage" — the user's
//     stated worry applies to incremental matching, which we are not doing.
//
// STAYING BEHIND THE LIVE POINT: we intentionally prefetch only a LAGGING
// prefix of the path — the points up to [_lagPoints] fixes before the newest —
// so we never chase the just-arrived fix (which may still be moving / noisy).
// Tiles already fetched near the live edge get picked up on the next tick or,
// worst case, by the final trip-end fetch.

import 'dart:async';

import 'package:auto_explore/features/matching/data/connectivity_seam.dart';
import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:logging/logging.dart';

/// Periodically warms the Overpass tile cache for the driven-so-far corridor of
/// an active recording trip. Fire-and-forget, best-effort, throttle-respecting.
class LiveTilePrefetchService {
  LiveTilePrefetchService({
    required WayCandidateSource source,
    required TripsDao tripsDao,
    required ConnectivitySeam connectivity,
    TileBboxMath tileMath = const TileBboxMath(),
    Duration interval = const Duration(seconds: 45),
    int lagPoints = 15,
  })  : _source = source,
        _tripsDao = tripsDao,
        _connectivity = connectivity,
        _tileMath = tileMath,
        _interval = interval,
        _lagPoints = lagPoints;

  final WayCandidateSource _source;
  final TripsDao _tripsDao;
  final ConnectivitySeam _connectivity;
  final TileBboxMath _tileMath;

  /// How often a prefetch tick runs while recording. 45 s keeps the fetch
  /// trickle gentle (well within the 2-slot Overpass budget) while still
  /// staying far ahead of a trip's end for a long drive.
  final Duration _interval;

  /// How many of the newest persisted fixes to EXCLUDE from each prefetch pass,
  /// so we stay a healthy distance behind the live GPS point. At 1 Hz this is
  /// ~15 s of lag — enough that a just-passed junction settles before we fetch
  /// its tile, and a dwell at the live edge never drives repeated fetches.
  final int _lagPoints;

  final _log = Logger('live_tile_prefetch');

  Timer? _ticker;
  int? _tripId;

  /// Tiles already requested this session — never re-requested. The underlying
  /// source is itself cache-first, but this avoids even the cache-hit round trip
  /// and keeps each tick's work set to genuinely new corridor tiles.
  final Set<TileId> _requested = <TileId>{};

  /// Guards against overlapping ticks if one pass runs longer than [_interval]
  /// (e.g. a slow throttled fetch). A tick is skipped while another is active.
  bool _busy = false;

  /// Begin prefetching for [tripId]. Idempotent per trip; restarts cleanly if
  /// called for a new trip (e.g. after a mid-trip split opens a new trip row).
  void start(int tripId) {
    if (_tripId == tripId && _ticker != null) return;
    stop();
    _tripId = tripId;
    _requested.clear();
    // Fire a first tick shortly after start so an early stop on a short trip
    // still benefits, then settle into the periodic cadence.
    _ticker = Timer.periodic(_interval, (_) => unawaited(_tick()));
  }

  /// Stop prefetching and release per-trip state.
  void stop() {
    _ticker?.cancel();
    _ticker = null;
    _tripId = null;
    _requested.clear();
  }

  Future<void> _tick() async {
    if (_busy) return;
    final tripId = _tripId;
    if (tripId == null) return;
    _busy = true;
    try {
      // Skip entirely when offline — no point spinning throttled retries; the
      // trip-end fetch (and its offline queue) will handle it later.
      if (!await _connectivity.isOnline()) return;

      final points = await _tripsDao.listPointsForTrip(tripId);
      // Need enough points that, after dropping the lagging tail, a meaningful
      // prefix remains.
      if (points.length <= _lagPoints + 1) return;

      final prefix = points.sublist(0, points.length - _lagPoints);
      final path = [for (final p in prefix) (lat: p.lat, lon: p.lon)];
      final pathTiles = _tileMath.tilesForPath(path);
      final fresh = pathTiles.difference(_requested);
      if (fresh.isEmpty) return;

      // Mark as requested up-front so a slow fetch doesn't get re-queued by the
      // next tick. Corridor bbox spans the prefix; restrictTiles narrows the
      // actual work to just the fresh corridor tiles.
      _requested.addAll(fresh);

      final bbox = _bboxOf(path);
      _log.fine(
        'prefetch trip $tripId: ${fresh.length} new corridor tile(s) '
        '(${prefix.length} fixes in prefix)',
      );
      // throwOnError:false → a throttle/timeout just leaves those tiles for the
      // next tick or the final trip-end fetch. cacheOnly:false → actually fetch
      // the missing tiles (that's the whole point). We discard the payloads —
      // the goal is the cache write side effect.
      await _source.fetchRawTilesInBbox(
        minLat: bbox.minLat,
        minLon: bbox.minLon,
        maxLat: bbox.maxLat,
        maxLon: bbox.maxLon,
        restrictTiles: fresh,
        throwOnError: false,
      );
      // Catch every throwable — a prefetch is pure optimization and must never
      // disrupt recording.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      _log.warning('prefetch tick failed (ignored): $e', e, st);
    } finally {
      _busy = false;
    }
  }

  ({double minLat, double minLon, double maxLat, double maxLon}) _bboxOf(
    List<({double lat, double lon})> path,
  ) {
    var minLat = 90.0;
    var minLon = 180.0;
    var maxLat = -90.0;
    var maxLon = -180.0;
    for (final p in path) {
      if (p.lat < minLat) minLat = p.lat;
      if (p.lon < minLon) minLon = p.lon;
      if (p.lat > maxLat) maxLat = p.lat;
      if (p.lon > maxLon) maxLon = p.lon;
    }
    return (minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon);
  }
}
