/// Shared pure-Dart admin-polygon primitives.
///
/// Used by:
///   - `tool/osm_pipeline/bin/fetch_admin_polygons.dart` (dev CLI producing
///     the committed `assets/admin/germany_admin.geojson.gz` bundle).
///   - `lib/features/admin/data/admin_bundle_refresher.dart` (runtime
///     user-triggered refresh path in the main Flutter app).
///
/// Single source of truth — do NOT duplicate the Overpass query, the
/// multipolygon assembly, or the Douglas-Peucker tolerances anywhere else.
library;

export 'src/admin_polygon_downloader.dart';
export 'src/admin_polygon_simplifier.dart';
