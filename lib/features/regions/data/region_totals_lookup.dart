// Trailblazer Phase 10, Plan 10-04:
// RegionTotalsLookup — loads the bundled per-region total road lengths from
// `assets/admin/region_totals.json.gz` once off the main isolate and provides
// an O(1) osm_id→meters lookup.
//
// Load posture mirrors AdminRegionLookup EXACTLY:
//   1. Read raw gzipped bytes on the main isolate via rootBundle.load (asset
//      bundle is not reachable from a spawned isolate — RESEARCH Pitfall 1).
//   2. Pass bytes to compute() for the heavy work off-isolate:
//      gzip.decode → utf8.decode → jsonDecode → Map<String,double>.
//   3. Cache the result; a single in-flight future collapses concurrent callers
//      into one parse.
//
// JSON shape (produced by Stage H, tool/osm_pipeline):
//   { "3600012345": 12345.6, "3600067890": 5678.9, … }
// Keys are OSM relation IDs as STRINGS — identical to coverage_cache.region_id
// which uses osmId.toString() (RESEARCH.md line 491, globally unique).
//
// Physical asset note: `assets/admin/region_totals.json.gz` is a DEFERRED DATA
// DEPENDENCY. The file does not exist on the dev machine until the Geofabrik
// Germany PBF is processed via Stage H (see 10-03-SUMMARY.md checkpoint). The
// loader handles the missing file gracefully: if the asset is absent, load()
// returns null and totalFor() always returns null — the recompute() pass then
// writes null for real_total_length_m and the region card shows "—".
// No code change is needed when the asset later arrives; the loader picks it
// up at runtime from the already-declared assets/admin/ directory in pubspec.

import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Path of the bundled per-region totals asset in the app rootBundle.
const String kRegionTotalsAssetPath = 'assets/admin/region_totals.json.gz';

/// Loads and caches the bundled per-region total Kfz road lengths.
///
/// Call [ensureLoaded] before the first [totalFor] call to guarantee the
/// table is available (idempotent after the first call, returns immediately).
/// In a Riverpod graph, inject via [regionTotalsLookupProvider] — the provider
/// calls nothing at construction time; the CoverageComputeService calls
/// ensureLoaded() as part of its recompute() warm-up sequence.
class RegionTotalsLookup {
  RegionTotalsLookup({AssetBundle? bundle})
      : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;

  /// Parsed map: osm_id string → total road length in meters.
  /// Null means the asset has not been loaded yet (or was absent/malformed).
  Map<String, double>? _totals;

  /// In-flight load future — single-flight guard so concurrent callers
  /// (e.g. parallel recompute + a UI warm-up) share one parse.
  Future<void>? _loading;

  /// Load and parse the asset once. Subsequent calls return immediately.
  ///
  /// If the asset is absent (not yet regenerated from the Germany PBF),
  /// [_totals] stays null and [totalFor] returns null for all queries.
  Future<void> ensureLoaded() {
    if (_totals != null) return Future<void>.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      Uint8List bytes;
      try {
        final byteData = await _bundle.load(kRegionTotalsAssetPath);
        bytes = byteData.buffer
            .asUint8List(byteData.offsetInBytes, byteData.lengthInBytes);
      } on Object {
        // Asset absent (deferred PBF checkpoint not yet run) — leave _totals
        // null so totalFor() returns null gracefully.
        return;
      }
      _totals = await compute(_parseTotalsBundle, bytes);
    } finally {
      _loading = null;
    }
  }

  /// Returns the bundled total Kfz road length (meters) for the given OSM
  /// relation id string, or `null` when the table is not loaded or the id is
  /// not present in the bundle (e.g. regions outside Germany, or the asset is
  /// still absent from this build).
  double? totalFor(String osmId) => _totals?[osmId];

  /// Clears the in-memory cache. Used in tests to reset state between cases.
  void invalidate() {
    _totals = null;
    _loading = null;
  }

  /// Test-visible: number of entries in the loaded table (0 if not loaded).
  int get entryCount => _totals?.length ?? 0;
}

/// Isolate entry point: inflate + parse the gzipped JSON bundle into a
/// String→double map. Runs via [compute] on a background isolate. Takes the
/// raw gzipped bytes — the asset bundle is not reachable off the UI isolate,
/// so the caller reads the bytes first and hands them over here.
Map<String, double> _parseTotalsBundle(Uint8List bytes) {
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

/// Singleton `RegionTotalsLookup` — plain `Provider<T>` per STATE 01-01 (no
/// @Riverpod codegen). The lookup loads lazily on the first `ensureLoaded()`
/// call from `CoverageComputeService.recompute()`.
final regionTotalsLookupProvider = Provider<RegionTotalsLookup>((ref) {
  return RegionTotalsLookup();
});
