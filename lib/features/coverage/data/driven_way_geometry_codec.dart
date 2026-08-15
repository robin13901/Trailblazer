// Trailblazer 2026-08-15 (durable way-geometry cache):
// Codec for per-way OSM geometry + node IDs stored in driven_way_geometry.
//
// Geometry shape:  [[lat,lon], [lat,lon], …]
// Node IDs shape:  [nodeId, nodeId, …]  (empty array when unavailable)
//
// Both use compact jsonEncode/jsonDecode — no custom format, easy to debug.

import 'dart:convert';

import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

/// Encodes a way's geometry polyline to JSON for DB storage.
String encodeWayGeometry(List<LatLng> geom) {
  return jsonEncode([
    for (final p in geom) [p.latitude, p.longitude],
  ]);
}

/// Decodes a stored geometry JSON back to a LatLng list.
/// Returns an empty list for null / malformed input — never throws.
List<LatLng> decodeWayGeometry(String? json) {
  if (json == null || json.isEmpty) return const [];
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return const [];
    final out = <LatLng>[];
    for (final p in decoded) {
      if (p is List && p.length >= 2) {
        out.add(LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()));
      }
    }
    return out;
  } on Object {
    return const [];
  }
}

/// Encodes a way's parallel OSM node ID list to JSON for DB storage.
String encodeNodeIds(List<int> ids) => jsonEncode(ids);

/// Decodes a stored node ID JSON back to a List`<`int`>`.
/// Returns an empty list for null / malformed input — never throws.
List<int> decodeNodeIds(String? json) {
  if (json == null || json.isEmpty) return const [];
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return const [];
    return [for (final id in decoded) (id as num).toInt()];
  } on Object {
    return const [];
  }
}
