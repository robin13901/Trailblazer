// Trailblazer undriven-ways overlay: the imperative controller.
//
// The region detail sheet's "Ungefahrene Wege anzeigen" button calls
// [UndrivenOverlayController.showRegion]; the headless UndrivenOverlayBridge
// watches [undrivenOverlayControllerProvider] and paints the result in blue.
//
// Deliberately IMPERATIVE (a Notifier<AsyncValue<…>> with explicit show/clear),
// not a reactive FutureProvider: the load is user-triggered, must not re-run on
// unrelated rebuilds, and drives a separate progress provider — all awkward
// inside a provider build (would mutate another provider during build).
//
// IN-MEMORY ONLY: the computed result lives in this Notifier's state and is
// discarded when the app closes (default state is empty). The tile fetch reads
// the shared Overpass cache but never writes to it (`persist: false`).
//
// Plain Notifier — no @Riverpod codegen (STATE 01-01).

import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/admin/data/admin_region_providers.dart';
import 'package:auto_explore/features/coverage/data/coverage_overlay_data.dart';
import 'package:auto_explore/features/coverage/data/coverage_overlay_providers.dart';
import 'package:auto_explore/features/coverage/data/undriven_fetch_progress_provider.dart';
import 'package:auto_explore/features/coverage/domain/interval_union.dart';
import 'package:auto_explore/features/coverage/domain/undriven_ways.dart';
import 'package:auto_explore/features/matching/data/matching_providers.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

final _log = Logger('UndrivenOverlayController');

/// Lowest admin level the undriven overlay is offered for: Gemeinde / Ortsteil
/// (8/9/10). Landkreis (6) and above span too many tiles (user decision
/// 2026-10-21). The region detail sheet gates its button on the same bound.
const int kUndrivenMinAdminLevel = 8;

/// Imperative controller for the on-demand undriven-ways overlay.
///
/// State:
///   - `AsyncData(empty)` — nothing shown (idle / cleared).
///   - `AsyncLoading()`   — fetching + computing (progress via the banner).
///   - `AsyncData(ways)`  — the undriven segments to paint.
class UndrivenOverlayController extends Notifier<AsyncValue<CoverageOverlayData>> {
  @override
  AsyncValue<CoverageOverlayData> build() =>
      const AsyncData(CoverageOverlayData.empty);

  /// Fetch + compute the undriven ways inside the region with [osmId] and
  /// expose them. No-op (clears) when the region is unknown or coarser than
  /// [kUndrivenMinAdminLevel]. Reads the shared tile cache but never writes it.
  Future<void> showRegion(int osmId) async {
    final region = ref.read(adminRegionLookupProvider).regionByOsmId(osmId);
    if (region == null || region.adminLevel < kUndrivenMinAdminLevel) {
      state = const AsyncData(CoverageOverlayData.empty);
      return;
    }

    state = const AsyncLoading<CoverageOverlayData>();
    final progress = ref.read(undrivenFetchProgressProvider.notifier);

    try {
      final data = await _resolve(region, progress);
      state = AsyncData(data);
    } on Object catch (e, st) {
      // Fail soft — the map must never crash, and a failed ad-hoc lookup just
      // shows nothing rather than an error surface.
      _log.warning('undriven overlay resolve failed — showing nothing', e, st);
      state = const AsyncData(CoverageOverlayData.empty);
    } finally {
      progress.clear();
    }
  }

  /// Clear the overlay (dismiss chip / plain jump-to-map / new region).
  void clear() => state = const AsyncData(CoverageOverlayData.empty);

  Future<CoverageOverlayData> _resolve(
    AdminRegion region,
    UndrivenFetchProgressNotifier progress,
  ) async {
    // Read the shared tile cache + fetch only the missing tiles, WITHOUT
    // persisting them (persist:false). The concrete source is required for the
    // persist option; if the source was overridden with a fake (tests) we skip.
    final source = ref.read(overpassWayCandidateSourceProvider);
    if (source == null) return CoverageOverlayData.empty;

    final ways = await source.fetchWaysInBbox(
      minLat: region.bboxMinLat,
      minLon: region.bboxMinLon,
      maxLat: region.bboxMaxLat,
      maxLon: region.bboxMaxLon,
      throwOnError: false,
      persist: false,
      onTileProgress: progress.update,
    );
    if (ways.isEmpty) return CoverageOverlayData.empty;

    // Driven intervals grouped per way (all trips).
    final rows = await ref.read(drivenWayIntervalsDaoProvider).getAllIntervals();
    final drivenByWayId = <int, List<Interval>>{};
    for (final r in rows) {
      (drivenByWayId[r.wayId] ??= <Interval>[]).add(
        Interval(r.startMeters, r.endMeters),
      );
    }

    // Clip + complement off the UI isolate (containment over all region ways).
    final clipped = await compute(
      _computeUndrivenEntry,
      _UndrivenPayload(
        ways: ways,
        region: region,
        drivenByWayId: drivenByWayId,
      ),
    );
    return clipped;
  }
}

/// On-demand undriven-ways overlay. Default `AsyncData(empty)` = nothing shown.
final undrivenOverlayControllerProvider =
    NotifierProvider<
      UndrivenOverlayController,
      AsyncValue<CoverageOverlayData>
    >(UndrivenOverlayController.new);

/// compute() entry — top-level so it can cross the isolate boundary.
CoverageOverlayData _computeUndrivenEntry(_UndrivenPayload p) {
  return CoverageOverlayData(
    computeUndrivenWays(
      ways: p.ways,
      region: p.region,
      drivenByWayId: p.drivenByWayId,
    ),
  );
}

/// Sendable payload for [_computeUndrivenEntry] (all fields are plain value
/// types / primitive-backed, so they cross the SendPort untouched).
@immutable
class _UndrivenPayload {
  const _UndrivenPayload({
    required this.ways,
    required this.region,
    required this.drivenByWayId,
  });

  final List<WayCandidate> ways;
  final AdminRegion region;
  final Map<int, List<Interval>> drivenByWayId;
}
