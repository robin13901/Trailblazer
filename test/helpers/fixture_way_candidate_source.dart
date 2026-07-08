// Phase 4 rescope Wave 2 (Plan 04-15):
// Deterministic, offline [WayCandidateSource] implementation for tests.
//
// Loads a pre-baked list of [WayCandidate]s (typically decoded from one of
// the gzipped Overpass fixtures under `test/fixtures/overpass/`) and answers
// bbox queries by filtering the pre-loaded list.
//
// **Test-only** — must NOT be imported from `lib/`. The grep tripwire in the
// plan is: `grep -rn FixtureWayCandidateSource lib/` returns nothing.

import 'dart:convert';
import 'dart:io';

import 'package:auto_explore/features/matching/data/overpass_response_parser.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';

class FixtureWayCandidateSource implements WayCandidateSource {
  FixtureWayCandidateSource({required List<WayCandidate> ways})
      : _ways = List.unmodifiable(ways);

  /// Load a fixture from a gzipped Overpass JSON blob on disk.
  static Future<FixtureWayCandidateSource> fromGzippedOverpassJson(
    String path,
  ) async {
    final bytes = await File(path).readAsBytes();
    final decompressed = utf8.decode(gzip.decode(bytes));
    return FixtureWayCandidateSource(
      ways: const OverpassResponseParser().parseWays(decompressed),
    );
  }

  final List<WayCandidate> _ways;

  @override
  Future<List<WayCandidate>> fetchWaysInBbox({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    bool throwOnError = true,
  }) async {
    return _ways.where((w) {
      return w.geometry.any(
        (p) =>
            p.latitude >= minLat &&
            p.latitude <= maxLat &&
            p.longitude >= minLon &&
            p.longitude <= maxLon,
      );
    }).toList();
  }
}
