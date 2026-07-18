// Phase 4 rescope Wave 2 (Plan 04-13):
// Overpass JSON-response → `List<WayCandidate>` parser.
//
// Overpass returns a JSON envelope of the shape:
//
// ```json
// {
//   "version": 0.6,
//   "generator": "Overpass API ...",
//   "elements": [
//     { "type": "way", "id": 1234, "geometry": [{"lat":..., "lon":...}, ...],
//       "tags": { "highway": "primary", "name": "Foo", ... } },
//     ...
//   ]
// }
// ```
//
// The parser is defensive: unknown element types are skipped, non-numeric
// way ids are skipped, geometry lists shorter than 2 points are skipped
// (can't drive along a single node), and any way whose `highway` tag is
// outside the Kfz allowlist is dropped at this boundary.

import 'dart:convert';

import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

/// Parses raw Overpass JSON bodies into filtered `List<WayCandidate>`.
///
/// Stateless; hold `const OverpassResponseParser()` at call sites.
class OverpassResponseParser {
  const OverpassResponseParser();

  /// Parses [rawJson] into a list of Kfz-allowlisted [WayCandidate]s.
  ///
  /// Non-way elements, malformed geometry, missing `highway` tags, and
  /// non-Kfz highway classes are dropped silently — the caller receives only
  /// well-formed drivable candidates. If [rawJson] cannot be parsed as JSON
  /// or lacks an `elements` array, an empty list is returned (callers should
  /// treat this as a valid "no candidates" response, not as an error — the
  /// HTTP layer decides success/failure).
  List<WayCandidate> parseWays(String rawJson) {
    final Object? decoded;
    try {
      decoded = jsonDecode(rawJson);
    } on FormatException {
      // Malformed JSON body (e.g. an HTML error page slipped past the HTTP
      // layer's 200 gate). Callers get an empty list — the client will
      // decide whether to retry based on the HTTP status, not on parse
      // success alone.
      return const [];
    }
    if (decoded is! Map<String, dynamic>) return const [];
    final elements = decoded['elements'];
    if (elements is! List) return const [];

    final results = <WayCandidate>[];
    for (final raw in elements) {
      if (raw is! Map<String, dynamic>) continue;
      if (raw['type'] != 'way') continue;

      final id = raw['id'];
      if (id is! int) continue;

      final geomRaw = raw['geometry'];
      if (geomRaw is! List) continue;
      final geometry = <LatLng>[];
      for (final pt in geomRaw) {
        if (pt is! Map) continue;
        final lat = pt['lat'];
        final lon = pt['lon'];
        if (lat is! num || lon is! num) continue;
        geometry.add(LatLng(lat.toDouble(), lon.toDouble()));
      }
      if (geometry.length < 2) continue;

      // OSM node ids (`elements[].nodes`) run parallel to `geometry` in an
      // `out geom` response. Capture them for exact junction topology — two
      // ways share a node iff they list the same id. Only trust the array when
      // it is all-int AND exactly as long as the parsed geometry; any mismatch
      // (a skipped malformed geometry point above, or a truncated response)
      // would misalign node↔coordinate, so we drop to `const []` and let the
      // matcher fall back to a coordinate hash rather than store bad topology.
      final nodesRaw = raw['nodes'];
      var nodeIds = const <int>[];
      if (nodesRaw is List && nodesRaw.length == geometry.length) {
        final parsed = <int>[];
        var ok = true;
        for (final n in nodesRaw) {
          if (n is int) {
            parsed.add(n);
          } else {
            ok = false;
            break;
          }
        }
        if (ok) nodeIds = parsed;
      }

      final tags = raw['tags'];
      if (tags is! Map<String, dynamic>) continue;
      final highwayClass = tags['highway'];
      if (highwayClass is! String) continue;
      if (!kfzHighwayClasses.contains(highwayClass)) continue;

      results.add(
        WayCandidate(
          wayId: id,
          geometry: geometry,
          nodeIds: nodeIds,
          highwayClass: highwayClass,
          name: _stringOrNull(tags['name']),
          ref: _stringOrNull(tags['ref']),
          oneway: _parseOneway(tags['oneway'], highwayClass),
          maxspeedKmh: _parseMaxspeed(tags['maxspeed']),
        ),
      );
    }
    return results;
  }

  /// Implicit-oneway highway classes per OSM wiki + STATE Plan 04-03.
  /// `trunk` itself is NOT implicit-oneway.
  static const _implicitOneway = <String>{
    'motorway',
    'motorway_link',
    'trunk_link',
  };

  static String? _stringOrNull(Object? v) {
    if (v is String && v.isNotEmpty) return v;
    return null;
  }

  static OnewayDirection _parseOneway(Object? raw, String highwayClass) {
    if (raw is String) {
      switch (raw) {
        case 'yes':
        case 'true':
        case '1':
          return OnewayDirection.forward;
        case '-1':
        case 'reverse':
          return OnewayDirection.backward;
        case 'no':
        case 'false':
        case '0':
          return OnewayDirection.no;
      }
    }
    // No/absent explicit tag — apply implicit-oneway rule.
    if (_implicitOneway.contains(highwayClass)) {
      return OnewayDirection.forward;
    }
    return OnewayDirection.no;
  }

  /// Parses OSM `maxspeed` tag values into km/h.
  ///
  /// Handles:
  /// - bare integers (`50`, `100`) → treat as km/h
  /// - `50 kmh` / `50 km/h` / `50km/h` → km/h
  /// - `30 mph` → converted to km/h (round to nearest int)
  /// - `walk` / `signals` / `variable` / `none` / unknown → null
  static int? _parseMaxspeed(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is! String) return null;
    final trimmed = raw.trim().toLowerCase();
    if (trimmed.isEmpty) return null;

    // Plain integer?
    final plain = int.tryParse(trimmed);
    if (plain != null) return plain;

    // With unit suffix — extract leading integer.
    final match = RegExp(r'^(\d+)\s*(km/h|kmh|mph)?').firstMatch(trimmed);
    if (match == null) return null;
    final value = int.tryParse(match.group(1)!);
    if (value == null) return null;
    final unit = match.group(2);
    if (unit == 'mph') {
      // 1 mph = 1.609344 km/h
      return (value * 1.609344).round();
    }
    // km/h, kmh, or no unit → assume km/h
    return value;
  }
}
