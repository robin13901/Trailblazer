// Trailblazer Phase 4 rescope, Plan 04-16 (Wave 3):
// Runtime user-triggered refresh of the bundled Germany admin polygon
// asset. Downloads a fresh copy via Overpass, replaces the app-docs-dir
// override file, bumps AppPrefs.adminBundleVersion, invalidates the
// in-memory AdminRegionLookup cache.
//
// Shared code (Overpass fetch + Douglas-Peucker simplification) lives in
// `packages/admin_geometry/` — single source of truth. The bundled asset it
// refreshes is now produced by `tool/region_stats/build_region_data.py`
// (the old Dart osm_pipeline was deleted 2026-07-17).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:admin_geometry/admin_geometry.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/core/prefs/app_prefs.dart';
import 'package:auto_explore/features/admin/data/admin_region_lookup.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

/// Coordinates a runtime refresh of the bundled admin-polygon asset.
class AdminBundleRefresher {
  AdminBundleRefresher({
    required AdminPolygonDownloader downloader,
    required AdminPolygonSimplifier simplifier,
    required AppPrefs appPrefs,
    required AdminRegionLookup lookup,
    Future<Directory> Function()? docsDirLoader,
  })  : _downloader = downloader,
        _simplifier = simplifier,
        _appPrefs = appPrefs,
        _lookup = lookup,
        _docsDirLoader = docsDirLoader ?? getApplicationDocumentsDirectory;

  final AdminPolygonDownloader _downloader;
  final AdminPolygonSimplifier _simplifier;
  final AppPrefs _appPrefs;
  final AdminRegionLookup _lookup;
  final Future<Directory> Function() _docsDirLoader;

  static final _log = Logger('AdminBundleRefresher');

  /// Full refresh cycle. Any transport / IO failure is wrapped as a
  /// `DomainError` at the boundary (STATE 01-04). On success, bumps
  /// `AppPrefs.adminBundleVersion` and invalidates the lookup cache so
  /// the next `regionAt` reloads.
  Future<void> refreshFromOverpass() async {
    try {
      _log.info('Refresh started');
      final raw = await _downloader.fetchDeAdminRelations();
      final fc = _simplifier.assembleAndSimplify(raw);
      final bytes = utf8.encode(jsonEncode(fc));
      final gzipped = gzip.encode(bytes);

      final docsDir = await _docsDirLoader();
      final file = File('${docsDir.path}/admin/germany_admin.geojson.gz');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(gzipped);

      final version = DateTime.now().toIso8601String();
      await _appPrefs.setAdminBundleVersion(version);
      _lookup.invalidate();
      _log.info(
        'Refresh complete: ${gzipped.length} bytes, version=$version',
      );
    } on DomainError {
      rethrow;
    } on Object catch (e, st) {
      _log.severe('Refresh failed', e, st);
      throw DomainError.wrap(e, st);
    }
  }
}
