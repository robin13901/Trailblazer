// Pure region-totals parsing (2026-07-22) — extracted from region_totals_lookup.dart
// so BOTH the main-isolate lookup AND the coverage-compute worker isolate can
// parse the bundled per-region totals asset without importing Flutter.
//
// STRICTLY PURE + isolate-safe: dart:convert, dart:io(gzip), dart:typed_data
// only. NO Flutter, NO Drift, NO rootBundle. Caller reads the raw gzipped bytes
// on the main isolate and hands them to [parseRegionTotalsBundle].

import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

/// Inflate + parse the gzipped JSON bundle into a `String→double` map
/// (osm_id string → total Kfz road length in meters).
///
/// Top-level so it runs via `compute()` (main) OR directly inside a worker
/// isolate. Corrupt/unexpected bytes → empty map (never throws).
Map<String, double> parseRegionTotalsBundle(Uint8List bytes) {
  try {
    final decoded = utf8.decode(gzip.decode(bytes));
    final json = jsonDecode(decoded);
    if (json is! Map<String, dynamic>) return const {};
    final out = <String, double>{};
    for (final entry in json.entries) {
      final v = entry.value;
      if (v is num) out[entry.key] = v.toDouble();
    }
    return out;
    // Corrupt/unexpected bytes: return empty rather than crashing the lookup.
    // ignore: avoid_catches_without_on_clauses
  } catch (_) {
    return const {};
  }
}
