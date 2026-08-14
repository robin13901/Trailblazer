// Trailblazer 2026-08-13 (durable coverage-line cache):
// coverage_line_codec — JSON (de)serialization for the complete clipped
// coverage line stored as one blob in `coverage_line_cache.lines_json`.
//
// Shape on disk:
//   {"v":1,"ways":[{"id":<wayId>,"g":[[lat,lon],…],"f":<fraction>,"full":0|1}]}
//
// This serializes the EXACT `List<CoverageWay>` that `clipDrivenWays` produces
// (wayId + geometry + CoverageDatum), so decode(encode(x)) reproduces the same
// rendered line bit-for-bit — the durable blob is a pure storage layer, it does
// not change how the line is computed or drawn.

import 'dart:convert';

import 'package:auto_explore/features/coverage/data/coverage_overlay_data.dart';
import 'package:auto_explore/features/coverage/domain/coverage_datum.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

/// Current on-disk blob format version.
const int kCoverageLineCodecVersion = 1;

/// Encodes [ways] to a compact JSON string for durable storage.
///
/// Degenerate ways (< 2 points) are dropped — they never render anyway and
/// keeping them would only bloat the blob.
String encodeCoverageLine(List<CoverageWay> ways) {
  return jsonEncode({
    'v': kCoverageLineCodecVersion,
    'ways': [
      for (final w in ways)
        if (w.geometry.length >= 2)
          {
            'id': w.wayId,
            'g': [
              for (final p in w.geometry) [p.latitude, p.longitude],
            ],
            'f': w.datum.fraction,
            'full': w.datum.isFull ? 1 : 0,
          },
    ],
  });
}

/// Decodes a `coverage_line_cache.lines_json` blob back to [CoverageWay]s.
///
/// Returns an empty list for null, empty, or malformed input — the caller
/// treats "no line" and "unparseable line" identically (recompute + render
/// nothing meanwhile). Never throws into the render path.
List<CoverageWay> decodeCoverageLine(String? json) {
  if (json == null || json.isEmpty) return const [];
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map) return const [];
    final rawWays = decoded['ways'];
    if (rawWays is! List) return const [];

    final out = <CoverageWay>[];
    for (final raw in rawWays) {
      if (raw is! Map) continue;
      final id = raw['id'];
      final g = raw['g'];
      if (id is! int || g is! List) continue;

      final geometry = <LatLng>[];
      for (final p in g) {
        if (p is List && p.length >= 2) {
          final lat = (p[0] as num).toDouble();
          final lon = (p[1] as num).toDouble();
          geometry.add(LatLng(lat, lon));
        }
      }
      if (geometry.length < 2) continue; // degenerate — skip

      final fraction = (raw['f'] as num?)?.toDouble() ?? 1.0;
      final isFull = (raw['full'] as num?)?.toInt() != 0;
      out.add(
        CoverageWay(
          wayId: id,
          geometry: geometry,
          datum: CoverageDatum(fraction: fraction, isFull: isFull),
        ),
      );
    }
    return out;
  } on Object {
    // Malformed JSON — treat as no line (never throw into the render path).
    return const [];
  }
}
