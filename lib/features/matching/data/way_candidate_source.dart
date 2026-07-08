// Phase 4 rescope Wave 2 (Plan 04-15):
// Abstract source of OSM way candidates for the map-matcher.
//
// Two implementations exist:
//   * `OverpassWayCandidateSource` — runtime, cache-first, network-backed.
//   * `FixtureWayCandidateSource` (test/helpers/) — deterministic, offline.
//
// The interface is what Phase 5's HMM matcher consumes. Both implementations
// must apply the Kfz allowlist (`kfzHighwayClasses` in
// `lib/features/matching/domain/way_candidate.dart`) and deduplicate by
// `wayId` across tile boundaries.
//
// The interface intentionally exposes a single method — future
// implementations may add sibling helpers, but the matcher only depends on
// this call, so `one_member_abstracts` is disabled at the file level.
// ignore_for_file: one_member_abstracts

import 'package:auto_explore/features/matching/domain/way_candidate.dart';

/// Abstract seam consumed by the future map-matcher (Phase 5).
///
/// `fetchWaysInBbox` returns every Kfz-allowlisted [WayCandidate] whose
/// geometry intersects the requested bbox. Coordinate order is
/// `(minLat, minLon, maxLat, maxLon)` — matches Overpass's
/// `(south, west, north, east)` convention.
///
/// `throwOnError` controls network-failure behavior:
///   * `true` (default) — rethrow as a `DomainError` (`NetworkError` for
///     HTTP failures, wrapped `UnknownError` otherwise).
///   * `false` — return whatever cached candidates are available and swallow
///     the network error. Used by the offline-drain path (04-15 coordinator).
abstract class WayCandidateSource {
  Future<List<WayCandidate>> fetchWaysInBbox({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    bool throwOnError = true,
  });
}
