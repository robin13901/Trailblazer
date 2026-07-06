/// Vector-tile layer vocabulary — the single source of truth shared between
/// the tippecanoe emit stage (04-07) and the style JSON rewrite (04-08).
///
/// The four layer names and per-feature `kind` values follow 04-RESEARCH §3
/// (Protomaps v4 semantics, road-graph subset). Style JSON `source-layer`
/// references MUST match the constants in [Layers] verbatim.
library;

/// Vector tile layer names — must match style JSON source-layer references.
///
/// 04-08 rewrites `map_style_light.json` + `map_style_dark.json` to target
/// these layer names.
abstract final class Layers {
  /// Roads layer (motorway..path + Feldweg tracks).
  static const String roads = 'roads';

  /// Admin boundaries layer (country..suburb, both LineString + Polygon).
  static const String adminBoundaries = 'admin_boundaries';

  /// Water bodies + waterways layer (inland lakes, rivers, streams).
  static const String water = 'water';

  /// Labels layer (place names + road shields).
  static const String labels = 'labels';
}

/// Collapse motorway_link → motorway, primary_link → primary, etc., per
/// 04-RESEARCH §3.
///
/// Unknown highway values collapse to `other`.
String collapseHighwayKind(String osmHighway) {
  switch (osmHighway) {
    case 'motorway_link':
      return 'motorway';
    case 'trunk_link':
      return 'trunk';
    case 'primary_link':
      return 'primary';
    case 'secondary_link':
      return 'secondary';
    case 'tertiary_link':
      return 'tertiary';
    case 'motorway':
    case 'trunk':
    case 'primary':
    case 'secondary':
    case 'tertiary':
      return osmHighway;
    case 'residential':
    case 'unclassified':
    case 'living_street':
    case 'road':
      return 'minor';
    case 'track':
      return 'track';
    case 'path':
      return 'path';
    default:
      return 'other';
  }
}

/// Minimum zoom per road kind (Protomaps convention, 04-RESEARCH §3).
int minZoomForRoadKind(String kind) {
  switch (kind) {
    case 'motorway':
      return 5;
    case 'trunk':
      return 6;
    case 'primary':
      return 7;
    case 'secondary':
      return 9;
    case 'tertiary':
      return 10;
    case 'minor':
    case 'track':
    case 'path':
      return 11;
    default:
      return 11;
  }
}

/// Admin level → kind label (04-RESEARCH §3).
///
/// Levels outside `{2, 4, 6, 8, 9, 10}` collapse to `other`.
String adminKindForLevel(int lvl) {
  switch (lvl) {
    case 2:
      return 'country';
    case 4:
      return 'state';
    case 6:
      return 'county';
    case 8:
      return 'municipality';
    case 9:
      return 'district';
    case 10:
      return 'suburb';
    default:
      return 'other';
  }
}

/// Minimum zoom per admin level (04-RESEARCH §3).
///
///   * L2/L4 visible from world view (`min_zoom = 0`).
///   * L6 counties from zoom 6.
///   * L8/L9/L10 (municipalities + below) from zoom 9.
int minZoomForAdminLevel(int lvl) {
  if (lvl <= 4) return 0;
  if (lvl == 6) return 6;
  return 9;
}
