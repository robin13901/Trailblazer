// Trailblazer Phase 6, Plan 06-06 Task 1:
// GoldenFixtureExporter — reads a recorded trip's raw state and writes the
// 3-file golden-corpus fixture format under `<AppDocs>/golden_export/<slug>/`.
//
// The three files match `test/features/matching/golden_corpus_test.dart`
// (and `test/fixtures/golden_trips/README.md`) byte-schema exactly:
//
//   * gps_trace.json     — JSON array of {lat, lon, accuracy, speedKmh, ts}
//                          read back by golden_corpus_test's `_loadGpsTrace`.
//   * ways.json.gz       — gzipped Overpass-shaped JSON envelope
//                          ({"elements":[{"type":"way",...}]}), parsed back by
//                          `FixtureWayCandidateSource.fromGzippedOverpassJson`.
//   * expected_ways.json — JSON array of {wayId, direction} — the interval
//                          way-ID sequence the matcher must reproduce.
//
// **Ways format decision (Issue 7 — Path B "re-gzip"):**
// The exporter serializes the RAW ways for the trip's *bbox* — obtained via
// `WayCandidateSource.fetchWaysInBbox` — NOT the corridor-filtered subset the
// TripMatchCoordinator feeds the HMM matcher. Capturing the full bbox input is
// what makes the fixture a faithful regression: the corpus test re-derives the
// corridor filter itself. Because `fetchWaysInBbox` returns parsed
// `WayCandidate`s (not the original Overpass bytes, which are stored per-tile
// in the cache and can't be concatenated into one valid envelope), we
// re-emit an Overpass-shaped JSON envelope from the candidates and gzip it.
// The exporter's own round-trip test proves this re-emitted shape parses
// cleanly through the exact corpus parser, so Path A/B drift fails loudly.

import 'dart:convert';
import 'dart:io';

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Slug format enforced on export directory names: `NNN_lower_snake` — a
/// zero-padded 3-digit index, an underscore, then `[a-z0-9_]+`.
/// e.g. `002_kleinheubach_roundabout`.
final RegExp kGoldenSlugPattern = RegExp(r'^\d{3}_[a-z0-9_]+$');

/// Exports a recorded trip's raw state as a golden-corpus fixture directory.
///
/// See the file header for the format contract. Throws a [DomainError]
/// ([StorageError] for slug / filesystem faults; propagated [NetworkError]
/// from the way source when the bbox ways can't be resolved) on failure.
class GoldenFixtureExporter {
  GoldenFixtureExporter({
    required TripsDao tripsDao,
    required WayCandidateSource waySource,
    required DrivenWayIntervalsDao intervalsDao,
    Future<Directory> Function()? appDocsFactory,
  })  : _tripsDao = tripsDao,
        _waySource = waySource,
        _intervalsDao = intervalsDao,
        // The plan sketch typed this seam `Directory Function()?`, but
        // `path_provider`'s resolver is async — so the seam is a
        // `Future<Directory> Function()`. Tests pass `() async => tempDir`.
        _appDocsFactory = appDocsFactory ?? getApplicationDocumentsDirectory;

  final TripsDao _tripsDao;
  final WayCandidateSource _waySource;
  final DrivenWayIntervalsDao _intervalsDao;
  final Future<Directory> Function() _appDocsFactory;

