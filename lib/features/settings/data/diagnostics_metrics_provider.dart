// Phase 9 (Plan 09-06): Diagnostics metrics accessor for the tracking HUD.
//
// Surfaces matcher queue depth (from [PendingRoadFetchesDao]) and Overpass
// tile cache hit/miss counters (from [OverpassWayCandidateSource]) in a
// single value type, keeping the domain-pure [TrackingDiagnostics] DTO
// untouched.
//
// Exposed as a top-level async function that the HUD's [_refreshAsync] tick
// invokes — matching the existing FgbState / PermissionService polling model
// rather than adding another Riverpod watch cycle.

import 'package:auto_explore/core/db/app_database_providers.dart';
import 'package:auto_explore/features/matching/data/matching_providers.dart';
import 'package:auto_explore/features/matching/data/overpass_way_candidate_source.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Snapshot of the two HUD metrics added in Plan 09-06.
///
/// [matcherQueueDepth] — number of pending road-fetch rows in the DB queue
///   (trips awaiting an Overpass refetch after a network failure).
///
/// [cacheHits] / [cacheMisses] — tile-level cache counters from the
///   main-isolate [OverpassWayCandidateSource] instance. Only this instance's
///   counters are surfaced; the matcher isolate holds its own copy whose
///   counters are not accessible from the UI.
///
/// [cacheHitRate] — null until at least one tile has been classified as hit
///   or miss (distinguishes "no data yet" from "0 % hit rate").
class DiagnosticsMetrics {
  const DiagnosticsMetrics({
    required this.matcherQueueDepth,
    required this.cacheHits,
    required this.cacheMisses,
    required this.cacheHitRate,
  });

  final int matcherQueueDepth;
  final int cacheHits;
  final int cacheMisses;
  final double? cacheHitRate;
}

/// Read the current [DiagnosticsMetrics] snapshot from Riverpod providers.
///
/// Intended to be called from the HUD's async refresh tick — it does a single
/// async DB read and two synchronous provider reads with no side effects.
///
/// If the `wayCandidateSourceProvider` is overridden with a fixture that is
/// not an [OverpassWayCandidateSource], cacheHits/cacheMisses default to 0
/// and cacheHitRate to null.
Future<DiagnosticsMetrics> readDiagnosticsMetrics(WidgetRef ref) async {
  final depth = (await ref
          .read(appDatabaseProvider)
          .pendingRoadFetchesDao
          .listPending())
      .length;

  final src = ref.read(wayCandidateSourceProvider);
  final hits = src is OverpassWayCandidateSource ? src.cacheHits : 0;
  final misses = src is OverpassWayCandidateSource ? src.cacheMisses : 0;
  final rate = src is OverpassWayCandidateSource ? src.cacheHitRate : null;

  return DiagnosticsMetrics(
    matcherQueueDepth: depth,
    cacheHits: hits,
    cacheMisses: misses,
    cacheHitRate: rate,
  );
}
