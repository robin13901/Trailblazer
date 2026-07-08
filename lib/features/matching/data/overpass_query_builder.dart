// Phase 4 rescope Wave 2 (Plan 04-13):
// Pure-function Overpass QL query builder.
//
// The result is passed to `OverpassClient.fetchWaysInBbox` (04-13 Task 2)
// which POSTs it as `application/x-www-form-urlencoded` under the `data`
// form key.
//
// Server-side filtering is intentionally minimal (`way[highway]`); the
// Kfz-vs-Feldweg allowlist is applied client-side inside
// `OverpassResponseParser` — this keeps the QL simple and lets us change the
// allowlist without redeploying a new query shape.

/// Builds Overpass QL bodies for bbox highway fetches.
///
/// Idempotent, stateless, allocation-cheap — hold as `const` at call sites.
class OverpassQueryBuilder {
  const OverpassQueryBuilder();

  /// Builds a QL body that fetches every way carrying a `highway=` tag
  /// intersecting the given bbox, with full geometry inlined and results
  /// sorted quadtree-style (`qt`) for tile-friendly ordering.
  ///
  /// Overpass bbox coordinate order is `(south, west, north, east)` — this
  /// method takes the corresponding named args to keep call sites obvious.
  ///
  /// [timeoutSeconds] maps to the QL `[timeout:X]` directive; the client-side
  /// HTTP timeout is separately configured on `OverpassClient` and should be
  /// slightly larger than this value.
  String buildBboxHighwayQuery({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    int timeoutSeconds = 25,
  }) {
    // Multi-line output is deliberate — makes probe curl one-liners readable
    // when the URL-decoded body lands in a logfile or a bug report.
    return '[out:json][timeout:$timeoutSeconds];\n'
        'way[highway]($minLat,$minLon,$maxLat,$maxLon);\n'
        'out geom qt;';
  }
}