  /// Exports the fixture for [tripId] under a directory named [slug].
  ///
  /// Returns the absolute path to the created directory. If a directory with
  /// the same slug already exists it is removed first, so the export is a
  /// clean overwrite (no stale files survive).
  Future<String> export({required int tripId, required String slug}) async {
    if (!kGoldenSlugPattern.hasMatch(slug)) {
      throw StorageError(
        'Invalid fixture slug "$slug" — expected NNN_lower_snake '
        '(e.g. 002_kleinheubach_roundabout).',
      );
    }

    try {
      final points = await _tripsDao.listPointsForTrip(tripId);
      if (points.isEmpty) {
        throw StorageError('Trip $tripId has no GPS points to export.');
      }

      final bbox = _bboxOfPoints(points);
      final ways = await _waySource.fetchWaysInBbox(
        minLat: bbox.minLat,
        minLon: bbox.minLon,
        maxLat: bbox.maxLat,
        maxLon: bbox.maxLon,
      );
      final intervals = await _intervalsDao.getByTrip(tripId);

      final appDocs = await _appDocsFactory();
      final dir = Directory(p.join(appDocs.path, 'golden_export', slug));
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
      await dir.create(recursive: true);

      await _writeStringAtomic(
        p.join(dir.path, 'gps_trace.json'),
        _prettyJson(_gpsTraceJson(points)),
      );
      await _writeBytesAtomic(
        p.join(dir.path, 'ways.json.gz'),
        gzip.encode(utf8.encode(jsonEncode(_overpassEnvelope(ways)))),
      );
      await _writeStringAtomic(
        p.join(dir.path, 'expected_ways.json'),
        _prettyJson(_expectedWaysJson(intervals)),
      );

      return dir.path;
    } on DomainError {
      rethrow;
    } on Object catch (e, st) {
      throw DomainError.wrap(e, st);
    }
  }

  // --- Serialization ------------------------------------------------------

  List<Map<String, dynamic>> _gpsTraceJson(List<TripPoint> points) {
    return [
      for (final pt in points)
        <String, dynamic>{
          'lat': pt.lat,
          'lon': pt.lon,
          'accuracy': pt.accuracyMeters,
          'speedKmh': pt.speedKmh,
          'ts': pt.ts.toUtc().toIso8601String(),
        },
    ];
  }

  List<Map<String, dynamic>> _expectedWaysJson(
    List<DrivenWayInterval> intervals,
  ) {
    return [
      for (final i in intervals)
        <String, dynamic>{'wayId': i.wayId, 'direction': i.direction},
    ];
  }

  /// Rebuilds an Overpass `out geom;`-shaped envelope from parsed candidates
  /// so the corpus parser round-trips the export unchanged.
  Map<String, dynamic> _overpassEnvelope(List<WayCandidate> ways) {
    return <String, dynamic>{
      'version': 0.6,
      'generator': 'trailblazer-golden-export',
      'elements': [
        for (final w in ways)
          <String, dynamic>{
            'type': 'way',
            'id': w.wayId,
            'geometry': [
              for (final pt in w.geometry)
                <String, dynamic>{'lat': pt.latitude, 'lon': pt.longitude},
            ],
            'tags': _wayTags(w),
          },
      ],
    };
  }

  Map<String, dynamic> _wayTags(WayCandidate w) {
    final tags = <String, dynamic>{'highway': w.highwayClass};
    if (w.name != null) tags['name'] = w.name;
    if (w.ref != null) tags['ref'] = w.ref;
    switch (w.oneway) {
      case OnewayDirection.forward:
        tags['oneway'] = 'yes';
      case OnewayDirection.backward:
        tags['oneway'] = '-1';
      case OnewayDirection.no:
        break;
    }
    if (w.maxspeedKmh != null) tags['maxspeed'] = '${w.maxspeedKmh}';
    return tags;
  }

  // --- Filesystem helpers -------------------------------------------------

  ({double minLat, double minLon, double maxLat, double maxLon}) _bboxOfPoints(
    List<TripPoint> points,
  ) {
    var minLat = 90.0;
    var minLon = 180.0;
    var maxLat = -90.0;
    var maxLon = -180.0;
    for (final pt in points) {
      if (pt.lat < minLat) minLat = pt.lat;
      if (pt.lat > maxLat) maxLat = pt.lat;
      if (pt.lon < minLon) minLon = pt.lon;
      if (pt.lon > maxLon) maxLon = pt.lon;
    }
    return (minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon);
  }

  String _prettyJson(Object value) =>
      const JsonEncoder.withIndent('  ').convert(value);

  Future<void> _writeStringAtomic(String path, String contents) async {
    final tmp = File('$path.tmp');
    await tmp.writeAsString(contents, flush: true);
    await tmp.rename(path);
  }

  Future<void> _writeBytesAtomic(String path, List<int> bytes) async {
    final tmp = File('$path.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(path);
  }
}
