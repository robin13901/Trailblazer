import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/tables/overpass_way_cache_table.dart';
import 'package:drift/drift.dart';

part 'overpass_way_cache_dao.g.dart';

/// DAO for the Overpass way-cache — gzipped raw JSON per slippy z12 tile.
///
/// Wave-2 flow (04-15) uses this to short-circuit re-fetching the same tile
/// when the user re-drives the same road within the TTL window.
///
/// Budget: [_lruHighWaterBytes] 50 MB compressed; when a write pushes total
/// bytes above the high water mark, LRU-evict rows (oldest `fetchedAt` first)
/// until under [_lruLowWaterBytes] 40 MB. TTL is 30 days (RESEARCH §2).
@DriftAccessor(tables: [OverpassWayCache])
class OverpassWayCacheDao extends DatabaseAccessor<AppDatabase>
    with _$OverpassWayCacheDaoMixin {
  OverpassWayCacheDao(super.attachedDatabase);

  static const int _lruHighWaterBytes = 50 * 1024 * 1024; // 50 MB
  static const int _lruLowWaterBytes = 40 * 1024 * 1024; // 40 MB
  static const Duration _ttl = Duration(days: 30);

  /// Read the cache entry for slippy tile (z, x, y). Null on miss.
  Future<OverpassWayCacheData?> getByTile(int z, int x, int y) {
    return (select(overpassWayCache)
          ..where(
            (t) =>
                t.tileZ.equals(z) & t.tileX.equals(x) & t.tileY.equals(y),
          ))
        .getSingleOrNull();
  }

  /// Upsert a cache entry and enforce the LRU budget after write.
  Future<void> put({
    required int z,
    required int x,
    required int y,
    required Uint8List payloadGzip,
    required int wayCount,
    DateTime? now,
  }) async {
    await into(overpassWayCache).insertOnConflictUpdate(
      OverpassWayCacheCompanion.insert(
        tileZ: z,
        tileX: x,
        tileY: y,
        fetchedAt: Value(now ?? DateTime.now()),
        wayCount: wayCount,
        payloadGzip: payloadGzip,
        payloadBytes: payloadGzip.length,
      ),
    );
    await _enforceLruBudget();
  }

  /// Delete rows older than 30 days. Returns count deleted.
  Future<int> sweepTtl({DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).subtract(_ttl);
    return (delete(overpassWayCache)
          ..where((t) => t.fetchedAt.isSmallerThanValue(cutoff)))
        .go();
  }

  /// Delete every cached tile with `way_count == 0`. Returns count deleted.
  ///
  /// Used by the one-shot stuck-fetch recovery migration (2026-07-14) to purge
  /// tiles poisoned before the Overpass HTTP-200-error client fix: an HTML
  /// error page served under 200 was parsed to zero ways and cached as a
  /// 0-way tile that would otherwise persist for the 30-day TTL, permanently
  /// starving a trip's match of road data. Legitimately-empty tiles (water /
  /// forest) are also removed, but they are cheap to refetch and re-cache as
  /// 0 — we cannot distinguish poisoned from genuinely-empty without a
  /// refetch, so purging all 0-way tiles is the safe, self-healing choice.
  Future<int> deleteZeroWayTiles() {
    return (delete(overpassWayCache)..where((t) => t.wayCount.equals(0))).go();
  }

  /// Sum of all `payload_bytes` across the cache. Zero on empty.
  Future<int> totalBytes() async {
    final row = await customSelect(
      'SELECT COALESCE(SUM(payload_bytes), 0) AS bytes FROM overpass_way_cache',
      readsFrom: {overpassWayCache},
    ).getSingle();
    return row.read<int>('bytes');
  }

  /// Delete oldest-fetched rows until `totalBytes() <= [_lruLowWaterBytes]`.
  ///
  /// No-op when already under the high-water mark. Runs an O(N) scan of the
  /// cache table when triggered; acceptable for the 50 MB compressed budget
  /// (30-60 tile-scale rows in practice).
  Future<void> _enforceLruBudget() async {
    final total = await totalBytes();
    if (total <= _lruHighWaterBytes) return;

    var running = total;
    final oldest =
        await (select(overpassWayCache)
              ..orderBy([(t) => OrderingTerm.asc(t.fetchedAt)]))
            .get();
    for (final row in oldest) {
      if (running <= _lruLowWaterBytes) break;
      await (delete(overpassWayCache)..where(
            (t) =>
                t.tileZ.equals(row.tileZ) &
                t.tileX.equals(row.tileX) &
                t.tileY.equals(row.tileY),
          ))
          .go();
      running -= row.payloadBytes;
    }
  }
}
