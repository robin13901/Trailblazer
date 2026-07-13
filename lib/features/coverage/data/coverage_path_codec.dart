// Trailblazer 2026-07-13 (coverage-from-trail rework):
// coverage_path_codec — JSON (de)serialization for the per-trip coverage
// polyline stored in `trips.coverage_path_json`.
//
// Shape on disk: `[[[lat,lon],[lat,lon],…], …]` — a list of polyline
// segments, each a list of `[lat, lon]` points. Kept as a tiny standalone
// codec so both the writer (TripMatchCoordinator) and the reader
// (coverage overlay data layer) share one format definition.

import 'dart:convert';

/// Encodes [segments] (`[[[lat,lon],…], …]`) to a compact JSON string.
String encodeCoveragePath(List<List<List<double>>> segments) =>
    jsonEncode(segments);

/// Decodes a `trips.coverage_path_json` value back to segments.
///
/// Returns an empty list for `null`, empty, or malformed input — the caller
/// treats "no path" and "unparseable path" identically (render nothing).
List<List<List<double>>> decodeCoveragePath(String? json) {
  if (json == null || json.isEmpty) return const [];
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return const [];
    final segments = <List<List<double>>>[];
    for (final seg in decoded) {
      if (seg is! List) continue;
      final points = <List<double>>[];
      for (final p in seg) {
        if (p is List && p.length >= 2) {
          final lat = (p[0] as num).toDouble();
          final lon = (p[1] as num).toDouble();
          points.add([lat, lon]);
        }
      }
      if (points.length >= 2) segments.add(points);
    }
    return segments;
  } on Object {
    // Malformed JSON — treat as no path (never throw into the render path).
    return const [];
  }
}
